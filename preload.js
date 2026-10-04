// Arayüze güvenli köprü: yalnızca gereken işlevler açılır
const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("jarvis", {
  loadData: () => ipcRenderer.invoke("data:load"),
  saveData: (text) => ipcRenderer.invoke("data:save", text),
  getSecret: (key) => ipcRenderer.invoke("secret:get", key),
  setSecret: (key, value) => ipcRenderer.invoke("secret:set", key, value),
  request: (opts) => ipcRenderer.invoke("net:request", opts),
  notify: (opts) => ipcRenderer.invoke("notify", opts),
  showAlarm: (opts) => ipcRenderer.invoke("alarm:show", opts),
  alarmAction: (id, action) => ipcRenderer.send("alarm:action", { id, action }),
  openExternal: (url) => ipcRenderer.invoke("shell:open", url),
  getAutoLaunch: () => ipcRenderer.invoke("autolaunch:get"),
  setAutoLaunch: (on) => ipcRenderer.invoke("autolaunch:set", on),
  info: () => ipcRenderer.invoke("app:info"),
  askMic: () => ipcRenderer.invoke("mic:ask"),
  on: (channel, fn) => {
    const allowed = ["hotkey", "alarm-action", "app:focus"];
    if (!allowed.includes(channel)) return;
    ipcRenderer.on(channel, (_e, payload) => fn(payload));
  }
});
