// node server/test.mjs — sahte OpenAI ile sunucu testleri
import assert from "node:assert";
import worker from "./worker.js";

const env = { OPENAI_API_KEY: "sk-test", APP_TOKEN: "gizli123" };
let lastPayload = null;
let fakeReply = null;

globalThis.fetch = async (url, init) => {
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

console.log(`\n${n} test geçti`);
