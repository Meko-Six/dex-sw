import { bridge } from './lib/bridge'
import { useEffect, useState } from 'react'
import { engine } from './audio/engine'
import { Alert, Head, Info, Screen } from './console/Band'
import { Chassis } from './console/Chassis'
import { isDemo } from './console/demo'
import { useDeckDrop } from './console/drop'
import { JUMP_KEYS, MAX_STRETCH, STAGE_H, STAGE_W, vars } from './console/layout'
import { HelpLayer } from './console/Help'
import { SheetLayer } from './console/SheetLayer'
import { GridSheet, Library, VolumePop } from './console/Sheets'
import { useConsole } from './console/state'
import { useEngineSnapshot } from './hooks'
import { useLibrary } from './state/library'

interface Fit {
  scale: number
  /** Extra stage height, in stage points, given to the zoom lanes. */
  stretch: number
}

/** The whole 1174 × 814 console as large as the window allows, plus any spare height up to 4:3. */
function useFit(): Fit {
  const measure = (): Fit => {
    const scale = Math.min(window.innerWidth / STAGE_W, window.innerHeight / STAGE_H)
    return { scale, stretch: Math.min(MAX_STRETCH, Math.max(0, window.innerHeight / scale - STAGE_H)) }
  }
  const [fit, setFit] = useState(measure)
  useEffect(() => {
    const onResize = (): void => setFit(measure())
    window.addEventListener('resize', onResize)
    return () => window.removeEventListener('resize', onResize)
  }, [])
  return fit
}

