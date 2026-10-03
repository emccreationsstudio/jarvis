import assert from "node:assert";
import { parse, isQuestion, isComplete } from "../renderer/commands.js";

assert.deepEqual(parse("Domates ekle, Jarvis kapan."), { body: "Domates ekle", end: "close" });
assert.deepEqual(parse("Jarvis, süt de ekle bitti"), { body: "süt de ekle", end: "done" });
assert.deepEqual(parse("Yarın saat onda toplantım var"), { body: "Yarın saat onda toplantım var", end: "none" });
assert.equal(parse("JARVIS KAPAN").end, "close");
assert.ok(isQuestion("Bugün planım ne"));
assert.ok(isQuestion("Yarın yağmur yağacak mı"));
assert.ok(isQuestion("Alışveriş listemi oku"));
assert.ok(!isQuestion("Çocuğu okula bırak"));
assert.ok(isComplete("Alışveriş listesine domates ekle"));
assert.ok(isComplete("Yarın saat 10'da toplantıyı hatırlat"));
assert.ok(!isComplete("Bir de şey"));
console.log("komut testleri geçti");
