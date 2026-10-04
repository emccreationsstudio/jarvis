// Jarvis masaüstü arayüzü: Jarvis · Takvim · Listeler · Hafıza · Ayarlar
import * as core from "./core.js";
import * as voice from "./voice.js";
import * as reminders from "./reminders.js";

const { esc, fmt, data, settings } = core;
const api = window.jarvis;
const view = document.getElementById("view");
const modalRoot = document.getElementById("modal-root");

const ui = {
  tab: "talk",
  calPage: "week",
  weekOffset: 0,
  year: new Date().getFullYear(),
  month: new Date().getMonth() + 1,
  listPage: "tasks",
  testResult: "",
  alarmResult: "",
  autoLaunch: false,
  info: { platform: "win32", hotkey: "CommandOrControl+Shift+J" }
};

// ================================================================ başlangıç

async function init() {
  await core.loadSettings();
  await core.loadData();
  ui.info = await api.info();
  ui.autoLaunch = await api.getAutoLaunch();
  document.getElementById("hotkey").innerHTML = (ui.info.platform === "darwin" ? "⌘⇧J" : "CTRL+⇧+J") + "<br>DİNLE";

  document.getElementById("nav").addEventListener("click", (e) => {
    const b = e.target.closest("button[data-tab]");
    if (!b) return;
    // "Jarvis" düğmesi: her basışta dinlemeyi de açar
    if (b.dataset.tab === "talk" && !voice.state.conversing && voice.state.phase === "idle") voice.startConversation(true);
    setTab(b.dataset.tab);
  });

  core.onChange((what) => {
    if (what === "show-calendar") {
      ui.calPage = core.uiRequests.calendarPage || "week";
      ui.weekOffset = 0;
      setTab("calendar");
      return;
    }
    scheduleRender(what);
  });
  voice.onState(() => { if (ui.tab === "talk") updateTalk(); });

  api.on("hotkey", () => {
    voice.state.sessionStart = Date.now(); // ekran temiz başlasın (geçmiş saklı)
    setTab("talk");
    voice.startConversation(true);
  });
  api.on("app:focus", () => core.pull());

  render();
  reminders.start();
  core.pull();
  setInterval(() => core.pull(), 120000);
  if (settings.autoListen) setTimeout(() => voice.startConversation(true), 800);
}

function setTab(tab) {
  ui.tab = tab;
  document.querySelectorAll("#nav button[data-tab]").forEach((b) => b.classList.toggle("active", b.dataset.tab === tab));
  render();
}

let renderTimer = null, deferred = false;
function scheduleRender(what) {
  if (ui.tab === "talk") {
    if (what === "messages" || what === "all") updateTalk();
    return;
  }
  // Bir alana yazı yazılıyorsa ekranı yenileyip yazıyı silme; odak kalkınca yenile
  const a = document.activeElement;
  if (a && view.contains(a) && /INPUT|TEXTAREA|SELECT/.test(a.tagName)) { deferred = true; return; }
  clearTimeout(renderTimer);
  renderTimer = setTimeout(render, 30);
}
view.addEventListener("focusout", () => { if (deferred) { deferred = false; setTimeout(render, 50); } });

function render() {
  switch (ui.tab) {
    case "talk": return renderTalk();
    case "calendar": view.innerHTML = `<div class="page">${calendarPage()}</div>`; break;
    case "lists": view.innerHTML = `<div class="page">${listsPage()}</div>`; break;
    case "memory": view.innerHTML = `<div class="page">${memoryPage()}</div>`; break;
    case "settings": view.innerHTML = `<div class="page">${settingsPage()}</div>`; break;
  }
}

// ================================================================ Jarvis (konuşma)

const EXAMPLES = [
  "Alınacaklara domates ve damacana su ekle",
  "Yarın saat 10'da çok önemli toplantım var, alarm gibi hatırlat",
  "Annemin doğum günü 3 Mart, 1962 doğumlu",
  "1 Ekim'de Harbiye'de konuk sanatçı olarak sahneye çıktım",
  "Bu haftamı planla",
  "Maslak'tan Zekeriyaköy'e nasıl giderim?"
];

function renderTalk() {
  view.innerHTML = `
  <div class="talk" id="talk">
    <section class="talk-left">
      <div class="talk-title">${esc(settings.assistantName.toUpperCase())}</div>
      <button class="reactor" id="reactor" title="Dokun ve konuş">
        <div class="halo"></div><div class="ticks"></div>
        <div class="ring r1"></div><div class="ring r2"></div><div class="ring r3"></div>
        <img src="../assets/orb.png" alt="" id="orb"><div class="spinner"></div>
      </button>
      <div>
        <div class="status" id="status"><span class="dot"></span><span id="status-text"></span></div>
      </div>
      <div class="status-hint" id="status-hint"></div>
      <div class="error" id="error"></div>
    </section>
    <section class="talk-right">
      <div class="messages" id="messages"></div>
      <div class="composer">
        <div class="field">
          <textarea id="input" rows="1" placeholder="Jarvis'e yaz…  (Enter: gönder · Shift+Enter: yeni satır)"></textarea>
          <button class="mic-btn" id="mic" title="Sesli konuş">
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/></svg>
          </button>
          <button class="send" id="send" title="Gönder">
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round"><path d="M12 19V5M5 12l7-7 7 7"/></svg>
          </button>
        </div>
      </div>
    </section>
  </div>`;

  const input = document.getElementById("input");
  const sendBtn = document.getElementById("send");
  const grow = () => { input.style.height = "auto"; input.style.height = Math.min(140, input.scrollHeight) + "px"; sendBtn.classList.toggle("ready", !!input.value.trim()); };
  const submit = () => {
    const text = input.value.trim();
    if (!text) return;
    input.value = ""; grow();
    voice.send(text);
  };
  input.addEventListener("input", grow);
  input.addEventListener("focus", () => voice.pauseForTyping());
  input.addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); submit(); } });
  sendBtn.addEventListener("click", submit);
  document.getElementById("reactor").addEventListener("click", () => voice.toggle());
  document.getElementById("mic").addEventListener("click", () => voice.toggle());
  document.getElementById("messages").addEventListener("click", (e) => {
    const li = e.target.closest("li[data-example]");
    if (li) voice.send(li.dataset.example);
  });
  updateTalk();
}

