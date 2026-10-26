/* Admin-only gift entry. No payment data or recipient details are stored locally. */
(() => {
  "use strict";
  const $ = id => document.getElementById(id), api = window.FarmerAPI;
  const cards = () => [...$("gift-deliveries").querySelectorAll(".gift-card")];
  const field = (card, name) => card.querySelector(`[data-gift-field="${name}"]`);
  let products = [], sequence = 0, revision = 0, busy = false, pending = null, sdkPromise = null, onSaved = () => {};
  const frozen = () => busy || !!pending;
  const tell = (text, error = false) => {
    $("gift-message").textContent = text;
    $("gift-message").classList.toggle("error", error);
  };
  const isPickup = card => field(card,"product_id").value === 'hopungmi-5kg-pickup';
  const read = () => cards().map(card => {
    const d=Object.fromEntries([...card.querySelectorAll("[data-gift-field]")].map(el=>[el.dataset.giftField,el.dataset.giftField==="quantity"?Number(el.value):el.value.trim()]));
    return {...d,gift_sponsor:$("gift-sponsor").value,...(isPickup(card)?{postal_code:'',address:'',address_detail:''}:{})};
  });
  function deliveryMode(card){
    const pickup=isPickup(card);card.querySelector('[data-gift-shipping-fields]').hidden=pickup;card.querySelector('[data-gift-pickup]').hidden=!pickup;
    const toggle=card.querySelector('[data-gift-pickup-toggle]');
    toggle.checked=pickup;
    toggle.disabled=frozen()||!['hopungmi-5kg','hopungmi-5kg-pickup'].includes(field(card,'product_id').value)||(!pickup&&!products.some(p=>p.id==='hopungmi-5kg-pickup'&&p.available));
    for(const key of ['postal_code','address','address_detail']){const e=field(card,key);e.disabled=pickup;e.required=!pickup&&key!=='address_detail';if(pickup)e.setCustomValidity('');}
    card.querySelector('[data-gift-label="memo"]').firstChild.textContent=pickup?'수령 메모 ':'배송 메모 ';
    field(card,'memo').placeholder=pickup?'예: 오후에 방문할게요':'예: 문 앞에 놓아 주세요';
    if(pickup)card.querySelector('[data-gift-search-panel]').hidden=true;
  }
  function totalWeight() {
    return read().reduce((sum, d) => sum + (products.find(p => p.id === d.product_id)?.weight_grams || 0) * d.quantity, 0);
  }
  function update() {
    const list = cards(), valid = ["윤가희","홍세환"].includes($("gift-sponsor").value) && list.length && read().every(d => products.some(p => p.id === d.product_id && p.available) && Number.isInteger(d.quantity) && d.quantity >= 1 && d.quantity <= 99);
    list.forEach((card, i) => {
      deliveryMode(card);
      card.querySelector("[data-gift-number]").textContent = i + 1;
      card.querySelector("[data-gift-remove]").hidden = list.length === 1;
      card.querySelector("[data-gift-search]").setAttribute("aria-label", `받는 분 ${i + 1} 주소 검색`);
    });
    $("gift-weight").textContent = valid ? (totalWeight() / 1000).toLocaleString("ko-KR") + " kg" : "—";
    $("gift-fields").disabled = frozen();
    $("gift-add").disabled = frozen() || list.length >= 20 || !products.length;
    $("gift-close").disabled = frozen();
    $("gift-submit").disabled = busy || (!pending && !valid);
    $("gift-submit").textContent = busy ? "등록 중…" : pending ? "등록 결과 다시 확인" : "선물 주문 등록";
  }
  function clear() {
    revision++;
    busy = false;
    pending = null;
    products = [];
    $("gift-sponsor").value="";
    $("gift-deliveries").replaceChildren();
    tell("");
    if ($("gift-dialog").open) $("gift-dialog").close();
    update();
  }
  function addCard(focus = false) {
    if (frozen() || cards().length >= 20) return;
    const fragment = $("gift-template").content.cloneNode(true), card = fragment.querySelector(".gift-card"), id = ++sequence;
    for (const el of card.querySelectorAll("[data-gift-field]")) {
      el.id = `gift-${id}-${el.dataset.giftField}`;
      card.querySelector(`[data-gift-label="${el.dataset.giftField}"]`).htmlFor = el.id;
      if (el.autocomplete) el.autocomplete = `section-gift${id} shipping ${el.autocomplete}`;
    }
    field(card, "product_id").replaceChildren(...products.map(p => {
      const option = document.createElement("option");
      option.value = p.id;
      option.textContent = p.name + (p.available ? "" : " · 재고 부족");
      option.disabled = !p.available;
      return option;
    }));
    field(card, "product_id").value = products.find(p => p.id === "hopungmi-5kg" && p.available)?.id || products.find(p => p.available)?.id || "";
    $("gift-deliveries").append(fragment);
    update();
    if (focus) field(card, "recipient_name").focus();
  }
  async function open() {
    clear();
    const current = revision;
    $("gift-dialog").showModal();
    busy = true;
    update();
    // Catalog loading can be cancelled without creating an order.
    $("gift-close").disabled = false;
    tell("상품 정보를 불러오고 있습니다.");
    try {
      const result = await api.rpc("farmer_catalog");
      if (current !== revision || !$("gift-dialog").open) return;
      products = result.products;
      busy = false;
      addCard();
      tell(products.some(p => p.available) ? "" : "현재 등록 가능한 재고가 없습니다.", !products.some(p => p.available));
    } catch (e) {
      if (current === revision) tell(e.message + " 닫은 뒤 다시 열어 주세요.", true);
    } finally {
      if (current === revision) { busy = false; update(); }
    }
  }
  function formatPhone(input) {
    const cursor = input.selectionStart ?? input.value.length;
    const count = input.value.slice(0, cursor).replace(/\D/g, "").length;
    const d = input.value.replace(/\D/g, "").slice(0, 11), prefix = d.startsWith("02") ? 2 : 3;
    const rest = d.slice(prefix), middle = rest.length > 7 ? 4 : 3;
    input.value = d.length <= prefix ? d : d.slice(0,prefix) + "-" + (rest.length <= middle ? rest : rest.slice(0,middle) + "-" + rest.slice(middle));
    let position = 0, digits = 0;
    while (position < input.value.length && digits < count) { if (/\d/.test(input.value[position])) digits++; position++; }
    input.setSelectionRange(position, position);
  }
  function postcodeSDK() {
    if (window.kakao?.Postcode || window.daum?.Postcode) return Promise.resolve();
    if (sdkPromise) return sdkPromise;
    sdkPromise = new Promise((resolve, reject) => {
      const script = document.createElement("script");
      const fail = () => { clearTimeout(timer); script.remove(); sdkPromise = null; reject(new Error("주소 검색에 연결하지 못했습니다. 우편번호와 주소를 직접 입력해 주세요.")); };
      const timer = setTimeout(fail, 15000);
      script.src = "https://t1.kakaocdn.net/mapjsapi/bundle/postcode/prod/postcode.v2.js";
      script.onload = () => { clearTimeout(timer); if (window.kakao?.Postcode || window.daum?.Postcode) resolve(); else fail(); };
      script.onerror = fail;
      document.head.append(script);
    });
    return sdkPromise;
  }
  async function search(card) {
    const panel = card.querySelector("[data-gift-search-panel]"), status = card.querySelector("[data-gift-search-status]"), button = card.querySelector("[data-gift-search]");
    panel.hidden = false;
    status.textContent = "주소 검색을 불러오고 있습니다.";
    button.disabled = true;
    const current = revision;
    try {
      await postcodeSDK();
      if (current !== revision || frozen() || !card.isConnected || panel.hidden || isPickup(card)) return;
      const Postcode = window.kakao?.Postcode || window.daum.Postcode, container = card.querySelector("[data-gift-embed]");
      container.replaceChildren();
      new Postcode({width:"100%",height:"100%",onresize:size => { container.style.height = size.height + "px"; },oncomplete:data => {
        if (current !== revision || frozen() || !card.isConnected || isPickup(card)) return;
        field(card,"postal_code").value = data.zonecode;
        field(card,"address").value = data.userSelectedType === "R" ? data.roadAddress : data.jibunAddress;
        field(card,"address_detail").value = "";
        field(card,"postal_code").setCustomValidity("");
        field(card,"address").setCustomValidity("");
        panel.hidden = true;
        field(card,"address_detail").focus();
      }}).embed(container);
      status.textContent = "도로명, 건물명 또는 지번으로 검색해 주세요.";
    } catch(e) { if (current === revision && card.isConnected) status.textContent = e.message; }
    finally { if (card.isConnected) button.disabled = false; }
  }
  $("gift-form").addEventListener("submit", async e => {
    e.preventDefault();
    if (busy) return;
    if (!pending) {
      for (const card of cards()) {
        const phone = field(card,"recipient_phone"), name = field(card,"recipient_name"), address = field(card,"address");
        phone.setCustomValidity(/^0\d{8,10}$/.test(phone.value.replace(/\D/g,"")) ? "" : "연락처를 확인해 주세요.");
        name.setCustomValidity(name.value.trim() ? "" : "받는 분 성함을 입력해 주세요.");
        address.setCustomValidity(isPickup(card) || address.value.trim().length >= 5 ? "" : "주소를 확인해 주세요.");
      }
      if (!$("gift-form").reportValidity() || !cards().length) return;
      const deliveries = read();
      if (!confirm(`${deliveries.length}곳의 선물 주문을 등록할까요?\n재고 ${(totalWeight()/1000).toLocaleString("ko-KR")}kg을 차감하며 받는 분께 비용을 청구하지 않습니다.`)) return;
      pending = { p_request_id:api.uuid(), p_deliveries:deliveries };
    }
    const current = revision;
    busy = true;
    cards().forEach(card => { card.querySelector("[data-gift-search-panel]").hidden = true; });
    update();
    tell("선물 주문을 등록하고 있습니다.");
    try {
      const result = await api.admin("farmer_admin_create_gifts",pending);
      if (current !== revision) return;
      clear();
      await onSaved(result);
    } catch(e) {
      if (current !== revision) return;
      if (!e.uncertain) pending = null;
      tell(e.uncertain ? "등록 결과를 확인하지 못했습니다. ‘등록 결과 다시 확인’을 눌러 주세요. 같은 요청을 확인하므로 주문과 재고가 중복 처리되지 않습니다." : e.message, true);
    } finally { if (current === revision) { busy = false; update(); } }
  });
  $("gift-deliveries").addEventListener("input", e => {
    const el = e.target;
    if (frozen() || !el.matches("[data-gift-field]")) return;
    el.setCustomValidity("");
    if (el.dataset.giftField === "recipient_phone") formatPhone(el);
    tell(""); update();
  });
  $("gift-deliveries").addEventListener("click", e => {
    const card = e.target.closest(".gift-card");
    if (!card || frozen()) return;
    if (e.target.closest("[data-gift-remove]")) { card.remove(); update(); $("gift-add").focus(); }
    else if (e.target.closest("[data-gift-search]")) search(card);
    else if (e.target.closest("[data-gift-close-search]")) { card.querySelector("[data-gift-search-panel]").hidden = true; card.querySelector("[data-gift-search]").focus(); }
  });
  $("gift-deliveries").addEventListener("change",e=>{
    if(frozen())return;
    if(e.target.matches('[data-gift-pickup-toggle]')){
      const card=e.target.closest('.gift-card'),id=e.target.checked?'hopungmi-5kg-pickup':'hopungmi-5kg';
      if(products.some(p=>p.id===id&&p.available))field(card,'product_id').value=id;
      tell('');update();
    }else if(e.target.matches('[data-gift-field="product_id"]'))update();
  });
  $("gift-sponsor").addEventListener("change",()=>{if(!frozen()){tell("");update();}});
  $("gift-add").addEventListener("click", () => addCard(true));
  $("gift-close").addEventListener("click", () => { if (!pending) clear(); });
  $("gift-dialog").addEventListener("cancel", e => { e.preventDefault(); if (!pending) clear(); });
  window.FarmerGifts = Object.freeze({open, clear, init:callback => { onSaved = callback; }});
})();
