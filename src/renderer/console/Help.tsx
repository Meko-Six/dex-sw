import { useConsole, type HelpTopic } from './state'

/** The instructions behind each (i) key: a term per control and one plain sentence for it. */
const HELP: Record<HelpTopic, { title: string; rows: [term: string, text: string][]; foot?: string }> = {
  grid: {
    title: 'How the beat grid works',
    rows: [
      ['Drag', 'Drag the waveform to pull the grid onto the beat.'],
      ['Set downbeat', 'Arm it, then tap the first beat of a bar.'],
      ['Tap', 'Tap along with the beat. Three taps set the tempo.'],
      ['±0.1 · 1 ms', 'Trim the tempo, or slide the grid earlier or later.'],
      ['÷2 · ×2', 'Fix a half-time or double-time reading.'],
      ['Other tempos', 'Swap in a tempo the analysis turned down. It brings its own downbeat.']
    ],
    foot: 'Every edit saves to the library straight away. There is no Apply step.'
  },
  tap: {
    title: 'How TAP tempo works',
    rows: [
      ['Input', 'Pick what to listen to. To follow another app, send its output to a loopback device such as BlackHole.'],
      ['Listening', 'A tempo shows after about 8 seconds of rhythm.'],
      ['Match deck', "Sets that deck's tempo to the one TAP hears."]
    ],
    foot: 'Nothing is recorded or sent to the mix. TAP only reads a tempo.'
  },
  trim: {
    title: 'Trim',
    rows: [
      ['Trim', 'Input gain for the track. Set it once when the track loads, then mix on the faders.'],
      ['Reset', 'Back to 0 dB.']
    ]
  },
  band: {
    title: 'EQ band',
    rows: [
      ['Slider', 'Full left kills the band. The right end is 0 dB.'],
      ['Fine', 'Drag up or down off the slider for fine moves.'],
      ['Long ride', 'Longer travel than the fader, for 16- and 32-bar rides. Same curve, same kills.'],
      ['Link lows', "Linked, one drag trades A's low for B's: the bass swap in one move."]
    ]
  },
  volume: {
    title: 'Volume',
    rows: [
      ['Master', 'The main output level.'],
      ['Cue mix', 'Blends the headphones from the cued deck (left) to the master (right).']
    ]
  },
  library: {
    title: 'How the library works',
    rows: [
      ['Load', "Tap a track, then tap a deck's album art. Or drag the track onto the deck."],
      ['Playlists', 'Drag a track onto a playlist, or use + on its row.'],
      ['Keys', 'Tap a key to show it and its harmonic matches.'],
      ['Sort', 'Tap a column heading.']
    ],
    foot: 'Files stay on this machine.'
  }
}

/** The round (i) key next to a sheet's or popover's DONE / CLOSE. */
export function InfoButton({ topic }: { topic: HelpTopic }) {
  const openHelp = useConsole((state) => state.openHelp)
  return (
    <button
      className="btn ghost info"
      onClick={(event) => {
        event.stopPropagation()
        openHelp(topic)
      }}
      title={HELP[topic].title}
    >
      <svg viewBox="0 0 20 20" aria-hidden="true">
        <circle cx="10" cy="4.5" r="2.1" />
        <rect x="8" y="8" width="4" height="9.5" rx="1" />
      </svg>
    </button>
  )
}

/** The open topic's instructions, over everything; a tap outside or CLOSE puts them away. */
export function HelpLayer() {
  const help = useConsole((state) => state.help)
  const openHelp = useConsole((state) => state.openHelp)
  const topic = help ? HELP[help] : null
  return (
    <section className={`help-layer ${topic ? 'open' : ''}`} onClick={() => openHelp(null)}>
      {topic && (
        <div className="gsheet narrow help" onClick={(event) => event.stopPropagation()}>
          <div className="gsheet-head">
            <h2>{topic.title}</h2>
            <button className="btn ghost done" onClick={() => openHelp(null)}>
              Close
            </button>
          </div>
          <div className="help-rows">
            {topic.rows.map(([term, text]) => (
              <div className="help-row" key={term}>
                <b>{term}</b>
                <span>{text}</span>
              </div>
            ))}
          </div>
          {topic.foot && <p className="help-foot">{topic.foot}</p>}
        </div>
      )}
    </section>
  )
}