const STATUS = {
  idle: ["HAZIR", "#3ddc84"], listening: ["DİNLİYORUM", "#59c7ff"],
  thinking: ["DÜŞÜNÜYORUM", "#ffd24d"], speaking: ["KONUŞUYOR", "#40a6ff"]
};

function updateTalk() {
  const talk = document.getElementById("talk");
  if (!talk) return;
  const st = voice.state;
  talk.className = "talk phase-" + st.phase;

  let [label, color] = STATUS[st.phase];
  if (st.phase === "idle" && !core.isConfigured()) { label = "AYARLARDAN SUNUCUYU BAĞLAYIN"; color = "#ff9f40"; }
  if (st.phase === "listening" && st.pending.length) label += ` · ${st.pending.length} NOT`;
  const statusEl = document.getElementById("status");
  statusEl.style.color = color;
  document.getElementById("status-text").textContent = label;
  document.getElementById("status-hint").textContent =
    !st.conversing && st.phase === "idle" ? "REAKTÖRE DOKUN YA DA " + (ui.info.platform === "darwin" ? "⌘⇧J" : "CTRL+SHIFT+J")
    : st.phase === "listening" ? "KONUŞ · SUSUNCA CEVAPLARIM · “JARVIS KAPAN” → KAPAT"
    : st.phase === "thinking" ? "EKLEMEK İSTERSEN KONUŞMAYA DEVAM ET"
    : st.phase === "speaking" ? "SUSTURMAK İÇİN REAKTÖRE DOKUN" : "";
  document.getElementById("error").textContent = st.error || "";
  document.getElementById("orb").style.transform = st.phase === "listening" ? `scale(${1 + st.level * 0.12})` : "";
  document.getElementById("mic").classList.toggle("on", st.conversing);

  const box = document.getElementById("messages");
  const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 60;
  const visible = data.messages.filter((m) => new Date(m.date).getTime() >= st.sessionStart).slice(-60);
  let html = "";
  if (!visible.length && !st.pending.length && !st.hearing && !st.transcribing) {
    html = `<div class="glass examples">
      <p>Reaktöre dokun ya da ${ui.info.platform === "darwin" ? "⌘⇧J" : "Ctrl+Shift+J"} tuşlarına bas. Rahatça konuş; susunca hepsini birlikte düşünüp cevaplarım. “Jarvis kapan” ile kapanırım. Yazarak da sorabilirsin.</p>
      <div class="hud-header" style="margin-top:8px">Örnekler</div>
      <ul>${EXAMPLES.map((x) => `<li data-example="${esc(x)}">“${esc(x)}”</li>`).join("")}</ul>
    </div>`;
  }
  html += visible.map((m) => `<div class="bubble ${m.role}">${esc(m.text)}</div>`).join("");
  html += st.pending.map((p) => `<div class="bubble pending">⏳ ${esc(p)}</div>`).join("");
  if (st.hearing) html += `<div class="bubble live">🎙 Dinliyorum…</div>`;
  else if (st.transcribing) html += `<div class="bubble live">✍️ Yazıya çevriliyor…</div>`;
  if (box.dataset.html !== html) {
    box.innerHTML = html;
    box.dataset.html = html;
    if (atBottom || st.phase !== "idle") box.scrollTop = box.scrollHeight;
  }
}

// ================================================================ Takvim

const PRIO_COLOR = { critical: "var(--crit)", high: "var(--high)", normal: "var(--normal)", low: "var(--low)" };
const PRIO_LABEL = { critical: "Kritik", high: "Yüksek", normal: "Normal", low: "Düşük" };

function weekStart(offset) {
  const d = core.startOfDay(new Date());
  const wd = (d.getDay() + 6) % 7; // pazartesi = 0
  return core.addDays(d, -wd + offset * 7);
}

function nearestSpecialText() {
  const now = new Date();
  let best = null;
  for (const s of data.specials) {
    const n = core.nextOccurrence(s, now);
    if (!best || n < best.n) best = { s, n };
  }
  if (!best) return fmt.long(now);
  const days = Math.round((best.n - core.startOfDay(now)) / 86400000);
  if (days === 0) return `Bugün: ${best.s.title}`;
  if (days <= 30) return `${days} gün sonra: ${best.s.title}`;
  return fmt.long(now);
}

