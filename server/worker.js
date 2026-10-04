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
  "show_calendar",   // uygulamada takvimi aç (note: "week" | "year" | "moments")
  "check_shopping",  // alındı olarak işaretle (items) — silmez
  "reopen_task",     // tamamlanan görevi yeniden aç (target_id)
  "create_list",     // yeni liste aç (title = ad, note = "daily" ise günlük liste, items = ilk satırlar)
  "add_list_items",  // listeye ekle (title = liste adı, items); liste yoksa açılır
  "check_list_items",// listede işaretle (title, items; items boşsa hepsi)
  "remove_list_items", // listeden sil (title, items) — çöp kutusuna gider
  "delete_list",     // listeyi sil (title ya da target_id)
  "update_event",    // takvim etkinliğini değiştir / ertele (target_id, title, due = yeni başlangıç, end, location)
  "delete_event",    // takvim etkinliğini sil (target_id)
  "open_maps",       // harita uygulamasında yol tarifini hemen aç (destination, origin)
  "send_message",    // mesaj hazırla (person, note = metin, title = "whatsapp" ya da "sms")
  "call_now"         // hemen ara (person = kişi ya da numara: "112", "155")
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
  return baseSystemPrompt(userName, assistantName) + EXTRA_RULES;
}

const EXTRA_RULES = `

SAYILAR VE YAZIM
- Görev başlıklarında, liste maddelerinde, notlarda ve cevaplarında sayıları HER ZAMAN rakamla yaz: "2 domates", "saat 16:30", "3 kutu", "15 Ekim", "%20".
- Mesajın başında "SESLİ: evet" yazıyorsa mesaj konuşmadan yazıya çevrilmiştir: yanlış duyulmuş sözcükleri bağlamdan düzelt (benzer sesli kişi, ürün, liste ve yer adlarını listelerdeki/hafızadaki doğru yazımla eşleştir; "carvis/çarvis" = Jarvis). Kaydettiğin başlık ve maddeler düzgün yazılmış olsun. Emin olamadığın önemli bir ad varsa kısaca teyit et.

LİSTELER (kullanıcının açtıkları)
- Bağlamdaki KULLANICI LİSTELERİ'ni kullan. "Eczane diye bir liste aç", "ilaç listesi oluştur" → create_list. Her gün tekrarlanan şeyler (günlük ilaçlar, vitaminler, rutin) için note: "daily".
- "Eczane listesine parol ekle" → add_list_items (title: "Eczane", items: ["Parol"]). Liste yoksa yine add_list_items kullan, uygulama açar. Alışveriş/market için add_shopping kullanmaya devam et.
- "İlaçlarımı içtim", "parolü aldım" → check_list_items. "Listeden çıkar" → remove_list_items. "Listeyi sil" → delete_list.
- Listeye dokunmak işaretler, silmez. Silinenler 30 gün çöp kutusunda kalır; kullanıcı sorarsa Listeler sekmesindeki çöp simgesinden geri alabileceğini söyle.
- Alışverişte "aldım" → check_shopping (işaretle). "Listeden çıkar/sil" → remove_shopping.

TAKVİM DÜZENLEME
- TAKVİM'deki etkinliklerin id'si var. "Yarınki toplantıyı 15:00'e al", "dişçiyi cumaya ertele" → update_event (target_id, due = yeni başlangıç; süre korunur). Başlık/yer değişikliği de update_event. "Toplantıyı iptal et / sil" → delete_event. Hangi etkinlik olduğu belirsizse sor.
- Görevler için update_task (zamanını değiştir), reopen_task (yanlışlıkla tamamlandıysa).

HARİTA, MESAJ, ARAMA
- "Yol tarifi başlat", "haritayı aç", "navigasyonu aç", "beni X'e götür" → open_maps (destination). Sadece süre soruluyorsa get_route.
- "Ahmet'e toplantıdayım, sonra arayacağım yaz" → send_message (person: "Ahmet", note: mesaj metni, title: "sms"; WhatsApp denirse "whatsapp"). Mesajı kullanıcının ağzından, kısa ve kibar yaz. Uygulama mesajı hazırlar, kullanıcı gönder'e basar.
- "Annemi ara", "112'yi ara" → call_now (person). Acil durum (yangın, kaza, sağlık) söylenirse hemen call_now ile 112'yi ara ve cevabında sakin, kısa yönlendirme yap.
- Gelen aramaları duyurmak ve meşgulken otomatik cevap iPhone'un kendi ayarlarıyla yapılır (Telefon → Aramaları Seslendir, Mesajla Yanıtla); Jarvis'in Ayarlar → Aramalar bölümünde anlatıldığını söyle.

HAVA DURUMU
- Bağlamda HAVA DURUMU varsa kullan; uydurma. Takvimdeki etkinliklerle ilişkilendir: dışarıda/uzak bir etkinlik varken yağmur → şemsiye ve trafiğe ek süre öner; soğuk/rüzgârlı → mont; çok sıcak → su. Vokal kaydı/sahne günü soğuk ya da kuru havaysa boğazı koruma (ılık su, atkı) öner.
- Kullanıcı sormadıkça her cevapta hava anlatma; plan, yarın, sabah özeti ya da dışarı çıkma konuşulurken kısaca an.

SABAH ÖZETİ VE HABERLER
- "Günaydın", "sabah özeti", "haberler ne", "gündemde ne var" → bu cevap 1-3 cümle kuralından muaftır ama yine sesli okunacak, akıcı ve en fazla 10-12 cümle olsun:
  1) kısa selam, 2) bugünün havası ve takvime göre önerisi, 3) bugünkü etkinlikler/kritik görevler, yaklaşan özel gün varsa, 4) HABERLER bağlamından Türkiye'den 3, dünyadan 2 önemli başlığı tarafsız ve kısaca özetle. Kaynak verilmemiş haber uydurma; haber bağlamı yoksa haberlere ulaşamadığını söyle.`;

