const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('pc2mp', {
  connect: () => ipcRenderer.invoke('connect'),
  gameStatus: () => ipcRenderer.invoke('game-status'),
  worlds: () => ipcRenderer.invoke('worlds'),
  loadWorld: name => ipcRenderer.invoke('load-world', name),
  createServer: (room, file) => ipcRenderer.invoke('create-server', room, file),
  join: room => ipcRenderer.invoke('join', room),
  refreshRooms: () => ipcRenderer.invoke('refresh-rooms'),
  on: (channel, fn) => ipcRenderer.on(channel, (_e, v) => fn(v)),
});
