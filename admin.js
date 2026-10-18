(() => {
  "use strict";
  const $ = (id) => document.getElementById(id),
    api = window.FarmerAPI;
  const statuses = {
    pending: "접수",
    confirmed: "확정 · 발송 대기",
    shipped: "배송 중",
    delivered: "배송 완료",
    cancelled: "취소",
  };
  const number = (n) =>
    Number(n).toLocaleString("ko-KR", { maximumFractionDigits: 3 });
  const date = (v) =>
    v
      ? new Date(v).toLocaleString("ko-KR", {
          timeZone: "Asia/Seoul",
          year: "numeric",
          month: "2-digit",
          day: "2-digit",
          hour: "2-digit",
          minute: "2-digit",
        })
      : "—";
  let state = { summary: null, orders: [], offset: 0, total: 0, current: null },
    version = 0,
    loading = false;
  const requests = new Map();
  const requestId = (payload) => {
    const key = JSON.stringify(payload);
    if (!requests.has(key)) requests.set(key, api.uuid());
    return requests.get(key);
  };
  const message = (id, text, error = false) => {
    $(id).textContent = text;
    $(id).classList.toggle("error", error);
  };
  const node = (tag, text, className) => {
    const el = document.createElement(tag);
    if (text !== undefined) el.textContent = text;
    if (className) el.className = className;
    return el;
  };
  const cell = (row, text) => {
    const td = node("td", text);
    row.append(td);
    return td;
  };
  function clearPrivateView() {
    version++;
    state = { summary: null, orders: [], offset: 0, total: 0, current: null };
    requests.clear();
    $("orders-body").replaceChildren();
    $("stock-history").replaceChildren();
    $("order-details").replaceChildren();
    $("search").value = "";
    $("dashboard").hidden = true;
    $("logout").hidden = true;
    $("login-panel").hidden = false;
    document.querySelectorAll("dialog[open]").forEach((d) => d.close());
  }
  function renderSummary() {
    const s = state.summary;
    $("stock-value").textContent = number(s.available_kg) + " kg";
    $("pending-value").textContent = s.pending + "건";
    $("confirmed-value").textContent = "발송 대기 " + s.confirmed + "건";
    $("shipped-value").textContent = s.shipped + "건";
    $("delivered-value").textContent = s.delivered + "건";
    $("updated-at").textContent = "최근 확인 " + date(new Date().toISOString());
  }
  function renderOrders() {
    $("orders-body").replaceChildren();
    for (const o of state.orders) {
      const row = node("tr"),
        first = cell(row);
      const link = node("button", o.order_number, "order-link");
      link.type = "button";
      link.addEventListener("click", () => openOrder(o));
      first.append(link, node("small", date(o.created_at)));
      const customer = cell(row, o.customer_name);
      customer.append(
        node("small", o.phone),
        node("small", "받는 분: " + (o.recipient_name || o.customer_name)),
      );
      const item = cell(row, o.product_name + " × " + o.quantity);
      item.append(node("small", "총 " + number(o.weight_grams / 1000) + " kg"));
      cell(row, number(o.total) + "원");
      cell(row).append(node("span", statuses[o.status], "badge " + o.status));
      cell(row, date(o.delivered_at));
      $("orders-body").append(row);
    }
    $("empty-orders").hidden = state.orders.length > 0;
    $("page-info").textContent = state.total
      ? `${state.offset + 1}–${Math.min(state.offset + 50, state.total)} / 총 ${state.total}건`
      : "총 0건";
    $("previous").disabled = state.offset === 0;
    $("next").disabled = state.offset + 50 >= state.total;
  }
  async function load() {
    if (loading) return;
    loading = true;
    const currentVersion = version;
    $("refresh").disabled = true;
    try {
      const [summary, result, history] = await Promise.all([
        api.admin("farmer_admin_summary"),
        api.admin("farmer_admin_orders", {
          p_status: $("status-filter").value,
          p_search: $("search").value.trim(),
          p_offset: state.offset,
        }),
        api.admin("farmer_admin_stock_history"),
      ]);
      if (currentVersion !== version) return;
      state.summary = summary;
      state.orders = result.orders;
      state.total = result.total;
      renderSummary();
      renderOrders();
      $("stock-history").replaceChildren();
      for (const e of history) {
        const row = node("tr");
        cell(row, date(e.created_at));
        cell(row, e.reason);
        cell(row, (e.delta_kg > 0 ? "+" : "") + number(e.delta_kg) + " kg");
        cell(row, number(e.balance_kg) + " kg");
        $("stock-history").append(row);
      }
      message("dashboard-message", "");
    } catch (e) {
      if (currentVersion === version)
        message("dashboard-message", e.message, true);
      throw e;
    } finally {
      loading = false;
      $("refresh").disabled = false;
    }
  }
  async function showDashboard() {
    await api.admin("farmer_admin_summary");
    $("login-panel").hidden = true;
    $("dashboard").hidden = false;
    $("logout").hidden = false;
    await load();
  }
  async function authenticate(signup = false) {
    if (!$("login-form").reportValidity()) return;
    $("login-button").disabled = true;
    $("signup-button").disabled = true;
    message(
      "login-message",
      signup ? "확인 메일을 요청하고 있습니다." : "로그인 중입니다.",
    );
    try {
      if (signup) {
        const r = await api.signUp(
          $("email").value.trim(),
          $("password").value,
        );
        $("password").value = "";
        if (r.access_token) {
          await showDashboard();
        } else
          message(
            "login-message",
            "이메일의 확인 링크를 누른 뒤 이 화면으로 돌아와 로그인해 주세요. 이미 가입했다면 기존 비밀번호로 로그인하세요.",
          );
      } else {
        await api.signIn($("email").value.trim(), $("password").value);
        $("password").value = "";
        await showDashboard();
      }
    } catch (e) {
      await api.signOut();
      clearPrivateView();
      message(
        "login-message",
        e.message === "Invalid login credentials"
          ? "이메일과 비밀번호를 확인해 주세요."
          : e.message === "Email not confirmed"
            ? "이메일 확인을 먼저 완료해 주세요."
            : e.message,
        true,
      );
    } finally {
      $("login-button").disabled = false;
      $("signup-button").disabled = false;
    }
  }
  function openOrder(o) {
    state.current = o;
    $("order-heading").textContent = o.order_number;
    $("order-details").replaceChildren();
    const details = [
      ["상태", statuses[o.status]],
      ["주문자", o.customer_name],
      ["받는 분", o.recipient_name || o.customer_name],
      ["받는 분 연락처", o.recipient_phone || o.phone],
      ["우편번호", o.postal_code || "기존 주문 · 미입력"],
      [
        "함께 접수한 주문",
        o.batch_id
          ? o.batch_id.slice(0, 8) + " · 배송지 " + o.delivery_index
          : "단일 주문",
      ],
      ["연락처", o.phone],
      [
        "상품",
        `${o.product_name} × ${o.quantity} · 총 ${number(o.weight_grams / 1000)}kg`,
      ],
      ["주문 금액", number(o.total) + "원"],
      [
        "할인",
        o.discount_code
          ? `${o.discount_code} · ${number(o.discount_amount)}원`
          : "없음",
      ],
      ["배송지", [o.address, o.address_detail].filter(Boolean).join(" ")],
      ["배송 메모", o.memo || "없음"],
      ["접수", date(o.created_at)],
      ["확정", date(o.confirmed_at)],
      ["발송", date(o.shipped_at)],
      ["배송 완료", date(o.delivered_at)],
      ["배송 방법", o.carrier || "—"],
      ["송장", o.tracking_number || "—"],
    ];
    for (const [key, value] of details)
      $("order-details").append(node("dt", key), node("dd", value));
    $("shipping-fields").hidden = o.status !== "confirmed";
    $("carrier").value = o.carrier;
    $("tracking").value = o.tracking_number;
    $("order-actions").replaceChildren();
    const choices =
      {
        pending: [
          ["confirmed", "주문 확정"],
          ["cancelled", "주문 취소"],
        ],
        confirmed: [
          ["shipped", "발송 처리"],
          ["cancelled", "주문 취소"],
        ],
        shipped: [["delivered", "배송 완료 처리"]],
      }[o.status] || [];
    for (const [status, label] of choices) {
      const b = node(
        "button",
        label,
        "button" + (status === "cancelled" ? " danger" : ""),
      );
      b.type = "button";
      b.addEventListener("click", () => changeOrder(status));
      $("order-actions").append(b);
    }
    $("order-change-help").textContent =
      o.status === "pending"
        ? `확정하면 재고 ${number(o.weight_grams / 1000)}kg이 차감됩니다.`
        : o.status === "confirmed"
          ? `배송 전 취소하면 재고 ${number(o.weight_grams / 1000)}kg이 복구됩니다.`
          : "";
    message("order-message", "");
    $("order-dialog").showModal();
  }
  async function changeOrder(status) {
    const o = state.current;
    if (!o) return;
    if (status === "shipped" && !$("carrier").value.trim()) {
      message("order-message", "택배사 또는 배송 방법을 입력해 주세요.", true);
      $("carrier").focus();
      return;
    }
    const prompt =
      status === "confirmed"
        ? `${o.order_number}를 확정하고 재고 ${number(o.weight_grams / 1000)}kg을 차감할까요?`
        : status === "cancelled"
          ? `${o.order_number}를 취소할까요?`
          : status === "shipped"
            ? "입력한 배송 정보로 발송 처리할까요?"
            : "실제 배송이 완료되었나요? 완료 일시가 기록됩니다.";
    if (!confirm(prompt)) return;
    const payload = {
      p_order_id: o.id,
      p_status: status,
      p_expected_version: o.version,
      p_carrier: $("carrier").value.trim(),
      p_tracking_number: $("tracking").value.trim(),
    };
    payload.p_request_id = requestId(payload);
    $("order-actions")
      .querySelectorAll("button")
      .forEach((b) => (b.disabled = true));
    try {
      await api.admin("farmer_admin_change_status", payload);
      $("order-dialog").close();
      await load();
      message("dashboard-message", "주문 상태를 변경했습니다.");
    } catch (e) {
      message(
        $("order-dialog").open ? "order-message" : "dashboard-message",
        e.message,
        true,
      );
    } finally {
      $("order-actions")
        .querySelectorAll("button")
        .forEach((b) => (b.disabled = false));
    }
  }
  $("login-form").addEventListener("submit", (e) => {
    e.preventDefault();
    authenticate();
  });
  $("signup-button").addEventListener("click", () => authenticate(true));
  $("logout").addEventListener("click", async () => {
    clearPrivateView();
    await api.signOut();
    message("login-message", "로그아웃했습니다.");
  });
  $("refresh").addEventListener("click", () => load().catch(() => {}));
  $("filter-form").addEventListener("submit", (e) => {
    e.preventDefault();
    if (loading) return;
    state.offset = 0;
    load().catch(() => {});
  });
  $("previous").addEventListener("click", () => {
    if (loading) return;
    state.offset = Math.max(0, state.offset - 50);
    load().catch(() => {});
  });
  $("next").addEventListener("click", () => {
    if (loading) return;
    state.offset += 50;
    load().catch(() => {});
  });
  document
    .querySelectorAll("[data-close]")
    .forEach((b) =>
      b.addEventListener("click", () => $(b.dataset.close).close()),
    );
  $("open-stock").addEventListener("click", () => {
    if (!state.summary) return;
    $("stock-form").reset();
    $("stock-current").textContent = number(state.summary.available_kg) + " kg";
    message("stock-message", "");
    $("stock-dialog").showModal();
  });
  $("stock-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    if (!$("stock-form").reportValidity()) return;
    const payload = {
      p_delta_kg:
        Number($("stock-kg").value) * Number($("stock-direction").value),
      p_reason: $("stock-reason").value.trim(),
      p_expected_version: state.summary.inventory_version,
    };
    payload.p_request_id = requestId(payload);
    $("stock-submit").disabled = true;
    try {
      await api.admin("farmer_admin_adjust_stock", payload);
      $("stock-dialog").close();
      await load();
      message("dashboard-message", "재고 변경을 저장했습니다.");
    } catch (error) {
      message(
        $("stock-dialog").open ? "stock-message" : "dashboard-message",
        error.message,
        true,
      );
    } finally {
      $("stock-submit").disabled = false;
    }
  });
  if (!api?.ready()) {
    message("login-message", "관리 시스템 연결을 준비하고 있습니다.", true);
    $("login-button").disabled = true;
    $("signup-button").disabled = true;
  } else if (api.consumeCallback())
    showDashboard().catch(async (e) => {
      await api.signOut();
      clearPrivateView();
      message("login-message", e.message, true);
    });
})();
