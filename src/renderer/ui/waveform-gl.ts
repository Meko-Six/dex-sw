import { BAND_COLOURS, BAND_GAINS, BAND_GAMMA, bandHeight } from '../../shared/waveform-bands'
import { ENERGY_COLOURS, energyColour, powerAt, type PowerAnalysis } from '../../shared/power'
import { useCallback, useEffect, useRef, useState } from 'react'
import { decodePeak, pickLevel, type WaveformLevel, type WaveformLevels } from '../../shared/waveform-levels'

/**
 * Draws a waveform one device pixel column at a time from the level pyramid
 * (shared/waveform-levels.ts): overlapping LOW/MID/HIGH envelopes, or the
 * musical-intensity palette. Brightness is identical across the playhead.
 *
 * WebGL2 does it in a fragment shader, so a lane redraws every frame for the
 * cost of one quad; the 2D fallback runs the same sums on the CPU.
 */

export type RGBA = [number, number, number, number]

export interface WaveformPaint {
  peak: RGBA
  rms: RGBA
  peakPlayed: RGBA
  rmsPlayed: RGBA
  /** The zero line behind the waveform; alpha 0 for none. */
  line: RGBA
}

export interface WaveformFrame {
  /** Absolute pixel column (in track time) at the left edge. */
  startCol: number
  samplesPerPixel: number
  /** Playhead sample, retained for callers; it does not affect brightness. */
  playSample: number
  /** Peak height as a fraction of half the canvas height (of the whole height when one-sided). */
  amp: number
  /** Bars rise from the bottom edge, as on a CDJ overview, instead of mirroring round the middle. */
  oneSided?: boolean
  paint: WaveformPaint
  power?: PowerAnalysis | null
  threeBand?: boolean
}

/** '#rrggbb' plus alpha, 0 … 1 channels. */
export function rgba(hex: string, alpha = 1): RGBA {
  const clean = hex.replace('#', '')
  return [parseInt(clean.slice(0, 2), 16) / 255, parseInt(clean.slice(2, 4), 16) / 255, parseInt(clean.slice(4, 6), 16) / 255, alpha]
}

const MAX_BINS_PER_PIXEL = 8
const TEXTURE_WIDTH = 4096

const VERTEX = `#version 300 es
in vec2 aPos;
void main() { gl_Position = vec4(aPos, 0.0, 1.0); }`