function calendarPage() {
  const seg = [["week", "Hafta", 0], ["year", "Yıl", data.specials.length], ["moments", "Anılar", data.moments.length]];
  const head = `
    <div class="page-head">
      <div class="header-text"><h1 class="title">TAKVİM</h1><div class="subtitle">${esc(nearestSpecialText())}</div></div>
      <div class="segmented">${seg.map(([k, l, c]) => `<button data-act="cal-page" data-v="${k}" class="${ui.calPage === k ? "active" : ""}">${l}${c ? ` <span class="badge">${c}</span>` : ""}</button>`).join("")}</div>
    </div>`;
  if (ui.calPage === "year") return head + yearView();
  if (ui.calPage === "moments") return head + momentsView();
  return head + weekView();
}

function weekView() {
  const start = weekStart(ui.weekOffset);
  const days = [...Array(7)].map((_, i) => core.addDays(start, i));
  const label = ui.weekOffset === 0 ? "Bu hafta" : ui.weekOffset === 1 ? "Gelecek hafta" : ui.weekOffset === -1 ? "Geçen hafta" : "";
  const f = (d) => d.toLocaleDateString("tr-TR", { day: "numeric", month: "short" });
  return `
  <div class="week-nav">
    <button class="icon-btn" data-act="week" data-v="-1">‹</button>
    <div class="range">${f(days[0])} – ${f(days[6])}<small>${label}</small></div>
    <button class="icon-btn" data-act="week" data-v="1">›</button>
    ${ui.weekOffset !== 0 ? `<button class="btn ghost small" data-act="week" data-v="0">Bugün</button>` : ""}
    <div style="flex:1"></div>
    <button class="btn" data-act="plan-week">✦ Jarvis haftamı planlasın</button>
  </div>
  <div class="week">${days.map(dayCard).join("")}</div>`;
}

function dayCard(day) {
  const hol = core.holidaysBetween(day, day);
  const sp = core.specialsOn(day);
  const mo = core.momentsOn(day);
  const tasks = core.tasksOn(day);
  const today = core.sameDay(day, new Date());
  let body = "";
  body += hol.map((h) => `<div class="chip" style="color:${core.HOLIDAY_COLOR[h.kind]}">${esc(h.title)}</div>`).join("");
  body += sp.map((s) => {
    const y = core.yearsOn(s, day);
    return `<div class="chip" style="color:${core.KIND[s.kind]?.color}">${core.KIND[s.kind]?.icon} ${esc(s.title)}${y ? ` · ${y}. ${s.kind === "birthday" ? "yaş" : "yıl"}` : ""}</div>`;
  }).join("");
  body += tasks.map((t) => `
    <div class="agenda" style="color:${PRIO_COLOR[t.priority] || PRIO_COLOR.normal};${t.done ? "opacity:.45" : ""}">
      <span class="t">${fmt.time(t.due)}</span><span class="bar"></span>
      <span style="color:#fff">${t.done ? "✓ " : ""}${esc(t.title)}</span>
    </div>`).join("");
  body += mo.map((m) => `<div class="chip" style="color:#4dd8ff">✦ Anı: ${esc(m.title)}</div>`).join("");
  if (!body) body = `<div class="free">Boş gün</div>`;
  return `
  <div class="glass day ${today ? "today" : ""}">
    <h4><span style="text-transform:capitalize">${fmt.weekday(day)}</span>${today ? `<span class="today-tag">BUGÜN</span>` : `<small>${fmt.dayMonth(day)}</small>`}</h4>
    ${today ? `<small style="color:var(--dim);font-size:11px;margin-top:-4px">${fmt.dayMonth(day)}</small>` : ""}
    ${body}
  </div>`;
}

function marksFor(date, hols) {
  const out = [];
  if (core.specialsOn(date).length) out.push("#ff5fa2");
  for (const h of hols) if (core.sameDay(h.date, date) && !out.includes(core.HOLIDAY_COLOR[h.kind])) out.push(core.HOLIDAY_COLOR[h.kind]);
  if (core.momentsOn(date).length) out.push("#4dd8ff");
  return out;
}

