import { isAudioFile, type FileRef, type DexBridge } from '../../shared/types'

export interface RendererBridge extends DexBridge {
  kind: 'electron' | 'browser'
}

declare global {
  interface Window {
    dex?: DexBridge
  }
}

const browserFiles = new Map<string, ArrayBuffer | File>()

function pickWithInput(directory: boolean): Promise<{ files: File[]; root: string }> {
  return new Promise((resolve) => {
    const input = document.createElement('input')
    input.type = 'file'
    input.accept = 'audio/*,.mp3,.flac,.wav,.aiff,.aif,.m4a,.aac,.ogg,.opus'
    if (directory) {
      Object.assign(input, { webkitdirectory: true, directory: true })
    } else {
      input.multiple = true
    }
    input.style.display = 'none'
    document.body.appendChild(input)
    const finish = (files: File[]): void => {
      input.remove()
      resolve({ files, root: directory ? 'folder' : '' })
    }
    input.addEventListener('change', () => finish(Array.from(input.files ?? [])))
    input.addEventListener('cancel', () => finish([]))
    input.click()
  })
}

const browserBridge: RendererBridge = {
  kind: 'browser',
  platform: 'browser',
  version: '0.1.0',

  async pickFiles(): Promise<FileRef[]> {
    const { files } = await pickWithInput(false)
    const payloads: FileRef[] = []
    for (const file of files) {
      if (!isAudioFile(file.name)) continue
      const path = `browser:${crypto.randomUUID()}/${file.name}`
      browserFiles.set(path, file)
      payloads.push({ name: file.name, path })
    }
    return payloads
  },

  async pickFolder(): Promise<FileRef[]> {
    const { files } = await pickWithInput(true)
    const refs: FileRef[] = []
    for (const file of files) {
      if (!isAudioFile(file.name)) continue
      const relative = `browser:${crypto.randomUUID()}/${file.name}`
      browserFiles.set(relative, file)
      refs.push({ name: file.name, path: relative })
    }
    return refs
  },

  async readFile(path: string): Promise<ArrayBuffer | null> {
    const file = browserFiles.get(path)
    return file instanceof ArrayBuffer ? file : file ? file.arrayBuffer() : null
  },

  async getPathForFile(): Promise<string> {
    return ''
  },

  async transcodeToWav(): Promise<ArrayBuffer | null> {
    return null
  },

  async loadLibrary(): Promise<string | null> {
    return window.localStorage.getItem('dex.library')
  },

  async saveLibrary(json: string): Promise<void> {
    window.localStorage.setItem('dex.library', json)
  }
}

export const bridge: RendererBridge =
  typeof window !== 'undefined' && window.dex ? { ...window.dex, kind: 'electron' } : browserBridge

/** Register bytes for a dropped/loaded file so the browser fallback can reload it. */
export function rememberBrowserFile(path: string, bytes: ArrayBuffer): void {
  browserFiles.set(path, bytes)
}

export function forgetBrowserFile(path: string): void { browserFiles.delete(path) }

/** Keep a browser File handle, reading its bytes only when needed. */
export function rememberBrowserSource(file: File): string {
  const path = `browser:${crypto.randomUUID()}/${file.name}`
  browserFiles.set(path, file)
  return path
}