const FRAGMENT = `#version 300 es
precision highp float;
precision highp int;
uniform highp sampler2D uData;
uniform int uTexW;
uniform int uCount;
uniform float uBinSize;
uniform float uStartCol;
uniform float uSpp;
uniform float uTotal;
uniform float uHeight;
uniform float uAmp;
uniform int uOneSided;
uniform vec4 uPeak;
uniform vec4 uRms;
uniform vec4 uPeakPlayed;
uniform vec4 uRmsPlayed;
uniform vec4 uLine;
uniform highp sampler2D uBands;
uniform int uThreeBand;
uniform highp sampler2D uEnergy;
uniform int uEnergyCount;
uniform float uEnergyStart;
uniform float uEnergyBar;
uniform float uSampleRate;
out vec4 outColor;

vec4 bin(int i) { return texelFetch(uData, ivec2(i % uTexW, i / uTexW), 0); }
vec3 bands(int i) { return texelFetch(uBands, ivec2(i % uTexW, i / uTexW), 0).rgb; }
float peak(float byte) { return (byte * 255.0 - 128.0) / 127.0; }
vec4 over(vec4 dst, vec4 src, float coverage) {
  float a = src.a * coverage;
  return vec4(src.rgb * a + dst.rgb * (1.0 - a), a + dst.a * (1.0 - a));
}

float energyBin(int i) { return texelFetch(uEnergy, ivec2(i % ${TEXTURE_WIDTH}, i / ${TEXTURE_WIDTH}), 0).r; }
vec3 energyColor(float samplePos) {
  float i = clamp((samplePos / uSampleRate - uEnergyStart) / uEnergyBar - 0.5, 0.0, float(uEnergyCount - 1));
  int lo = int(floor(i));
  float v = mix(energyBin(lo), energyBin(min(lo + 1, uEnergyCount - 1)), fract(i)) * 3.0;
  vec3 blue = vec3(${ENERGY_COLOURS[0].map((v) => `${v}.0`).join(',')}) / 255.;
  vec3 cyan = vec3(${ENERGY_COLOURS[1].map((v) => `${v}.0`).join(',')}) / 255.;
  vec3 amber = vec3(${ENERGY_COLOURS[2].map((v) => `${v}.0`).join(',')}) / 255.;
  vec3 red = vec3(${ENERGY_COLOURS[3].map((v) => `${v}.0`).join(',')}) / 255.;
  return v < 1.0 ? mix(blue, cyan, v) : v < 2.0 ? mix(cyan, amber, v - 1.0) : mix(amber, red, v - 2.0);
}
void main() {
  float y = gl_FragCoord.y;
  bool oneSided = uOneSided == 1;
  float mid = oneSided ? 0.0 : floor(uHeight * 0.5) + 0.5;
  vec4 color = vec4(0.0);
  if (!oneSided && abs(y - mid) < 0.5) color = over(color, uLine, 1.0);

  float col = uStartCol + floor(gl_FragCoord.x);
  float s0 = col * uSpp;
  float s1 = s0 + uSpp;
  if (s1 > 0.0 && s0 < uTotal) {
    if (uThreeBand == 1) {
      vec3 envelope = vec3(0.0);
      if (uSpp < uBinSize) {
        float t = clamp((s0 + s1) * 0.5 / uBinSize - 0.5, 0.0, float(uCount - 1));
        int i = int(floor(t));
        envelope = mix(bands(i), bands(min(i + 1, uCount - 1)), fract(t));
      } else {
        int first = min(uCount - 1, int(floor(max(s0, 0.0) / uBinSize)));
        int end = clamp(int(ceil(min(s1, uTotal) / uBinSize)), first + 1, uCount);
        int stride = max(1, (end - first + ${MAX_BINS_PER_PIXEL - 1}) / ${MAX_BINS_PER_PIXEL});
        for (int j = 0; j < ${MAX_BINS_PER_PIXEL}; j++) {
          int i = first + j * stride;
          if (i >= end) break;
          envelope = max(envelope, bands(i));
        }
      }
      vec3 gains = vec3(${BAND_GAINS.join(',')});
      for (int band = 0; band < 3; band++) {
        float size = pow(min(1.0, envelope[band] * gains[band]), ${BAND_GAMMA}) * uHeight * (oneSided ? 1.0 : 0.5) * uAmp;
        if (size <= 0.01) continue;
        float top = mid + size;
        float bottom = oneSided ? 0.0 : mid - size;
        float cover = clamp(top - y + 0.5, 0.0, 1.0) * clamp(y - bottom + 0.5, 0.0, 1.0);
        vec3 rgb = band == 0 ? vec3(${BAND_COLOURS[0].map(v => `${v}.0`).join(',')}) : band == 1 ? vec3(${BAND_COLOURS[1].map(v => `${v}.0`).join(',')}) : vec3(${BAND_COLOURS[2].map(v => `${v}.0`).join(',')});
        color = over(color, vec4(rgb / 255.0, 1.0), cover);
      }
      outColor = color;
      return;
    }
    float lo;
    float hi;
    float level;
    if (uSpp < uBinSize) {
      // Zoomed past the finest level: blend the two nearest bins.
      float t = clamp((s0 + s1) * 0.5 / uBinSize - 0.5, 0.0, float(uCount - 1));
      int i0 = int(floor(t));
      vec4 v = mix(bin(i0), bin(min(i0 + 1, uCount - 1)), fract(t));
      lo = peak(v.r);
      hi = peak(v.g);
      level = v.b;
    } else {
      int b0 = min(uCount - 1, int(floor(max(s0, 0.0) / uBinSize)));
      int b1 = clamp(int(ceil(min(s1, uTotal) / uBinSize)), b0 + 1, uCount);
      int stride = max(1, (b1 - b0 + ${MAX_BINS_PER_PIXEL - 1}) / ${MAX_BINS_PER_PIXEL});
      lo = 1.0;
      hi = -1.0;
      float squares = 0.0;
      float n = 0.0;
      for (int j = 0; j < ${MAX_BINS_PER_PIXEL}; j++) {
        int i = b0 + j * stride;
        if (i >= b1) break;
        vec4 v = bin(i);
        lo = min(lo, peak(v.r));
        hi = max(hi, peak(v.g));
        squares += v.b * v.b;
        n += 1.0;
      }
      level = sqrt(squares / n);
    }
    float amp = uHeight * (oneSided ? 1.0 : 0.5) * uAmp;
    // One-sided, the bar is the louder of the two peaks, standing on the bottom edge.
    if (oneSided) hi = max(hi, -lo);
    float top = max(mid + 0.5, mid + max(hi, 0.0) * amp);
    float bottom = oneSided ? 0.0 : min(mid - 0.5, mid + min(lo, 0.0) * amp);
    float edge = clamp(top - y + 0.5, 0.0, 1.0) * clamp(y - bottom + 0.5, 0.0, 1.0);
    float body = level * amp;
    float bodyCover = clamp(min(mid + body, top) - y + 0.5, 0.0, 1.0) * clamp(y - max(oneSided ? 0.0 : mid - body, bottom) + 0.5, 0.0, 1.0);
    vec4 peakColor = uPeak;
    vec4 rmsColor = uRms;
    if (uEnergyCount > 0) {
      vec3 rgb = energyColor((s0 + s1) * 0.5);
      peakColor = vec4(rgb, 1.0);
      rmsColor = peakColor;
    }
    color = over(color, peakColor, edge);
    if (body > 0.25) color = over(color, rmsColor, bodyCover);
  }
  outColor = color;
}`

