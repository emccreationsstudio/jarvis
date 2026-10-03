// Jarvis beyni — Cloudflare Worker
// Telefon her konuşmada: mesajı, kısa sohbet geçmişini ve güncel durumu (saat, listeler, takvim, hafıza) gönderir.
// Bu sunucu OpenAI'ye sorar ve iki şey döndürür: söylenecek cevap + telefonda yapılacak işler (actions).
//
// Gerekli ayarlar (Cloudflare → Worker → Settings → Variables and Secrets):
//   OPENAI_API_KEY  (Secret)  OpenAI anahtarınız
//   APP_TOKEN       (Secret)  Uygulamanın Ayarlar ekranına yazacağınız uzun bir şifre
//   TTS_MODEL       (Text, isteğe bağlı)  Varsayılan: gpt-4o-mini-tts
//   STT_MODEL       (Text, isteğe bağlı)  Varsayılan: gpt-4o-mini-transcribe
//   JARVIS_KV       (KV namespace binding, isteğe bağlı)  Cihazlar arası eşitleme için
//   OPENAI_MODEL    (Text, isteğe bağlı)  Varsayılan: gpt-5.6-luna

const DEFAULT_MODEL = "gpt-5.6-luna";

const ACTION_TYPES = [
  "add_task",        // görev / hatırlatıcı ekle
  "complete_task",   // görevi tamamla (target_id)
  "update_task",     // görevin zamanını / önemini / başlığını değiştir (target_id)
  "delete_task",     // görevi sil (target_id)
  "add_shopping",    // alışveriş listesine ekle (items)
  "remove_shopping", // alışveriş listesinden çıkar / alındı (items)
  "clear_shopping",  // alışveriş listesini temizle
  "add_call",        // aranacaklar listesine ekle (person, title = konu)
  "complete_call",   // aranacaktan çıkar (target_id)
  "add_event",       // takvime etkinlik ekle (title, due, end, location)
  "get_route",       // rota ve trafik süresi (origin boşsa mevcut konum, destination)
  "remember",        // kalıcı hafızaya bilgi kaydet (note)
  "forget",          // hafızadan sil (target_id)
  "add_special_day", // her yıl tekrar eden özel gün: doğum günü, yıl dönümü (title, person, due, note = tür)
  "delete_special_day", // özel günü sil (target_id)
  "add_moment",      // yaşanmış bir anıyı sakla (title, due = tarih, location, note)
  "show_calendar"    // uygulamada takvimi aç (note: "week" | "year" | "moments")
];

const nullableString = { type: ["string", "null"] };

const RESPONSE_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["reply", "actions"],
  properties: {
    reply: {
      type: "string",
      description: "Kullanıcıya sesli okunacak kısa Türkçe cevap."
    },
    actions: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["type", "title", "items", "due", "end", "priority", "person", "origin", "destination", "location", "note", "target_id"],
        properties: {
          type: { type: "string", enum: ACTION_TYPES },
          title: nullableString,
          items: { type: "array", items: { type: "string" } },
          due: { type: ["string", "null"], description: "Yerel saat, biçim YYYY-MM-DDTHH:MM" },
          end: { type: ["string", "null"], description: "Etkinlik bitişi, biçim YYYY-MM-DDTHH:MM" },
          priority: { type: ["string", "null"], enum: ["low", "normal", "high", "critical", null] },
          person: nullableString,
          origin: nullableString,
          destination: nullableString,
          location: nullableString,
          note: nullableString,
          target_id: nullableString
        }
      }
    }
  }
};

