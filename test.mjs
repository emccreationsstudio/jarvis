// node server/test.mjs — sahte OpenAI ile sunucu testleri
import assert from "node:assert";
import worker from "./worker.js";

const env = { OPENAI_API_KEY: "sk-test", APP_TOKEN: "gizli123" };
let lastPayload = null;
let fakeReply = null;

const FAKE_WEATHER = {
  current: { time: "2026-10-04T09:00", temperature_2m: 17.4, apparent_temperature: 16.1, weather_code: 61, wind_speed_10m: 22, precipitation: 0.4 },
  hourly: {
    time: ["2026-10-04T09:00", "2026-10-04T12:00", "2026-10-04T15:00", "2026-10-04T18:00", "2026-10-05T09:00"],
    temperature_2m: [17, 19, 20, 18, 15], precipitation_probability: [70, 40, 10, 0, 5], weather_code: [61, 3, 2, 1, 0]
  },
  daily: {
    time: ["2026-10-04", "2026-10-05"], weather_code: [61, 0], temperature_2m_max: [20, 22], temperature_2m_min: [14, 13],
    precipitation_probability_max: [70, 5], wind_speed_10m_max: [30, 12]
  }
};
const FAKE_RSS = `<?xml version="1.0"?><rss><channel><title>Kanal</title>
<item><title><![CDATA[Meclis yeni yasayı kabul etti]]></title><description><![CDATA[<p>Ayrıntılar &amp; tepkiler</p>]]></description></item>
<item><title>İstanbul&#39;da trafik düzenlemesi</title></item>
</channel></rss>`;
const FAKE_ATOM = `<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><title>NTV</title>
<entry><title type="html">Ankara'da kritik toplantı</title><summary type="html">&lt;p&gt;Gündem yoğun&lt;/p&gt;</summary></entry></feed>`;
let weatherCalls = 0, newsCalls = 0, failExternal = false;

globalThis.fetch = async (url, init = {}) => {
  if (String(url).startsWith("https://api.open-meteo.com/")) {
    weatherCalls++;
    if (failExternal) throw new Error("ağ yok");
    return new Response(JSON.stringify(FAKE_WEATHER), { status: 200 });
  }
  if (/ntv|aa\.com|bbci/.test(String(url))) {
    newsCalls++;
    if (failExternal) return new Response("x", { status: 503 });
    return new Response(String(url).includes("ntv") ? FAKE_ATOM : FAKE_RSS, { status: 200 });
  }
  assert.equal(url, "https://api.openai.com/v1/responses");
  assert.equal(init.headers.authorization, "Bearer sk-test");
  lastPayload = JSON.parse(init.body);
  return new Response(JSON.stringify({
    output: [
      { type: "reasoning", summary: [] },
      { type: "message", content: [{ type: "output_text", text: JSON.stringify(fakeReply) }] }
    ]
  }), { status: 200 });
};

const req = (path, body, token = "gizli123", method = "POST") =>
  new Request("https://jarvis.example" + path, {
    method,
    headers: { "content-type": "application/json", ...(token ? { authorization: "Bearer " + token } : {}) },
    body: body ? JSON.stringify(body) : undefined
  });

let n = 0;
const test = async (name, fn) => { await fn(); n++; console.log("✓", name); };

await test("sağlık kontrolü şifresiz açık", async () => {
  const r = await worker.fetch(new Request("https://jarvis.example/"), env);
  assert.equal((await r.json()).status, "online");
});

await test("şifre yoksa / yanlışsa 401", async () => {
  assert.equal((await worker.fetch(req("/chat", { message: "x" }, null), env)).status, 401);
  assert.equal((await worker.fetch(req("/chat", { message: "x" }, "yanlis"), env)).status, 401);
});

await test("boş mesaj 400", async () => {
  assert.equal((await worker.fetch(req("/chat", { message: "  " }), env)).status, 400);
});