interface Uniforms {
  [name: string]: WebGLUniformLocation | null
}

export class WaveformRenderer {
  private readonly gl: WebGL2RenderingContext
  private program: WebGLProgram | null = null
  private quad: WebGLBuffer | null = null
  private canvas: HTMLCanvasElement
  private uniforms: Uniforms = {}
  private textures = new Map<WaveformLevel, WebGLTexture>()
  private bandTextures = new Map<WaveformLevel, WebGLTexture>()
  private levels: WaveformLevels | null = null
  private lost = false
  private power: PowerAnalysis | null = null
  private energyTexture: WebGLTexture | null = null

  /** Null when WebGL2 is unavailable; the caller falls back to drawWaveform2D. */
  static create(canvas: HTMLCanvasElement): WaveformRenderer | null {
    const gl = canvas.getContext('webgl2', { premultipliedAlpha: true, antialias: false, alpha: true })
    if (!gl) return null
    try { return new WaveformRenderer(canvas, gl) }
    catch (error) { gl.getExtension('WEBGL_lose_context')?.loseContext(); throw error }
  }

  private constructor(canvas: HTMLCanvasElement, gl: WebGL2RenderingContext) {
    this.gl = gl
    this.canvas = canvas
    // Initialize before attaching listeners, so a failed constructor retains none.
    this.init()
    canvas.addEventListener('webglcontextlost', this.onLost)
    canvas.addEventListener('webglcontextrestored', this.onRestored)
  }

  private onLost = (event: Event): void => { event.preventDefault(); this.lost = true }
  private onRestored = (): void => {
    this.lost = false
    this.textures.clear()
    this.bandTextures.clear()
    this.power = null
    this.energyTexture = null
    this.init()
    const levels = this.levels
    this.levels = null
    this.setLevels(levels)
  }