function systemPrompt(userName, assistantName) {
  return `Sen ${userName} adlı kullanıcının kişisel asistanı ${assistantName}'sin. Görevin onun hayatını organize etmek: görevler, hatırlatıcılar, alışveriş listesi, aranacak kişiler, takvim, rotalar ve günlük planlar.

KONUŞMA TARZI
- Türkçe, doğal, samimi ve KISA konuş. Cevabın sesli okunacak: 1-3 cümle, madde işareti ve emoji kullanma.
- Kullanıcıya adıyla (${userName}) hitap edebilirsin ama her cümlede değil.
- Bir şey yaptıysan ne yaptığını kısaca söyle ("Domates ve damacana suyu alışveriş listesine eklendi.").
- Gerçekten eksik ve tahmin edilemeyecek bir bilgi varsa (örneğin "hatırlat" denip hiç zaman verilmemiş ve bağlamdan çıkmıyorsa) kısa bir soru sor ve o işlemi yapma.

İŞLEMLER (actions)
- Kullanıcının istediği her somut işi actions listesine ekle. Bir mesajda birden fazla iş olabilir.
- Tarih ve saatleri "ŞU AN" bilgisine göre hesapla ve YYYY-MM-DDTHH:MM biçiminde yaz. "Yarın", "cuma", "akşam", "öğleden sonra 3" gibi ifadeleri sen çöz. Saat belirtilmemiş bir hatırlatıcıda makul bir saat seç (sabah işleri 09:00, akşam işleri 19:00) ve cevabında söyle.
- Mevcut bir görevi, aramayı ya da hafıza kaydını değiştirirken listedeki id'yi target_id olarak kullan. Asla id uydurma.
- Kullanılmayan alanlar null olsun; items kullanılmıyorsa boş liste olsun.

ÖNEM SIRASI (priority) — kendi kararınla belirle
- critical: Kaçırılırsa ciddi sonucu olan işler (uçak, önemli toplantı, ilaç, son başvuru günü, kullanıcının "çok önemli/kesin hatırlat" dediği şeyler). Telefon alarm gibi çalar.
- high: Bugün yapılması gereken önemli işler, randevular, toplantılar. Israrlı bildirim.
- normal: Sıradan görevler.
- low: Acelesi olmayan, "bir ara" işler. Sessiz bildirim.
Kullanıcı önemi açıkça söylerse ona uy.

ALIŞVERİŞ
- "Alınacaklara ekle", "evde X bitti", "X eksik" gibi cümlelerde add_shopping kullan; ürünleri ayrı ayrı items'a yaz (ör. ["Domates", "Damacana su"]).
- "Ne alacaktım?" denirse listeyi cevabında oku. Damacana su, tüp, deterjan gibi ağır/hacimli ürünler için eve sipariş verilebileceğini hatırlat.
- "Aldım" denirse remove_shopping.

ARAMALAR
- "X'i aramam lazım", "X'i arayacağım" → add_call (person = kişi, title = konu varsa). Bir saat verildiyse ayrıca add_task ile hatırlatıcı da kur.

TAKVİM VE ROTA
- Belirli saatte bir buluşma/toplantı/randevu → add_event (varsa location). Önemliyse ayrıca hatırlatıcı gerekmez; takvim etkinliği kendi hatırlatmasıyla eklenir.
- "X'ten Y'ye nasıl giderim", "Y'ye ne kadar sürer" → get_route. Kalkış belirtilmemişse origin null (mevcut konum). Süreyi telefon hesaplayacak; cevabında "Rotaya bakıyorum" gibi kısa bir şey söyle, süre uydurma.
- Takvimdeki uzak bir yüz yüze toplantı günü zorlaştıracaksa (İstanbul trafiği, karşı yakaya geçiş, yoğun gün) bunu fark et ve önemine göre online (Zoom) görüşme veya saat değişikliği öner. Karar kullanıcının; sen öner.

PLANLAMA
- "Bugün ne var?", "planım ne?" → takvim ve görevleri zaman sırasıyla özetle, en önemlisini öne çıkar.
- Kullanıcı bir hedef/etkinlik söylediğinde (ör. "cuma stüdyoda vokal kaydım var") gerekirse hazırlık programı öner. Vokal kaydı için: 2 gün önceden bol su, alkol/sigara/kafein ve süt ürünlerini azaltma, erken uyku; kayıt sabahı hafif kahvaltı, ses ısınması (Ses Açma uygulaması), kayıt öncesi ve arasında ılık su. Kullanıcı isterse bu adımları zamanlı görevler olarak ekle; istemeden onlarca görev ekleme, önce kısaca öner.
- Gün çok yoğunsa önceliklendir, ertelenebilecekleri söyle.

HAFIZA
- Kullanıcı kalıcı bir bilgi verirse ("markette hep X alırım", "stüdyo Kadıköy'de") remember ile kaydet. Hafızadaki bilgileri cevaplarında kullan.

ÖZEL GÜNLER (her yıl tekrar eder)
- Doğum günü, evlilik/tanışma yıl dönümü, anma günü gibi kişisel özel günler → add_special_day. remember KULLANMA.
  title: kısa ve anlaşılır ("Annemin doğum günü", "Evlilik yıl dönümü"), person: kişi varsa, note: "doğum günü" | "yıl dönümü" | "özel gün".
  due: tarih YYYY-MM-DDT00:00. Doğum/başlangıç yılı biliniyorsa o yılı yaz (ör. 1962-03-03T00:00), bilinmiyorsa bu yılın tarihini yaz.
- Uygulama bunları yıllık takvimde işaretler; 1 hafta önce ve o gün kendisi hatırlatır. Ayrıca add_task ekleme.
- Bağlamdaki ÖZEL GÜNLER ve YAKLAŞAN BAYRAMLAR'ı planlarda dikkate al; yaklaşan bir doğum günü varsa uygun anda hediye/kutlama öner.

ANILAR
- Kullanıcı yaşadığı anlamlı bir olayı anlatırsa (sahneye çıktım, konser verdim, mezun oldum, ilk kez bir şey yaptım, önemli bir buluşma) → add_moment.
  title: kısa başlık ("Harbiye'de konuk sanatçı olarak sahne"), due: olayın tarihi (geçmişte olabilir; "1 ekimde" → bu yılın 1 Ekim'i, saat bilinmiyorsa T20:00), location: yer, note: kullanıcının anlattığı ayrıntılar.
- Cevabında bunu anı olarak sakladığını sıcak bir dille söyle. "Geçen yıl bugün ne yapmıştım?" gibi sorularda ANILAR listesini kullan.

HAFTALIK PROGRAM
- "Haftamı planla", "haftalık program yap" → takvim etkinliklerini, açık görevleri, özel günleri ve bayramları dikkate alarak makul sayıda zamanlı add_task ile programı kur (günde en fazla 3-4 iş), cevapta kısaca özetle ve show_calendar (note: "week") ekle.
- "Haftamı/takvimimi göster", "bu hafta ne var" → show_calendar (note: "week") + kısa sesli özet. "Yılı göster" → note: "year". "Anılarımı göster" → note: "moments".`;
}

