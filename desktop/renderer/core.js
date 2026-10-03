// Jarvis çekirdeği: veri, ayarlar, sunucu, işlemler, eşitleme, tarih yardımcıları.
// Veri biçimi iPhone uygulamasıyla birebir aynıdır (eşitleme için).

const api = window.jarvis;

// ---------------------------------------------------------------- yardımcılar

export const uuid = () => (crypto.randomUUID ? crypto.randomUUID() : String(Date.now()) + Math.random()).toUpperCase();
export const pad = (n) => String(n).padStart(2, "0");
export const iso = (d) => new Date(d).toISOString(); // 2026-10-03T10:00:00.123Z
const isoNoMs = (d) => new Date(d).toISOString().replace(/\.\d{3}Z$/, "Z"); // iPhone'un .iso8601 biçimi

/** Sunucu ile alışveriş biçimi: 2026-10-03T09:00 (yerel saat) */
export function wire(d) {
  d = new Date(d);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}
export function dayKey(d) {
  d = new Date(d);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}
/** "2026-10-03T09:00" ya da "2026-10-03" → Date (yerel saat) */
export function parseWire(s) {
  if (!s) return null;
  const m = String(s).trim().match(/^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2}))?/);
  if (!m) { const d = new Date(s); return isNaN(d) ? null : d; }
  return new Date(+m[1], +m[2] - 1, +m[3], m[4] ? +m[4] : 0, m[5] ? +m[5] : 0);
}
export const startOfDay = (d) => { d = new Date(d); d.setHours(0, 0, 0, 0); return d; };
export const addDays = (d, n) => { d = new Date(d); d.setDate(d.getDate() + n); return d; };
export const sameDay = (a, b) => dayKey(a) === dayKey(b);

