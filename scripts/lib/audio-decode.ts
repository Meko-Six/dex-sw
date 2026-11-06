import { execFile } from 'node:child_process'

/**
 * Decode any audio file ffmpeg understands to de-interleaved stereo float
 * samples at `sampleRate`.
 *
 * There is deliberately no pure-JS fallback: the analysers run at 22.05 kHz, so
 * a fast, well-tested resampler matters more than avoiding a process spawn, and
 * ffmpeg is already the app's last-resort decoder. Shared by the crate importer
 * and the accuracy bench so both feed the pipeline identical audio.
 */
export function decodeStereo(path: string, sampleRate: number): Promise<Float32Array[]> {
  return new Promise((resolvePromise, reject) => {
    execFile(
      'ffmpeg',
      [
        '-v',
        'error',
        '-nostdin',
        '-i',
        path,
        '-map',
        'a:0',
        '-f',
        'f32le',
        '-acodec',
        'pcm_f32le',
        '-ac',
        '2',
        '-ar',
        String(sampleRate),
        '-'
      ],
      { maxBuffer: 512 * 1024 * 1024, encoding: 'buffer' },
      (error, stdout) => {
        if (error) {
          reject(new Error(`ffmpeg failed for ${path}: ${error.message}`))
          return
        }
        const buffer = Buffer.from(stdout)
        const frames = Math.floor(buffer.length / 8)
        const left = new Float32Array(frames)
        const right = new Float32Array(frames)
        for (let i = 0; i < frames; i++) {
          left[i] = buffer.readFloatLE(i * 8)
          right[i] = buffer.readFloatLE(i * 8 + 4)
        }
        resolvePromise([left, right])
      }
    )
  })
}
