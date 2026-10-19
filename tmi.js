/* Public field notes. Edit tmi-data.js for records; no admin or order data is fetched. */
(() => {
  'use strict';
  const data = window.FARMER_TMI;
  if (!data) return;
  const $ = id => document.getElementById(id);
  const el = (tag, text, cls) => { const n = document.createElement(tag); if (text != null) n.textContent = text; if (cls) n.className = cls; return n; };
  const num = n => new Intl.NumberFormat('ko-KR', { maximumFractionDigits: 1 }).format(n);
  const dayMs = 86400000;
  function dateValue(s) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(s)) return NaN;
    const t = Date.parse(s + 'T00:00:00Z');
    return Number.isFinite(t) && new Date(t).toISOString().slice(0, 10) === s ? t : NaN;
  }
  const iso = t => new Date(t).toISOString().slice(0, 10);
  const shortDate = s => `${Number(s.slice(5, 7))}.${Number(s.slice(8, 10))}`;
  const fullDate = s => `${s.slice(0, 4)}년 ${Number(s.slice(5, 7))}월 ${Number(s.slice(8, 10))}일`;
  function parseWeather(raw, start, end) {
    const params = raw?.properties?.parameter;
    const units = raw?.parameters;
    if (!params || units?.T2M_MAX?.units !== 'C' || units?.T2M_MIN?.units !== 'C' || units?.PRECTOTCORR?.units !== 'mm/day' || raw.header?.time_standard !== 'LST') throw new Error('날씨 자료를 준비하고 있습니다.');
    const fill = raw.header.fill_value ?? -999;
    const read = (key, date) => {
      const v = params[key]?.[date];
      return typeof v === 'number' && Number.isFinite(v) && v !== fill && v !== -999 && (key !== 'PRECTOTCORR' || v >= 0) ? v : null;
    };
    const rows = [];
    for (let t = dateValue(start); t <= dateValue(end); t += dayMs) {
      const date = iso(t), key = date.replaceAll('-', '');
      rows.push({ date, high: read('T2M_MAX', key), low: read('T2M_MIN', key), rain: read('PRECTOTCORR', key) });
    }
    if (!rows.some(r => r.high !== null || r.low !== null || r.rain !== null)) throw new Error('재배기간의 날씨 자료가 아직 준비되지 않았습니다.');
    return rows;
  }
  // Kept separate from rendering so missing-data and date logic can be checked without network calls.
  window.FarmerWeather = Object.freeze({ parseWeather });

  function showSupplies(filter = 'all') {
    const list = data.supplies.filter(s => filter === 'all' || (filter === 'npk' ? s.npk : !s.npk)).sort((a, b) => a.date.localeCompare(b.date));
    $('supply-records').replaceChildren(...list.map(s => {
      const card = el('article', null, 'supply-card');
      const meta = el('div', null, 'supply-meta'); meta.append(el('span', fullDate(s.date)), el('span', s.kind === 'cover' ? '밭을 덮는 자재' : '밭에 사용한 자재'));
      const amount = el('p', s.packKg ? `${s.packKg}kg × ${s.packs}포` : s.spec, 'supply-amount'); amount.append(el('b', s.packKg ? `총 ${num(s.packKg * s.packs)}kg 사용` : `총 ${s.quantity}${s.unit} 사용`));
      card.append(meta, el('h4', s.name), amount);
      if (s.npk) {
        const profile = el('div', null, 'npk-profile');
        ['N · 질소', 'P · 인산', 'K · 칼리'].forEach((label, i) => {
          const col = el('div', null, 'npk-column'), bar = el('i'), labelBox = el('div');
          bar.style.height = `${Math.max(2, s.npk[i] / 45 * 72)}px`; bar.setAttribute('aria-hidden', 'true');
          labelBox.append(el('b', `${s.npk[i]}`), el('span', label)); col.append(bar, labelBox); profile.append(col);
        });
        card.append(profile, el('p', `제품명에 기록된 성분 표기 ${s.npk.join('–')} · 같은 눈금으로 비교`, 'supply-caption'));
      } else card.append(el('p', s.kind === 'cover' ? '밭을 덮는 비닐 · 영양분 성분 그래프에서 제외했습니다.' : '기록된 수량 전부 사용 · 성분 표기는 추가 확인 중입니다.', 'unclassified'));
      return card;
    }));
  }
  document.querySelectorAll('[data-food-filter]').forEach(b => b.addEventListener('click', () => {
    document.querySelectorAll('[data-food-filter]').forEach(n => n.setAttribute('aria-pressed', String(n === b)));
    showSupplies(b.dataset.foodFilter);
  }));
  $('food-dates').textContent = String(new Set(data.supplies.map(s => s.date)).size).padStart(2, '0');
  $('food-products').textContent = String(data.supplies.length).padStart(2, '0');
  $('food-npk').textContent = String(data.supplies.filter(s => s.npk).length).padStart(2, '0');
  showSupplies();
  function showPerson(index) {
    document.querySelectorAll('#people-path button').forEach((b, i) => b.setAttribute('aria-pressed', String(i === index)));
    const p = data.people[index];
    $('people-detail').replaceChildren(el('p', p.name, 'person-name'), el('h3', p.title), el('p', p.body, 'person-body'), el('p', p.fact, 'person-fact'), el('p', p.foot, 'person-foot'));
  }
  data.people.forEach((p, i) => {
    const b = el('button'); b.type = 'button'; b.setAttribute('aria-pressed', String(i === 0)); b.setAttribute('aria-controls', 'people-detail'); b.append(el('b', p.step), el('span', p.label)); b.addEventListener('click', () => showPerson(i)); $('people-path').append(b);
  });
  showPerson(0);
  let scrollQueued = false;
  const progress = () => { const span = document.documentElement.scrollHeight - innerHeight; $('reading-progress').style.width = `${span > 0 ? Math.min(100, scrollY / span * 100) : 0}%`; scrollQueued = false; };
  addEventListener('scroll', () => { if (!scrollQueued) { requestAnimationFrame(progress); scrollQueued = true; } }, { passive: true });
  addEventListener('resize', progress); progress();

  let rows = [], mode = 'temperature', selectedDate = '';
  $('weather-location').textContent = data.weather.label;
  $('weather-coordinates').textContent = `참고 지점: 북위 ${data.weather.latitude.toFixed(2)}°, 동경 ${data.weather.longitude.toFixed(2)}°. 원북면 원이로 인근을 대표하는 참고 좌표이며 농장의 정확한 위치를 의미하지 않습니다.`;
  const setMessage = (text, error = false) => { $('weather-message').textContent = text; $('weather-message').classList.toggle('error', error); };
  const svgNS = 'http://www.w3.org/2000/svg';
  function sv(tag, attrs, text) { const n = document.createElementNS(svgNS, tag); Object.entries(attrs || {}).forEach(([k, v]) => n.setAttribute(k, v)); if (text != null) n.textContent = text; return n; }
  function renderChart() {
    const chart = $('weather-chart');
    chart.replaceChildren(sv('title', { id: 'weather-chart-title' }, mode === 'rain' ? '재배기간의 일별 강수량' : '재배기간의 일별 최고·최저기온'), sv('desc', { id: 'weather-chart-desc' }, '누락된 값은 빈 구간으로 표시합니다. 아래 일별 수치 표에서 같은 자료를 읽을 수 있습니다.'));
    const values = rows.flatMap(r => mode === 'rain' ? [r.rain] : [r.high, r.low]).filter(v => v !== null);
    if (!values.length) { chart.append(sv('text', { x: 450, y: 130, 'text-anchor': 'middle', fill: '#766a61' }, '이 항목의 공개 자료가 없습니다.')); return; }
    let lo = mode === 'rain' ? 0 : Math.floor((Math.min(...values) - 2) / 5) * 5;
    let hi = mode === 'rain' ? Math.max(5, Math.ceil(Math.max(...values) / 5) * 5) : Math.ceil((Math.max(...values) + 2) / 5) * 5;
    const x = i => rows.length === 1 ? 470 : 60 + i / (rows.length - 1) * 800;
    const y = v => 220 - (v - lo) / (hi - lo) * 192;
    for (let i = 0; i <= 4; i++) {
      const value = lo + (hi - lo) * i / 4, yy = y(value);
      chart.append(sv('line', { x1: 60, x2: 865, y1: yy, y2: yy, stroke: '#ded6c8', 'stroke-dasharray': '3 4' }), sv('text', { x: 47, y: yy + 4, 'text-anchor': 'end', fill: '#766a61' }, num(value)));
    }
    chart.append(sv('text', { x: 18, y: 13, fill: '#766a61' }, mode === 'rain' ? 'mm' : '°C'));
    if (mode === 'rain') {
      const w = Math.min(22, 740 / rows.length);
      rows.forEach((r, i) => { if (r.rain !== null) chart.append(sv('rect', { x: x(i) - w / 2, y: y(r.rain), width: w, height: 220 - y(r.rain), fill: '#60889d', rx: 1 })); });
    } else {
      [['high', '#633951'], ['low', '#60889d']].forEach(([key, color]) => {
        let d = '', connected = false;
        rows.forEach((r, i) => { if (r[key] === null) { connected = false; return; } d += `${connected ? 'L' : 'M'}${x(i).toFixed(2)},${y(r[key]).toFixed(2)} `; connected = true; chart.append(sv('circle', { cx: x(i), cy: y(r[key]), r: rows.length < 32 ? 2.5 : 1.2, fill: color })); });
        chart.append(sv('path', { d, fill: 'none', stroke: color, 'stroke-width': 2, 'stroke-linejoin': 'round' }));
      });
    }
    [...new Set([0, Math.floor((rows.length - 1) / 3), Math.floor((rows.length - 1) * 2 / 3), rows.length - 1])].forEach(i => chart.append(sv('text', { x: x(i), y: 246, 'text-anchor': 'middle', fill: '#766a61' }, shortDate(rows[i].date))));
  }
  const valueText = (v, unit) => v === null ? '자료 없음' : `${num(v)}${unit}`;
  function dayText(r) { return `${fullDate(r.date)} · 최고 ${valueText(r.high, '°C')} / 최저 ${valueText(r.low, '°C')} / 비 ${valueText(r.rain, 'mm')}`; }
  function selectDay(date) {
    selectedDate = date;
    document.querySelectorAll('[data-weather-day]').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.weatherDay === date)));
    $('weather-selected').textContent = dayText(rows.find(r => r.date === date));
  }
  function renderCalendar() {
    const months = new Map();
    rows.forEach(r => { const key = r.date.slice(0, 7); if (!months.has(key)) months.set(key, []); months.get(key).push(r); });
    const values = rows.map(r => mode === 'rain' ? r.rain : r.high).filter(v => v !== null);
    const low = mode === 'rain' ? 0 : Math.min(...values), high = Math.max(...values);
    $('weather-calendars').replaceChildren(...[...months].map(([key, days]) => {
      const month = el('section', null, 'weather-month'); month.append(el('h4', `${key.slice(0, 4)}년 ${Number(key.slice(5))}월`));
      const week = el('div', null, 'weather-weekdays'); week.setAttribute('aria-hidden', 'true'); ['일', '월', '화', '수', '목', '금', '토'].forEach(d => week.append(el('span', d))); month.append(week);
      const grid = el('div', null, 'weather-days');
      for (let i = 0; i < new Date(days[0].date + 'T00:00:00Z').getUTCDay(); i++) grid.append(el('span'));
      days.forEach(r => {
        const b = el('button', Number(r.date.slice(8))); b.type = 'button'; b.dataset.weatherDay = r.date;
        b.setAttribute('aria-label', dayText(r)); b.title = dayText(r); b.setAttribute('aria-pressed', String(r.date === selectedDate));
        const v = mode === 'rain' ? r.rain : r.high;
        if (v === null) b.className = 'missing'; else { const f = high === low ? .3 : Math.max(0, Math.min(1, (v - low) / (high - low))); b.style.setProperty('--day-color', mode === 'rain' ? `hsl(201 28% ${95 - f * 26}%)` : `hsl(331 28% ${95 - f * 25}%)`); }
        b.addEventListener('click', () => selectDay(r.date)); grid.append(b);
      });
      month.append(grid); return month;
    }));
  }
  function renderResults() {
    const highs = rows.filter(r => r.high !== null), rain = rows.filter(r => r.rain !== null);
    const highest = highs.reduce((best, r) => !best || r.high > best.high ? r : best, null);
    $('weather-days').textContent = `${rows.length}일`;
    $('weather-dates').textContent = `${rows[0].date} — ${rows.at(-1).date}`;
    $('weather-high').textContent = highest ? `${num(highest.high)}°C` : '자료 없음';
    $('weather-high-date').textContent = highest ? `${fullDate(highest.date)} · ${highs.length}/${rows.length}일 확보` : '최고기온 자료 없음';
    $('weather-rain').textContent = rain.length ? `${num(rain.reduce((s, r) => s + r.rain, 0))}mm` : '자료 없음';
    $('weather-rain-coverage').textContent = rain.length === rows.length ? `${rows.length}일 전체 합계` : `${rain.length}/${rows.length}일 확보 · 확보된 날짜만 합산`;
    $('weather-wet').textContent = rain.length ? `${rain.filter(r => r.rain >= 1).length}일` : '자료 없음';
    $('weather-wet').nextElementSibling.textContent = `${rain.length}/${rows.length}일의 강수자료에서 계산`;
    $('weather-table').replaceChildren(...rows.map(r => { const tr = el('tr'); [r.date, valueText(r.high, '°C'), valueText(r.low, '°C'), valueText(r.rain, 'mm')].forEach(t => tr.append(el('td', t))); return tr; }));
    selectedDate = rows[0].date;
    $('weather-empty').hidden = true; $('weather-results').hidden = false;
    renderMode(); selectDay(selectedDate); progress();
  }
  function renderMode() {
    document.querySelectorAll('[data-weather-mode]').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.weatherMode === mode)));
    $('weather-legend').replaceChildren(...(mode === 'rain' ? ['일별 강수량 · mm'] : ['최고기온 · °C', '최저기온 · °C']).map(t => el('span', t)));
    $('weather-legend').classList.toggle('rain-legend', mode === 'rain');
    renderChart(); renderCalendar();
  }
  document.querySelectorAll('[data-weather-mode]').forEach(b => b.addEventListener('click', () => { mode = b.dataset.weatherMode; renderMode(); }));
  try {
    const snapshot = window.FARMER_TMI_WEATHER;
    const raw = snapshot?.data;
    const point = raw?.geometry?.coordinates;
    if (!raw || raw.header?.start !== data.weather.start.replaceAll('-', '') || raw.header?.end !== data.weather.end.replaceAll('-', '') || !point || Math.abs(point[0] - data.weather.longitude) > .001 || Math.abs(point[1] - data.weather.latitude) > .001) throw new Error('재배기간의 날씨 자료를 준비하고 있습니다.');
    rows = parseWeather(raw, data.weather.start, data.weather.end);
    renderResults();
    $('weather-retrieved').textContent = `자료 확보일: ${snapshot.retrievedAt.slice(0, 10)} (UTC). 최근 기상자료는 제공처의 보정으로 달라질 수 있습니다.`;
    setMessage('심은 날부터 수확한 날까지, 원북면 인근의 지역 참고 날씨입니다.');
  } catch (err) {
    $('weather-results').hidden = true;
    $('weather-empty').hidden = false;
    setMessage(err.message, true);
  }
})();