export function App() {
  const snapshot = useEngineSnapshot()
  const error = useLibrary((state) => state.error)
  const setError = useLibrary((state) => state.setError)
  const applyGridToLibrary = useLibrary((state) => state.applyGrid)
  const libOpen = useConsole((state) => state.libOpen)
  const { scale, stretch } = useFit()
  const [startupError, setStartupError] = useState<string | null>(null)
  useDeckDrop()

  useEffect(() => {
    if (isDemo) return
    let cancelled = false
    engine
      .init()
      .then(() => {
        if (!cancelled) void engine.resume()
      })
      .catch((reason: unknown) => {
        if (!cancelled) setStartupError(reason instanceof Error ? reason.message : String(reason))
      })
    void useLibrary.getState().hydrate()
    const removeCloseListener = bridge.onBeforeClose?.(() => useLibrary.getState().flush())
    // The audio context may only start after a gesture.
    const resume = (): void => {
      void engine.resume()
    }
    window.addEventListener('pointerdown', resume)
    return () => {
      cancelled = true
      removeCloseListener?.()
      window.removeEventListener('pointerdown', resume)
    }
  }, [])

  useEffect(() => {
    if (!error || isDemo) return
    const timer = window.setTimeout(() => setError(null), 7000)
    return () => window.clearTimeout(timer)
  }, [error, setError])

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent): void => {
      const target = event.target as HTMLElement | null
      const tag = target?.tagName
      const ui = useConsole.getState()
      // Escape has to work from the library's search field too, so it is
      // handled before the text-input guard. It closes the topmost thing.
      if (event.key === 'Escape' && !event.metaKey && !event.ctrlKey && !event.altKey) {
        event.preventDefault()
        if (ui.help) ui.openHelp(null)
        else if (ui.sheet) ui.setSheet(null)
        else if (useLibrary.getState().error) setError(null)
        else if (ui.gridOpen) ui.closeGrid()
        else if (ui.cueOpen.A || ui.cueOpen.B) useConsole.setState({ cueOpen: { A: false, B: false }, cueDelete: { A: false, B: false } })
        else if (ui.mixPop) ui.setMixPop(null)
        else if (ui.volOpen) ui.toggleVol(false)
        else if (ui.libOpen) ui.toggleLib(false)
        else void engine.stopAll()
        return
      }
      if (tag === 'INPUT' || tag === 'TEXTAREA' || target?.isContentEditable) return
      if (event.metaKey || event.ctrlKey || event.altKey) return

      const current = engine.getSnapshot()
      const focused = current.focusedDeck
      const other: 0 | 1 = focused === 0 ? 1 : 0
      const deck = current.decks[focused]
      const key = event.key
      const handled = (): void => event.preventDefault()
      // Beat jump: a pair of keys per deck, so neither needs focus.
      const lower = key.toLowerCase()
      const jumpSide = (['A', 'B'] as const).find((side) => JUMP_KEYS[side].includes(lower))

      if (jumpSide) {
        handled()
        // One jump per press: a held key's auto-repeat is ignored.
        if (!event.repeat) engine.beatJump(jumpSide === 'A' ? 0 : 1, lower === JUMP_KEYS[jumpSide][0] ? -1 : 1)
      } else if (key === '1' || key === '2') {
        handled()
        void engine.togglePlay(key === '1' ? 0 : 1)
      } else if (key === ' ') {
        // Space always plays the focused deck: a key left focused by a tap
        // (the album art that loaded the track) must not take it.
        if (tag === 'BUTTON') target?.blur()
        handled()
        if (!event.repeat) void engine.togglePlay(focused)
      } else if (key === 's') {
        handled()
        engine.sync(other)
      } else if (key === 'S') {
        handled()
        engine.sync(focused)
      } else if (key === 'c' || key === 'C') {
        handled()
        if (!event.repeat) void engine.cueDown(focused)
      } else if (key === 'm' || key === 'M') {
        handled()
        engine.setCue(focused, !deck.cue)
      } else if (key === 'l') {
        handled()
        void engine.toggleLoop(focused)
      } else if (key === 'L') {
        handled()
        engine.halveLoop(focused)
      } else if (key === '[' || key === ']') {
        handled()
        engine.nudgeTempo(focused, key === '[' ? -0.001 : 0.001)
      } else if (key === 'ArrowLeft' || key === 'ArrowRight') {
        if (!deck.grid) return
        handled()
        const step = event.shiftKey ? 10 : 1
        engine.nudgeGrid(focused, key === 'ArrowLeft' ? -step : step)
        const grid = engine.getDeck(focused)?.grid
        if (deck.trackId && grid) applyGridToLibrary(deck.trackId, grid)
      } else if (key === '?' || key === '/') {
        handled()
        ui.setSheet(ui.sheet === 'shortcuts' ? null : 'shortcuts')
      }
    }
    // CDJ cue previews for as long as the key is held.
    const onKeyUp = (event: KeyboardEvent): void => {
      // A button activates on Space's keyup; Space is the play key here.
      if (event.key === ' ') event.preventDefault()
      if (event.key === 'c' || event.key === 'C') void engine.cueUp(engine.getSnapshot().focusedDeck)
    }
    window.addEventListener('keydown', onKeyDown)
    window.addEventListener('keyup', onKeyUp)
    return () => {
      window.removeEventListener('keydown', onKeyDown)
      window.removeEventListener('keyup', onKeyUp)
    }
  }, [applyGridToLibrary, setError])

  return (
    <div className="fit">
      <div className="fit-box" style={{ width: STAGE_W * scale, height: (STAGE_H + stretch) * scale }}>
        <div className={`ipad${libOpen ? ' lib-open' : ''}`} style={vars({ transform: `scale(${scale})`, '--stretch': `${stretch}px` })}>
          <header className="band">
            <Head snapshot={snapshot} />
            <Screen snapshot={snapshot} />
            <Info snapshot={snapshot} />
            {startupError ? (
              <Alert title="NO AUDIO" message={`The audio engine didn't start: ${startupError}`} />
            ) : (
              error && <Alert title={error.title} message={error.message} onDismiss={() => setError(null)} />
            )}
          </header>
          <Chassis snapshot={snapshot} />
          <VolumePop snapshot={snapshot} />
          <Library snapshot={snapshot} />
          <GridSheet snapshot={snapshot} />
          <SheetLayer snapshot={snapshot} />
          <HelpLayer />
        </div>
      </div>
    </div>
  )
}
