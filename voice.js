// Sesli sohbet: mikrofonu dinler, duraksamalarda konuşmayı parça parça yazıya çevirir (sunucu /stt),
// iPhone'daki akışla aynı: notlar birikir, susunca hepsine birlikte cevap verilir; "Jarvis kapan" kapatır.

import * as core from "./core.js";
import * as cmd from "./commands.js";
import { normalizeNumbers } from "./numbers.js";

export const state = {
  phase: "idle",          // idle | listening | thinking | speaking
  conversing: false,
  pending: [],             // henüz gönderilmemiş cümleler
  level: 0,                // mikrofon seviyesi 0…1
  hearing: false,          // şu an konuşma algılanıyor
  transcribing: 0,         // yazıya çevrilen parça sayısı
  error: null,
  sessionStart: Date.now() // ekranda gösterilecek sohbetin başlangıcı
};

const listeners = new Set();
export const onState = (fn) => listeners.add(fn);
const notify = () => listeners.forEach((fn) => fn(state));
function setPhase(p) { state.phase = p; notify(); }

// ---------------------------------------------------------------- mikrofon ve sessizlik algılama

let stream = null, ctx = null, analyser = null, recorder = null, chunks = [];
let micOpen = false, loopTimer = null;
let speechMs = 0, silenceMs = 0, segmentMs = 0, noiseFloor = 0.01, heardInSegment = false;
const PAUSE_MS = 1300, MAX_SEGMENT_MS = 30000, TICK = 50;

async function ensureStream() {
  if (stream) return true;
  await window.jarvis.askMic();
  try {
    stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true } });
  } catch (e) {
    state.error = "Mikrofona erişilemedi. Sistem ayarlarından Jarvis'e mikrofon izni verin.";
    notify();
    return false;
  }
  ctx = new AudioContext();
  const src = ctx.createMediaStreamSource(stream);
  analyser = ctx.createAnalyser();
  analyser.fftSize = 1024;
  src.connect(analyser);
  return true;
}

function rms() {
  const buf = new Float32Array(analyser.fftSize);
  analyser.getFloatTimeDomainData(buf);
  let s = 0;
  for (const v of buf) s += v * v;
  return Math.sqrt(s / buf.length);
}

function startRecorder() {
  chunks = [];
  heardInSegment = false;
  segmentMs = 0; speechMs = 0; silenceMs = 0;
  const type = MediaRecorder.isTypeSupported("audio/webm;codecs=opus") ? "audio/webm;codecs=opus" : "audio/webm";
  recorder = new MediaRecorder(stream, { mimeType: type });
  recorder.ondataavailable = (e) => { if (e.data.size) chunks.push(e.data); };
  recorder.start(250);
}

function cutSegment() {
  if (!recorder) return;
  const r = recorder, had = heardInSegment, parts = chunks;
  recorder = null;
  r.onstop = () => {
    if (had) {
      const blob = new Blob(parts, { type: "audio/webm" });
      transcribe(blob);
    }
  };
  try { r.stop(); } catch {}
  if (micOpen) startRecorder();
}

function tick() {
  if (!micOpen || !analyser) return;
  const level = rms();
  // Ortam gürültüsünü yavaşça öğren
  if (!state.hearing) noiseFloor = noiseFloor * 0.97 + level * 0.03;
  const threshold = Math.max(0.018, noiseFloor * 3);
  state.level = Math.min(1, level * 12);
  segmentMs += TICK;

  if (level > threshold) {
    speechMs += TICK; silenceMs = 0;
    if (speechMs >= 150 && !state.hearing) {
      state.hearing = true;
      heardInSegment = true;
      userIsSpeaking();
    }
  } else {
    silenceMs += TICK;
    if (state.hearing && silenceMs >= PAUSE_MS) {
      state.hearing = false;
      cutSegment();
    } else if (!state.hearing) {
      speechMs = 0;
      // Uzun süre sessizse kaydı tazele (gereksiz büyümesin)
      if (segmentMs > 20000) cutSegment();
    }
  }
  if (state.hearing && segmentMs > MAX_SEGMENT_MS) { state.hearing = false; cutSegment(); }
  notify();
}