const TR = "tr-TR";
export const fmt = {
  time: (d) => new Date(d).toLocaleTimeString(TR, { hour: "2-digit", minute: "2-digit" }),
  dayMonth: (d) => new Date(d).toLocaleDateString(TR, { day: "numeric", month: "long" }),
  long: (d) => new Date(d).toLocaleDateString(TR, { day: "numeric", month: "long", year: "numeric" }),
  weekday: (d) => new Date(d).toLocaleDateString(TR, { weekday: "long" }),
  month: (d) => new Date(d).toLocaleDateString(TR, { month: "long" }),
  now: (d) => {
    d = new Date(d);
    return `${dayKey(d)} ${d.toLocaleDateString(TR, { weekday: "long" })} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
  },
  friendly: (d) => {
    d = new Date(d);
    const t = fmt.time(d);
    if (sameDay(d, new Date())) return `Bugün ${t}`;
    if (sameDay(d, addDays(new Date(), 1))) return `Yarın ${t}`;
    if (sameDay(d, addDays(new Date(), -1))) return `Dün ${t}`;
    return `${d.toLocaleDateString(TR, { day: "numeric", month: "short", weekday: "short" })} ${t}`;
  }
};
export const upperTR = (s) => s.toLocaleUpperCase(TR);
export const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

// ---------------------------------------------------------------- olaylar

const listeners = new Set();
export const onChange = (fn) => listeners.add(fn);
export const emit = (what) => listeners.forEach((fn) => fn(what));

// ---------------------------------------------------------------- ayarlar

const DEFAULT_SETTINGS = {
  serverURL: "", userName: "Ertunç", assistantName: "Jarvis",
  speakReplies: true, autoListen: false, alarmAll: true, syncEnabled: false,
  naturalVoice: true, voiceFemale: false, voiceTone: 0, voiceSpeed: 1.05
};
export const settings = { ...DEFAULT_SETTINGS, token: "" };

export async function loadSettings() {
  try { Object.assign(settings, JSON.parse(localStorage.getItem("settings") || "{}")); } catch {}
  settings.token = (await api.getSecret("appToken")) || "";
}
export async function saveSettings(patch = {}) {
  Object.assign(settings, patch);
  const { token, ...rest } = settings;
  try { localStorage.setItem("settings", JSON.stringify(rest)); } catch {}
  if ("token" in patch) await api.setSecret("appToken", patch.token || "");
  emit("settings");
}
export const isConfigured = () => /^https?:\/\//.test(settings.serverURL.trim()) && !!settings.token;

const MALE = ["onyx", "ash", "ballad", "echo", "verse"];
const FEMALE = ["sage", "coral", "alloy", "shimmer", "nova"];
export function voiceName() {
  const list = settings.voiceFemale ? FEMALE : MALE;
  return list[Math.max(0, Math.min(list.length - 1, Math.round(settings.voiceTone * (list.length - 1))))];
}

// ---------------------------------------------------------------- veri (iPhone ile aynı biçim)

export const data = {
  tasks: [], shopping: [], calls: [], memory: [], messages: [], specials: [], moments: [],
  updatedAt: 0 // ms
};

const reviveDate = (s) => (s ? new Date(s) : null);

function fromSnapshot(snap) {
  return {
    tasks: (snap.tasks || []).map((t) => ({ ...t, due: reviveDate(t.due), createdAt: reviveDate(t.createdAt) || new Date() })),
    shopping: (snap.shopping || []).map((x) => ({ ...x, createdAt: reviveDate(x.createdAt) || new Date() })),
    calls: (snap.calls || []).map((x) => ({ ...x, createdAt: reviveDate(x.createdAt) || new Date() })),
    memory: (snap.memory || []).map((x) => ({ ...x, createdAt: reviveDate(x.createdAt) || new Date() })),
    messages: (snap.messages || []).map((x) => ({ ...x, date: reviveDate(x.date) || new Date() })),
    specials: snap.specials || [],
    moments: (snap.moments || []).map((x) => ({ ...x, date: reviveDate(x.date) || new Date(), createdAt: reviveDate(x.createdAt) || new Date() }))
  };
}

function clean(o) {
  const out = {};
  for (const [k, v] of Object.entries(o)) {
    if (v === null || v === undefined) continue; // iPhone tarafı eksik alanı "yok" olarak okur
    out[k] = v instanceof Date ? isoNoMs(v) : v;
  }
  return out;
}

export function snapshot() {
  return {
    tasks: data.tasks.map((t) => clean({ id: t.id, title: t.title, due: t.due, priority: t.priority || "normal", done: !!t.done, createdAt: t.createdAt, alarmID: t.alarmID })),
    shopping: data.shopping.map((x) => clean({ id: x.id, name: x.name, createdAt: x.createdAt })),
    calls: data.calls.map((x) => clean({ id: x.id, person: x.person, reason: x.reason, createdAt: x.createdAt })),
    memory: data.memory.map((x) => clean({ id: x.id, text: x.text, createdAt: x.createdAt })),
    messages: data.messages.slice(-200).map((x) => clean({ id: x.id, role: x.role, text: x.text, date: x.date })),
    specials: data.specials.map((x) => clean({ id: x.id, title: x.title, person: x.person, month: x.month, day: x.day, year: x.year, kind: x.kind || "special", note: x.note })),
    moments: data.moments.map((x) => clean({ id: x.id, title: x.title, date: x.date, place: x.place, note: x.note, createdAt: x.createdAt })),
    updatedAt: isoNoMs(data.updatedAt || Date.now())
  };
}

let applyingRemote = false;
let saveTimer = null;

export async function loadData() {
  const text = await api.loadData();
  if (!text) return;
  try {
    const snap = JSON.parse(text);
    Object.assign(data, fromSnapshot(snap));
    data.updatedAt = snap.updatedAt ? Date.parse(snap.updatedAt) : 0;
    if (snap._updatedAtMs) data.updatedAt = snap._updatedAtMs;
  } catch (e) { console.warn("Veri okunamadı", e); }
}

/** Her değişiklikten sonra çağır: diske yazar, eşitleme açıksa gönderir, ekranı yeniler */
export function changed(what = "data") {
  if (!applyingRemote) data.updatedAt = Date.now();
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    api.saveData(JSON.stringify({ ...snapshot(), _updatedAtMs: data.updatedAt }));
  }, 300);
  if (!applyingRemote) schedulePush();
  emit(what);
}

// ---- görevler / listeler

const rank = { critical: 0, high: 1, normal: 2, low: 3 };
export function openTasks() {
  return data.tasks.filter((t) => !t.done).sort((a, b) => {
    if (a.due && b.due) return a.due - b.due;
    if (a.due) return -1;
    if (b.due) return 1;
    return (rank[a.priority] ?? 2) - (rank[b.priority] ?? 2);
  });
}
export const findTask = (id) => data.tasks.find((t) => t.id === id);
export function upsertTask(t) {
  const i = data.tasks.findIndex((x) => x.id === t.id);
  if (i >= 0) data.tasks[i] = t; else data.tasks.push(t);
  changed("tasks");
}
export function completeTask(id) {
  const t = findTask(id);
  if (t) { t.done = true; changed("tasks"); }
}
export function deleteTask(id) { data.tasks = data.tasks.filter((t) => t.id !== id); changed("tasks"); }

export function addShopping(names) {
  const added = [];
  for (const raw of names) {
    const name = raw.trim();
    if (!name) continue;
    if (data.shopping.some((x) => x.name.toLocaleLowerCase(TR) === name.toLocaleLowerCase(TR))) continue;
    const cap = name.charAt(0).toLocaleUpperCase(TR) + name.slice(1);
    data.shopping.push({ id: uuid(), name: cap, createdAt: new Date() });
    added.push(cap);
  }
  changed("shopping");
  return added;
}
export function removeShopping(names) {
  const set = names.map((n) => n.toLocaleLowerCase(TR).trim());
  data.shopping = data.shopping.filter((x) => {
    const n = x.name.toLocaleLowerCase(TR);
    return !set.some((s) => n === s || n.includes(s) || s.includes(n));
  });
  changed("shopping");
}

// ---- özel günler, anılar, bayramlar

export const KIND = {
  birthday: { label: "Doğum günü", icon: "🎂", color: "#ff5fa2" },
  anniversary: { label: "Yıl dönümü", icon: "❤", color: "#ff4d5e" },
  special: { label: "Özel gün", icon: "★", color: "#ffd24d" }
};
export function kindFrom(text) {
  const t = (text || "").toLocaleLowerCase(TR);
  if (t.includes("doğum") || t.includes("birthday")) return "birthday";
  if (t.includes("yıl dönüm") || t.includes("yıldönüm") || t.includes("evlilik") || t.includes("tanış")) return "anniversary";
  return "special";
}
export function nextOccurrence(s, from = new Date()) {
  const today = startOfDay(from);
  for (let y = today.getFullYear(); y < today.getFullYear() + 5; y++) {
    const d = new Date(y, s.month - 1, s.day);
    if (d.getMonth() === s.month - 1 && d >= today) return d;
  }
  return today;
}
export function yearsOn(s, date) {
  if (!s.year) return null;
  const n = new Date(date).getFullYear() - s.year;
  return n > 0 ? n : null;
}
export const specialsOn = (date) => data.specials.filter((s) => s.month === date.getMonth() + 1 && s.day === date.getDate());
export const momentsOn = (date) => data.moments.filter((m) => sameDay(m.date, date));
export const tasksOn = (date) => data.tasks.filter((t) => t.due && sameDay(t.due, date)).sort((a, b) => a.due - b.due);

export function addSpecial(s) {
  const i = data.specials.findIndex((x) => x.month === s.month && x.day === s.day && x.title.toLocaleLowerCase(TR) === s.title.toLocaleLowerCase(TR));
  if (i >= 0) data.specials[i] = { ...s, id: data.specials[i].id }; else data.specials.push(s);
  changed("specials");
}
export function removeSpecial(id) { data.specials = data.specials.filter((x) => x.id !== id); changed("specials"); }
export function addMoment(m) { data.moments.push(m); data.moments.sort((a, b) => b.date - a.date); changed("moments"); }
export function removeMoment(id) { data.moments = data.moments.filter((x) => x.id !== id); changed("moments"); }

const nthSunday = (y, month, n) => {
  const first = new Date(y, month - 1, 1);
  return new Date(y, month - 1, 1 + ((7 - first.getDay()) % 7) + (n - 1) * 7);
};
const RELIGIOUS = {
  2026: [["Ramazan Bayramı Arifesi", 3, 19, 1], ["Ramazan Bayramı", 3, 20, 3], ["Kurban Bayramı Arifesi", 5, 26, 1], ["Kurban Bayramı", 5, 27, 4]],
  2027: [["Ramazan Bayramı Arifesi", 3, 8, 1], ["Ramazan Bayramı", 3, 9, 3], ["Kurban Bayramı Arifesi", 5, 15, 1], ["Kurban Bayramı", 5, 16, 4]]
};
export const HOLIDAY_COLOR = { national: "#ff4d4d", religious: "#3ddc84", observance: "#b07cff" };
export function holidays(year) {
  const out = [];
  const add = (title, date, kind) => out.push({ title, date, kind });
  add("Yılbaşı", new Date(year, 0, 1), "national");
  add("Sevgililer Günü", new Date(year, 1, 14), "observance");
  add("Dünya Kadınlar Günü", new Date(year, 2, 8), "observance");
  add("Ulusal Egemenlik ve Çocuk Bayramı", new Date(year, 3, 23), "national");
  add("Emek ve Dayanışma Günü", new Date(year, 4, 1), "national");
  add("Anneler Günü", nthSunday(year, 5, 2), "observance");
  add("Atatürk'ü Anma, Gençlik ve Spor Bayramı", new Date(year, 4, 19), "national");
  add("Babalar Günü", nthSunday(year, 6, 3), "observance");
  add("Demokrasi ve Millî Birlik Günü", new Date(year, 6, 15), "national");
  add("Zafer Bayramı", new Date(year, 7, 30), "national");
  add("Cumhuriyet Bayramı", new Date(year, 9, 29), "national");
  add("Atatürk'ü Anma Günü", new Date(year, 10, 10), "observance");
  add("Öğretmenler Günü", new Date(year, 10, 24), "observance");
  for (const [title, m, d, len] of RELIGIOUS[year] || []) {
    for (let i = 0; i < len; i++) add(len > 1 ? `${title} ${i + 1}. gün` : title, new Date(year, m - 1, d + i), "religious");
  }
  return out.sort((a, b) => a.date - b.date);
}
export function holidaysBetween(start, end) {
  const out = [];
  for (let y = start.getFullYear(); y <= end.getFullYear(); y++) out.push(...holidays(y));
  return out.filter((h) => h.date >= startOfDay(start) && h.date <= end);
}

// ---------------------------------------------------------------- sunucu

function base() { return settings.serverURL.trim().replace(/\/+$/, ""); }
function auth(extra = {}) { return { authorization: `Bearer ${settings.token}`, ...extra }; }

export async function serverJSON(path, method = "GET", body) {
  const res = await api.request({
    url: base() + path, method,
    headers: auth({ "content-type": "application/json" }),
    body: body === undefined ? null : JSON.stringify(body)
  });
  let json = null;
  try { json = res.text ? JSON.parse(res.text) : null; } catch {}
  return { status: res.status, json, error: res.error };
}

export function buildContext() {
  const now = new Date();
  return {
    now: fmt.now(now),
    timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || "Europe/Istanbul",
    userName: settings.userName,
    assistantName: settings.assistantName,
    tasks: openTasks().slice(0, 60).map((t) => ({ id: t.id, title: t.title, due: t.due ? wire(t.due) : null, priority: t.priority || "normal" })),
    shopping: data.shopping.map((s) => ({ id: s.id, name: s.name })),
    calls: data.calls.map((c) => ({ id: c.id, person: c.person, reason: c.reason || null })),
    events: [],
    memory: data.memory.slice(-80).map((m) => ({ id: m.id, text: m.text })),
    specials: data.specials.map((s) => {
      const next = nextOccurrence(s);
      return { id: s.id, title: s.title, person: s.person || null, kind: KIND[s.kind]?.label || "Özel gün", next: dayKey(next), years: yearsOn(s, next) };
    }),
    holidays: holidaysBetween(now, addDays(now, 60))
      .filter((h) => !h.title.includes(". gün") || h.title.endsWith("1. gün"))
      .map((h) => ({ date: dayKey(h.date), title: h.title })),
    moments: data.moments.slice(0, 20).map((m) => ({ date: dayKey(m.date), title: m.title, place: m.place || null, note: m.note || null }))
  };
}

export async function chat(text, signal) {
  const history = data.messages.slice(0, -1).slice(-12).map((m) => ({ role: m.role, content: m.text }));
  const res = await serverJSON("/chat", "POST", { message: text, history, context: buildContext() });
  if (signal?.aborted) throw new DOMException("İptal", "AbortError");
  if (res.status === 401) throw new Error("Uygulama şifresi sunucudakiyle eşleşmiyor.");
  if (res.status !== 200 || !res.json) throw new Error(res.json?.error || res.error || `Sunucu hatası (${res.status})`);
  return res.json;
}

export async function tts(text) {
  const res = await api.request({
    url: base() + "/tts", method: "POST", binary: true,
    headers: auth({ "content-type": "application/json" }),
    body: JSON.stringify({ text, voice: voiceName(), speed: settings.voiceSpeed })
  });
  if (res.status !== 200 || !res.bytes) return null;
  return new Blob([res.bytes], { type: "audio/mpeg" });
}

export async function stt(blob) {
  const bytes = new Uint8Array(await blob.arrayBuffer());
  const res = await api.request({
    url: base() + "/stt", method: "POST",
    headers: auth({ "content-type": blob.type || "audio/webm" }),
    body: bytes
  });
  if (res.status !== 200) return "";
  try { return JSON.parse(res.text).text || ""; } catch { return ""; }
}

// ---------------------------------------------------------------- işlemler (Jarvis'in cevabındaki actions)

export const uiRequests = { calendarPage: null, route: null };

export async function applyAction(a) {
  const pr = ["low", "normal", "high", "critical"].includes(a.priority) ? a.priority : null;
  switch (a.type) {
    case "add_task": {
      if (!a.title) return null;
      upsertTask({ id: uuid(), title: a.title, due: parseWire(a.due), priority: pr || "normal", done: false, createdAt: new Date() });
      return null;
    }
    case "update_task": {
      const t = findTask(a.target_id);
      if (!t) return null;
      if (a.title) t.title = a.title;
      const d = parseWire(a.due); if (d) t.due = d;
      if (pr) t.priority = pr;
      upsertTask(t);
      return null;
    }
    case "complete_task": if (a.target_id) completeTask(a.target_id); return null;
    case "delete_task": if (a.target_id) deleteTask(a.target_id); return null;
    case "add_shopping": addShopping(a.items?.length ? a.items : [a.title].filter(Boolean)); return null;
    case "remove_shopping": removeShopping(a.items?.length ? a.items : [a.title].filter(Boolean)); return null;
    case "clear_shopping": data.shopping = []; changed("shopping"); return null;
    case "add_call": {
      const person = a.person || a.title;
      if (!person) return null;
      data.calls.push({ id: uuid(), person, reason: a.person ? a.title : null, createdAt: new Date() });
      changed("calls");
      return null;
    }
    case "complete_call":
      data.calls = data.calls.filter((c) => c.id !== a.target_id && (!a.person || c.person.toLocaleLowerCase(TR) !== a.person.toLocaleLowerCase(TR)));
      changed("calls");
      return null;
    case "add_event": {
      // Bilgisayarda telefon takvimi yok → Jarvis takvimine zamanlı görev olarak eklenir
      const start = parseWire(a.due);
      if (!a.title || !start) return null;
      upsertTask({ id: uuid(), title: a.title + (a.location ? ` · ${a.location}` : ""), due: start, priority: pr || "high", done: false, createdAt: new Date() });
      return null;
    }
    case "get_route": {
      if (!a.destination) return null;
      const url = "https://www.google.com/maps/dir/?api=1&travelmode=driving"
        + (a.origin ? "&origin=" + encodeURIComponent(a.origin) : "")
        + "&destination=" + encodeURIComponent(a.destination);
      uiRequests.route = url;
      await api.openExternal(url);
      return "Rotayı ve güncel trafiği haritada açtım.";
    }
    case "remember": {
      const note = a.note || a.title;
      if (!note) return null;
      data.memory.push({ id: uuid(), text: note, createdAt: new Date() });
      changed("memory");
      return null;
    }
    case "forget": data.memory = data.memory.filter((m) => m.id !== a.target_id); changed("memory"); return null;
    case "add_special_day": {
      const d = parseWire(a.due);
      if (!a.title || !d) return null;
      const s = { id: uuid(), title: a.title, person: a.person || null, month: d.getMonth() + 1, day: d.getDate(), kind: kindFrom(a.note || a.title) };
      if (d.getFullYear() < new Date().getFullYear()) s.year = d.getFullYear();
      addSpecial(s);
      return null;
    }
    case "delete_special_day": if (a.target_id) removeSpecial(a.target_id); return null;
    case "add_moment":
      if (!a.title) return null;
      addMoment({ id: uuid(), title: a.title, date: parseWire(a.due) || new Date(), place: a.location || null, note: a.note || null, createdAt: new Date() });
      return null;
    case "show_calendar":
      uiRequests.calendarPage = ["week", "year", "moments"].includes(a.note) ? a.note : "week";
      emit("show-calendar");
      return null;
    default: return null;
  }
}

// ---------------------------------------------------------------- eşitleme (isteğe bağlı)

export const syncState = { status: "Henüz eşitlenmedi" };
let pushTimer = null;
let pulling = false;

function applyRemote(snapData, remoteMs) {
  applyingRemote = true;
  const keepAlarm = new Map(data.tasks.map((t) => [t.id, t.alarmID]));
  Object.assign(data, fromSnapshot(snapData));
  data.tasks.forEach((t) => { if (keepAlarm.has(t.id)) t.alarmID = keepAlarm.get(t.id); });
  data.updatedAt = remoteMs;
  changed("all");
  applyingRemote = false;
}

export async function pull() {
  if (!settings.syncEnabled || !isConfigured() || pulling) return syncState.status;
  pulling = true;
  try {
    const res = await serverJSON("/sync");
    if (res.status === 501) syncState.status = "Sunucuda eşitleme kurulmamış (JARVIS_KV).";
    else if (res.status !== 200) syncState.status = res.status ? `Eşitleme hatası (${res.status})` : "Sunucuya ulaşılamadı";
    else if (!res.json?.updatedAt || !res.json.data) { syncState.status = "Sunucuya ilk kez gönderiliyor"; await push(); }
    else {
      const remote = Date.parse(res.json.updatedAt);
      if (remote > data.updatedAt + 500) { applyRemote(res.json.data, remote); syncState.status = "Güncellendi · " + fmt.time(new Date()); }
      else if (data.updatedAt > remote + 500) { await push(); }
      else syncState.status = "Eşit · " + fmt.time(new Date());
    }
  } finally {
    pulling = false;
    emit("sync");
  }
  return syncState.status;
}

function schedulePush() {
  if (!settings.syncEnabled || !isConfigured()) return;
  clearTimeout(pushTimer);
  pushTimer = setTimeout(push, 2000);
}

async function push() {
  const { updatedAt, ...rest } = snapshot();
  const res = await serverJSON("/sync", "PUT", { updatedAt: iso(data.updatedAt || Date.now()), data: { ...rest, updatedAt } });
  if (res.status === 409 && res.json?.data) {
    applyRemote(res.json.data, Date.parse(res.json.updatedAt));
    syncState.status = "Diğer cihazdaki daha yeni veri alındı";
  } else if (res.status === 200) syncState.status = "Gönderildi · " + fmt.time(new Date());
  else syncState.status = res.status ? `Gönderilemedi (${res.status})` : "Sunucuya ulaşılamadı";
  emit("sync");
}
