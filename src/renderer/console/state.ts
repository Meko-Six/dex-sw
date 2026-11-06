import { create } from 'zustand'

export type Side = 'A' | 'B'
export type MixPop = { kind: 'trim'; side: Side } | { kind: 'band'; band: 'high' | 'mid' | 'low' } | null
/** The sheets over the whole console. */
export type Sheet = 'shortcuts' | 'tap' | null
/** The instructions behind an (i) key. */
export type HelpTopic = 'grid' | 'tap' | 'trim' | 'band' | 'volume' | 'library'
/** A file or library row dragged over a deck, and what it is. */
export type Drop = { side: Side; label: string } | null

/** Seconds across a zoom lane. The readout counts zoom from ×1 at 48 s. */
export const SPAN_DEFAULT_SEC = 12
export const SPAN_MIN_SEC = 3
export const SPAN_MAX_SEC = 48
export const clampSpan = (seconds: number): number => Math.max(SPAN_MIN_SEC, Math.min(SPAN_MAX_SEC, seconds))

interface ConsoleState {
  energyEnabled: boolean
  toggleEnergy: () => void
  libOpen: boolean
  volOpen: boolean
  /** The deck whose beat grid sheet is up. */
  gridOpen: Side | null
  mixPop: MixPop
  cueOpen: Record<Side, boolean>
  cueDelete: Record<Side, boolean>
  /** The library row picked for loading. */
  selectedId: string | null
  spanSec: number
  /** LINK LOWS. */
  link: boolean
  sheet: Sheet
  /** The open help topic, over everything. */
  help: HelpTopic | null
  drop: Drop
  toggleLib: (open?: boolean) => void
  toggleVol: (open?: boolean) => void
  openGrid: (side: Side) => void
  closeGrid: () => void
  setMixPop: (pop: MixPop) => void
  toggleHotCues: (side: Side) => void
  setCueDelete: (side: Side, on: boolean) => void
  select: (trackId: string | null) => void
  setSpan: (seconds: number) => void
  toggleLink: () => void
  setSheet: (sheet: Sheet) => void
  openHelp: (topic: HelpTopic | null) => void
  setDrop: (drop: Drop) => void
}

function readEnergyPreference(): boolean {
  try { return localStorage.getItem('dex.waveform') === 'energy' } catch { return false }
}

/** What the console shows beyond the engine: which sheets and popovers are open. */
export const useConsole = create<ConsoleState>((set, get) => ({
  energyEnabled: readEnergyPreference(),
  toggleEnergy: () => {
    const energyEnabled = !get().energyEnabled
    try {
      localStorage.setItem('dex.waveform', energyEnabled ? 'energy' : '3band')
      localStorage.setItem('dex.energy', energyEnabled ? 'on' : 'off')
    } catch { /* private storage */ }
    set({ energyEnabled })
  },
  libOpen: false,
  volOpen: false,
  gridOpen: null,
  mixPop: null,
  cueOpen: { A: false, B: false },
  cueDelete: { A: false, B: false },
  selectedId: null,
  spanSec: SPAN_DEFAULT_SEC,
  link: false,
  sheet: null,
  help: null,
  drop: null,
  toggleLib: (open = !get().libOpen) => set(open ? { libOpen: true, gridOpen: null } : { libOpen: false }),
  toggleVol: (open = !get().volOpen) => set({ volOpen: open }),
  openGrid: (side) => set({ gridOpen: side, libOpen: false }),
  closeGrid: () => set({ gridOpen: null, help: null }),
  setMixPop: (mixPop) => set({ mixPop }),
  toggleHotCues: (side) => {
    const open = !get().cueOpen[side]
    set({
      cueOpen: { ...get().cueOpen, [side]: open },
      cueDelete: open ? get().cueDelete : { ...get().cueDelete, [side]: false }
    })
  },
  setCueDelete: (side, on) => set({ cueDelete: { ...get().cueDelete, [side]: on } }),
  select: (selectedId) => set({ selectedId }),
  setSpan: (seconds) => set({ spanSec: clampSpan(seconds) }),
  toggleLink: () => set({ link: !get().link }),
  setSheet: (sheet) => set({ sheet }),
  openHelp: (help) => set({ help }),
  setDrop: (drop) => {
    const current = get().drop
    if (current?.side !== drop?.side || current?.label !== drop?.label) set({ drop })
  }
}))