await test("alışveriş + bağlam modele doğru gidiyor", async () => {
  fakeReply = {
    reply: "Domates ve damacana su listeye eklendi.",
    actions: [{ type: "add_shopping", title: null, items: ["Domates", "Damacana su"], due: null, end: null, priority: null, person: null, origin: null, destination: null, location: null, note: null, target_id: null }]
  };
  const r = await worker.fetch(req("/chat", {
    message: "alınacaklara domates ve damacana su ekle",
    history: [{ role: "user", content: "selam" }, { role: "assistant", content: "Merhaba" }, { role: "system", content: "hack" }],
    context: {
      now: "2026-10-02 Cuma 21:40", userName: "Ertunç",
      tasks: [{ id: "t1", title: "Klip bütçesi", due: "2026-10-03T15:00", priority: "high" }],
      shopping: [{ id: "s1", name: "Ekmek" }], calls: [], events: [], memory: [{ id: "m1", text: "Stüdyo Kadıköy'de" }]
    }
  }), env);
  const body = await r.json();
  assert.equal(r.status, 200);
  assert.equal(body.actions[0].type, "add_shopping");
  assert.deepEqual(body.actions[0].items, ["Domates", "Damacana su"]);
  // geçmişten system rolü süzülmeli
  assert.equal(lastPayload.input.filter((m) => m.role === "system").length, 0);
  const last = lastPayload.input.at(-1).content;
  assert.ok(last.includes("ŞU AN: 2026-10-02 Cuma 21:40"));
  assert.ok(last.includes("[id:t1] Klip bütçesi | 2026-10-03T15:00 | önem:high"));
  assert.ok(last.includes("[id:s1] Ekmek"));
  assert.ok(last.includes("Stüdyo Kadıköy'de"));
  assert.equal(lastPayload.text.format.type, "json_schema");
  assert.ok(lastPayload.instructions.includes("Ertunç"));
});

await test("geçersiz işlem türü ve öncelik temizleniyor", async () => {
  fakeReply = {
    reply: "",
    actions: [
      { type: "hack_phone", items: [] },
      { type: "add_task", title: "Uçak", items: [], due: "2026-10-04T07:00", end: null, priority: "ultra", person: null, origin: null, destination: null, location: null, note: null, target_id: null }
    ]
  };
  const body = await (await worker.fetch(req("/chat", { message: "x" }), env)).json();
  assert.equal(body.actions.length, 1);
  assert.equal(body.actions[0].priority, null);
  assert.equal(body.reply, "Tamam, hallettim.");
});

await test("OpenAI hatası 502 olarak dönüyor", async () => {
  const saved = globalThis.fetch;
  globalThis.fetch = async () => new Response("rate limit", { status: 429 });
  const r = await worker.fetch(req("/chat", { message: "x" }), env);
  assert.equal(r.status, 502);
  assert.ok((await r.json()).error.includes("429"));
  globalThis.fetch = saved;
});

await test("şema strict kurallarına uygun (her alan zorunlu, ek alan yok)", async () => {
  const check = (s, path) => {
    if (s.type === "object" || (Array.isArray(s.type) && s.type.includes("object"))) {
      assert.equal(s.additionalProperties, false, path);
      assert.deepEqual([...s.required].sort(), Object.keys(s.properties).sort(), path);
      for (const [k, v] of Object.entries(s.properties)) check(v, path + "." + k);
    }
    if (s.items) check(s.items, path + "[]");
    if (s.enum && Array.isArray(s.type) && s.type.includes("null")) assert.ok(s.enum.includes(null), path);
  };
  check(lastPayload.text.format.schema, "root");
});

await test("ses: /tts OpenAI'den mp3 döndürüyor, ses ve hız sınırlanıyor", async () => {
  const saved = globalThis.fetch;
  let sent = null;
  globalThis.fetch = async (url, init) => {
    assert.equal(url, "https://api.openai.com/v1/audio/speech");
    sent = JSON.parse(init.body);
    return new Response(new Uint8Array([1, 2, 3]), { status: 200, headers: { "content-type": "audio/mpeg" } });
  };
  const r = await worker.fetch(req("/tts", { text: "Merhaba efendim", voice: "kotu-ses", speed: 9 }), env);
  assert.equal(r.status, 200);
  assert.equal(r.headers.get("content-type"), "audio/mpeg");
  assert.equal((await r.arrayBuffer()).byteLength, 3);
  assert.equal(sent.voice, "onyx");
  assert.equal(sent.speed, 1.4);
  assert.equal(sent.model, "gpt-4o-mini-tts");
  assert.ok(sent.instructions.includes("Türkçe"));
  assert.equal((await worker.fetch(req("/tts", { text: "x" }, "yanlis"), env)).status, 401);
  assert.equal((await worker.fetch(req("/tts", { text: "  " }), env)).status, 400);
  globalThis.fetch = saved;
});