function buildContext(ctx) {
  const lines = [];
  lines.push(`ŞU AN: ${ctx.now || "bilinmiyor"} (${ctx.timezone || "Europe/Istanbul"})`);
  if (ctx.location) lines.push(`KONUM: ${ctx.location}`);
  const list = (title, arr, fmt) => {
    lines.push(`${title}:`);
    if (!arr || arr.length === 0) lines.push("  (boş)");
    else arr.forEach((x) => lines.push("  " + fmt(x)));
  };
  list("AÇIK GÖREVLER", ctx.tasks, (t) => `[id:${t.id}] ${t.title}${t.due ? " | " + t.due : ""} | önem:${t.priority || "normal"}`);
  list("ALIŞVERİŞ LİSTESİ", ctx.shopping, (s) => `[id:${s.id}] ${s.name}`);
  list("ARANACAKLAR", ctx.calls, (c) => `[id:${c.id}] ${c.person}${c.reason ? " — " + c.reason : ""}`);
  list("TAKVİM (önümüzdeki günler)", ctx.events, (e) => `${e.start}${e.end ? "–" + e.end : ""} ${e.title}${e.location ? " @ " + e.location : ""}`);
  list("HAFIZA", ctx.memory, (m) => `[id:${m.id}] ${m.text}`);
  list("ÖZEL GÜNLER (yıllık)", ctx.specials, (d) => `[id:${d.id}] ${d.title}${d.person ? " (" + d.person + ")" : ""} | ${d.kind} | sıradaki: ${d.next}${d.years ? " | " + d.years + ". yıl" : ""}`);
  list("YAKLAŞAN BAYRAMLAR VE ÖNEMLİ GÜNLER", ctx.holidays, (h) => `${h.date} ${h.title}`);
  list("ANILAR (son)", ctx.moments, (m) => `${m.date} ${m.title}${m.place ? " @ " + m.place : ""}${m.note ? " — " + m.note : ""}`);
  return lines.join("\n");
}

