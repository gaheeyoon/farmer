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
    shipping = 3500,
    discount = null,
    revision = 0,
    sequence = 0,
    prepared = null,
    receipt = null,
    locked = false,
    submitting = false,
    sdkPromise = null;
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
        (discount ? Math.min(subtotal, discount.amount) : 0),
      fee = q?.shipping_fee ?? cards().length * shipping;
    message("subtotal-amount", valid ? money(subtotal) : "—");
    message("shipping-label", `배송비 · ${cards().length}곳`);
    message("shipping-amount", money(fee));
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
    receipt = null;
    $("submit-order").disabled = true;
    $("copy-button").disabled = true;
    message("order-status", "");
    if (!$("summary-panel").hidden) {
      $("stale-note").hidden = false;
      $("summary-text").value =
        "입력 내용이 변경되었습니다. 주문서를 다시 확인해 주세요.";
    }
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
      discount = { code: q.discount_code, amount: q.discount_amount };
      code.value = q.discount_code;
      message(
        "discount-status",
        `${q.discount_code} · 전체 주문 ${money(q.discount_amount)} 할인 적용`,
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
    if (e.target.matches('[data-field="postal_code"]'))
      e.target.value = e.target.value.replace(/\D/g, "").slice(0, 5);
    stale();
    if (e.target === code) clearDiscount();
    totals();
    $("form-errors").hidden = true;
  });
  form.addEventListener("change", (e) => {
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
    $("edit-button").disabled = value;
    if (!value) refreshCards();
  }
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    if (locked || !validate()) return;
    const version = revision,
      payload = {
        p_customer_name: $("customer").value.trim(),
        p_phone: $("phone").value.trim(),
        p_deliveries: deliveries(),
        p_coupon_code: discount?.code || "",
        p_privacy_consent: $("order-check").checked,
      };
    $("prepare-button").disabled = true;
    message("connection-status", "전체 주문 금액을 확인하고 있습니다.");
    try {
      const q = await api.rpc("farmer_quote_batch", {
        p_deliveries: quoteItems(),
        p_code: payload.p_coupon_code,
      });
      if (version !== revision) return;
      payload.p_expected_total = q.total;
      const key = JSON.stringify(payload);
      if (!requests.has(key)) requests.set(key, api.uuid());
      payload.p_request_id = requests.get(key);
      prepared = payload;
      receipt = null;
      totals(q);
      $("summary-text").value = [
        "[어쩌다 농부 · 고구맙습니다 주문서]",
        "",
        `주문자: ${payload.p_customer_name}`,
        `주문자 연락처: ${payload.p_phone}`,
        ...payload.p_deliveries.flatMap((d, i) => [
          "",
          `[배송지 ${i + 1}] 받는 분: ${d.recipient_name}`,
          `연락처: ${d.recipient_phone}`,
          `상품: ${q.deliveries[i].product_name} × ${d.quantity}개`,
          `주소: (${d.postal_code}) ${d.address} ${d.address_detail}`.trim(),
          `배송 메모: ${d.memo || "없음"}`,
          `배송지별 금액: ${money(q.deliveries[i].total)}${i === 0 && q.discount_amount ? " (전체 할인 포함)" : ""}`,
        ]),
        "",
        `상품 금액 합계: ${money(q.subtotal)}`,
        ...(q.discount_code
          ? [
              `할인코드: ${q.discount_code} · −${money(q.discount_amount)} (전체 주문 1회)`,
            ]
          : []),
        `배송비: ${money(q.shipping_fee)} (${payload.p_deliveries.length}곳)`,
        `총 주문 금액: ${money(q.total)}`,
      ].join("\n");
      $("summary-panel").hidden = false;
      $("submit-order").hidden = false;
      $("submit-order").disabled = false;
      $("copy-button").disabled = false;
      $("stale-note").hidden = true;
      message("summary-heading", "모든 배송지를 확인해 주세요.");
      message(
        "summary-guide",
        `${payload.p_deliveries.length}곳으로 보내는 주문입니다. 확인 후 ‘주문 접수하기’를 눌러 주세요.`,
      );
      message("copy-status", "");
      message("order-status", "");
      $("summary-heading").focus({ preventScroll: true });
      $("summary-panel").scrollIntoView({
        behavior: matchMedia("(prefers-reduced-motion: reduce)").matches
          ? "auto"
          : "smooth",
        block: "start",
      });
    } catch (error) {
      message("connection-status", error.message);
    } finally {
      if (version === revision && prepared) message("connection-status", "");
      if (!locked) $("prepare-button").disabled = false;
    }
  });
  $("submit-order").addEventListener("click", async () => {
    if (!prepared || receipt || submitting) return;
    submitting = true;
    lock(true);
    cards().forEach((c) => closeSearch(c));
    $("submit-order").disabled = true;
    message(
      "order-status",
      "모든 배송지의 주문을 함께 접수하고 있습니다. 잠시 기다려 주세요.",
    );
    try {
      const result = await api.rpc("farmer_submit_batch", prepared);
      if (
        !Array.isArray(result?.orders) ||
        result.orders.length !== prepared.p_deliveries.length
      )
        throw Object.assign(new Error("접수 결과를 확인하지 못했습니다."), {
          uncertain: true,
        });
      receipt = result;
      message(
        "summary-heading",
        `${result.orders.length}곳의 주문이 접수되었습니다.`,
      );
      message(
        "summary-guide",
        `총 ${money(result.total)} · 배송지별 주문번호를 확인해 주세요.`,
      );
      message(
        "order-status",
        "판매자가 주문을 확인한 뒤 확정합니다. 결제는 별도 안내를 따라 주세요.",
      );
      $("summary-text").value =
        result.orders
          .map((o) => `배송지 ${o.delivery_index} 주문번호: ${o.order_number}`)
          .join("\n") +
        "\n\n" +
        $("summary-text").value;
      $("submit-order").hidden = true;
      $("new-order").hidden = false;
    } catch (error) {
      $("submit-order").disabled = false;
      if (error.uncertain)
        message(
          "order-status",
          error.message +
            " 같은 버튼을 다시 누르면 중복 없이 접수 결과를 확인합니다.",
        );
      else {
        lock(false);
        message("order-status", error.message);
      }
    } finally {
      submitting = false;
    }
  });
  $("edit-button").addEventListener("click", () => {
    if (!locked) $("customer").focus();
  });
  $("copy-button").addEventListener("click", async () => {
    if (!prepared || $("copy-button").disabled) return;
    const text = $("summary-text").value,
      version = revision;
    let copied = false;
    try {
      await navigator.clipboard.writeText(text);
      copied = true;
    } catch (_) {
      $("summary-text").focus();
      $("summary-text").select();
      try {
        copied = document.execCommand("copy");
      } catch (_) {}
    }
    if (version === revision)
      message(
        "copy-status",
        copied
          ? "주문 내용을 복사했습니다."
          : "선택한 내용을 Ctrl+C / ⌘C 또는 길게 눌러 복사해 주세요.",
      );
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
        shipping: money(shipping),
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
    requests.clear();
    $("deliveries").replaceChildren();
    addCard();
    stale();
    clearDiscount();
    $("summary-panel").hidden = true;
    $("summary-text").value = "";
    $("new-order").hidden = true;
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
    if (e.persisted) reset();
  });
  addCard();
  catalog();
})();