async function openMic() {
  if (!state.conversing) return;
  setPhase("listening");
  if (micOpen) return;
  if (!(await ensureStream())) { endConversation(); return; }
  if (ctx.state === "suspended") await ctx.resume();
  micOpen = true;
  state.hearing = false;
  startRecorder();
  clearInterval(loopTimer);
  loopTimer = setInterval(tick, TICK);
  armIdle();
}

function closeMic() {
  micOpen = false;
  clearInterval(loopTimer);
  state.hearing = false;
  state.level = 0;
  if (recorder) { const r = recorder; recorder = null; r.onstop = null; try { r.stop(); } catch {} }
  notify();
}

async function transcribe(blob) {
  state.transcribing++; notify();
  try {
    const text = (await core.stt(blob)).trim();
    if (text && !/^(\.|altyazı|abone ol)/i.test(text)) handleSegment(text);
  } finally {
    state.transcribing--; notify();
  }
}

// ---------------------------------------------------------------- sohbet akışı

let commitTimer = null, idleTimer = null, closeAfter = false;
let inflight = null; // { controller, text, messageId }

function armIdle() {
  clearTimeout(idleTimer);
  idleTimer = setTimeout(() => {
    if (state.conversing && state.phase === "listening") finish(true);
  }, 120000);
}

function userIsSpeaking() { clearTimeout(commitTimer); commitTimer = null; }

function handleSegment(segment) {
  if (!state.conversing) return;
  armIdle();
  // Söylenen sayılar rakamla yazılsın: "saat dörtte iki domates" → "saat 4'te 2 domates"
  const parsed = cmd.parse(normalizeNumbers(segment));

  // Düşünürken araya girildi → isteği iptal et, söyleneni geri al ve birleştir
  if (inflight && state.phase === "thinking") {
    inflight.controller.abort();
    core.data.messages = core.data.messages.filter((m) => m.id !== inflight.messageId);
    core.changed("messages");
    state.pending.unshift(inflight.text);
    inflight = null;
    setPhase("listening");
  }

  if (parsed.end === "close") { if (parsed.body) state.pending.push(parsed.body); finish(true); return; }
  if (parsed.end === "done") { if (parsed.body) state.pending.push(parsed.body); finish(false); return; }
  if (!parsed.body) return;
  state.pending.push(parsed.body);
  notify();
  scheduleCommit(cmd.isComplete(parsed.body));
}

function scheduleCommit(quick) {
  clearTimeout(commitTimer);
  commitTimer = setTimeout(() => {
    if (!state.conversing || state.hearing || state.transcribing) return scheduleCommit(quick);
    finish(false);
  }, quick ? 700 : 1800);
}

function finish(close) {
  clearTimeout(commitTimer);
  const text = state.pending.join(" ").trim();
  state.pending = [];
  if (!text) {
    if (close) {
      closeMic();
      state.conversing = false;
      setPhase("speaking");
      speak("Kapanıyorum.", () => setPhase("idle"));
    }
    notify();
    return;
  }
  closeAfter = close;
  send(text, true);
}

export function startConversation(greet = true) {
  if (state.conversing) return;
  stopSpeaking();
  state.conversing = true;
  state.pending = [];
  state.error = null;
  closeAfter = false;
  if (greet) {
    setPhase("speaking");
    speak("Efendim?", () => openMic());
  } else openMic();
}

export function endConversation() {
  clearTimeout(idleTimer); clearTimeout(commitTimer);
  closeMic();
  state.conversing = false;
  if (state.phase !== "thinking" && state.phase !== "speaking") setPhase("idle");
  notify();
}

/** Reaktöre / Jarvis düğmesine dokunuş */
export function toggle() {
  if (!state.conversing) return startConversation(true);
  if (state.phase === "speaking") return stopSpeaking();
  if (state.phase === "thinking") return;
  closeMic();
  finish(true);
}

/** Yazı alanına odaklanınca dinlemeyi durdur */
export function pauseForTyping() {
  if (!state.conversing) return;
  if (state.phase === "speaking") stopSpeaking();
  if (state.pending.length) finish(true); else endConversation();
}

