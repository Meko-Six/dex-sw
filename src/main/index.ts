import { promises as fs } from 'node:fs'
import path from 'node:path'
import { app, BrowserWindow, dialog, ipcMain, shell, type IpcMainInvokeEvent } from 'electron'
import { AUDIO_EXTENSIONS, isAudioFile, type FileRef } from '../shared/types'
import { MAX_LIBRARY_BYTES, parseLibrary } from '../shared/library-schema'
import { LibraryRepository } from './services/library-repository'
import { AudioFiles } from './services/audio-files'
import { externalUrl, trustedDocument } from './services/security'
import { stopTranscodes, transcodeToWav } from './services/transcode'

app.setName('Dex')
const devServerUrl = !app.isPackaged ? process.env.ELECTRON_RENDERER_URL : undefined
const entry = path.join(__dirname, '../renderer/index.html')
let mainWindow: BrowserWindow | null = null
let repository: LibraryRepository
const files = new AudioFiles()
let initialLibraryLoaded = false
let quitting = false
let closing = false

function assertSender(event: IpcMainInvokeEvent): void {
  const frame = event.senderFrame
  if (!mainWindow || event.sender !== mainWindow.webContents || !frame || frame !== event.sender.mainFrame || !trustedDocument(frame.url, entry, devServerUrl)) throw new Error('Untrusted application request.')
}

async function collectAudioFiles(directory: string, limit = 3000): Promise<FileRef[]> {
  const found: FileRef[] = []
  const walk = async (dir: string, depth = 0): Promise<void> => {
    if (found.length >= limit || depth > 32) return
    let entries
    try { entries = await fs.readdir(dir, { withFileTypes: true }) } catch { return }
    for (const entry of entries) {
      if (found.length >= limit) return
      if (entry.name.startsWith('.')) continue
      const full = path.join(dir, entry.name)
      if (entry.isDirectory()) await walk(full, depth + 1)
      else if (entry.isFile() && isAudioFile(entry.name)) {
        try { await files.grant(full); found.push({ name: entry.name, path: full }) } catch { /* skip unsupported file */ }
      }
    }
  }
  await walk(directory)
  return found.sort((a, b) => a.path.localeCompare(b.path))
}

function registerIpc(): void {
  const handle = <Args extends unknown[]>(channel: string, action: (...args: Args) => unknown): void => {
    ipcMain.handle(channel, (event, ...args) => { assertSender(event); return action(...args as Args) })
  }
  handle('dialog:pickFiles', async (): Promise<FileRef[]> => {
    const result = await dialog.showOpenDialog(mainWindow ?? undefined!, {
      title: 'Add tracks', properties: ['openFile', 'multiSelections'],
      filters: [{ name: 'Audio', extensions: [...AUDIO_EXTENSIONS] }]
    })
    if (result.canceled) return []
    const refs: FileRef[] = []
    for (const file of result.filePaths.slice(0, 3000)) {
      try { await files.grant(file); refs.push({ name: path.basename(file), path: file }) } catch { /* skip unreadable file */ }
    }
    return refs
  })
  handle('dialog:pickFolder', async (): Promise<FileRef[]> => {
    const result = await dialog.showOpenDialog(mainWindow ?? undefined!, { title: 'Add a folder of tracks', properties: ['openDirectory'] })
    return result.canceled || !result.filePaths.length ? [] : collectAudioFiles(result.filePaths[0])
  })
  // Only preload can obtain a path from a real DOM File via webUtils.
  handle('fs:grantDroppedFile', (file: unknown) => files.grant(file))
  handle('fs:readFile', (file: unknown) => files.read(file))
  handle('audio:transcode', transcodeToWav)
  handle('library:load', async () => {
    const json = await repository.load()
    if (!initialLibraryLoaded) {
      for (const track of json ? parseLibrary(json).tracks : []) {
        if (track.path) await files.restore(track.path)
      }
      initialLibraryLoaded = true
    }
    return json
  })
  handle('library:save', (json: unknown) => {
    if (typeof json !== 'string' || Buffer.byteLength(json, 'utf8') > MAX_LIBRARY_BYTES) throw new Error('Invalid library payload.')
    const doc = parseLibrary(json)
    if (doc.tracks.some((track) => track.path && !files.has(track.path))) throw new Error('The library contains an unapproved file path.')
    return repository.save(json)
  })
  handle('app:closeReady', async (ok: unknown) => {
    if (!closing) return
    closing = false
    if (ok !== true) { quitting = false; return }
    try { await repository.flush() } catch { quitting = false; return }
    stopTranscodes()
    mainWindow?.destroy()
    if (quitting || process.platform !== 'darwin') app.quit()
  })
}

