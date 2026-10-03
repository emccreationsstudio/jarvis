// Hatırlatmalar: görevler (önem sırasına göre bildirim ya da alarm penceresi), özel günler ve bayramlar.
// Uygulama tepside çalıştığı sürece her 15 saniyede kontrol edilir.

import * as core from "./core.js";

const api = window.jarvis;
const FIRED_KEY = "firedReminders";
let fired = new Set();
try { fired = new Set(JSON.parse(localStorage.getItem(FIRED_KEY) || "[]")); } catch {}

function mark(key) {
  fired.add(key);
  // Liste büyümesin: son 500 kayıt
  const arr = [...fired].slice(-500);
  fired = new Set(arr);
  try { localStorage.setItem(FIRED_KEY, JSON.stringify(arr)); } catch {}
}

const once = (key, fn) => { if (!fired.has(key)) { mark(key); fn(); } };

function taskKey(t, suffix) { return `task:${t.id}:${t.due ? t.due.getTime() : 0}:${suffix}`; }

function checkTasks(now) {
  for (const t of core.data.tasks) {
    if (t.done || !t.due) continue;
    const due = t.due.getTime();
    const late = now - due;
    const asAlarm = t.priority === "critical" || t.priority === "high" || (t.priority === "normal" && core.settings.alarmAll);

    // Kritik: 30 dk önce ön uyarı
    if (t.priority === "critical" && due - now <= 30 * 60000 && due - now > 0) {
      once(taskKey(t, "pre"), () => api.notify({ title: t.title, body: "30 dakika sonra · önemli" }));
    }
    if (late < 0) continue;

    if (late > 6 * 3600000) {
      // Uygulama kapalıyken kaçırılmış
      once(taskKey(t, "missed"), () => api.notify({ title: "Kaçırılan hatırlatma", body: `${t.title} · ${core.fmt.friendly(t.due)}` }));
      continue;
    }
    if (t.priority === "low") {
      once(taskKey(t, "0"), () => api.notify({ title: t.title, body: "Hatırlatma", silent: true }));
    } else if (asAlarm) {
      once(taskKey(t, "alarm"), () => api.showAlarm({ id: t.id, title: t.title, body: core.fmt.time(t.due) }));
    } else {
      once(taskKey(t, "0"), () => api.notify({ title: t.title, body: "Zamanı geldi" }));
    }
  }
}

function checkSpecials(now) {
  const d = new Date(now);
  const year = d.getFullYear();
  for (const s of core.data.specials) {
    const day = new Date(year, s.month - 1, s.day);
    const who = s.person ? ` · ${s.person}` : "";
    const label = core.KIND[s.kind]?.label || "Özel gün";
    // O gün 09:00
    if (core.sameDay(day, d) && d.getHours() >= 9) {
      const age = core.yearsOn(s, day);
      once(`sd:${s.id}:${year}:0`, () => api.notify({ title: `Bugün: ${s.title}`, body: label + who + (age ? ` · ${age}. ${s.kind === "birthday" ? "yaş" : "yıl"}` : "") }));
    }
    // 1 hafta önce 10:00
    const before = core.addDays(day, -7);
    if (core.sameDay(before, d) && d.getHours() >= 10) {
      once(`sd:${s.id}:${year}:7`, () => api.notify({ title: `1 hafta sonra: ${s.title}`, body: s.kind === "birthday" ? "Hediye ya da kutlama planı için zaman var." : label + who }));
    }
  }
}

function checkHolidays(now) {
  const d = new Date(now);
  for (const h of core.holidaysBetween(d, core.addDays(d, 4))) {
    if (h.title.includes(". gün") && !h.title.endsWith("1. gün")) continue;
    const gift = ["Anneler Günü", "Babalar Günü", "Sevgililer Günü"].includes(h.title);
    const at = core.addDays(h.date, gift ? -3 : -1);
    at.setHours(20, 0, 0, 0);
    if (core.sameDay(at, d) && now >= at.getTime()) {
      const name = h.title.replace(" 1. gün", "");
      once(`hol:${core.dayKey(h.date)}:${name}`, () => api.notify({
        title: gift ? `3 gün sonra: ${name}` : `Yarın: ${name}`,
        body: gift ? "Bir hediye ya da sürpriz düşünmek ister misin?" : "Planlarını buna göre yapabilirsin."
      }));
    }
  }
}

export function check() {
  const now = Date.now();
  try { checkTasks(now); checkSpecials(now); checkHolidays(now); } catch (e) { console.warn(e); }
}

export function start() {
  check();
  setInterval(check, 15000);
  // Alarm penceresindeki düğmeler
  api.on("alarm-action", ({ id, action }) => {
    const t = core.findTask(id);
    if (!t) return;
    if (action === "done") core.completeTask(id);
    if (action === "snooze") {
      t.due = new Date(Date.now() + 10 * 60000);
      core.upsertTask(t);
    }
  });
}

/** Ayarlar → "Alarmı dene" */
export function testAlarm() {
  setTimeout(() => api.showAlarm({ id: "test-" + Date.now(), title: "Jarvis alarm testi", body: "Her şey yolunda görünüyor." }), 10000);
}
