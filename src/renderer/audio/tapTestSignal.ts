import { renderPattern } from '../../shared/synth'

/**
 * Dev-only: a synthetic 128 BPM house loop exposed as a MediaStream, so the tap
 * can be exercised end-to-end on machines with no microphone and no loopback
 * device. Routes through the same MediaStreamSource path as real hardware.
 */
export async function createTestSignal(): Promise<{ stream: MediaStream; stop: () => void }> {
  const context = new AudioContext()
  await context.resume()
  const sampleRate = context.sampleRate
  const mono = renderPattern({ bpm: 128, seconds: 20, sampleRate, style: 'house', gain: 0.9 })

  const buffer = context.createBuffer(2, mono.length + sampleRate, sampleRate)
  for (let channel = 0; channel < 2; channel++) {
    const data = buffer.getChannelData(channel)
    data.set(mono, 0)
  }
  const source = context.createBufferSource()
  source.buffer = buffer
  source.loop = true
  const destination = context.createMediaStreamDestination()
  const gain = context.createGain()
  gain.gain.value = 0.8
  source.connect(gain)
  gain.connect(destination)
  source.start()

  return {
    stream: destination.stream,
    stop: () => {
      try {
        source.stop()
      } catch {
        /* already stopped */
      }
      source.disconnect()
      gain.disconnect()
      void context.close()
    }
  }
}
