// Söylenen sayıları rakama çevirir: "yarın saat dörtte iki domates" → "yarın saat 4'te 2 domates"
// iPhone'daki NumberWords.swift ile aynı kurallar.

const TR = "tr-TR";

const UNITS = { "sıfır": 0, "bir": 1, "iki": 2, "üç": 3, "dört": 4, "dörd": 4, "beş": 5, "altı": 6, "yedi": 7, "sekiz": 8, "dokuz": 9 };
const TENS = { "on": 10, "yirmi": 20, "otuz": 30, "kırk": 40, "elli": 50, "altmış": 60, "yetmiş": 70, "seksen": 80, "doksan": 90 };
const BIG = { "yüz": 100, "bin": 1000, "milyon": 1000000 };

// Başka anlamı da olan sözcükler: "bir şey", "ona söyle", "masanın altı", "yemek yedi", "otobüse bin", "yüzünü yıka"
const AMBIGUOUS = new Set(["bir", "on", "altı", "yedi", "yüz", "bin"]);
// Bunlardan önce gelirse sayı olduğu kesin
const TIME_BEFORE = new Set(["saat", "saati", "sabah", "akşam", "gece", "öğlen", "öğle", "sonra", "yarın", "bugün", "ayın", "yüzde", "toplam", "tam", "en", "fazla", "az"]);
// Bunlar ardından gelirse sayı olduğu kesin
const UNIT_AFTER = new Set([
  "tane", "adet", "kilo", "kg", "gram", "gr", "litre", "lt", "paket", "kutu", "şişe", "koli", "düzine", "dilim", "porsiyon",
  "lira", "tl", "dolar", "euro", "avro", "kuruş", "kişi", "kişilik", "saat", "saatte", "dakika", "dakikada", "saniye",
  "gün", "günde", "hafta", "ay", "yıl", "sene", "kez", "defa", "kere", "metre", "km", "kilometre", "numara", "numaralı",
  "buçuk", "çeyrek", "milyon", "bin", "yüz", "mg", "ml", "doz", "hap", "tablet", "kapsül", "damla", "ölçek"
]);

const SUFFIX = /^(y?[aeıiuü]|[dt][ae]n?|n?[ıiuü]n|s?[ıiuü]n?[dt]?[ae]|s?[ıiuü]n[ıiuü]|s?[ıiuü]|[ıiuü]?nc[ıiuü])$/;
const ORDINAL = /^[ıiuü]?nc[ıiuü]$/;

const ROOTS = { ...UNITS, ...TENS, ...BIG };
const ROOT_NAMES = Object.keys(ROOTS).sort((a, b) => b.length - a.length);

const lower = (s) => s.toLocaleLowerCase(TR);

/** Sözcüğü sayı köküne + eke ayırır. "beşte" → {value:5, suffix:"te"} */
function analyze(word) {
  const w = lower(word);
  if (w in ROOTS) return { value: ROOTS[w], suffix: "", root: w };
  if (w === "yüzde") return null; // "yüzde 50" → yüzde ayrı işlenir
  for (const r of ROOT_NAMES) {
    if (w.startsWith(r) && w.length > r.length) {
      const rest = w.slice(r.length);
      if (SUFFIX.test(rest)) return { value: ROOTS[r], suffix: rest, root: r === "dörd" ? "dört" : r };
    }
  }
  return null;
}

/** Belirsiz kök eksiz söylendiğinde yine de sayı mı? */
function bareIsNumber(tok, prevWord, atEnd) {
  if (tok.info.suffix) return false;                       // "ona", "biri", "altında", "yüzünü" → bağlam gerekir
  switch (tok.info.root) {
    case "on": return true;                                // "on" başka anlama gelmez
    case "yüz": return true;                               // "yüz gram", "yüz kişi"
    case "altı": return !(prevWord && /(ın|in|un|ün)$/.test(prevWord)); // "masanın altı" değil
    case "yedi": return !atEnd;                            // "yemek yedi" değil
    default: return false;                                 // "bir", "bin"
  }
}