function extractOutputText(data) {
  if (typeof data.output_text === "string" && data.output_text) return data.output_text;
  for (const item of data.output || []) {
    if (item.type === "message") {
      for (const c of item.content || []) {
        if (c.type === "output_text" && c.text) return c.text;
        if (c.type === "refusal") throw new Error("Model isteği reddetti: " + c.refusal);
      }
    }
  }
  throw new Error("OpenAI cevabında metin bulunamadı.");
}

function sanitize(result) {
  const out = { reply: String(result.reply || "").trim(), actions: [] };
  for (const a of Array.isArray(result.actions) ? result.actions : []) {
    if (!a || !ACTION_TYPES.includes(a.type)) continue;
    out.actions.push({
      type: a.type,
      title: a.title ?? null,
      items: Array.isArray(a.items) ? a.items.map(String).filter((s) => s.trim()) : [],
      due: a.due ?? null,
      end: a.end ?? null,
      priority: ["low", "normal", "high", "critical"].includes(a.priority) ? a.priority : null,
      person: a.person ?? null,
      origin: a.origin ?? null,
      destination: a.destination ?? null,
      location: a.location ?? null,
      note: a.note ?? null,
      target_id: a.target_id ?? null
    });
  }
  if (!out.reply) out.reply = out.actions.length ? "Tamam, hallettim." : "Bunu tam anlayamadım, tekrar söyler misin?";
  return out;
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" }
  });
}

async function handleChat(request, env) {
  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: "Geçersiz istek." }, 400);
  }
  const message = typeof body.message === "string" ? body.message.trim() : "";
  if (!message) return json({ error: "Mesaj boş." }, 400);

  const ctx = body.context || {};
  const history = (Array.isArray(body.history) ? body.history : [])
    .filter((m) => m && (m.role === "user" || m.role === "assistant") && typeof m.content === "string")
    .slice(-12)
    .map((m) => ({ role: m.role, content: m.content.slice(0, 2000) }));

  const payload = {
    model: env.OPENAI_MODEL || DEFAULT_MODEL,
    instructions: systemPrompt(ctx.userName || "Ertunç", ctx.assistantName || "Jarvis"),
    input: [
      ...history,
      { role: "user", content: `${buildContext(ctx)}\n\nKULLANICI: ${message.slice(0, 4000)}` }
    ],
    text: {
      format: { type: "json_schema", name: "jarvis_response", strict: true, schema: RESPONSE_SCHEMA }
    }
  };

  const res = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${env.OPENAI_API_KEY}`
    },
    body: JSON.stringify(payload)
  });

  if (!res.ok) {
    const detail = await res.text();
    return json({ error: `OpenAI hatası (${res.status})`, detail: detail.slice(0, 500) }, 502);
  }

  const data = await res.json();
  let parsed;
  try {
    parsed = JSON.parse(extractOutputText(data));
  } catch (e) {
    return json({ error: "Cevap çözümlenemedi.", detail: String(e.message || e) }, 502);
  }
  return json(sanitize(parsed));
}

// --- Ses (metni doğal sese çevirir) ---
const DEFAULT_TTS_MODEL = "gpt-4o-mini-tts";
const TTS_VOICES = ["onyx", "ash", "echo", "alloy", "ballad", "coral", "sage", "shimmer", "verse", "nova", "fable"];
const TTS_STYLE =
  "Türkçe konuş. Sakin, kendinden emin, sıcak ve akıcı bir kişisel asistan gibi; " +
  "kibar ama samimi, hafif esprili bir uşak tonu. Doğal vurgu ve tonlama kullan, " +
  "cümleler arasında kısa ve doğal duraksamalar yap, robotik okuma yapma.";

async function handleTTS(request, env) {
  let body;
  try { body = await request.json(); } catch { return json({ error: "Geçersiz istek." }, 400); }
  const text = String(body?.text ?? "").trim().slice(0, 4000);
  if (!text) return json({ error: "Metin boş." }, 400);
  const voice = TTS_VOICES.includes(body?.voice) ? body.voice : "onyx";
  const speed = Math.min(1.4, Math.max(0.8, Number(body?.speed) || 1.05));

  const res = await fetch("https://api.openai.com/v1/audio/speech", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${env.OPENAI_API_KEY}` },
    body: JSON.stringify({
      model: env.TTS_MODEL || DEFAULT_TTS_MODEL,
      voice,
      input: text,
      instructions: TTS_STYLE,
      speed,
      response_format: "mp3"
    })
  });
  if (!res.ok) {
    return json({ error: `Ses hatası (${res.status})` }, 502);
  }
  return new Response(res.body, { headers: { "content-type": "audio/mpeg", "cache-control": "no-store" } });
}