function yearView() {
  const hols = core.holidays(ui.year);
  const months = [...Array(12)].map((_, i) => {
    const m = i + 1;
    const first = new Date(ui.year, i, 1);
    const count = new Date(ui.year, m, 0).getDate();
    const lead = (first.getDay() + 6) % 7;
    let cells = ["P", "S", "Ç", "P", "C", "C", "P"].map((w) => `<div class="wd">${w}</div>`).join("");
    for (let k = 0; k < lead; k++) cells += `<div class="d"></div>`;
    for (let d = 1; d <= count; d++) {
      const date = new Date(ui.year, i, d);
      const dots = marksFor(date, hols);
      const today = core.sameDay(date, new Date());
      cells += `<div class="d ${dots.length ? "marked" : ""} ${today ? "today" : ""}"><span>${d}</span><div class="dots">${dots.slice(0, 3).map((c) => `<i style="background:${c}"></i>`).join("")}</div></div>`;
    }
    return `<div class="glass month ${ui.month === m ? "selected" : ""}" data-act="month" data-v="${m}"><h5>${fmt.month(first)}</h5><div class="mgrid">${cells}</div></div>`;
  }).join("");

  // Seçilen ayın ayrıntısı
  const items = [];
  for (const h of hols) if (h.date.getMonth() + 1 === ui.month) items.push({ d: h.date, c: core.HOLIDAY_COLOR[h.kind], t: h.title });
  for (const s of data.specials) if (s.month === ui.month) {
    const d = new Date(ui.year, s.month - 1, s.day), y = core.yearsOn(s, d);
    items.push({ d, c: core.KIND[s.kind]?.color, t: `${core.KIND[s.kind]?.icon} ${s.title}${y ? ` · ${y}. ${s.kind === "birthday" ? "yaş" : "yıl"}` : ""}` });
  }
  for (const m of data.moments) if (m.date.getFullYear() === ui.year && m.date.getMonth() + 1 === ui.month) items.push({ d: m.date, c: "#4dd8ff", t: "✦ " + m.title });
  items.sort((a, b) => a.d - b.d);

  const specials = [...data.specials].sort((a, b) => core.nextOccurrence(a) - core.nextOccurrence(b));
  const left = (d) => { const n = Math.round((d - core.startOfDay(new Date())) / 86400000); return n === 0 ? "Bugün" : n === 1 ? "Yarın" : `${n} gün`; };

  return `
  <div class="week-nav">
    <button class="icon-btn" data-act="year" data-v="-1">‹</button>
    <div class="range" style="font:300 22px var(--mono);letter-spacing:4px">${ui.year}</div>
    <button class="icon-btn" data-act="year" data-v="1">›</button>
    <div style="flex:1"></div>
    <div class="legend"><span><i style="background:#ff5fa2"></i>Özel gün</span><span><i style="background:#ff4d4d"></i>Resmî</span><span><i style="background:#3ddc84"></i>Dini</span><span><i style="background:#b07cff"></i>Kutlama</span><span><i style="background:#4dd8ff"></i>Anı</span></div>
  </div>
  <div style="display:grid;grid-template-columns:minmax(0,1fr) 320px;gap:16px;align-items:start">
    <div class="year-grid">${months}</div>
    <div>
      <div class="glass card detail-list">
        <h3>${esc(core.upperTR(fmt.month(new Date(ui.year, ui.month - 1, 1))))}</h3>
        ${items.length ? items.map((it) => `<div><span class="n">${it.d.getDate()}</span><span style="color:${it.c}">●</span><span>${esc(it.t)}</span></div>`).join("") : `<div class="hint">Bu ayda işaretli gün yok.</div>`}
      </div>
      <div class="hud-header" style="display:flex;justify-content:space-between;align-items:center">Özel günlerim <button class="btn small ghost" data-act="add-special">+ Ekle</button></div>
      ${specials.length ? specials.map((s) => {
        const n = core.nextOccurrence(s), y = core.yearsOn(s, n);
        return `<div class="glass row">
          <span style="color:${core.KIND[s.kind]?.color};font-size:18px">${core.KIND[s.kind]?.icon}</span>
          <div class="grow"><div>${esc(s.title)}</div><div class="meta">${fmt.dayMonth(n)}${y ? ` · ${y}. ${s.kind === "birthday" ? "yaş" : "yıl"}` : ""}</div></div>
          <span style="color:var(--glow);font-size:12px;font-weight:600">${left(n)}</span>
          <div class="actions"><button class="icon-btn" data-act="del-special" data-id="${s.id}" title="Sil">✕</button></div>
        </div>`;
      }).join("") : `<div class="hint">Jarvis'e “Annemin doğum günü 3 Mart” diyebilir ya da Ekle'ye basabilirsin. Her yıl 1 hafta önce ve o gün hatırlatırım.</div>`}
    </div>
  </div>`;
}