function createWindow(): void {
  mainWindow = new BrowserWindow({
    width: 1174, height: 814, useContentSize: true, minWidth: 587, minHeight: 407,
    show: false, backgroundColor: '#000000',
    webPreferences: {
      preload: path.join(__dirname, '../preload/index.js'), contextIsolation: true,
      nodeIntegration: false, sandbox: true,
      // Audio/sync keep running in the background; visual clocks pause separately.
      backgroundThrottling: false, autoplayPolicy: 'no-user-gesture-required'
    }
  })
  const window = mainWindow
  const session = window.webContents.session
  const trusted = (url: string): boolean => trustedDocument(url, entry, devServerUrl)
  session.setPermissionRequestHandler((contents, permission, callback, details) => {
    callback(contents === window.webContents && trusted(contents.getURL()) && details.isMainFrame && permission === 'media' && 'mediaTypes' in details && details.mediaTypes?.every((type) => type === 'audio') === true)
  })
  session.setPermissionCheckHandler((contents, permission, _origin, details) => contents === window.webContents && details.isMainFrame && permission === 'media' && details.mediaType === 'audio' && trusted(details.requestingUrl || ''))
  // Inline CSS is used for scaled controls; scripts are bundled, and only WASM compilation needs eval permission.
  const devOrigin = devServerUrl ? new URL(devServerUrl).origin : ''
  const csp = `default-src 'self'; script-src 'self' blob: 'wasm-unsafe-eval'${devServerUrl ? " 'unsafe-inline'" : ''}; worker-src 'self' blob:; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self'${devOrigin ? ` ${devOrigin} ${devOrigin.replace(/^http/, 'ws')}` : ''}; media-src 'self' blob:; object-src 'none'; base-uri 'none'; frame-src 'none'`
  session.webRequest.onHeadersReceived((details, callback) => callback({ responseHeaders: { ...details.responseHeaders, 'Content-Security-Policy': [csp] } }))
  window.on('ready-to-show', () => window.show())
  window.on('closed', () => { if (mainWindow === window) mainWindow = null })
  window.on('close', (event) => {
    if (!window.webContents.getURL()) return
    event.preventDefault()
    if (closing) return
    closing = true
    window.webContents.send('app:beforeClose')
  })
  window.webContents.setWindowOpenHandler(({ url }) => {
    if (externalUrl(url)) void shell.openExternal(url).catch(() => undefined)
    return { action: 'deny' }
  })
  window.webContents.on('will-navigate', (event, url) => { if (!trusted(url)) event.preventDefault() })
  window.webContents.on('will-redirect', (event, url) => { if (!trusted(url)) event.preventDefault() })
  window.webContents.on('will-attach-webview', (event) => event.preventDefault())
  if (devServerUrl) void window.loadURL(devServerUrl)
  else void window.loadFile(entry)
}

app.whenReady().then(() => {
  repository = new LibraryRepository(path.join(app.getPath('userData'), 'library.json'))
  registerIpc()
  createWindow()
  app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow() })
})
app.on('before-quit', (event) => {
  if (!mainWindow) { stopTranscodes(); return }
  event.preventDefault()
  quitting = true
  mainWindow.close()
})
app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit() })
