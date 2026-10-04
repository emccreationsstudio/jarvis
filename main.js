// Jarvis masaüstü — ana süreç (pencere, tepsi simgesi, kısayol, bildirim, alarm penceresi, ağ)
const {
  app, BrowserWindow, Tray, Menu, globalShortcut, ipcMain, Notification,
  shell, nativeImage, safeStorage, session, systemPreferences, screen
} = require("electron");
const path = require("path");
const fs = require("fs");

const HOTKEY = "CommandOrControl+Shift+J";
let win = null;
let tray = null;
let quitting = false;
const alarms = new Map(); // id → BrowserWindow

const dataFile = () => path.join(app.getPath("userData"), "jarvis-data.json");
const secretFile = () => path.join(app.getPath("userData"), "secrets.json");
const asset = (name) => path.join(__dirname, "assets", name);

// Tek kopya: ikinci kez açılırsa mevcut pencereyi öne getir
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on("second-instance", () => showWindow());
}

function createWindow() {
  win = new BrowserWindow({
    width: 1180,
    height: 780,
    minWidth: 860,
    minHeight: 600,
    title: "Jarvis",
    backgroundColor: "#02060c",
    icon: asset("icon.png"),
    titleBarStyle: process.platform === "darwin" ? "hiddenInset" : "default",
    autoHideMenuBar: true,
    show: false,
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      backgroundThrottling: false, // gizliyken de hatırlatmalar zamanında çalışsın
      autoplayPolicy: "no-user-gesture-required"
    }
  });
  win.loadFile(path.join(__dirname, "renderer", "index.html"));
  win.once("ready-to-show", () => {
    if (!process.argv.includes("--hidden")) win.show();
  });
  // Kapatınca gizlen: Jarvis tepside çalışmaya ve hatırlatmaya devam eder
  win.on("close", (e) => {
    if (!quitting) {
      e.preventDefault();
      win.hide();
    }
  });
  win.on("focus", () => win.webContents.send("app:focus"));
}

function showWindow(listen = false) {
  if (!win) return;
  if (win.isMinimized()) win.restore();
  win.show();
  win.focus();
  if (listen) win.webContents.send("hotkey");
}

function createTray() {
  const img = nativeImage.createFromPath(asset(process.platform === "darwin" ? "tray16.png" : "tray.png"));
  tray = new Tray(img);
  tray.setToolTip("Jarvis");
  const menu = () => Menu.buildFromTemplate([
    { label: "Jarvis'i aç", click: () => showWindow() },
    { label: `Dinle  (${process.platform === "darwin" ? "⌘⇧J" : "Ctrl+Shift+J"})`, click: () => showWindow(true) },
    { type: "separator" },
    {
      label: "Bilgisayar açılınca başlat",
      type: "checkbox",
      checked: app.getLoginItemSettings().openAtLogin,
      click: (item) => app.setLoginItemSettings({ openAtLogin: item.checked, args: ["--hidden"] })
    },
    { type: "separator" },
    { label: "Çık", click: () => { quitting = true; app.quit(); } }
  ]);
  tray.setContextMenu(menu());
  tray.on("click", () => (win.isVisible() && win.isFocused() ? win.hide() : showWindow()));
  tray.on("right-click", () => tray.setContextMenu(menu()));
}

// --- Alarm penceresi (her zaman üstte, sesli) ---
function showAlarm({ id, title, body }) {
  if (alarms.has(id)) {
    alarms.get(id).focus();
    return;
  }
  const display = screen.getPrimaryDisplay().workArea;
  const w = 460, h = 300;
  const alarm = new BrowserWindow({
    width: w,
    height: h,
    x: Math.round(display.x + (display.width - w) / 2),
    y: Math.round(display.y + display.height * 0.18),
    frame: false,
    resizable: false,
    alwaysOnTop: true,
    skipTaskbar: false,
    backgroundColor: "#02060c",
    show: false,
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      autoplayPolicy: "no-user-gesture-required"
    }
  });
  alarm.setAlwaysOnTop(true, "screen-saver");
  alarm.setVisibleOnAllWorkspaces(true);
  alarm.loadFile(path.join(__dirname, "renderer", "alarm.html"), { query: { id, title, body: body || "" } });
  alarm.once("ready-to-show", () => {
    alarm.show();
    alarm.focus();
    alarm.flashFrame(true);
    if (process.platform === "darwin" && app.dock) app.dock.bounce("critical");
  });
  alarm.on("closed", () => alarms.delete(id));
  alarms.set(id, alarm);
}