  private init(): void {
    const gl = this.gl
    const compile = (type: number, source: string): WebGLShader => {
      const shader = gl.createShader(type)!
      gl.shaderSource(shader, source)
      gl.compileShader(shader)
      if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(shader) ?? 'Waveform shader failed')
      return shader
    }
    const program = gl.createProgram()!
    const vertex = compile(gl.VERTEX_SHADER, VERTEX)
    const fragment = compile(gl.FRAGMENT_SHADER, FRAGMENT)
    gl.attachShader(program, vertex)
    gl.attachShader(program, fragment)
    gl.linkProgram(program)
    gl.deleteShader(vertex)
    gl.deleteShader(fragment)
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program) ?? 'Waveform program failed')
    gl.useProgram(program)
    this.program = program

    const quad = gl.createBuffer()
    this.quad = quad
    gl.bindBuffer(gl.ARRAY_BUFFER, quad)
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW)
    const position = gl.getAttribLocation(program, 'aPos')
    gl.enableVertexAttribArray(position)
    gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0)

    for (const name of ['uData', 'uTexW', 'uCount', 'uBinSize', 'uStartCol', 'uSpp', 'uTotal', 'uHeight', 'uAmp', 'uOneSided', 'uPeak', 'uRms', 'uPeakPlayed', 'uRmsPlayed', 'uLine', 'uBands', 'uThreeBand', 'uEnergy', 'uEnergyCount', 'uEnergyStart', 'uEnergyBar', 'uSampleRate']) {
      this.uniforms[name] = gl.getUniformLocation(program, name)
    }
    gl.uniform1i(this.uniforms.uData, 0)
    gl.uniform1i(this.uniforms.uEnergy, 1)
    gl.uniform1i(this.uniforms.uBands, 2)
    gl.uniform1i(this.uniforms.uTexW, TEXTURE_WIDTH)
  }

  /** Switch the CPU pyramid and release the previous view cache. */
  setLevels(levels: WaveformLevels | null): void {
    if (levels === this.levels) return
    const gl = this.gl
    for (const texture of this.textures.values()) gl.deleteTexture(texture)
    this.textures.clear()
    for (const texture of this.bandTextures.values()) gl.deleteTexture(texture)
    this.bandTextures.clear()
    this.levels = levels
  }

  /** A view needs one level now; retain one neighbor for zooming, not the full pyramid. */
  private ensureLevel(level: WaveformLevel): WebGLTexture | undefined {
    const gl = this.gl
    if (!this.textures.has(level)) {
      while (this.textures.size >= 2) {
        const oldest = this.textures.keys().next().value!
        gl.deleteTexture(this.textures.get(oldest)!)
        const bands = this.bandTextures.get(oldest)
        if (bands) gl.deleteTexture(bands)
        this.textures.delete(oldest)
        this.bandTextures.delete(oldest)
      }
      const rows = Math.ceil(level.count / TEXTURE_WIDTH)
      gl.activeTexture(gl.TEXTURE0)
      for (const [bytes, textures] of [[level.data, this.textures], [level.bands, this.bandTextures]] as const) {
        if (!bytes) continue
        const padded = new Uint8Array(TEXTURE_WIDTH * rows * 4)
        padded.set(bytes)
        const texture = gl.createTexture()!
        gl.bindTexture(gl.TEXTURE_2D, texture)
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, TEXTURE_WIDTH, rows, 0, gl.RGBA, gl.UNSIGNED_BYTE, padded)
        textures.set(level, texture)
      }
    }
    const texture = this.textures.get(level)
    // Refresh LRU order without uploading again.
    if (texture) { this.textures.delete(level); this.textures.set(level, texture) }
    return texture
  }

  private setPower(power: PowerAnalysis | null): void {
    if (power === this.power) return
    const gl = this.gl
    if (this.energyTexture) gl.deleteTexture(this.energyTexture)
    this.energyTexture = null
    this.power = power
    if (!power) return
    const rows = Math.ceil(power.values.length / TEXTURE_WIDTH)
    const data = new Uint8Array(TEXTURE_WIDTH * rows * 4)
    power.values.forEach((v, i) => { data[i * 4] = Math.round(v * 255); data[i * 4 + 3] = 255 })
    this.energyTexture = gl.createTexture()
    gl.activeTexture(gl.TEXTURE1)
    gl.bindTexture(gl.TEXTURE_2D, this.energyTexture)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, TEXTURE_WIDTH, rows, 0, gl.RGBA, gl.UNSIGNED_BYTE, data)
  }

  draw(frame: WaveformFrame): void {
    const gl = this.gl
    const { width, height } = gl.canvas
    gl.viewport(0, 0, width, height)
    gl.clearColor(0, 0, 0, 0)
    gl.clear(gl.COLOR_BUFFER_BIT)
    const levels = this.levels
    if (this.lost || !levels || !this.program) return
    this.setPower(frame.power ?? null)
    const level = pickLevel(levels, frame.samplesPerPixel)
    const texture = this.ensureLevel(level)
    if (!texture) return
    const u = this.uniforms
    gl.useProgram(this.program)
    gl.uniform1i(u.uThreeBand, frame.threeBand && level.bands ? 1 : 0)
    gl.activeTexture(gl.TEXTURE2)
    gl.bindTexture(gl.TEXTURE_2D, this.bandTextures.get(level) ?? texture)
    gl.uniform1i(u.uEnergyCount, this.power?.values.length ?? 0)
    gl.uniform1f(u.uEnergyStart, this.power?.startSec ?? 0)
    gl.uniform1f(u.uEnergyBar, this.power?.barSec ?? 1)
    gl.uniform1f(u.uSampleRate, levels.sampleRate)
    gl.activeTexture(gl.TEXTURE1)
    // WebGL needs a complete texture even when the energy branch is off.
    gl.bindTexture(gl.TEXTURE_2D, this.energyTexture ?? texture)
    gl.activeTexture(gl.TEXTURE0)
    gl.bindTexture(gl.TEXTURE_2D, texture)
    gl.uniform1i(u.uCount, level.count)
    gl.uniform1f(u.uBinSize, level.binSize)
    gl.uniform1f(u.uStartCol, frame.startCol)
    gl.uniform1f(u.uSpp, frame.samplesPerPixel)
    gl.uniform1f(u.uTotal, levels.totalSamples)
    gl.uniform1f(u.uHeight, height)
    gl.uniform1f(u.uAmp, frame.amp)
    gl.uniform1i(u.uOneSided, frame.oneSided ? 1 : 0)
    gl.uniform4fv(u.uPeak, frame.paint.peak)
    gl.uniform4fv(u.uRms, frame.paint.rms)
    gl.uniform4fv(u.uPeakPlayed, frame.paint.peakPlayed)
    gl.uniform4fv(u.uRmsPlayed, frame.paint.rmsPlayed)
    gl.uniform4fv(u.uLine, frame.paint.line)
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4)
  }

  dispose(): void {
    this.canvas.removeEventListener('webglcontextlost', this.onLost)
    this.canvas.removeEventListener('webglcontextrestored', this.onRestored)
    this.setLevels(null)
    this.setPower(null)
    if (this.program) this.gl.deleteProgram(this.program)
    this.program = null
    if (this.quad) this.gl.deleteBuffer(this.quad)
    this.quad = null
  }
}