function momentsView() {
  const groups = {};
  for (const m of data.moments) (groups[m.date.getFullYear()] ||= []).push(m);
  const years = Object.keys(groups).sort((a, b) => b - a);
  return `
  <button class="btn" data-act="add-moment">+ Anı ekle</button>
  ${!data.moments.length ? `<div class="glass card" style="margin-top:16px;max-width:560px"><div>Henüz anı yok.</div><div class="note">Jarvis'e anlatman yeterli: “1 Ekim'de Harbiye'de konuk sanatçı olarak sahneye çıktım.” Senin için saklarım.</div></div>` : ""}
  ${years.map((y) => `
    <div class="hud-header">${y}</div>
    <div class="moments">${groups[y].sort((a, b) => b.date - a.date).map((m) => `
      <div class="glass moment">
        <div class="date"><b>${m.date.getDate()}</b><small>${core.upperTR(m.date.toLocaleDateString("tr-TR", { month: "short" }))}</small></div>
        <div><h4>${esc(m.title)}</h4>
          ${m.place ? `<div class="place">📍 ${esc(m.place)}</div>` : ""}
          ${m.note ? `<div class="note">${esc(m.note)}</div>` : ""}
        </div>
        <button class="icon-btn del" data-act="del-moment" data-id="${m.id}" title="Sil">✕</button>
      </div>`).join("")}
    </div>`).join("")}
  <div class="hint" style="margin-top:20px">Yakında: anılarına fotoğraflarını da ekleyebileceksin.</div>`;
}

// ================================================================ Listeler

function listsPage() {
  const open = core.openTasks();
  const crit = open.filter((t) => t.priority === "critical").length;
  const shop = data.shopping.filter((s) => !s.done), calls = data.calls.filter((c) => !c.done);
  const sub = crit ? `${crit} kritik görev var` : (!open.length && !shop.length && !calls.length) ? "Her şey yolunda"
    : `${open.length} görev · ${shop.length} ürün · ${calls.length} arama`;
  const seg = [["tasks", "Görevler", open.length], ["shopping", "Alışveriş", shop.length], ["calls", "Aranacak", calls.length],
    ...data.lists.map((l) => ["list:" + l.id, l.name, (l.items || []).filter((i) => !i.done).length])];
  if (!seg.some(([k]) => k === ui.listPage)) ui.listPage = "tasks";
  let body = "";
  if (ui.listPage === "tasks") {
    body = addField("task", "Yeni görev") + (open.length ? `<div class="hud-header">Açık görevler</div>` : "") +
      (open.length ? open.map(taskRow).join("") : `<div class="glass empty">Açık görev yok. Jarvis'e söyleyebilir ya da yukarıdan ekleyebilirsin.</div>`);
  } else if (ui.listPage.startsWith("list:")) {
    const l = data.lists.find((x) => "list:" + x.id === ui.listPage);
    const items = l.items || [];
    body = addField("litem:" + l.id, `${l.name} listesine ekle`) + (l.daily ? `<div class="meta" style="margin:4px 0 8px">Günlük liste · işaretler her sabah kalkar</div>` : "") +
      (items.length ? items.map((i) => `
        <div class="glass row" style="${i.done ? "opacity:.5" : ""}"><button class="check" style="color:var(--glow)" data-act="litem-toggle" data-id="${l.id}" data-v="${i.id}" title="İşaretle">${i.done ? "✓" : ""}</button>
          <div class="grow" style="${i.done ? "text-decoration:line-through" : ""}">${esc(i.text)}</div></div>`).join("")
        : `<div class="glass empty">Liste boş. “${esc(l.name)} listesine … ekle” diyebilirsin.</div>`);
  } else if (ui.listPage === "shopping") {
    body = addField("shop", "Ürün ekle") + (shop.length ? `<div class="hud-header">Alınacaklar</div>` : "") +
      (shop.length ? shop.map((s) => `
        <div class="glass row"><button class="check" style="color:var(--glow)" data-act="shop-done" data-id="${s.id}" title="Alındı"></button>
          <div class="grow">${esc(s.name)}</div></div>`).join("") + `<button class="btn danger small" data-act="shop-clear" style="margin-top:8px">Listeyi temizle</button>`
        : `<div class="glass empty">Liste boş. “Alınacaklara süt ekle” diyebilirsin.</div>`);
  } else {
    body = addField("call", "Kimi arayacaksın?") + (calls.length ? `<div class="hud-header">Aranacaklar</div>` : "") +
      (calls.length ? calls.map((c) => `
        <div class="glass row">
          <span style="width:36px;height:36px;border-radius:50%;display:grid;place-items:center;background:rgba(64,166,255,.25);border:1px solid rgba(89,199,255,.5);color:var(--glow);font-weight:600">${esc(core.upperTR(c.person.charAt(0)))}</span>
          <div class="grow"><div>${esc(c.person)}</div>${c.reason ? `<div class="meta">${esc(c.reason)}</div>` : ""}</div>
          <button class="btn small ghost" data-act="call-done" data-id="${c.id}">✓ Arandı</button>
        </div>`).join("") : `<div class="glass empty">Aranacak kimse yok.</div>`);
  }
  return `
  <div class="page-head">
    <div class="header-text"><h1 class="title">LİSTELER</h1><div class="subtitle">${esc(sub)}</div></div>
    <div class="segmented">${seg.map(([k, l, c]) => `<button data-act="list-page" data-v="${k}" class="${ui.listPage === k ? "active" : ""}">${l}${c ? ` <span class="badge">${c}</span>` : ""}</button>`).join("")}</div>
  </div>
  <div style="max-width:820px">${body}</div>`;
}

function addField(kind, placeholder) {
  return `<form class="field" data-form="${kind}" style="margin-bottom:6px">
    <input name="text" placeholder="${esc(placeholder)}" autocomplete="off">
    <button class="plus" type="submit">+</button></form>`;
}

function taskRow(t) {
  const color = PRIO_COLOR[t.priority] || PRIO_COLOR.normal;
  const late = t.due && t.due < new Date();
  return `
  <div class="glass row" style="color:${color}">
    <span class="prio-bar"></span>
    <button class="check" data-act="task-done" data-id="${t.id}" title="Tamamlandı"></button>
    <div class="grow" style="color:#fff;cursor:pointer" data-act="task-edit" data-id="${t.id}">
      <div>${esc(t.title)}</div>
      <div class="meta">
        ${t.due ? `<span style="color:${late ? "var(--crit)" : "var(--dim)"}">${t.priority === "critical" ? "⏰" : "🔔"} ${fmt.friendly(t.due)}</span>` : ""}
        ${t.priority !== "normal" ? `<span class="pill" style="color:${color}">${PRIO_LABEL[t.priority]}</span>` : ""}
      </div>
    </div>
    <div class="actions">
      <button class="icon-btn" data-act="task-edit" data-id="${t.id}" title="Düzenle">✎</button>
      <button class="icon-btn" data-act="task-del" data-id="${t.id}" title="Sil">✕</button>
    </div>
  </div>`;
}