function baseSystemPrompt(userName, assistantName) {
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
- "Aldım" denirse check_shopping (alındı olarak işaretlenir, listede üstü çizili kalır).

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
  if (typeof ctx.location === "string" && ctx.location) lines.push(`KONUM: ${ctx.location}`);
  const list = (title, arr, fmt) => {
    lines.push(`${title}:`);
    if (!arr || arr.length === 0) lines.push("  (boş)");
    else arr.forEach((x) => lines.push("  " + fmt(x)));
  };
  list("AÇIK GÖREVLER", ctx.tasks, (t) => `[id:${t.id}] ${t.title}${t.due ? " | " + t.due : ""} | önem:${t.priority || "normal"}`);
  list("ALIŞVERİŞ LİSTESİ", ctx.shopping, (s) => `[id:${s.id}] ${s.name}`);
  list("ARANACAKLAR", ctx.calls, (c) => `[id:${c.id}] ${c.person}${c.reason ? " — " + c.reason : ""}`);
  list("TAKVİM (önümüzdeki günler)", ctx.events, (e) => `${e.id ? "[id:" + e.id + "] " : ""}${e.start}${e.end ? "–" + e.end : ""} ${e.title}${e.location ? " @ " + e.location : ""}`);
  list("HAFIZA", ctx.memory, (m) => `[id:${m.id}] ${m.text}`);
  list("ÖZEL GÜNLER (yıllık)", ctx.specials, (d) => `[id:${d.id}] ${d.title}${d.person ? " (" + d.person + ")" : ""} | ${d.kind} | sıradaki: ${d.next}${d.years ? " | " + d.years + ". yıl" : ""}`);
  list("YAKLAŞAN BAYRAMLAR VE ÖNEMLİ GÜNLER", ctx.holidays, (h) => `${h.date} ${h.title}`);
  list("ANILAR (son)", ctx.moments, (m) => `${m.date} ${m.title}${m.place ? " @ " + m.place : ""}${m.note ? " — " + m.note : ""}`);
  list("KULLANICI LİSTELERİ", ctx.lists, (l) =>
    `[id:${l.id}] ${l.name}${l.daily ? " (günlük)" : ""}: ${(l.items || []).join(", ") || "(boş)"}${l.done?.length ? " | işaretli: " + l.done.join(", ") : ""}`);
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

  // Hava durumu ve (istenirse) haberler — paralel, kısa zaman aşımıyla; alınamazsa sohbet yine çalışır
  const [weather, news] = await Promise.all([
    getWeather(ctx.location, ctx.timezone).catch(() => null),
    wantsNews(message) ? getNews().catch(() => null) : Promise.resolve(null)
  ]);
  const extra = [weather, news].filter(Boolean).join("\n");
  const voiceTag = body.voice === true ? "SESLİ: evet\n" : "";

  const payload = {
    model: env.OPENAI_MODEL || DEFAULT_MODEL,
    instructions: systemPrompt(ctx.userName || "Ertunç", ctx.assistantName || "Jarvis"),
    input: [
      ...history,
      { role: "user", content: `${buildContext(ctx)}${extra ? "\n" + extra : ""}\n\n${voiceTag}KULLANICI: ${message.slice(0, 4000)}` }
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

// --- Hava durumu (Open-Meteo, anahtar gerektirmez) ---
const WMO = {
  0: "açık", 1: "çoğunlukla açık", 2: "parçalı bulutlu", 3: "kapalı", 45: "sisli", 48: "kırağılı sis",
  51: "hafif çisenti", 53: "çisenti", 55: "yoğun çisenti", 56: "dondurucu çisenti", 57: "dondurucu çisenti",
  61: "hafif yağmur", 63: "yağmur", 65: "kuvvetli yağmur", 66: "dondurucu yağmur", 67: "dondurucu yağmur",
  71: "hafif kar", 73: "kar", 75: "yoğun kar", 77: "kar taneleri", 80: "hafif sağanak", 81: "sağanak", 82: "şiddetli sağanak",
  85: "kar sağanağı", 86: "yoğun kar sağanağı", 95: "gök gürültülü fırtına", 96: "dolu ile fırtına", 99: "dolu ile şiddetli fırtına"
};
const ISTANBUL = { lat: 41.01, lon: 28.98 };

async function fetchWithTimeout(url, ms, init = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), ms);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

async function getWeather(loc, timezone) {
  const lat = Number(loc?.lat), lon = Number(loc?.lon);
  const p = Number.isFinite(lat) && Number.isFinite(lon) && Math.abs(lat) <= 90 && Math.abs(lon) <= 180 ? { lat, lon } : ISTANBUL;
  const tz = typeof timezone === "string" && /^[A-Za-z_]+\/[A-Za-z_]+$/.test(timezone) ? timezone : "Europe/Istanbul";
  const url = `https://api.open-meteo.com/v1/forecast?latitude=${p.lat.toFixed(2)}&longitude=${p.lon.toFixed(2)}`
    + "&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m,precipitation"
    + "&hourly=temperature_2m,precipitation_probability,weather_code"
    + "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,wind_speed_10m_max"
    + `&timezone=${encodeURIComponent(tz)}&forecast_days=4&wind_speed_unit=kmh`;
  const res = await fetchWithTimeout(url, 3000);
  if (!res.ok) return null;
  const d = await res.json();
  const lines = [`HAVA DURUMU (${p === ISTANBUL ? "İstanbul" : "bulunduğun yer"}):`];
  const c = d.current;
  if (c) {
    lines.push(`  Şu an: ${Math.round(c.temperature_2m)}°C (hissedilen ${Math.round(c.apparent_temperature)}°C), ${WMO[c.weather_code] || "?"}, rüzgâr ${Math.round(c.wind_speed_10m)} km/sa`);
  }
  // Bugünün kalan saatleri (3 saatte bir)
  const h = d.hourly;
  if (h?.time?.length) {
    const nowKey = (c?.time || h.time[0]).slice(0, 13);
    const today = nowKey.slice(0, 10);
    const parts = [];
    for (let i = 0; i < h.time.length; i++) {
      const t = h.time[i];
      if (t.slice(0, 10) !== today || t.slice(0, 13) < nowKey) continue;
      const hour = Number(t.slice(11, 13));
      if (hour % 3 !== 0) continue;
      parts.push(`${t.slice(11, 16)} ${Math.round(h.temperature_2m[i])}° ${WMO[h.weather_code[i]] || ""}${h.precipitation_probability[i] >= 20 ? " yağış %" + h.precipitation_probability[i] : ""}`);
    }
    if (parts.length) lines.push("  Bugün: " + parts.join(" · "));
  }
  const dl = d.daily;
  if (dl?.time?.length) {
    for (let i = 0; i < Math.min(dl.time.length, 4); i++) {
      lines.push(`  ${dl.time[i]}: ${Math.round(dl.temperature_2m_min[i])}–${Math.round(dl.temperature_2m_max[i])}°C, ${WMO[dl.weather_code[i]] || "?"}, yağış olasılığı %${dl.precipitation_probability_max[i] ?? 0}, rüzgâr en çok ${Math.round(dl.wind_speed_10m_max[i])} km/sa`);
    }
  }
  return lines.length > 1 ? lines.join("\n") : null;
}

// --- Haberler (RSS başlıkları; özetini model yapar) ---
const NEWS_FEEDS = [
  { area: "Türkiye", url: "https://www.ntv.com.tr/gundem.rss" },
  { area: "Türkiye", url: "https://www.aa.com.tr/tr/rss/default?cat=guncel" },
  { area: "Dünya", url: "https://feeds.bbci.co.uk/turkce/rss.xml" },
  { area: "Dünya", url: "https://feeds.bbci.co.uk/news/world/rss.xml" }
];

function wantsNews(text) {
  return /(haber|gündem|günaydın|sabah özet|brifing|manşet|dünyada ne|türkiye'de ne|neler oluyor|son dakika)/i
    .test(text.toLocaleLowerCase("tr-TR"));
}

const decodeEntities = (s) => s
  .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1")
  .replace(/&lt;/g, "<").replace(/&gt;/g, ">")
  .replace(/<[^>]+>/g, "")                       // (kaçışlı olanlar dahil) HTML etiketlerini at
  .replace(/&quot;/g, '"').replace(/&#39;|&apos;/g, "'")
  .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(Number(n)))
  .replace(/&nbsp;/g, " ").replace(/&amp;/g, "&")
  .replace(/\s+/g, " ").trim();

function parseRss(xml, limit = 6) {
  const out = [];
  // RSS <item> ya da Atom <entry> (NTV Atom kullanır)
  const items = xml.match(/<item[\s>][\s\S]*?<\/item>/g) || xml.match(/<entry[\s>][\s\S]*?<\/entry>/g) || [];
  for (const item of items) {
    const title = decodeEntities(item.match(/<title[^>]*>([\s\S]*?)<\/title>/)?.[1] || "");
    if (!title) continue;
    const rawDesc = item.match(/<(description|summary)[^>]*>([\s\S]*?)<\/\1>/)?.[2] || "";
    const desc = decodeEntities(rawDesc).slice(0, 160);
    out.push(desc && !desc.startsWith(title) ? `${title} — ${desc}` : title);
    if (out.length >= limit) break;
  }
  return out;
}

async function getNews() {
  const results = await Promise.allSettled(NEWS_FEEDS.map(async (f) => {
    const res = await fetchWithTimeout(f.url, 3500, { headers: { "user-agent": "Mozilla/5.0 JarvisAssistant" } });
    if (!res.ok) return null;
    return { area: f.area, items: parseRss(await res.text(), f.area === "Türkiye" ? 6 : 5) };
  }));
  const byArea = { "Türkiye": [], "Dünya": [] };
  for (const r of results) {
    if (r.status === "fulfilled" && r.value) byArea[r.value.area].push(...r.value.items);
  }
  if (!byArea["Türkiye"].length && !byArea["Dünya"].length) return null;
  const lines = ["HABERLER (son başlıklar; tarafsız özetle, uydurma):"];
  for (const area of ["Türkiye", "Dünya"]) {
    const seen = new Set();
    const items = byArea[area].filter((t) => { const k = t.slice(0, 40).toLocaleLowerCase("tr-TR"); if (seen.has(k)) return false; seen.add(k); return true; }).slice(0, 10);
    if (items.length) {
      lines.push(`  ${area}:`);
      items.forEach((t) => lines.push("   - " + t));
    }
  }
  return lines.join("\n");
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

