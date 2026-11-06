import { describe, expect, it } from 'vitest'
import { bridge, forgetBrowserFile, rememberBrowserFile, rememberBrowserSource } from '../src/renderer/lib/bridge'
describe('browser source ownership', () => {
  it('releases forgotten buffers from the reload registry', async () => {
    rememberBrowserFile('temporary.wav', new ArrayBuffer(32))
    expect((await bridge.readFile('temporary.wav'))?.byteLength).toBe(32)
    forgetBrowserFile('temporary.wav')
    expect(await bridge.readFile('temporary.wav')).toBeNull()
  })
  it('keeps same-name files distinct and reads lazy File handles', async () => {
    const a = rememberBrowserSource(new File(['one'], 'same.wav'))
    const b = rememberBrowserSource(new File(['two'], 'same.wav'))
    expect(a).not.toBe(b)
    expect(new TextDecoder().decode((await bridge.readFile(a))!)).toBe('one')
    expect(new TextDecoder().decode((await bridge.readFile(b))!)).toBe('two')
    forgetBrowserFile(a); forgetBrowserFile(b)
  })
})