// ================================================================ Hafıza

function memoryPage() {
  const notes = [...data.memory].reverse();
  return `
  <div class="page-head"><div class="header-text"><h1 class="title">HAFIZA</h1>
    <div class="subtitle">${notes.length ? `${notes.length} kayıt · her konuşmada dikkate alınır` : "Jarvis henüz bir şey ezberlemedi"}</div></div></div>
  <div style="max-width:820px">
    ${addField("memory", "Jarvis neyi hatırlasın?")}
    <div class="hint" style="margin:4px 4px 0">Konuşurken “bunu hatırla” demen de yeterli.</div>
    ${notes.length ? `<div class="hud-header">Bildikleri</div>` : ""}
    ${notes.map((n) => `
      <div class="glass row"><span style="color:var(--glow)">🔖</span><div class="grow">${esc(n.text)}</div>
        <div class="actions"><button class="icon-btn" data-act="mem-del" data-id="${n.id}" title="Sil">✕</button></div></div>`).join("")}
    ${!notes.length ? `<div class="glass empty" style="margin-top:14px">Örnek: “Pazartesi ve perşembe stüdyom var”, “Bostancı'daki müşteri Ahmet Bey”.</div>` : ""}
  </div>`;
}

// ================================================================ Ayarlar

const sw = (key, checked) => `<span class="switch"><input type="checkbox" data-set="${key}" ${checked ? "checked" : ""}><span></span></span>`;

function settingsPage() {
  const toneLabel = ["Çok kalın", "Kalın", "Orta", "İnce", "Çok ince"][Math.round(settings.voiceTone * 4)];
  const speedLabel = settings.voiceSpeed < 0.93 ? "Yavaş" : settings.voiceSpeed < 1.12 ? "Normal" : settings.voiceSpeed < 1.27 ? "Hızlı" : "Çok hızlı";
  const key = ui.info.platform === "darwin" ? "⌘ + ⇧ + J" : "Ctrl + Shift + J";
  return `
  <div class="page-head"><div class="header-text"><h1 class="title">AYARLAR</h1><div class="subtitle">${core.isConfigured() ? "Sunucu bağlı" : "Sunucu bağlı değil"}</div></div></div>
  <div class="settings">
    <div class="glass card">
      <h3>SUNUCU</h3>
      <input type="url" data-text="serverURL" placeholder="https://jarvis.….workers.dev" value="${esc(settings.serverURL)}">
      <input type="password" data-text="token" placeholder="Uygulama şifresi (APP_TOKEN)" value="${esc(settings.token)}">
      <div class="btns"><button class="btn" data-act="test-conn">⚡ Bağlantıyı test et</button></div>
      ${ui.testResult ? `<div class="result">${esc(ui.testResult)}</div>` : ""}
      <div class="note">Telefondaki Jarvis'e girdiğin sunucu adresi ve şifrenin aynısı.</div>
    </div>

    <div class="glass card">
      <h3>SES</h3>
      <label class="line">Doğal ses (yapay zekâ) ${sw("naturalVoice", settings.naturalVoice)}</label>
      ${settings.naturalVoice ? `<label class="line">Ses
        <span class="segmented"><button data-act="voice-gender" data-v="0" class="${!settings.voiceFemale ? "active" : ""}">Erkek</button><button data-act="voice-gender" data-v="1" class="${settings.voiceFemale ? "active" : ""}">Kadın</button></span></label>` : ""}
      <div class="line" style="display:block;padding:9px 0"><div style="display:flex;justify-content:space-between;font-size:14px">Ton <span style="color:var(--dim)">${toneLabel}</span></div>
        <input type="range" min="0" max="1" step="0.25" value="${settings.voiceTone}" data-range="voiceTone">
        <div class="slider-labels"><span>Kalın</span><span>İnce</span></div></div>
      <div class="line" style="display:block;padding:9px 0"><div style="display:flex;justify-content:space-between;font-size:14px">Konuşma hızı <span style="color:var(--dim)">${speedLabel}</span></div>
        <input type="range" min="0.8" max="1.4" step="0.05" value="${settings.voiceSpeed}" data-range="voiceSpeed">
        <div class="slider-labels"><span>🐢 Yavaş</span><span>Hızlı 🐇</span></div></div>
      <label class="line">Cevapları sesli oku ${sw("speakReplies", settings.speakReplies)}</label>
      <div class="btns"><button class="btn ghost" data-act="voice-test">🔊 Sesi dene</button></div>
    </div>

    <div class="glass card">
      <h3>HATIRLATMALAR</h3>
      <label class="line">Tüm hatırlatmalar alarm gibi çalsın ${sw("alarmAll", settings.alarmAll)}</label>
      <div class="btns"><button class="btn ghost" data-act="alarm-test">⏰ Alarmı dene (10 sn)</button></div>
      ${ui.alarmResult ? `<div class="result">${esc(ui.alarmResult)}</div>` : ""}
      <div class="note">Alarm: her pencerenin üstünde, sesli bir uyarı penceresi açılır. Jarvis tepside çalıştığı sürece hatırlatır; pencereyi kapatmak Jarvis'i kapatmaz.</div>
    </div>

    <div class="glass card">
      <h3>CİHAZLAR ARASI EŞİTLEME</h3>
      <label class="line">Telefonla eşitle ${sw("syncEnabled", settings.syncEnabled)}</label>
      ${settings.syncEnabled ? `<div class="btns"><button class="btn ghost" data-act="sync-now">⟳ Şimdi eşitle</button></div><div class="result">${esc(core.syncState.status)}</div>` : ""}
      <div class="note">Açıksa görevler, listeler, takvim, özel günler, anılar ve hafıza iPhone'daki Jarvis ile ortak olur. İki cihazda da açık olmalı; sunucuda JARVIS_KV kurulu olmalı.</div>
    </div>

    <div class="glass card">
      <h3>KİŞİSEL</h3>
      <input type="text" data-text="userName" placeholder="Adın" value="${esc(settings.userName)}">
      <input type="text" data-text="assistantName" placeholder="Asistanın adı" value="${esc(settings.assistantName)}">
      <label class="line">Açılınca hemen dinlemeye başla ${sw("autoListen", settings.autoListen)}</label>
      <label class="line">Bilgisayar açılınca başlat ${`<span class="switch"><input type="checkbox" data-act-change="autolaunch" ${ui.autoLaunch ? "checked" : ""}><span></span></span>`}</label>
    </div>

    <div class="glass card">
      <h3>HIZLI ERİŞİM</h3>
      <div class="line" style="font-size:14px;line-height:1.6">
        <b style="color:var(--glow)">${key}</b> — Jarvis her yerden açılır ve dinlemeye başlar.<br>
        Pencereyi kapatınca Jarvis saatin yanındaki ${ui.info.platform === "darwin" ? "menü çubuğunda" : "sistem tepsisinde"} çalışmaya devam eder.<br>
        Tamamen çıkmak için tepsi simgesine sağ tıklayıp <b>Çık</b>.
      </div>
    </div>
  </div>`;
}

// ================================================================ olaylar

view.addEventListener("click", async (e) => {
  const el = e.target.closest("[data-act]");
  if (!el || el.tagName === "INPUT") return;
  const { act, v, id } = el.dataset;
  switch (act) {
    case "cal-page": ui.calPage = v; break;
    case "week": ui.weekOffset = v === "0" ? 0 : ui.weekOffset + Number(v); break;
    case "year": ui.year += Number(v); break;
    case "month": ui.month = Number(v); break;
    case "plan-week":
      setTab("talk");
      voice.send(ui.weekOffset === 1 ? "Gelecek haftamı planla" : "Bu haftamı planla");
      return;
    case "add-special": return specialModal();
    case "del-special": if (confirmDelete()) core.removeSpecial(id); return;
    case "add-moment": return momentModal();
    case "del-moment": if (confirmDelete()) core.removeMoment(id); return;
    case "list-page": ui.listPage = v; break;
    case "task-done": core.completeTask(id); return;
    case "task-del": core.deleteTask(id); return;
    case "task-edit": return taskModal(core.findTask(id));
    // Dokununca işaretlenir (silinmez); temizlenenler iPhone'daki çöp kutusuna gider
    case "shop-done": { const s = data.shopping.find((x) => x.id === id); if (s) s.done = true; core.changed("shopping"); return; }
    case "shop-clear": core.clearShopping(); return;
    case "call-done": { const c = data.calls.find((x) => x.id === id); if (c) c.done = true; core.changed("calls"); return; }
    case "litem-toggle": {
      const l = data.lists.find((x) => x.id === id);
      const i = l?.items?.find((x) => x.id === v);
      if (i) { i.done = !i.done; core.changed("lists"); }
      return;
    }
    case "mem-del": {
      const m = data.memory.find((x) => x.id === id);
      if (m) core.toTrash("memory", "memory", { id: m.id, text: m.text, createdAt: new Date(m.createdAt || Date.now()).toISOString().replace(/\.\d{3}Z$/, "Z") });
      data.memory = data.memory.filter((x) => x.id !== id);
      core.changed("memory");
      return;
    }
    case "voice-gender": await core.saveSettings({ voiceFemale: v === "1" }); break;
    case "voice-test": voice.speak(`Merhaba ${settings.userName}, ben ${settings.assistantName}. Bugün senin için ne yapabilirim?`); return;
    case "alarm-test": reminders.testAlarm(); ui.alarmResult = "Alarm 10 saniye sonra açılacak."; break;
    case "sync-now": await core.pull(); break;
    case "test-conn": {
      ui.testResult = "Deneniyor…"; render();
      try {
        const r = await core.chat("Bağlantı testi. Sadece 'Bağlantı tamam' de, hiçbir işlem yapma.");
        ui.testResult = "Bağlantı başarılı: " + r.reply;
      } catch (err) { ui.testResult = "Bağlantı kurulamadı: " + err.message; }
      break;
    }
    default: return;
  }
  render();
});

const confirmDelete = () => window.confirm("Silinsin mi?");

view.addEventListener("submit", (e) => {
  const form = e.target.closest("form[data-form]");
  if (!form) return;
  e.preventDefault();
  const text = form.elements.text.value.trim();
  if (!text) return;
  form.elements.text.value = "";
  switch (form.dataset.form) {
    case "task": core.upsertTask({ id: core.uuid(), title: text, due: null, priority: "normal", done: false, createdAt: new Date() }); break;
    case "shop": core.addShopping([text]); break;
    default:
      if (form.dataset.form.startsWith("litem:")) {
        const l = data.lists.find((x) => "litem:" + x.id === form.dataset.form);
        if (l) core.addListItems(l.name, [text]);
      }
      break;
    case "call": data.calls.push({ id: core.uuid(), person: text, reason: null, createdAt: new Date() }); core.changed("calls"); break;
    case "memory": data.memory.push({ id: core.uuid(), text, createdAt: new Date() }); core.changed("memory"); break;
  }
  setTimeout(() => view.querySelector(`form[data-form="${form.dataset.form}"] input`)?.focus(), 60);
});

view.addEventListener("change", async (e) => {
  const t = e.target;
  if (t.dataset.set) {
    await core.saveSettings({ [t.dataset.set]: t.checked });
    if (t.dataset.set === "syncEnabled" && t.checked) await core.pull();
    render();
  } else if (t.dataset.text) {
    await core.saveSettings({ [t.dataset.text]: t.value.trim() });
  } else if (t.dataset.range) {
    await core.saveSettings({ [t.dataset.range]: Number(t.value) });
    render();
  } else if (t.dataset.actChange === "autolaunch") {
    ui.autoLaunch = await api.setAutoLaunch(t.checked);
  }
});

// ================================================================ pencereler (düzenle / ekle)

function modal(title, inner, onSave) {
  modalRoot.innerHTML = `<div class="modal-back"><form class="modal"><h3>${esc(title)}</h3>${inner}
    <div class="btns"><button type="button" class="btn ghost" data-close>Vazgeç</button><button type="submit" class="btn">Kaydet</button></div></form></div>`;
  const form = modalRoot.querySelector("form");
  const close = () => { modalRoot.innerHTML = ""; };
  modalRoot.querySelector("[data-close]").onclick = close;
  modalRoot.querySelector(".modal-back").addEventListener("mousedown", (e) => { if (e.target.classList.contains("modal-back")) close(); });
  form.onsubmit = (e) => { e.preventDefault(); if (onSave(form.elements) !== false) close(); };
  form.querySelector("input,textarea")?.focus();
}

const localInput = (d) => (d ? core.wire(d) : "");

function taskModal(t) {
  if (!t) return;
  modal("GÖREV", `
    <label>Başlık</label><input name="title" value="${esc(t.title)}" required>
    <label>Zaman (boş: hatırlatma yok)</label><input name="due" type="datetime-local" value="${localInput(t.due)}">
    <label>Önem</label><select name="priority">${["low", "normal", "high", "critical"].map((p) => `<option value="${p}" ${t.priority === p ? "selected" : ""}>${PRIO_LABEL[p]}</option>`).join("")}</select>
    <div class="hint" style="margin-top:10px">Kritik: alarm penceresi + 30 dk önce uyarı. Yüksek: alarm. Düşük: sessiz bildirim.</div>`,
    (f) => {
      if (!f.title.value.trim()) return false;
      core.upsertTask({ ...t, title: f.title.value.trim(), due: core.parseWire(f.due.value), priority: f.priority.value });
    });
}

function specialModal() {
  modal("ÖZEL GÜN", `
    <label>Tür</label><select name="kind">${Object.entries(core.KIND).map(([k, v]) => `<option value="${k}">${v.label}</option>`).join("")}</select>
    <label>Başlık</label><input name="title" placeholder="ör. Annemin doğum günü" required>
    <label>Kişi (isteğe bağlı)</label><input name="person">
    <label>Tarih</label><input name="date" type="date" required>
    <label class="inline"><input type="checkbox" name="knows"> Yılı biliyorum (yaşı hesaplansın)</label>`,
    (f) => {
      const d = core.parseWire(f.date.value);
      if (!d || !f.title.value.trim()) return false;
      core.addSpecial({ id: core.uuid(), title: f.title.value.trim(), person: f.person.value.trim() || null,
        month: d.getMonth() + 1, day: d.getDate(), year: f.knows.checked ? d.getFullYear() : undefined, kind: f.kind.value });
    });
}

function momentModal() {
  modal("ANI", `
    <label>Ne oldu?</label><input name="title" placeholder="ör. Harbiye'de konuk sanatçı" required>
    <label>Tarih</label><input name="date" type="datetime-local" value="${core.wire(new Date())}">
    <label>Yer (isteğe bağlı)</label><input name="place">
    <label>Ayrıntılar</label><textarea name="note" rows="4" placeholder="Duygular, kimler vardı…"></textarea>`,
    (f) => {
      if (!f.title.value.trim()) return false;
      core.addMoment({ id: core.uuid(), title: f.title.value.trim(), date: core.parseWire(f.date.value) || new Date(),
        place: f.place.value.trim() || null, note: f.note.value.trim() || null, createdAt: new Date() });
    });
}

init();
