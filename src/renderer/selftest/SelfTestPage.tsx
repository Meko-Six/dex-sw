import { useCallback, useState } from 'react'
import { runSelfTest, type SelfTestReport } from './run'

declare global {
  interface Window {
    __selftest?: SelfTestReport
    __selftestProgress?: string
  }
}

export function SelfTestPage() {
  const [report, setReport] = useState<SelfTestReport | null>(null)
  const [progress, setProgress] = useState('Idle — press run (needs a user gesture for audio)')
  const [running, setRunning] = useState(false)

  const run = useCallback(async () => {
    setRunning(true)
    setReport(null)
    try {
      const result = await runSelfTest((message) => {
        window.__selftestProgress = message
        setProgress(message)
      })
      window.__selftest = result
      setReport(result)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      window.__selftestProgress = `failed: ${message}`
      setProgress(`failed: ${message}`)
    } finally {
      setRunning(false)
    }
  }, [])

  return (
    <div className="selftest">
      <header>
        <h1>Dex self-test</h1>
        <p className="muted">
          Renders real audio through the deck engine and measures sync alignment, loop period and seam, EQ and filter
          response, and the crossfader law. Takes about 20 seconds.
        </p>
        <button className="btn" onClick={() => void run()} disabled={running}>
          {running ? 'Running…' : report ? 'Run again' : 'Run self-test'}
        </button>
        <span className="muted small">{progress}</span>
      </header>

      {report && (
        <>
          <div className={`selftest-summary ${report.ok ? 'ok' : 'bad'}`}>
            {report.ok ? 'All measurements pass' : 'Some measurements failed'} · {report.metrics.length} checks ·{' '}
            {(report.durationMs / 1000).toFixed(1)} s
          </div>
          <table className="selftest-table">
            <thead>
              <tr>
                <th>Measurement</th>
                <th>Value</th>
                <th>Expected</th>
                <th>Result</th>
              </tr>
            </thead>
            <tbody>
              {report.metrics.map((metric) => (
                <tr key={metric.name} className={metric.pass ? 'pass' : 'fail'}>
                  <td>{metric.name}</td>
                  <td className="mono">
                    {metric.value.toFixed(2)} {metric.unit}
                  </td>
                  <td className="mono">{metric.expected}</td>
                  <td>{metric.pass ? 'PASS' : 'FAIL'}</td>
                </tr>
              ))}
            </tbody>
          </table>
          {report.errors.length > 0 && (
            <ul className="selftest-errors">
              {report.errors.map((error) => (
                <li key={error}>{error}</li>
              ))}
            </ul>
          )}
        </>
      )}
    </div>
  )
}