const css = ([r, g, b, a]: RGBA): string => `rgba(${Math.round(r * 255)}, ${Math.round(g * 255)}, ${Math.round(b * 255)}, ${a})`

/** The same drawing on a 2D canvas, one device pixel per column, for when WebGL2 is unavailable. */
export function drawWaveform2D(ctx: CanvasRenderingContext2D, levels: WaveformLevels | null, frame: WaveformFrame): void {
  const { width, height } = ctx.canvas
  ctx.setTransform(1, 0, 0, 1, 0, 0)
  ctx.clearRect(0, 0, width, height)
  const oneSided = frame.oneSided === true
  const mid = oneSided ? height : Math.floor(height / 2)
  if (!oneSided && frame.paint.line[3] > 0) {
    ctx.fillStyle = css(frame.paint.line)
    ctx.fillRect(0, mid, width, 1)
  }
  if (!levels) return
  const level = pickLevel(levels, frame.samplesPerPixel)
  const amp = (oneSided ? height : height / 2) * frame.amp
  const spp = frame.samplesPerPixel
  for (let x = 0; x < width; x++) {
    const s0 = (frame.startCol + x) * spp
    const s1 = s0 + spp
    if (s1 <= 0 || s0 >= levels.totalSamples) continue
    const b0 = Math.min(level.count - 1, Math.floor(Math.max(0, s0) / level.binSize))
    const b1 = Math.max(b0 + 1, Math.min(level.count, Math.ceil(Math.min(s1, levels.totalSamples) / level.binSize)))
    const stride = Math.max(1, Math.ceil((b1 - b0) / MAX_BINS_PER_PIXEL))
    let lo = 1
    let hi = -1
    let squares = 0
    let n = 0
    for (let i = b0; i < b1; i += stride) {
      lo = Math.min(lo, decodePeak(level.data[i * 4]))
      hi = Math.max(hi, decodePeak(level.data[i * 4 + 1]))
      squares += (level.data[i * 4 + 2] / 255) ** 2
      n++
    }
    if (frame.threeBand && level.bands) {
      const envelope = [0, 0, 0]
      if (spp < level.binSize) {
        const t = Math.max(0, Math.min(level.count - 1, (s0 + s1) * 0.5 / level.binSize - 0.5))
        const i = Math.floor(t), next = Math.min(level.count - 1, i + 1)
        for (let b = 0; b < 3; b++) envelope[b] = (level.bands[i * 4 + b] * (1 - (t - i)) + level.bands[next * 4 + b] * (t - i)) / 255
      } else {
        for (let i = b0; i < b1; i += stride) for (let b = 0; b < 3; b++) envelope[b] = Math.max(envelope[b], level.bands[i * 4 + b] / 255)
      }
      for (let b = 0; b < 3; b++) {
        const size = bandHeight(envelope[b], b) * amp
        if (size <= 0.01) continue
        ctx.fillStyle = `rgb(${BAND_COLOURS[b].join(',')})`
        ctx.fillRect(x, mid - size, 1, oneSided ? size : 2 * size)
      }
      continue
    }
    const energy = frame.power ? [...energyColour(powerAt(frame.power, (s0 + s1) / 2 / levels.sampleRate)), 1] as RGBA : null
    if (oneSided) hi = Math.max(hi, -lo)
    const top = Math.min(mid - 1, mid - Math.max(0, hi) * amp)
    const bottom = oneSided ? height : Math.max(mid + 1, mid - Math.min(0, lo) * amp)
    ctx.fillStyle = css(energy ?? frame.paint.peak)
    ctx.fillRect(x, top, 1, bottom - top)
    const body = Math.sqrt(squares / n) * amp
    if (body > 0.25) {
      const bodyTop = Math.max(top, mid - body)
      const bodyBottom = oneSided ? height : Math.min(bottom, mid + body)
      ctx.fillStyle = css(energy ?? frame.paint.rms)
      ctx.fillRect(x, bodyTop, 1, bodyBottom - bodyTop)
    }
  }
}