await test("özel gün, anı ve takvim işlemleri kabul ediliyor, bağlama ekleniyor", async () => {
  fakeReply = {
    reply: "Annenin doğum gününü ve Harbiye anını kaydettim.",
    actions: [
      { type: "add_special_day", title: "Annemin doğum günü", items: [], due: "1962-03-03T00:00", end: null, priority: null, person: "Annem", origin: null, destination: null, location: null, note: "doğum günü", target_id: null },
      { type: "add_moment", title: "Harbiye'de konuk sanatçı", items: [], due: "2026-10-01T20:00", end: null, priority: null, person: null, origin: null, destination: null, location: "Harbiye Açıkhava", note: "Konuk sanatçı olarak sahneye çıktım", target_id: null },
      { type: "show_calendar", title: null, items: [], due: null, end: null, priority: null, person: null, origin: null, destination: null, location: null, note: "week", target_id: null }
    ]
  };
  const body = await (await worker.fetch(req("/chat", {
    message: "annemin doğum günü 3 mart",
    context: {
      specials: [{ id: "s1", title: "Babamın doğum günü", kind: "birthday", next: "2027-01-05", years: 70 }],
      holidays: [{ date: "2026-10-29", title: "Cumhuriyet Bayramı" }],
      moments: [{ date: "2026-10-01", title: "Harbiye", place: "Harbiye", note: null }]
    }
  }), env)).json();
  assert.deepEqual(body.actions.map((a) => a.type), ["add_special_day", "add_moment", "show_calendar"]);
  const last = lastPayload.input.at(-1).content;
  assert.ok(last.includes("Babamın doğum günü") && last.includes("70. yıl"));
  assert.ok(last.includes("Cumhuriyet Bayramı"));
  assert.ok(last.includes("ANILAR"));
  assert.ok(lastPayload.instructions.includes("add_moment"));
});

await test("stt: sesi OpenAI'ye gönderip yazıyı döndürüyor", async () => {
  const saved = globalThis.fetch;
  let form = null;
  globalThis.fetch = async (url, init) => {
    assert.equal(url, "https://api.openai.com/v1/audio/transcriptions");
    form = init.body;
    return new Response(JSON.stringify({ text: " Domates ekle. " }), { status: 200 });
  };
  const r = await worker.fetch(new Request("https://jarvis.example/stt", {
    method: "POST", headers: { authorization: "Bearer gizli123", "content-type": "audio/webm" }, body: new Uint8Array([1, 2, 3, 4])
  }), env);
  assert.equal(r.status, 200);
  assert.equal((await r.json()).text, "Domates ekle.");
  assert.equal(form.get("language"), "tr");
  assert.equal(form.get("model"), "gpt-4o-mini-transcribe");
  assert.equal(form.get("file").name, "ses.webm");
  globalThis.fetch = saved;
});

await test("sync: KV yoksa 501, varsa yaz/oku, eski veri 409", async () => {
  assert.equal((await worker.fetch(req("/sync", null, "gizli123", "GET"), env)).status, 501);
  const mem = new Map();
  const kv = {
    get: async (k, t) => (mem.has(k) ? (t === "json" ? JSON.parse(mem.get(k)) : mem.get(k)) : null),
    put: async (k, v) => { mem.set(k, v); }
  };
  const e2 = { ...env, JARVIS_KV: kv };
  const empty = await (await worker.fetch(req("/sync", null, "gizli123", "GET"), e2)).json();
  assert.equal(empty.updatedAt, null);
  const put = await worker.fetch(new Request("https://jarvis.example/sync", {
    method: "PUT", headers: { authorization: "Bearer gizli123", "content-type": "application/json" },
    body: JSON.stringify({ updatedAt: "2026-10-03T10:00:00Z", data: { tasks: [{ id: "a", title: "Su iç" }] } })
  }), e2);
  assert.equal(put.status, 200);
  const got = await (await worker.fetch(req("/sync", null, "gizli123", "GET"), e2)).json();
  assert.equal(got.data.tasks[0].title, "Su iç");
  const old = await worker.fetch(new Request("https://jarvis.example/sync", {
    method: "PUT", headers: { authorization: "Bearer gizli123", "content-type": "application/json" },
    body: JSON.stringify({ updatedAt: "2026-10-03T09:00:00Z", data: { tasks: [] } })
  }), e2);
  assert.equal(old.status, 409);
  assert.equal((await old.json()).data.tasks.length, 1);
  assert.equal((await worker.fetch(req("/sync", null, "yanlis", "GET"), e2)).status, 401);
});

const blank = { title: null, items: [], due: null, end: null, priority: null, person: null, origin: null, destination: null, location: null, note: null, target_id: null };

await test("yeni işlem türleri geçiyor (listeler, takvim düzenleme, harita, mesaj, arama)", async () => {
  const types = ["check_shopping", "reopen_task", "create_list", "add_list_items", "check_list_items", "remove_list_items",
    "delete_list", "update_event", "delete_event", "open_maps", "send_message", "call_now"];
  fakeReply = { reply: "Tamam.", actions: types.map((type) => ({ ...blank, type })) };
  const body = await (await worker.fetch(req("/chat", { message: "x" }), env)).json();
  assert.deepEqual(body.actions.map((a) => a.type), types);
  const schemaTypes = lastPayload.text.format.schema.properties.actions.items.properties.type.enum;
  types.forEach((t) => assert.ok(schemaTypes.includes(t), t));
});

