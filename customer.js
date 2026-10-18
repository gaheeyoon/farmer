/* Prices, coupon validation and final totals are checked again by Supabase. */
(() => {
  "use strict";
  const $ = (id) => document.getElementById(id),
    api = window.FarmerAPI;
  const form = $("order-form"),
    select = $("product-select"),
    quantity = $("quantity"),
    code = $("discount-code");
  const money = (n) => Number(n).toLocaleString("ko-KR") + "원";
  let products = [],
    shipping = 3500,
    discount = null,
    revision = 0,
    prepared = null,
    receipt = null,
    submitting = false,
    locked = false;
  const requests = new Map();
  const product = () => products.find((p) => p.id === select.value);
  const validQuantity = () =>
    quantity.value.trim() !== "" &&
    Number.isInteger(Number(quantity.value)) &&
    Number(quantity.value) >= 1 &&
    Number(quantity.value) <= 99;
  const message = (id, text) => {
    $(id).textContent = text;
  };
  function totals(q) {
    const p = product(),
      valid = p && validQuantity();
    const subtotal =
        q?.subtotal ?? (valid ? p.price * Number(quantity.value) : 0),
      d =
        q?.discount_amount ??
        (discount ? Math.min(subtotal, discount.amount) : 0);
    message("subtotal-amount", valid ? money(subtotal) : "—");
    message("shipping-amount", money(q?.shipping_fee ?? shipping));
    $("discount-line").hidden = !discount;
    message("discount-amount", "−" + money(d));
    message(
      "total-amount",
      valid
        ? money(q?.total ?? subtotal - d + shipping)
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
  const rules = [
    [
      "product-select",
      "product-error",
      () =>
        product()?.available ? "" : "현재 주문 가능한 상품을 선택해 주세요.",
    ],
    [
      "quantity",
      "quantity-error",
      () => (validQuantity() ? "" : "수량은 1~99 사이의 정수로 입력해 주세요."),
    ],
    [
      "discount-code",
      "discount-error",
      () =>
        code.value.trim() && !discount
          ? "할인코드를 적용하거나 입력란을 비워 주세요."
          : "",
    ],
    [
      "customer",
      "customer-error",
      () => ($("customer").value.trim() ? "" : "주문자 성함을 입력해 주세요."),
    ],
    [
      "phone",
      "phone-error",
      () =>
        /^(?:0\d{8,10}|\+82\d{8,10})$/.test(
          $("phone")
            .value.trim()
            .replace(/[\s()-]/g, ""),
        )
          ? ""
          : "연락 가능한 전화번호를 입력해 주세요.",
    ],
    [
      "address",
      "address-error",
      () =>
        $("address").value.trim().length >= 5
          ? ""
          : "배송 주소를 5자 이상 입력해 주세요.",
    ],
    [
      "order-check",
      "order-check-error",
      () =>
        $("order-check").checked
          ? ""
          : "주문 정보 확인과 개인정보 수집·이용에 동의해 주세요.",
    ],
  ];
  function validate() {
    const errors = [];
    for (const [id, errorId, test] of rules) {
      const value = test();
      message(errorId, value);
      $(id).setAttribute("aria-invalid", String(!!value));
      if (value) errors.push({ id, value });
    }
    $("form-errors").hidden = !errors.length;
    if (errors.length) {
      message(
        "form-errors",
        `${errors.length}개 항목을 확인해 주세요. ${errors[0].value}`,
      );
      $(errors[0].id).focus();
      return false;
    }
    return true;
  }
  async function catalog() {
    $("prepare-button").disabled = true;
    try {
      if (!api?.ready()) throw new Error("주문 연결을 준비하고 있습니다.");
      const data = await api.rpc("farmer_catalog");
      products = data.products;
      shipping = data.shipping_fee;
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
      const fields = {
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
        .forEach((el) => (el.textContent = fields[el.dataset.catalog]));
      $("prepare-button").disabled = !products.some((p) => p.available);
      message(
        "connection-status",
        products.some((p) => p.available)
          ? ""
          : "현재 준비된 수량이 모두 소진되었습니다.",
      );
      totals();
    } catch (e) {
      message(
        "connection-status",
        e.message + " 잠시 후 페이지를 새로고침해 주세요.",
      );
    }
  }
  async function applyDiscount() {
    if (locked || submitting) return;
    stale();
    clearDiscount();
    const normalized = code.value.normalize("NFKC").trim().toUpperCase(),
      version = revision;
    if (!normalized) {
      message("discount-error", "할인코드를 입력해 주세요.");
      return;
    }
    if (!product() || !validQuantity()) {
      message("discount-error", "상품과 수량을 먼저 확인해 주세요.");
      return;
    }
    $("apply-discount").disabled = true;
    try {
      const q = await api.rpc("farmer_quote", {
        p_product_id: select.value,
        p_quantity: Number(quantity.value),
        p_code: normalized,
      });
      if (version !== revision) return;
      discount = { code: q.discount_code, amount: q.discount_amount };
      code.value = q.discount_code;
      message(
        "discount-status",
        `${q.discount_code} · 주문당 ${money(q.discount_amount)} 할인 적용`,
      );
      $("remove-discount").hidden = false;
      totals(q);
    } catch (e) {
      if (version === revision) {
        message("discount-error", e.message);
        code.setAttribute("aria-invalid", "true");
      }
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
    if (locked) return;
    stale();
    code.value = "";
    clearDiscount();
    code.focus();
  });
  form.addEventListener("input", (e) => {
    if (locked) return;
    stale();
    if (e.target === code) clearDiscount();
    totals();
    $("form-errors").hidden = true;
  });
  select.addEventListener("change", () => {
    if (!locked) {
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
  }
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    if (locked || !validate()) return;
    const version = revision;
    const payload = {
      p_product_id: select.value,
      p_quantity: Number(quantity.value),
      p_coupon_code: discount?.code || "",
      p_customer_name: $("customer").value.trim(),
      p_phone: $("phone").value.trim(),
      p_address: $("address").value.trim(),
      p_address_detail: $("address-detail").value.trim(),
      p_memo: $("memo").value.trim(),
      p_privacy_consent: $("order-check").checked,
    };
    $("prepare-button").disabled = true;
    message("connection-status", "금액을 확인하고 있습니다.");
    try {
      const q = await api.rpc("farmer_quote", {
        p_product_id: payload.p_product_id,
        p_quantity: payload.p_quantity,
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
        `[어쩌다 농부 · 고구맙습니다 주문서]`,
        "",
        `상품: ${q.product_name}`,
        `수량: ${q.quantity}개 · 총 ${q.weight_grams / 1000}kg`,
        `상품 금액: ${money(q.subtotal)}`,
        ...(q.discount_code
          ? [
              `할인코드: ${q.discount_code}`,
              `할인 금액: −${money(q.discount_amount)}`,
            ]
          : []),
        `배송비: ${money(q.shipping_fee)}`,
        `총 주문 금액: ${money(q.total)}`,
        "",
        `주문자: ${payload.p_customer_name}`,
        `연락처: ${payload.p_phone}`,
        `배송 주소: ${[payload.p_address, payload.p_address_detail].filter(Boolean).join(" ")}`,
        `배송 메모: ${payload.p_memo || "없음"}`,
      ].join("\n");
      $("summary-panel").hidden = false;
      $("submit-order").hidden = false;
      $("submit-order").disabled = false;
      $("copy-button").disabled = false;
      $("stale-note").hidden = true;
      message("summary-heading", "주문서를 확인해 주세요.");
      message(
        "summary-guide",
        "상품과 배송지를 확인한 뒤 ‘주문 접수하기’를 눌러 주세요.",
      );
      message("copy-status", "");
      message("order-status", "");
      $("summary-heading").focus({ preventScroll: true });
      $("summary-panel").scrollIntoView({
        behavior: matchMedia("(prefers-reduced-motion: reduce)").matches
          ? "auto"
          : "smooth",
        block: "center",
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
    $("submit-order").disabled = true;
    message(
      "order-status",
      "주문을 접수하고 있습니다. 창을 닫지 말고 잠시 기다려 주세요.",
    );
    try {
      const result = await api.rpc("farmer_submit_order", prepared);
      if (!result?.order_number)
        throw Object.assign(new Error("처리 결과를 확인하지 못했습니다."), {
          uncertain: true,
        });
      receipt = result;
      message("summary-heading", "주문이 접수되었습니다.");
      message(
        "summary-guide",
        `주문번호 ${result.order_number} · 총 ${money(result.total)}`,
      );
      message(
        "order-status",
        "판매자가 주문을 확인한 뒤 확정합니다. 결제는 별도 안내를 따라 주세요.",
      );
      $("summary-text").value =
        `주문번호: ${result.order_number}\n접수 일시: ${new Date(result.created_at).toLocaleString("ko-KR")}\n\n` +
        $("summary-text").value;
      $("submit-order").hidden = true;
    } catch (error) {
      $("submit-order").disabled = false;
      if (error.uncertain) {
        message(
          "order-status",
          error.message +
            " 아래 버튼을 다시 누르면 같은 주문의 접수 결과를 확인합니다.",
        );
      } else {
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
          : "선택한 주문 내용을 Ctrl+C / ⌘C 또는 길게 눌러 복사해 주세요.",
      );
  });
  addEventListener("pageshow", (e) => {
    if (e.persisted) {
      lock(false);
      form.reset();
      stale();
      clearDiscount();
      $("summary-panel").hidden = true;
      $("summary-text").value = "";
      catalog();
    }
  });
  catalog();
})();