/**
 * A canvas that draws waveform frames: WebGL2 when it can, else 2D. The
 * canvas is sized by the caller (in device pixels) before each draw.
 */
export function useWaveformLayer(): {
  canvasKey: string
  canvasRef: React.RefObject<HTMLCanvasElement | null>
  draw: (levels: WaveformLevels | null, frame: WaveformFrame) => void
} {
  const [fallback, setFallback] = useState(false)
  const canvasRef = useRef<HTMLCanvasElement | null>(null)
  const layer = useRef<{ gl: WaveformRenderer | null; ctx: CanvasRenderingContext2D | null } | null>(null)

  useEffect(() => () => {
    layer.current?.gl?.dispose()
    layer.current = null
  }, [])

  const draw = useCallback((levels: WaveformLevels | null, frame: WaveformFrame) => {
    const canvas = canvasRef.current
    if (!canvas) return
    if (!layer.current) {
      let gl: WaveformRenderer | null = null
      try {
        if (!fallback) gl = WaveformRenderer.create(canvas)
      } catch (error) {
        console.warn('Waveform: WebGL2 failed, drawing in 2D', error)
        setFallback(true)
        return
      }
      layer.current = { gl, ctx: gl ? null : canvas.getContext('2d') }
    }
    const { gl, ctx } = layer.current
    if (gl) {
      gl.setLevels(levels)
      gl.draw(frame)
    } else if (ctx) {
      drawWaveform2D(ctx, levels, frame)
    }
  }, [fallback])

  return { canvasKey: fallback ? '2d' : 'webgl', canvasRef, draw }
}