await test("hava durumu bağlama ekleniyor, konum yoksa İstanbul", async () => {
  fakeReply = { reply: "Şemsiye al.", actions: [] };
  weatherCalls = 0;
  await worker.fetch(req("/chat", { message: "yarın ne giysem", context: { now: "2026-10-04 Pazar 09:10" } }), env);
  assert.equal(weatherCalls, 1);
  const last = lastPayload.input.at(-1).content;
  assert.ok(last.includes("HAVA DURUMU (İstanbul)"), last);
  assert.ok(last.includes("Şu an: 17°C"));
  assert.ok(last.includes("09:00 17° hafif yağmur yağış %70"));
  assert.ok(last.includes("2026-10-05: 13–22°C, açık"));
  assert.ok(!last.includes("HABERLER"), "haber istenmedi");
});

await test("konum verilirse o konum kullanılıyor", async () => {
  let asked = null;
  const saved = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    if (String(url).includes("open-meteo")) { asked = String(url); return new Response(JSON.stringify(FAKE_WEATHER)); }
    return saved(url, init);
  };
  await worker.fetch(req("/chat", { message: "hava nasıl", context: { location: { lat: 40.99, lon: 29.03 } } }), env);
  globalThis.fetch = saved;
  assert.ok(asked.includes("latitude=40.99&longitude=29.03"), asked);
  assert.ok(lastPayload.input.at(-1).content.includes("HAVA DURUMU (bulunduğun yer)"));
});

await test("sabah özeti: haber başlıkları ekleniyor", async () => {
  fakeReply = { reply: "Günaydın.", actions: [] };
  newsCalls = 0;
  await worker.fetch(req("/chat", { message: "Günaydın Jarvis, sabah özetimi ver" }), env);
  assert.equal(newsCalls, 4);
  const last = lastPayload.input.at(-1).content;
  assert.ok(last.includes("HABERLER"));
  assert.ok(last.includes("  Türkiye:"));
  assert.ok(last.includes("Meclis yeni yasayı kabul etti — Ayrıntılar & tepkiler"), last);
  assert.ok(last.includes("İstanbul'da trafik düzenlemesi"));
  assert.ok(last.includes("Ankara'da kritik toplantı — Gündem yoğun"), "Atom beslemesi okunmalı");
});

await test("hava/haber alınamazsa sohbet yine çalışıyor", async () => {
  failExternal = true;
  fakeReply = { reply: "Haberlere şu an ulaşamıyorum.", actions: [] };
  const r = await worker.fetch(req("/chat", { message: "haberler ne" }), env);
  failExternal = false;
  assert.equal(r.status, 200);
  const last = lastPayload.input.at(-1).content;
  assert.ok(!last.includes("HAVA DURUMU") && !last.includes("HABERLER"));
});

await test("sesli mesaj işaretleniyor, listeler ve takvim id'leri bağlamda", async () => {
  fakeReply = { reply: "Tamam.", actions: [] };
  await worker.fetch(req("/chat", {
    message: "eczane listesine parol ekle", voice: true,
    context: {
      lists: [{ id: "l1", name: "Eczane", daily: false, items: ["Vitamin"], done: ["Krem"] }, { id: "l2", name: "Günlük ilaçlar", daily: true, items: [], done: [] }],
      events: [{ id: "E1", start: "2026-10-05T10:00", end: "2026-10-05T11:00", title: "Dişçi", location: "Kadıköy" }]
    }
  }), env);
  const last = lastPayload.input.at(-1).content;
  assert.ok(last.includes("SESLİ: evet\nKULLANICI: eczane listesine parol ekle"));
  assert.ok(last.includes("[id:l1] Eczane: Vitamin | işaretli: Krem"));
  assert.ok(last.includes("[id:l2] Günlük ilaçlar (günlük): (boş)"));
  assert.ok(last.includes("[id:E1] 2026-10-05T10:00–2026-10-05T11:00 Dişçi @ Kadıköy"));
  assert.ok(lastPayload.instructions.includes("rakamla"));
  // yazılı mesajda işaret yok
  await worker.fetch(req("/chat", { message: "selam" }), env);
  assert.ok(!lastPayload.input.at(-1).content.includes("SESLİ"));
});

console.log(`\n${n} test geçti`);