// --- Konuşmayı yazıya çevirme (bilgisayar uygulaması için) ---
async function handleSTT(request, env) {
  const type = request.headers.get("content-type") || "audio/webm";
  const audio = await request.arrayBuffer();
  if (!audio.byteLength) return json({ error: "Ses boş." }, 400);
  if (audio.byteLength > 20 * 1024 * 1024) return json({ error: "Ses çok uzun." }, 413);
  const ext = type.includes("mp4") || type.includes("m4a") ? "m4a" : type.includes("wav") ? "wav" : type.includes("ogg") ? "ogg" : "webm";
  const form = new FormData();
  form.append("file", new Blob([audio], { type }), `ses.${ext}`);
  form.append("model", env.STT_MODEL || "gpt-4o-mini-transcribe");
  form.append("language", "tr");
  const res = await fetch("https://api.openai.com/v1/audio/transcriptions", {
    method: "POST",
    headers: { authorization: `Bearer ${env.OPENAI_API_KEY}` },
    body: form
  });
  if (!res.ok) return json({ error: `Yazıya çevirme hatası (${res.status})` }, 502);
  const data = await res.json();
  return json({ text: String(data.text || "").trim() });
}

// --- Cihazlar arası eşitleme (telefon ↔ bilgisayar) ---
// Tüm veri tek kayıt olarak saklanır; en son yazan kazanır (updatedAt).
async function handleSync(request, env) {
  if (!env.JARVIS_KV) {
    return json({ error: "Eşitleme kapalı: Cloudflare'de JARVIS_KV bağlantısı eklenmemiş." }, 501);
  }
  if (request.method === "GET") {
    const stored = await env.JARVIS_KV.get("data", "json");
    return json(stored || { updatedAt: null, data: null });
  }
  if (request.method === "PUT") {
    let body;
    try { body = await request.json(); } catch { return json({ error: "Geçersiz veri." }, 400); }
    if (!body || typeof body.updatedAt !== "string" || typeof body.data !== "object" || body.data === null) {
      return json({ error: "updatedAt ve data gerekli." }, 400);
    }
    const stored = await env.JARVIS_KV.get("data", "json");
    if (stored?.updatedAt && stored.updatedAt > body.updatedAt) {
      // Sunucudaki daha yeni: istemci önce onu almalı
      return json({ conflict: true, ...stored }, 409);
    }
    await env.JARVIS_KV.put("data", JSON.stringify({ updatedAt: body.updatedAt, data: body.data }));
    return json({ ok: true, updatedAt: body.updatedAt });
  }
  return json({ error: "Desteklenmeyen yöntem." }, 405);
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/") {
      return json({ status: "online", name: "Jarvis" });
    }
    if (!env.APP_TOKEN || request.headers.get("authorization") !== `Bearer ${env.APP_TOKEN}`) {
      return json({ error: "Yetkisiz." }, 401);
    }
    if (!env.OPENAI_API_KEY) return json({ error: "Sunucuda OPENAI_API_KEY tanımlı değil." }, 500);
    if (request.method === "POST" && url.pathname === "/chat") {
      return handleChat(request, env);
    }
    if (request.method === "POST" && url.pathname === "/tts") {
      return handleTTS(request, env);
    }
    if (request.method === "POST" && url.pathname === "/stt") {
      return handleSTT(request, env);
    }
    if (url.pathname === "/sync") {
      return handleSync(request, env);
    }
    return json({ error: "Bulunamadı." }, 404);
  }
};