// --- IPC ---
function registerIpc() {
  ipcMain.handle("data:load", async () => {
    try { return fs.readFileSync(dataFile(), "utf8"); } catch { return null; }
  });
  ipcMain.handle("data:save", async (_e, text) => {
    const tmp = dataFile() + ".tmp";
    fs.writeFileSync(tmp, text, "utf8");
    fs.renameSync(tmp, dataFile());
    return true;
  });

  // Şifre (APP_TOKEN) işletim sisteminin anahtar zinciriyle şifrelenir
  ipcMain.handle("secret:get", async (_e, key) => {
    try {
      const all = JSON.parse(fs.readFileSync(secretFile(), "utf8"));
      const v = all[key];
      if (!v) return "";
      if (v.enc && safeStorage.isEncryptionAvailable()) return safeStorage.decryptString(Buffer.from(v.value, "base64"));
      return v.value || "";
    } catch { return ""; }
  });
  ipcMain.handle("secret:set", async (_e, key, value) => {
    let all = {};
    try { all = JSON.parse(fs.readFileSync(secretFile(), "utf8")); } catch {}
    if (safeStorage.isEncryptionAvailable()) {
      all[key] = { enc: true, value: safeStorage.encryptString(value || "").toString("base64") };
    } else {
      all[key] = { enc: false, value };
    }
    fs.writeFileSync(secretFile(), JSON.stringify(all), "utf8");
    return true;
  });

  // Sunucu istekleri ana süreçten yapılır (tarayıcı CORS kısıtı olmasın)
  ipcMain.handle("net:request", async (_e, { url, method = "GET", headers = {}, body = null, binary = false }) => {
    try {
      const res = await fetch(url, {
        method,
        headers,
        body: body == null ? undefined : (typeof body === "string" ? body : Buffer.from(body)),
        signal: AbortSignal.timeout(60000)
      });
      const contentType = res.headers.get("content-type") || "";
      if (binary && res.ok) {
        const buf = new Uint8Array(await res.arrayBuffer());
        return { status: res.status, contentType, bytes: buf };
      }
      return { status: res.status, contentType, text: await res.text() };
    } catch (err) {
      return { status: 0, error: String(err && err.message || err) };
    }
  });

  ipcMain.handle("notify", async (_e, { title, body, silent }) => {
    if (!Notification.isSupported()) return false;
    const n = new Notification({ title, body, silent: !!silent, icon: asset("icon.png") });
    n.on("click", () => showWindow());
    n.show();
    return true;
  });

  ipcMain.handle("alarm:show", async (_e, payload) => { showAlarm(payload); return true; });
  ipcMain.on("alarm:action", (_e, { id, action }) => {
    const w = alarms.get(id);
    if (w) w.close();
    if (win) win.webContents.send("alarm-action", { id, action });
  });

  ipcMain.handle("shell:open", async (_e, url) => {
    if (/^(https?:|tel:|mailto:)/.test(url)) await shell.openExternal(url);
    return true;
  });
  ipcMain.handle("autolaunch:get", async () => app.getLoginItemSettings().openAtLogin);
  ipcMain.handle("autolaunch:set", async (_e, on) => {
    app.setLoginItemSettings({ openAtLogin: !!on, args: ["--hidden"] });
    return app.getLoginItemSettings().openAtLogin;
  });
  ipcMain.handle("app:info", async () => ({ platform: process.platform, version: app.getVersion(), hotkey: HOTKEY }));
  ipcMain.handle("mic:ask", async () => {
    if (process.platform === "darwin") {
      try { return await systemPreferences.askForMediaAccess("microphone"); } catch { return false; }
    }
    return true;
  });
}

app.whenReady().then(() => {
  if (process.platform === "win32") app.setAppUserModelId("com.emccreationsstudio.jarvis.desktop");
  // Mikrofon izni (yalnızca kendi sayfalarımız için)
  session.defaultSession.setPermissionRequestHandler((_wc, permission, cb) => {
    cb(["media", "notifications", "clipboard-sanitized-write"].includes(permission));
  });
  registerIpc();
  createWindow();
  createTray();
  if (!globalShortcut.register(HOTKEY, () => showWindow(true))) {
    console.warn("Kısayol kaydedilemedi:", HOTKEY);
  }
  app.on("activate", () => showWindow());
});

app.on("before-quit", () => { quitting = true; });
app.on("will-quit", () => globalShortcut.unregisterAll());
// Pencere kapansa da tepside çalışmaya devam et (bu dinleyici varsayılan "kapat ve çık" davranışını engeller)
app.on("window-all-closed", () => {});
