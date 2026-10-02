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

console.log(`\n${n} test geçti`);
