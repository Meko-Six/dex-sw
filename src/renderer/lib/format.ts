export function formatTime(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return '0:00'
  const total = Math.floor(seconds)
  const mins = Math.floor(total / 60)
  const secs = total % 60
  return `${mins}:${secs.toString().padStart(2, '0')}`
}

export function formatSignedPercent(rate: number): string {
  const pct = (rate - 1) * 100
  const sign = pct > 0 ? '+' : ''
  return `${sign}${pct.toFixed(1)}%`
}

export function formatBpm(bpm: number): string {
  return bpm.toFixed(1)
}

export function formatBeats(beats: number): string {
  return `${beats} beat${beats === 1 ? '' : 's'}`
}

export function stripExtension(name: string): string {
  return name.replace(/\.[^./\\]+$/, '')
}

export function confidenceLabel(confidence: number): 'good' | 'fair' | 'poor' {
  if (confidence >= 0.6) return 'good'
  if (confidence >= 0.35) return 'fair'
  return 'poor'
}
