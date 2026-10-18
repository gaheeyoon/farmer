/* One checkout can contain multiple delivery orders. Supabase validates all totals. */
(() => {
  "use strict";
  const $ = (id) => document.getElementById(id),
    api = window.FarmerAPI,
    form = $("order-form"),
    code = $("discount-code");
  const cards = () => [...$("deliveries").querySelectorAll(".delivery-card")];
  const field = (card, key) => card.querySelector(`[data-field="${key}"]`);
  const money = (n) => Number(n).toLocaleString("ko-KR") + "원";
  let products = [],
    shipping = 0,
    discount = null,
    revision = 0,
    sequence = 0,
    prepared = null,
    receipt = null,
    locked = false,
    submitting = false,
    sdkPromise = null,
    displayedTotal = 0,
    preparedQuote = null,
    lookupRevision = 0,
    lookupQuery = null,
    lookupOffset = null,
    lookupBusy = false;
  const requests = new Map();
  const message = (id, text) => {
    $(id).textContent = text;
  };
  const phoneDigits = (value) => value.replace(/\D/g, "").slice(0, 11);
  function formatPhone(value) {
    const d = phoneDigits(value),
      prefix = d.startsWith("02") ? 2 : 3;
    if (d.length <= prefix) return d;
    const rest = d.slice(prefix),
      middle = rest.length > 7 ? 4 : 3;
    return (
      d.slice(0, prefix) +
      "-" +
      (rest.length <= middle
        ? rest
        : rest.slice(0, middle) + "-" + rest.slice(middle))
    );
  }
  function phoneInput(input, e) {
    const start = input.selectionStart ?? input.value.length,
      old = input.value;
    let count = old.slice(0, start).replace(/\D/g, "").length;
    let digits = phoneDigits(old);
    input.value = formatPhone(digits);
    let pos = 0,
      seen = 0;
    while (pos < input.value.length && seen < count) {
      if (/\d/.test(input.value[pos])) seen++;
      pos++;
    }
    input.setSelectionRange(pos, pos);
  }
  const validPhone = (value) => /^0\d{8,10}$/.test(value.replace(/\D/g, ""));
  const ordererStorageKey = "farmer-orderer:v1";
  function saveOrderer() {
    const name = $("customer").value.trim().slice(0, 40);
    const phone = phoneDigits($("phone").value);
    try {
      if (name || phone) localStorage.setItem(ordererStorageKey, JSON.stringify({ name, phone }));
      else localStorage.removeItem(ordererStorageKey);
    } catch { /* Ordering remains available when browser storage is blocked. */ }
  }
  function restoreOrderer() {
    try {
      const saved = JSON.parse(localStorage.getItem(ordererStorageKey) || "null");
      if (!saved || typeof saved !== "object" || Array.isArray(saved)) return;
      if (typeof saved.name === "string") $("customer").value = saved.name.slice(0, 40);
      if (typeof saved.phone === "string") $("phone").value = formatPhone(saved.phone);
    } catch { /* Ignore unavailable storage or an invalid saved value. */ }
  }
  const deliveries = () =>
    cards().map((c) =>
      Object.fromEntries(
        [...c.querySelectorAll("[data-field]")].map((el) => [
          el.dataset.field,
          el.dataset.field === "quantity" ? Number(el.value) : el.value.trim(),
        ]),
      ),
    );
  const quoteItems = () =>
    deliveries().map(({ product_id, quantity }) => ({ product_id, quantity }));
  function totals(q) {
    const lines = quoteItems(),
      valid = lines.every(
        (d) =>
          products.some((p) => p.id === d.product_id) &&
          Number.isInteger(d.quantity) &&
          d.quantity >= 1 &&
          d.quantity <= 99,
      );
    const subtotal =
        q?.subtotal ??
        lines.reduce(
          (sum, d) =>
            sum +
            (products.find((p) => p.id === d.product_id)?.price || 0) *
              d.quantity,
          0,
        ),
      amount =
        q?.discount_amount ??
        (discount
          ? discount.percent
            ? lines.reduce((sum, d) => sum + Math.floor((products.find((p) => p.id === d.product_id)?.price || 0) * d.quantity * discount.percent / 100), 0)
            : Math.min(subtotal, discount.amount)
          : 0),
      fee = q?.shipping_fee ?? cards().length * shipping;
    displayedTotal = q?.total ?? subtotal - amount + fee;
    message("subtotal-amount", valid ? money(subtotal) : "—");
    message("shipping-label", `배송비 · ${cards().length}곳`);
    message("shipping-amount", fee === 0 ? "무료" : money(fee));
    $("discount-line").hidden = !discount;
    message("discount-amount", "−" + money(amount));
    message(
      "total-amount",
      valid
        ? money(q?.total ?? subtotal - amount + fee)
        : "상품과 수량을 확인해 주세요",
    );
  }
  function stale() {
    revision++;
    prepared = null;
    preparedQuote = null;
    receipt = null;
    $("payment-guide").hidden = true;
    $("summary-panel").hidden = true;
    $("receipt-cards").replaceChildren();
    message("payment-amount", "");
  }
  function clearDiscount() {
    discount = null;
    message("discount-status", "");
    message("discount-error", "");
    code.removeAttribute("aria-invalid");
    $("remove-discount").hidden = true;
    totals();
  }
  function refreshCards() {
    cards().forEach((c, i) => {
      c.querySelector("[data-number]").textContent = String(i + 1);
      c.querySelector("[data-remove]").hidden = cards().length === 1;
      c.querySelector("[data-search]").setAttribute(
        "aria-label",
        `받는 분 ${i + 1} 주소 검색`,
      );
    });
    message("delivery-count", `배송지 ${cards().length}곳`);
    $("add-delivery").disabled = locked || cards().length >= 20;
    totals();
  }
  function options(select) {
    const current = select.value;
    select.replaceChildren(
      ...products.map((p) => {
        const o = document.createElement("option");
        o.value = p.id;
        o.textContent =
          p.name + " · " + money(p.price) + (p.available ? "" : " · 품절");
        o.defaultSelected = p.id === "hopungmi-5kg";
        o.disabled = !p.available;
        return o;
      }),
    );
    select.value = products.some((p) => p.id === current && p.available)
      ? current
      : products.find((p) => p.id === "hopungmi-5kg" && p.available)?.id ||
        products.find((p) => p.available)?.id ||
        "";
  }
  function addCard(focus = false) {
    if (locked || cards().length >= 20) return;
    const fragment = $("delivery-template").content.cloneNode(true),
      card = fragment.querySelector(".delivery-card"),
      id = ++sequence;
    card.dataset.key = String(id);
    card.querySelectorAll("[data-field]").forEach((el) => {
      const key = el.dataset.field;
      el.id = `delivery-${id}-${key}`;
      const label = card.querySelector(`[data-label="${key}"]`);
      label.htmlFor = el.id;
      const error = card.querySelector(`[data-error="${key}"]`);
      if (error) {
        error.id = el.id + "-error";
        el.setAttribute("aria-describedby", error.id);
      }
      if (el.autocomplete)
        el.autocomplete = `section-delivery${id} shipping ${el.autocomplete}`;
    });
    options(field(card, "product_id"));
    $("deliveries").append(fragment);
    refreshCards();
    if (focus) field(card, "recipient_name").focus();
  }
  function closeSearch(card, focus = false) {
    card.querySelector("[data-search-panel]").hidden = true;
    if (focus) card.querySelector("[data-search]").focus();
  }
  function postcodeSDK() {
    if (window.kakao?.Postcode || window.daum?.Postcode)
      return Promise.resolve();
    if (sdkPromise) return sdkPromise;
    sdkPromise = new Promise((resolve, reject) => {
      const script = document.createElement("script"),
        timer = setTimeout(() => fail(), 15000);
      const fail = () => {
        clearTimeout(timer);
        script.remove();
        sdkPromise = null;
        reject(
          new Error(
            "주소 검색에 연결하지 못했습니다. 다시 시도하거나 아래에서 직접 입력해 주세요.",
          ),
        );
      };
      script.src =
        "https://t1.kakaocdn.net/mapjsapi/bundle/postcode/prod/postcode.v2.js";
      script.onload = () => {
        clearTimeout(timer);
        if (window.kakao?.Postcode || window.daum?.Postcode) resolve();
        else fail();
      };
      script.onerror = fail;
      document.head.append(script);
    });
    return sdkPromise;
  }
  async function searchAddress(card) {
    const panel = card.querySelector("[data-search-panel]"),
      status = card.querySelector("[data-search-status]"),
      button = card.querySelector("[data-search]");
    panel.hidden = false;
    status.textContent = "주소 검색을 불러오고 있습니다.";
    button.disabled = true;
    try {
      await postcodeSDK();
      if (!card.isConnected || locked || panel.hidden) return;
      const Postcode = window.kakao?.Postcode || window.daum.Postcode,
        container = card.querySelector("[data-postcode-embed]");
      container.replaceChildren();
      container.style.height = "450px";
      new Postcode({
        width: "100%",
        height: "100%",
        onresize: (size) => {
          container.style.height = size.height + "px";
        },
        oncomplete: (data) => {
          if (!card.isConnected || locked) return;
          field(card, "postal_code").value = data.zonecode;
          field(card, "address").value =
            data.userSelectedType === "R"
              ? data.roadAddress
              : data.jibunAddress;
          field(card, "address_detail").value = "";
          field(card, "postal_code").readOnly = true;
          field(card, "address").readOnly = true;
          stale();
          closeSearch(card);
          field(card, "address_detail").focus();
        },
      }).embed(container);
      status.textContent = "도로명, 건물명 또는 지번으로 검색해 주세요.";
    } catch (e) {
      status.textContent = e.message;
    } finally {
      button.disabled = locked;
    }
  }
  $("deliveries").addEventListener("click", (e) => {
    const card = e.target.closest(".delivery-card");
    if (!card || locked) return;
    if (e.target.closest("[data-remove]")) {
      const previous = card.previousElementSibling || card.nextElementSibling;
      card.remove();
      stale();
      refreshCards();
      previous?.querySelector('[data-field="recipient_name"]').focus();
    } else if (e.target.closest("[data-copy]")) {
      field(card, "recipient_name").value = $("customer").value.trim();
      field(card, "recipient_phone").value = formatPhone($("phone").value);
      stale();
    } else if (e.target.closest("[data-search]")) searchAddress(card);
    else if (e.target.closest("[data-close-search]")) closeSearch(card, true);
    else if (e.target.closest("[data-manual]")) {
      closeSearch(card);
      field(card, "postal_code").readOnly = false;
      field(card, "address").readOnly = false;
      field(card, "postal_code").focus();
    }
  });
  $("add-delivery").addEventListener("click", () => {
    if (!locked) {
      addCard(true);
      stale();
    }
  });
  function validate() {
    let errors = [];
    const check = (el, errorEl, text) => {
      if (errorEl) errorEl.textContent = text;
      el.setAttribute("aria-invalid", String(!!text));
      if (text) errors.push({ el, text });
    };
    check(
      $("customer"),
      $("customer-error"),
      $("customer").value.trim() ? "" : "주문자 성함을 입력해 주세요.",
    );
    check(
      $("phone"),
      $("phone-error"),
      validPhone($("phone").value) ? "" : "주문자 연락처를 확인해 주세요.",
    );
    cards().forEach((c, i) => {
      const d = deliveries()[i];
      for (const [key, text] of Object.entries({
        product_id: products.some((p) => p.id === d.product_id && p.available)
          ? ""
          : "주문 가능한 상품을 선택해 주세요.",
        quantity:
          Number.isInteger(d.quantity) && d.quantity >= 1 && d.quantity <= 99
            ? ""
            : "수량은 1~99 사이의 정수로 입력해 주세요.",
        recipient_name: d.recipient_name ? "" : "받는 분 성함을 입력해 주세요.",
        recipient_phone: validPhone(d.recipient_phone)
          ? ""
          : "받는 분 연락처를 확인해 주세요.",
        postal_code: /^\d{5}$/.test(d.postal_code)
          ? ""
          : "5자리 우편번호를 입력하거나 주소를 검색해 주세요.",
        address: d.address.length >= 5 ? "" : "배송 주소를 확인해 주세요.",
      }))
        check(
          field(c, key),
          c.querySelector(`[data-error="${key}"]`),
          text ? `${i + 1}번 배송지: ${text}` : "",
        );
    });
    check(
      code,
      $("discount-error"),
      code.value.trim() && !discount
        ? "할인코드를 적용하거나 입력란을 비워 주세요."
        : "",
    );
    check(
      $("order-check"),
      $("order-check-error"),
      $("order-check").checked
        ? ""
        : "주문 정보 확인과 개인정보 수집·이용에 동의해 주세요.",
    );
    $("form-errors").hidden = !errors.length;
    if (errors.length) {
      message(
        "form-errors",
        `${errors.length}개 항목을 확인해 주세요. ${errors[0].text}`,
      );
      errors[0].el.focus();
      return false;
    }
    return true;
  }
  async function applyDiscount() {
    if (locked) return;
    stale();
    clearDiscount();
    const normalized = code.value.normalize("NFKC").trim().toUpperCase(),
      version = revision;
    if (!normalized) {
      message("discount-error", "할인코드를 입력해 주세요.");
      return;
    }
    $("apply-discount").disabled = true;
    try {
      const q = await api.rpc("farmer_quote_batch", {
        p_deliveries: quoteItems(),
        p_code: normalized,
      });
      if (version !== revision) return;
      discount = { code: q.discount_code, amount: q.discount_amount, percent: q.discount_percent || 0 };
      code.value = q.discount_code;
      message(
        "discount-status",
        `${q.discount_code} · ${q.discount_percent ? q.discount_percent + "%" : money(q.discount_amount)} 할인 적용`,
      );
      $("remove-discount").hidden = false;
      totals(q);
    } catch (e) {
      if (version === revision) message("discount-error", e.message);
    } finally {
      if (!locked) $("apply-discount").disabled = false;
    }
  }
  $("apply-discount").addEventListener("click", applyDiscount);
  code.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.isComposing) {
      e.preventDefault();
      applyDiscount();
    }
  });
  $("remove-discount").addEventListener("click", () => {
    if (!locked) {
      code.value = "";
      stale();
      clearDiscount();
    }
  });
  form.addEventListener("input", (e) => {
    if (locked) return;
    if (e.target.matches("[data-phone]")) phoneInput(e.target, e);
    if (e.target.id === "customer" || e.target.id === "phone") saveOrderer();
    if (e.target.matches('[data-field="postal_code"]'))
      e.target.value = e.target.value.replace(/\D/g, "").slice(0, 5);
    stale();
    if (e.target === code) clearDiscount();
    totals();
    $("form-errors").hidden = true;
  });
  form.addEventListener("change", (e) => {
    if (!locked && (e.target.id === "customer" || e.target.id === "phone")) {
      if (e.target.id === "phone") e.target.value = formatPhone(e.target.value);
      saveOrderer();
      stale();
    }
    if (!locked && e.target.matches("select")) {
      stale();
      totals();
    }
  });
  function lock(value) {
    locked = value;
    form
      .querySelectorAll("input,select,textarea,button")
      .forEach((el) => (el.disabled = value));
    if (!value) refreshCards();
  }
  const statusLabels = {
    pending: "입금 대기", confirmed: "입금 확인(배송 준비)", shipped: "배송 중",
    delivered: "배송 완료", cancelled: "주문 취소",
  };
  const node = (tag, text, className) => {
    const el = document.createElement(tag);
    if (text !== undefined) el.textContent = text;
    if (className) el.className = className;
    return el;
  };
  const date = (value) => {
    const d = new Date(value);
    return Number.isFinite(d.getTime())
      ? new Intl.DateTimeFormat("ko-KR", {timeZone:"Asia/Seoul",year:"numeric",month:"2-digit",day:"2-digit"}).format(d)
      : "";
  };
  function renderOrderCards(container, orders, append = false) {
    if (!append) container.replaceChildren();
    for (const o of orders) {
      const card = node("article", undefined, "order-result-card");
      const top = node("div", undefined, "result-card-top");
      const badge = node("span", statusLabels[o.status] || "확인 중", "order-state");
      badge.dataset.state = Object.hasOwn(statusLabels, o.status) ? o.status : "unknown";
      top.append(node("span", o.order_number, "result-order-number"), badge);
      card.append(top, node("h4", `${o.product_name} × ${o.quantity}`, "result-product"),
        node("p", `받는 분 ${o.recipient_name}`, "result-recipient"));
      const detail = node("dl", undefined, "result-details");
      const amounts = [["상품 금액", money(o.subtotal)]];
      if (o.discount_amount) amounts.push(["할인", "−" + money(o.discount_amount)]);
      amounts.push(["배송비", money(o.shipping_fee)]);
      for (const [label, value] of amounts) {
        const row = node("div");row.append(node("dt", label), node("dd", value));detail.append(row);
      }
      card.append(detail);
      const total = node("div", undefined, "result-total");
      total.append(node("span", "주문 금액"), node("strong", money(o.total)));card.append(total);
      card.append(node("span", (o.delivered_at ? "배송 완료 " + date(o.delivered_at) : "주문일 " + date(o.created_at)), "result-date"));
      container.append(card);
    }
  }
  function showPayment(total) {
    const payment = window.FARMER_PAYMENT || {};
    const hasAccount = [payment.bank, payment.account, payment.holder].every(
      value => typeof value === "string" && value.trim().length > 0,
    );
    $("payment-account").hidden = !hasAccount;
    $("payment-missing").hidden = hasAccount;
    message("payment-bank", hasAccount ? payment.bank : "");
    message("payment-number", hasAccount ? payment.account : "");
    message("payment-holder", hasAccount ? "예금주 " + payment.holder : "");
    message("copy-payment-label", "복사");
    message("payment-copy-status", "");
    message("payment-amount", money(total));
    $("payment-guide").hidden = false;
  }
  $("copy-payment").addEventListener("click", async () => {
    const payment = window.FARMER_PAYMENT || {};
    const bank = String(payment.bank || "").trim().replace(/은행$/, "");
    const account = String(payment.account || "").trim();
    if (!bank || !account) return;
    const text = `${bank} ${account}`, button = $("copy-payment");
    button.disabled = true;
    message("payment-copy-status", "");
    try {
      try {
        if (!navigator.clipboard?.writeText) throw new Error("Clipboard unavailable");
        await navigator.clipboard.writeText(text);
      } catch {
        // Keep copying available in browsers that restrict the Clipboard API.
        const input = document.createElement("textarea");
        input.value = text;
        input.readOnly = true;
        input.tabIndex = -1;
        input.style.cssText = "position:fixed;left:-9999px;top:0;font-size:16px";
        document.body.append(input);
        try {
          input.select();
          input.setSelectionRange(0, input.value.length);
          if (!document.execCommand("copy")) throw new Error("Copy failed");
        } finally { input.remove(); }
      }
      message("copy-payment-label", "복사 완료");
      message("payment-copy-status", "은행과 계좌번호를 복사했습니다.");
    } catch {
      message("copy-payment-label", "복사");
      message("payment-copy-status", "복사하지 못했습니다. 은행과 계좌번호를 직접 선택해 복사해 주세요.");
    } finally {
      button.disabled = false;
      button.focus({ preventScroll: true });
    }
  });
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    if (receipt || submitting || (locked && !prepared)) return;
    saveOrderer();
    if (!prepared && !validate()) return;
    submitting = true;
    const expectedTotal = displayedTotal;
    lock(true);
    cards().forEach(c => closeSearch(c));
    let sent = false, uncertain = false;
    message("connection-status", "주문을 접수하고 있습니다.");
    try {
      if (!prepared) {
        const payload = {
          p_customer_name: $("customer").value.trim(), p_phone: $("phone").value.trim(),
          p_deliveries: deliveries(), p_coupon_code: discount?.code || "",
          p_privacy_consent: $("order-check").checked,
        };
        const q = await api.rpc("farmer_quote_batch", {
          p_deliveries: payload.p_deliveries.map(({product_id,quantity}) => ({product_id,quantity})),
          p_code: payload.p_coupon_code,
        });
        totals(q);
        if (q.total !== expectedTotal) {
          message("connection-status", "주문 금액이 변경되었습니다. 금액을 확인한 뒤 다시 주문해 주세요.");
          return;
        }
        payload.p_expected_total = q.total;
        const key = JSON.stringify(payload);
        if (!requests.has(key)) requests.set(key, api.uuid());
        payload.p_request_id = requests.get(key);
        prepared = payload;
        preparedQuote = q;
      }
      sent = true;
      const result = await api.rpc("farmer_submit_batch", prepared);
      if (!Array.isArray(result?.orders) || result.orders.length !== prepared.p_deliveries.length || !Number.isFinite(result.total))
        throw Object.assign(new Error("접수 결과를 확인하지 못했습니다."), {uncertain:true});
      receipt = result;
      const receiptRows = result.orders.map((o, i) => ({
        ...preparedQuote.deliveries[i], ...o, status:o.status || "pending",
        recipient_name:prepared.p_deliveries[i].recipient_name,
        created_at:o.created_at || result.created_at,
      }));
      renderOrderCards($("receipt-cards"), receiptRows);
      showPayment(result.total);
      message("connection-status", "");
      form.hidden = true;
      $("summary-panel").hidden = false;
      if (!$("new-order-panel").hidden) $("summary-heading").focus();
    } catch (error) {
      uncertain = sent && !!error.uncertain;
      message("connection-status", uncertain
        ? error.message + " 아래 버튼을 다시 누르면 중복 없이 접수 결과를 확인합니다."
        : error.message);
      if (!uncertain) {prepared = null;preparedQuote = null;}
    } finally {
      submitting = false;
      if (!receipt) {
        if (!uncertain) lock(false);
        $("prepare-button").disabled = false;
        $("prepare-button").textContent = uncertain ? "접수 결과 다시 확인" : "주문하기 →";
      }
    }
  });

  function setOrderView(view, focusTab = false) {
    const lookup = view === "lookup";
    $("new-order-panel").hidden = lookup;
    $("order-lookup").hidden = !lookup;
    for (const [id, active] of [["new-order-tab", !lookup],["lookup-order-tab", lookup]]) {
      $(id).setAttribute("aria-selected", String(active));$(id).tabIndex = active ? 0 : -1;
    }
    if (focusTab) $(lookup ? "lookup-order-tab" : "new-order-tab").focus();
  }
  function openView(view, focusTab = false) {
    const hash = view === "lookup" ? "#order-lookup" : "#order";
    if (location.hash !== hash) history.pushState(null, "", hash);
    setOrderView(view, focusTab);
    $("order").scrollIntoView({behavior:matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth",block:"start"});
  }
  document.querySelectorAll("[data-order-view]").forEach(control => {
    control.addEventListener("click", e => {e.preventDefault();openView(control.dataset.orderView);});
  });
  document.querySelector(".order-tabs").addEventListener("keydown", e => {
    if (!["ArrowLeft","ArrowRight","Home","End"].includes(e.key)) return;
    e.preventDefault();
    const view = e.key === "Home" ? "new" : e.key === "End" ? "lookup" : $("new-order-panel").hidden ? "new" : "lookup";
    openView(view, true);
  });
  const syncView = () => setOrderView(location.hash === "#order-lookup" ? "lookup" : "new");
  addEventListener("popstate", syncView);addEventListener("hashchange", syncView);syncView();

  function clearLookup() {
    lookupRevision++;lookupQuery = null;lookupOffset = null;
    $("lookup-results").hidden = true;$("lookup-cards").replaceChildren();
    $("lookup-more").hidden = true;
    message("lookup-total", "");message("lookup-message", "");
  }
  $("lookup-form").addEventListener("input", e => {
    if (e.target.id === "lookup-phone") phoneInput(e.target, e);
    clearLookup();
  });
  async function loadOrders(append = false) {
    if (lookupBusy || !lookupQuery) return;
    const version = lookupRevision;
    lookupBusy = true;$("lookup-button").disabled = true;$("lookup-more").disabled = true;
    message("lookup-message","주문을 확인하고 있습니다.");
    try {
      const result = await api.rpc("farmer_lookup_orders",{...lookupQuery,p_offset:append ? lookupOffset : 0});
      if (version !== lookupRevision) return;
      if (!result?.found) {
        message("lookup-message",result?.retry_after ? "조회가 잠시 제한되었습니다. 잠시 후 다시 확인해 주세요." : "입력하신 정보와 일치하는 주문을 찾지 못했습니다.");
        return;
      }
      renderOrderCards($("lookup-cards"),result.orders,append);
      lookupOffset = result.next_offset;
      $("lookup-more").hidden = lookupOffset === null;
      message("lookup-total",`총 ${result.total_count}건`);
      message("lookup-message","");$("lookup-results").hidden = false;
      if (!append && !$("order-lookup").hidden) $("lookup-results-title").focus();
    } catch (error) {
      if (version === lookupRevision) message("lookup-message",error.message);
    } finally {
      lookupBusy = false;$("lookup-button").disabled = false;$("lookup-more").disabled = false;
    }
  }
  $("lookup-form").addEventListener("submit", e => {
    e.preventDefault();
    if (lookupBusy) return;
    clearLookup();
    const name = $("lookup-name").value.trim(), phone = $("lookup-phone").value;
    const nameError = name && name.length <= 40 ? "" : "주문자 성함을 입력해 주세요.";
    const phoneError = validPhone(phone) ? "" : "주문자 연락처를 확인해 주세요.";
    message("lookup-name-error",nameError);message("lookup-phone-error",phoneError);
    $("lookup-name").setAttribute("aria-invalid",String(!!nameError));$("lookup-phone").setAttribute("aria-invalid",String(!!phoneError));
    if (nameError || phoneError) {$(nameError ? "lookup-name" : "lookup-phone").focus();return;}
    lookupQuery = {p_customer_name:name,p_phone:phone};
    loadOrders();
  });
  $("lookup-more").addEventListener("click", () => {
    if (lookupOffset !== null) loadOrders(true);
  });
  $("view-receipt").addEventListener("click", () => {
    if (!receipt || !prepared) return;
    $("lookup-name").value = prepared.p_customer_name;
    $("lookup-phone").value = prepared.p_phone;
    openView("lookup");$("lookup-form").requestSubmit();
  });
  async function catalog() {
    try {
      if (!api?.ready()) throw new Error("주문 연결을 준비하고 있습니다.");
      const data = await api.rpc("farmer_catalog");
      products = data.products;
      shipping = data.shipping_fee;
      cards().forEach((c) => options(field(c, "product_id")));
      const values = {
        variety: "호풍미",
        weight:
          "혼합 / " +
          products.map((p) => p.weight_grams / 1000 + "kg").join(", "),
        price: products
          .map((p) => p.weight_grams / 1000 + "kg " + money(p.price))
          .join(" / "),
        shipping: shipping === 0 ? "무료배송" : money(shipping),
      };
      document
        .querySelectorAll("[data-catalog]")
        .forEach((el) => (el.textContent = values[el.dataset.catalog]));
      $("prepare-button").disabled = !products.some((p) => p.available);
      message(
        "connection-status",
        products.some((p) => p.available)
          ? ""
          : "현재 준비된 수량이 모두 소진되었습니다.",
      );
      totals();
    } catch (e) {
      message("connection-status", e.message + " 잠시 후 새로고침해 주세요.");
      $("prepare-button").disabled = true;
    }
  }
  function reset() {
    lock(false);
    form.reset();
    restoreOrderer();
    requests.clear();
    $("deliveries").replaceChildren();
    addCard();
    stale();
    clearDiscount();
    $("summary-panel").hidden = true;
    form.hidden = false;
    $("prepare-button").textContent = "주문하기 →";
    clearLookup();
    $("form-errors").hidden = true;
    ["customer-error", "phone-error", "order-check-error"].forEach((id) =>
      message(id, ""),
    );
    catalog();
  }
  $("new-order").addEventListener("click", () => {
    reset();
    $("customer").focus();
  });
  addEventListener("pageshow", (e) => {
    if (e.persisted) {reset();$("lookup-form").reset();}
  });
  restoreOrderer();
  addCard();
  catalog();
})();