export async function send(raw, spoken = false) {
  const text = String(raw || "").trim();
  if (!text) return;
  state.error = null;
  if (inflight) inflight.controller.abort();
  const message = { id: core.uuid(), role: "user", text, date: new Date() };
  core.data.messages.push(message);
  core.changed("messages");
  if (state.conversing) clearTimeout(idleTimer); // mikrofon açık kalır: araya girilebilir

  if (!core.isConfigured()) {
    return reply("Önce Ayarlar'dan sunucu adresini ve uygulama şifresini girmen gerekiyor.", true);
  }
  setPhase("thinking");
  const controller = new AbortController();
  inflight = { controller, text, messageId: message.id };
  try {
    const res = await core.chat(text, controller.signal, spoken);
    if (controller.signal.aborted) return;
    inflight = null;
    const extras = [];
    for (const a of res.actions || []) {
      const note = await core.applyAction(a);
      if (note) extras.push(note);
    }
    reply([res.reply, ...extras].filter(Boolean).join(" "), state.conversing || core.settings.speakReplies);
  } catch (e) {
    if (controller.signal.aborted) return;
    inflight = null;
    state.error = e.message;
    reply("Şu anda sunucuya ulaşamıyorum. İnternet bağlantını ya da Ayarlar'daki sunucu bilgisini kontrol eder misin?", state.conversing || core.settings.speakReplies);
  }
}

function reply(text, spoken) {
  core.data.messages.push({ id: core.uuid(), role: "assistant", text, date: new Date() });
  core.changed("messages");
  if (spoken) {
    if (state.conversing) closeMic(); // Jarvis kendini duymasın
    setPhase("speaking");
    // "Jarvis kapan" denmişse uzun cevap okunmaz, yalnızca "Kapanıyorum" der (cevap ekranda kalır)
    speak(closeAfter ? "Kapanıyorum." : text, afterReply);
  } else afterReply();
}

function afterReply() {
  if (state.conversing && !closeAfter) openMic();
  else {
    if (state.conversing) endConversation();
    closeAfter = false;
    setPhase("idle");
  }
}

// ---------------------------------------------------------------- konuşma (doğal ses, yoksa sistem sesi)

let audio = null, speakDone = null, speakToken = 0;

function chunksOf(text) {
  const sentences = text.match(/[^.!?…]+[.!?…]*\s*/g)?.map((s) => s.trim()).filter(Boolean) || [text];
  const out = [sentences.shift()];
  let cur = "";
  for (const s of sentences) {
    if (cur.length + s.length > 300 && cur) { out.push(cur); cur = ""; }
    cur += (cur ? " " : "") + s;
  }
  if (cur) out.push(cur);
  return out;
}

export function speak(text, done) {
  stopAudio();
  speakDone = done || null;
  const token = ++speakToken;
  const clean = String(text || "").trim();
  if (!clean) return finishSpeaking(token);

  const s = core.settings;
  if (!s.naturalVoice || !core.isConfigured()) return speakSystem(clean, token);

  // İlk cümle hemen, kalanı paralel hazırlanır
  const parts = chunksOf(clean);
  const fetches = parts.map((p) => core.tts(p));
  (async () => {
    for (let i = 0; i < parts.length; i++) {
      const blob = await fetches[i];
      if (token !== speakToken) return;
      if (!blob) return speakSystem(parts.slice(i).join(" "), token);
      await new Promise((resolve) => {
        audio = new Audio(URL.createObjectURL(blob));
        audio.onended = resolve;
        audio.onerror = resolve;
        audio.play().catch(resolve);
      });
      if (token !== speakToken) return;
    }
    finishSpeaking(token);
  })();
}

function speakSystem(text, token) {
  const u = new SpeechSynthesisUtterance(text);
  u.lang = "tr-TR";
  const tr = speechSynthesis.getVoices().find((v) => v.lang?.toLowerCase().startsWith("tr"));
  if (tr) u.voice = tr;
  u.rate = Math.min(1.5, Math.max(0.7, core.settings.voiceSpeed));
  u.pitch = 0.8 + core.settings.voiceTone * 0.4;
  u.onend = () => finishSpeaking(token);
  u.onerror = () => finishSpeaking(token);
  speechSynthesis.speak(u);
}

function finishSpeaking(token) {
  if (token !== speakToken) return;
  audio = null;
  const cb = speakDone;
  speakDone = null;
  cb?.();
}

function stopAudio() {
  speakToken++;
  if (audio) { audio.pause(); audio = null; }
  speechSynthesis.cancel();
}

/** Konuşmayı keser; bekleyen akış (yeniden dinleme) devam eder */
export function stopSpeaking() {
  const cb = speakDone;
  speakDone = null;
  stopAudio();
  cb?.();
}