/** Bir sonraki sayı sözcüğü öncekine eklenebilir mi? ("yirmi beş" evet, "iki üç" hayır) */
function canFollow(prev, next) {
  if (next < 10) return (prev >= 10 && prev < 100) || prev >= 100;          // onlar/yüz/bin → birler
  if (next < 100) return prev >= 100;                                        // yüz/bin → onlar
  if (next === 100) return (prev >= 2 && prev < 10) || prev >= 1000;         // "iki yüz", "bin yüz"
  return prev < next;                                                        // "yirmi bin", "iki yüz bin"
}

/** Sözcük dizisinden sayı grupları çıkarır (geçersiz sıralamada böler) */
function groups(tokens) {
  const out = [];
  let i = 0;
  while (i < tokens.length) {
    const t = tokens[i];
    if (!t.info) { out.push({ kind: "word", tokens: [t] }); i++; continue; }
    const grp = [t];
    let j = i + 1;
    while (j < tokens.length && tokens[j].info) {
      const last = grp[grp.length - 1];
      if (last.info.suffix || last.punct) break;                // ekli ya da noktalamalı sözcük grubu bitirir
      if (!canFollow(last.info.value, tokens[j].info.value)) break;
      grp.push(tokens[j]);
      j++;
    }
    out.push({ kind: "num", tokens: grp });
    i = j;
  }
  return out;
}

function valueOf(grp) {
  let total = 0, current = 0;
  for (const t of grp) {
    const v = t.info.value;
    if (v === 100) current = (current || 1) * 100;
    else if (v >= 1000) { total += (current || 1) * v; current = 0; }
    else current += v;
  }
  return total + current;
}

export function normalizeNumbers(text) {
  if (!text) return text;
  // Sözcük + ardından gelen noktalama
  const parts = text.match(/[^\s]+/g) || [];
  const tokens = parts.map((p) => {
    const m = p.match(/^(.*?)([.,!?;:…]*)$/u);
    const word = m[1], punct = m[2];
    return { raw: p, word, punct, info: word ? analyze(word) : null };
  });

  const gs = groups(tokens);
  const words = [];
  for (let g = 0; g < gs.length; g++) {
    const grp = gs[g];
    if (grp.kind === "word") { words.push(grp.tokens[0].raw); continue; }
    const first = grp.tokens[0], last = grp.tokens[grp.tokens.length - 1];
    const prevWord = g > 0 && gs[g - 1].kind === "word" ? lower(gs[g - 1].tokens[0].word) : null;
    const nextGrp = gs[g + 1];
    const nextWord = nextGrp ? lower(nextGrp.tokens[0].word) : null;

    // Tek sözcüklü belirsiz sayılar: yalnızca bağlam sayıyı gösteriyorsa çevir
    if (grp.tokens.length === 1 && AMBIGUOUS.has(first.info.root)) {
      const prevGrp = g > 0 ? gs[g - 1] : null;
      const sure = (prevWord && TIME_BEFORE.has(prevWord)) || (nextWord && UNIT_AFTER.has(nextWord))
        || (nextGrp && nextGrp.kind === "num") || (prevGrp && prevGrp.kind === "num");
      if (!sure && !bareIsNumber(first, prevWord, !nextGrp || !!first.punct)) { words.push(first.raw); continue; }
    }

    const n = valueOf(grp.tokens);
    const suffix = last.info.suffix;
    let out;
    if (suffix && ORDINAL.test(suffix)) out = `${n}.`;
    else if (suffix) out = `${n}'${suffix}`;
    else out = String(n);
    words.push(out + (last.punct || ""));
  }

  let s = words.join(" ");
  // "yüzde 50" → "%50"
  s = s.replace(/\byüzde (\d+)/giu, "%$1");
  // "saat 14 30" → "saat 14.30" · "saat 2 buçuk(ta)" → "saat 2.30('da)"
  s = s.replace(/(saat) (\d{1,2}) (\d{2})(?=$|[\s'.,!?])/giu, "$1 $2.$3");
  s = s.replace(/(saat) (\d{1,2}) buçuk(ta|da)?(?=$|[\s.,!?])/giu, (_, a, h, suf) => `${a} ${h}.30${suf ? "'da" : ""}`);
  return s;
}
