import { contextBridge, ipcRenderer, webUtils } from 'electron'
import type { DexBridge } from '../shared/types'

let flushLibrary: (() => Promise<void>) | undefined
// Available even if the UI has not mounted yet or failed to initialize.
ipcRenderer.on('app:beforeClose', () => {
  void Promise.resolve().then(() => flushLibrary?.()).then(
    () => ipcRenderer.invoke('app:closeReady', true),
    () => ipcRenderer.invoke('app:closeReady', false)
  ).catch(() => undefined)
})

const api: DexBridge = {
  pickFiles: () => ipcRenderer.invoke('dialog:pickFiles'),
  pickFolder: () => ipcRenderer.invoke('dialog:pickFolder'),
  readFile: (filePath) => ipcRenderer.invoke('fs:readFile', filePath),
  getPathForFile: async (file) => {
    try {
      const path = webUtils.getPathForFile(file as Parameters<typeof webUtils.getPathForFile>[0])
      return path ? await ipcRenderer.invoke('fs:grantDroppedFile', path) : ''
    } catch {
      return ''
    }
  },
  transcodeToWav: (bytes, name) => ipcRenderer.invoke('audio:transcode', bytes, name),
  loadLibrary: () => ipcRenderer.invoke('library:load'),
  saveLibrary: (json) => ipcRenderer.invoke('library:save', json),
  onBeforeClose: (flush) => {
    flushLibrary = flush
    return () => { if (flushLibrary === flush) flushLibrary = undefined }
  },
  platform: process.platform,
  version: process.env.npm_package_version ?? '0.1.0'
}

contextBridge.exposeInMainWorld('dex', api)
