// Sesli komut çözümleme: bitiş sözleri ("bitti", "Jarvis kapan"), soru ve komut tespiti.
// iPhone uygulamasındaki VoiceCommand ile aynı kurallar.

const lower = (s) => s.toLocaleLowerCase("tr-TR");
const norm = (w) => lower(w).replace(/^[\p{P}\p{S}\s]+|[\p{P}\p{S}\s]+$/gu, "").replace(/^jarvıs/, "jarvis"); // "JARVIS" → "jarvıs" olmasın

// Cümle sonunda her zaman kapatır
const CLOSE = [
  ["jarvis", "kapan"], ["jarvis", "kapat"], ["kapanabilirsin"], ["jarvis", "kapanabilirsin"],
  ["jarvis", "görüşürüz"], ["sağ", "ol", "jarvis"]
];
// Yalnızca tek başına söylenirse kapatır ("ışığı kapat", "alarmı kapat" kapatmaz)
const CLOSE_ALONE = [["kapan"], ["kapat"], ["görüşürüz"], ["kapanış"], ["kapanıyoruz"]];
const DONE = [
  ["bitti"], ["jarvis", "bitti"], ["tamam", "bitti"], ["bu", "kadar"], ["hepsi", "bu"],
  ["şimdilik", "bu", "kadar"], ["işle"], ["hadi", "işle"]
];

function matchEnd(n, phrases) {
  for (const p of [...phrases].sort((a, b) => b.length - a.length)) {
    if (p.length > n.length) continue;
    const tail = n.slice(n.length - p.length);
    if (tail.every((w, i) => w === p[i])) return p.length;
  }
  return 0;
}

function cleanBody(words) {
  let s = words.join(" ").trim().replace(/^[,;:\-–—\s]+|[,;:\-–—\s]+$/g, "");
  if (lower(s).startsWith("jarvis")) s = s.slice(6).replace(/^[,;:\-–—\s]+/, "");
  return s;
}

/** Cümlenin sonundaki bitiş sözünü ayıklar → { body, end: "none" | "done" | "close" } */
export function parse(text) {
  const words = text.trim().split(/\s+/).filter(Boolean);
  const n = words.map(norm);
  let k = matchEnd(n, CLOSE);
  if (k) return { body: cleanBody(words.slice(0, words.length - k)), end: "close" };
  const only = n.filter(Boolean);
  if (CLOSE_ALONE.some((p) => p.length === only.length && p.every((w, i) => w === only[i]))) return { body: "", end: "close" };
  k = matchEnd(n, DONE);
  if (k) return { body: cleanBody(words.slice(0, words.length - k)), end: "done" };
  return { body: text.trim(), end: "none" };
}

const PARTICLES = new Set([
  "mı", "mi", "mu", "mü", "mısın", "misin", "musun", "müsün", "mıyım", "miyim", "muyum", "müyüm",
  "mıdır", "midir", "mudur", "müdür", "mıyız", "miyiz", "muyuz", "müyüz", "mısınız", "misiniz",
  "musunuz", "müsünüz", "mıydı", "miydi", "muydu", "müydü"
]);
const QWORDS = new Set([
  "ne", "neden", "niye", "niçin", "nasıl", "nasılsın", "nerede", "nerde", "nereye", "nereden",
  "kaç", "kaçta", "kaça", "kaçıncı", "kim", "kimi", "kime", "kimden", "kimle", "hangi", "hangisi",
  "neler", "nedir", "neresi"
]);
const ASK_PREFIX = ["söyle", "anlat", "özetle", "hesapla", "açıkla", "öner"];
const ASK_EXACT = new Set(["oku", "okur", "okusana", "okuyabilir", "okuyun", "bakar", "baksana", "sayar", "göster"]);

/** Hemen sesli cevap gerektiren bir soru/istek mi? */
export function isQuestion(text) {
  if (text.includes("?")) return true;
  for (const x of text.split(/\s+/).map(norm)) {
    if (!x) continue;
    if (PARTICLES.has(x) || QWORDS.has(x)) return true;
    if (x.startsWith("nere") || x.startsWith("nası")) return true;
    if (ASK_EXACT.has(x) || ASK_PREFIX.some((p) => x.startsWith(p))) return true;
  }
  return false;
}

const COMMAND_ENDINGS = ["le", "la", "lat", "let", "kur", "ara", "yaz", "sil", "yap", "aç", "kapat",
  "koy", "gönder", "bul", "planla", "oluştur", "ayarla", "hazırla", "çıkar", "bitir",
  "lütfen", "rica", "et", "edin", "eyim", "ayım", "ırım", "irim", "urum", "ürüm"];
const MARKERS = ["hatırlat", "ekle", "kur", "oluştur", "ara", "sil", "planla", "not"];

/** Tamamlanmış bir komut ya da soru mu? (öyleyse kısa bekleyip cevap verilir) */
export function isComplete(text) {
  if (isQuestion(text)) return true;
  const words = text.split(/\s+/).map(norm).filter(Boolean);
  const last = words[words.length - 1];
  if (!last) return false;
  if (COMMAND_ENDINGS.some((e) => last.endsWith(e))) return true;
  return words.length >= 3 && words.some((w) => MARKERS.some((m) => w.startsWith(m)));
}
