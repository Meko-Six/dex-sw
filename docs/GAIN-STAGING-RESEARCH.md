# Gain staging: the source video, the standards, and what Dex should do

Research for the mixer's level controls on Mac and iPad, written 9 November 2026 as a
brief an implementing agent can work from. The source is the user's transcript of
[Set Your Volumes Like A Pro.md](Set%20Your%20Volumes%20Like%20A%20Pro.md) (Expert DJ,
"How To Set Your Volumes Like A Pro When DJing", 5 minutes). Section 1 is what that
video says. Everything after it comes from manufacturer documentation and standards, all
linked at the end. Section 6 is measured, on all 52 bench tracks, on 9 November 2026;
anything else marked as arithmetic is worked from the bench numbers in
[HANDOFF](../HANDOFF.md).

This doc changed no code. [HANDOFF](../HANDOFF.md) records the measured result and links back here.

The problem it solves: the video teaches a six-step ritual on physical gear, with an
average-reading LED meter. Dex has peak meters in dBFS, no amplifier stage and no cue
level, so the ritual cannot be copied. It has to be translated. Section 6 does the
translation and section 10 says what controls that implies.

## 1. What the video says

Four places volume gets set, from the audience back to the track:

| Stage | Where | What it is for |
| --- | --- | --- |
| Amplifier gain | Knob on computer speakers, back of an active PA, or a PA power amp | The room's absolute loudness |
| Master output | Master knob on controller, software or mixer | Overall level out of the rig |
| Input gain (trim) | Per channel, above the EQ | Compensates level differences between tracks |
| Channel output fader | Per channel, below the EQ | Per-channel level while mixing |

The sequence, in this order:

1. **Everything down.** Every gain stage fully left, faders down.
2. **Input gain.** Play a track at a loud point, raise trim until the **average** reads
   **0 dB** (top green LED).
3. **Check peaks.** Transients should sit **+3 to +6 dB** (yellow). **Never red**, which
   is distortion.
4. **Channel faders fully up.**
5. **Master gain.** Same again: **average 0 dB** (top green), peaks **+3 to +6 dB**
   (yellow), no red.
6. **Amplifier or PA.** Average **0 dB**, the **last green LED**. With no meters: raise
   until the **clip light** lights, then back off until it stops.

Then the rule for the night: leave it below these settings so there is somewhere to go,
and adjust at "the closest control to the speakers that you have access to". If the amp
is locked away, use master instead.

### What the video gets right

- **The order is correct.** Source, channel, mix bus, amplifier, set last, is what every
  manufacturer's guide describes: the upstream stages decide how hard the amplifier is
  driven.
- **"Faders fully up" is a unity-gain convention, not a boost.** Allen & Heath documents
  channel faders as running "from fully off (infinity) to fully on (unity)"
  ([Xone:92 Mk2](https://www.allen-heath.com/content/uploads/2024/10/Xone92-Mk2-User-Guide.pdf),
  [Xone:96](https://support.allen-heath.com/hc/en-gb/articles/43053562464017-Xone-96-User-Guide)).
  A fader at the top is not adding anything, so leaving the headroom to master and amp
  is deliberate rather than arbitrary.
- **"Average at 0, peaks at +6" is the published analogue convention**, near verbatim.
  Xone:96: set so the meter "averages around 0 with loudest peaks around +6", and turn
  the gain down if the +10 LED stays lit. Xone:24: averaging about 0, peaks "+6 to +9".
  Xone:43: peaks no higher than +6.
- **The clip-light fallback is real commissioning practice.** The industry version backs
  off about **3 dB** after the clip LED starts, rather than "until it stops" (Extron,
  [Optimizing Audio Levels](https://www.extron.com/product/files/helpfiles/dspconfig25/Content/mtrxpr_DMP128/Optimizing_Audio_Levels_mtrxpr.htm)).

## 2. Where the ambiguity is

**"0 dB" on a DJ meter is not 0 dBFS, 0 dBu, or a fixed point at all.** It is a marking
on a meter whose calibration varies by mixer, and the video's "average at 0" assumes a
meter that reads average. Digital gear, and Dex, reads peaks. The difference between the
two is the whole crest factor of the music: 10 to 14 dB for dance tracks (section 5).

The clearest evidence that these are two separate schools: Pioneer and AlphaTheta tell
you to put **peaks** at 0, not the average. "Adjust the TRIM control so that the channel
level indicator lights around 0 dB at the peak level of the input audio", and set master
the same way
([DJM-750MK2 help](https://support.alphatheta.com/en-US/articles/4408734012953?product=4416503568025)).
The DJM-A9 help says trim until the **orange** indicator lights at maximum. So a mixer
manual and this video, describing the same gesture, disagree by roughly 12 dB, because
they assume different meters.

An agent copying the video's numbers onto a dBFS meter lands 10 to 15 dB too hot. That
single translation error is the reason this document exists.

## 3. Where 0 dB sits on real gear

| Gear | Meter 0 means | Red and clip | Source |
| --- | --- | --- | --- |
| DJM-900NXS2 | Channel meter spans +12 to -30 in 3 dB steps; master +15 to -27. Manual asks for peaks around 0 | Red is a warning zone, not the clip point. Support says stay below **+12**; output is clean to **+21 dB** on the meter at Master Out ATT 0 (model-specific) | [manual](https://jundc.com/wp-content/uploads/2022/06/djm900nxs2-1.pdf), [support](https://support.alphatheta.com/en-US/articles/4405910354201?product=4416490599449) |
| Xone:92 Mk2 | **+4 dBu** at MIX 1 XLR, -2 dBu at MIX 2 | Top red **+10**, "12 dB before clipping". Average 0, peaks +6 | [guide](https://www.allen-heath.com/content/uploads/2024/10/Xone92-Mk2-User-Guide.pdf) |
| Xone:96 | Channel meter -20 to +10 dBu, 9 LEDs; master -35 to +10, 11 LEDs | A continuously lit +10 means turn down | [guide](https://support.allen-heath.com/hc/en-gb/articles/43053562464017-Xone-96-User-Guide) |
| Xone:43 | 9-LED, -20 to +10 dB; peaks no higher than +6 | +20 dB internal channel headroom | [guide](https://www.allen-heath.com/content/uploads/2023/06/AP9968_2_X43_UG.pdf) |
| Traktor Kontrol S4 Mk3 | Yellow is "above 0 and below +6 dB" | Red is clipping | [manual](https://www.native-instruments.com/fileadmin/ni_media/downloads/manuals/traktor/TRAKTOR_KONTROL_S4_MK3_Manual_English.pdf) |
| Serato DJ Pro master | Knob runs -12 to +12. At the **0 dB** position all green is lit; at **+3 dB** ("no headroom") green and yellow are lit | Above +3 the **limiter** engages; the meter still shows red up to +9 above the 0 position | [Serato](https://support.serato.com/hc/en-us/articles/224966287-Master-Output-Level) |
| Denon X1850, Prime 4 | No per-LED scale published | Headroom specified as **>15 dB** line in, **>20 dB** outputs | [guide](https://cdn.inmusicbrands.com/denondj/X1850Prime/X1850%20PRIME%20-%20User%20Guide%20-%20v1.4.pdf) |

Two conclusions. There is **no single DJ-mixer convention**: the documented spread from
meter 0 to clip is +12 dB on a Xone:92, +21 dB on a DJM-900NXS2, and "20 dB of output
headroom" quoted as a specification on a Prime 4. And on an analogue mixer "0 dB" is a
*nominal operating reference*, a comfortable place to run, not a threshold where
anything happens.

The useful shape is Allen & Heath's: **0 dB average, +6 dB peaks, top red at +10, clip
12 dB above the 0 mark.** That is a meter with six dB of visible room above a correctly
set peak, and it is reproducible.

## 4. The four scales, so they stop being confused

- **dBu**: analogue volts. 0 dBu = 0.775 V RMS. Meters marked in dBu are analogue
  meters.
- **VU or average**: a meter with integration time, reading roughly the energy of the
  music. "Average 0, peaks +6" assumes this.
- **dBFS**: digital, referenced to full scale, read as peaks. 0 dBFS is the largest
  sample value in fixed point, and nothing above it survives a converter. In 32-bit
  float inside an app, levels above 0 dBFS are representable and recoverable *until*
  they meet a fixed-point stage, a level-sensitive plug-in or the DAC
  ([SSL](https://support.solidstatelogic.com/hc/en-gb/articles/24642897272221-32-Bit-Conversion-Explained-SSL-Audio-Interfaces)).
  Dex's limiter at ceiling 0.99 is that boundary. What clips before it is gone.
- **LUFS**: perceived loudness, integrated over time. Not a peak, and not a meter
  reading. Used to match tracks, never to set a fader directly.

The mapping between them is a calibration, not a law. EBU R68 puts the digital alignment
signal 18 dB below maximum coding level, and a common European calibration maps 0 dBu to
-18 dBFS ([EBU R 68](https://tech.ebu.ch/docs/r/r068.pdf)). Extron's working figures for
programme material are an average of **-15 to -12 dBFS** and peaks around **-6 dBFS**.

That last line is the bridge the video is missing. **"Average 0 dB, peaks +6" on an
analogue mixer is, in dBFS, roughly "average -15, peaks -6 to -9".**

## 5. The arithmetic that constrains the design

Three numbers explain why the video insists on yellow and never red.

**Crest factor.** Dance and electronic masters measure a median of -8.7 LUFS (dance and
EDM) to -9.3 LUFS (electronic) integrated, with the middle half of EDM between -10.4 and
-7.4; 90% of a 314,876-track dataset is louder than -14 LUFS
([Freshly Baked](https://freshlybakedstudios.com/blog/average-lufs-by-genre); a
commercial dataset, projected values). A smaller measured set of 151 masters gives a
crest factor of **13.6 dB** for masters at or below -14 LUFS and **10.2 dB** for masters
above -9 LUFS, and 62% of it measures above 0 dBTP
([LuvLang](https://luvlang.studio/research/loudness-2026)). So peak-to-average on club
material runs 10 to 14 dB, and at the loud end the peaks are already flattened.

**Summing.** Two equal decks add **+6.02 dB** when their signals are correlated and in
phase, and **+3.01 dB** in average power when uncorrelated
([Yamaha](https://jp.yamaha.com/files/download/other_assets/7/329527/Automixer_WhitePaper_en.pdf)).
Two copies of one track beat-aligned is the +6 case; two different tracks is nearer +3,
but peaks wander, so the master has to budget for the correlated case. This is why the
channel stage cannot sit at full scale: the sum needs 6 dB nobody accounted for.

**True peak.** A sample-peak meter under-reads the reconstructed waveform. EBU R128 sets
**-1 dBTP** as the maximum true peak for programme
([R 128](https://tech.ebu.ch/docs/r/r128.pdf)). That governs exports and reference files
more than a live bus, but it is why "just under 0" is not a safe target.

Put together: a deck peaking at 0 dBFS leaves nothing, and a deck peaking 6 dB below full
scale leaves exactly the 6 dB a correlated pair needs.

## 6. Translating into Dex's numbers

This section is measured: all 52 tracks through `DexCore/Loudness.swift`, 9 November
2026, at each target in turn. It is the part an implementing agent most needs. An earlier
chat summary of this research had the correlated-pair column wrong: it read -6 dBFS per
deck becoming -3 dBFS in the master, but two correlated decks add +6, so it is 0 dBFS.
The measurement below is the corrected and confirmed version.

Dex today: four meters, **peaks, -30 to +6 dBFS**, falling 20 dB a second with a 2 s held
segment, red **from 0 dBFS**, limiter ceiling **0.99**. A and B are each deck after TRIM,
EQ and FILTER and before LEVEL; L and R are the master after VOLUME and before the
limiter. LEVEL's top is 0 dB on the same law as the bands. TRIM is +/-12 dB. AUTO brings
a track's main groove to **-10 LUFS**.

Measured, 52 tracks: main groove **-9.30 to -5.04 LUFS** (median -6.84); integrated
-10.51 to -6.24 (median -8.12); every file peaks at exactly **0.00 dBFS**. AUTO trims at
-10 land at -0.7 to -5.0 dB, so **a single deck at full LEVEL peaks between -0.7 and -5
dBFS**, median -3.2, and 22 of the 52 sit above -3.

The video's step 2 cannot be performed as written: there is no "0 dB average, peaks +6"
region, because the scale tops out 6 dB above the red line. The meter reference and the
AUTO target have to be chosen together. Lowering the AUTO target by 1 dB lowers every
deck's peak by 1 dB, so the two move in lockstep:

| AUTO target | Trim applied | Worst deck peak | Median deck peak | Two worst decks, correlated | Two worst decks, uncorrelated | Decks over -6 dBFS | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- |
| -10 LUFS (today) | -0.7 to -5.0 | -0.7 | -3.2 | **+5.3**, limiter hard | +2.3 | 52 of 52 | No headroom anywhere |
| -12 | -2.7 to -7.0 | -2.7 | -5.2 | +3.3 | +0.3 | 44 | Still over |
| -14 | -4.7 to -9.0 | -4.7 | -7.2 | +1.3 | -1.7 | 11 | Limiter catches the worst case |
| **-16** | **-6.7 to -11.0** | **-6.7** | **-9.2** | **-0.7** | **-3.7** | **0** | **Worst case under full scale** |
| -18 | -8.7 to -12.0, clamped | -8.7 | -11.2 | -2.7 | -5.7 | 0 | Trim range ran out on the loudest track |

**Recommendation: AUTO at -16 LUFS.** Measured, it is the highest target at which no deck
exceeds -6 dBFS, and even the library's worst pair, correlated, stays under full scale at
-0.7 dBFS: 0.6 dB below the limiter's ceiling of 0.99, which is -0.09 dBFS. It puts a
median deck's peaks at -9.2 dBFS, which is the "peaks in the yellow" position of the
video's method once the meter has a reference, and it costs 6 dB against today rather
than the 12 dB a strict analogue reading would. It also sits on the safe side of the
user's proposal of -12 to -14, and it is the lowest target the +/-12 dB trim range covers
with a dB to spare: the loudest track needs -11.0 dB at -16 and clamps at -18.

The correlated case reaching the ceiling is inherent, not a flaw: the analogue convention
expects it too, which is why +6 dB peaks and clip 12 dB above the 0 mark coexist on the
same meter. The limiter is the backstop for that case. What is not acceptable is the
limiter working on a single deck, which is today's state.

Three things to keep in view. After trim the loudness spread disappears by construction,
so the residual is peak spread, 4.3 dB across the library (-11.0 to -6.7), from crest
factor differing per track: 6.24 to 10.51 dB against integrated loudness (median 8.12),
and 5.04 to 9.30 dB against the main groove. That crest is tighter than the 10 to 14 dB
section 5 cites, because every file here is peak-normalised to 0.00 dBFS, so these peaks
are this library's best case; a crate of quieter masters would sit higher at the same
target. Sample peaks are also not true peaks, which sit slightly higher. And the
correlated sum is a bound rather than a prediction, since real peaks seldom align to the
sample. All three argue for holding -16 rather than easing toward -14.

## 7. What the video leaves out

**A fifth stage for the digital source.** Every number in the video assumes a track
arriving at a known level. Real libraries are not like that: dance masters sit at -9 to
-11 LUFS with peaks at or over 0 dBTP, and streaming catalogues are normalised to -14
LUFS ([Spotify](https://support.spotify.com/us/artists/article/loudness-normalization/)).
That spread, about 5 dB either way, is what trim exists to absorb, and it is wider than
most DJs assume.

**Cue and booth.** The headphone path is a separate monitor bus with its own level,
independent of master on most mixers: on a Xone:24 the master control drives the house
outputs and the headphone control the headphones, with cue and mix taken pre-master.
Booth output is a third, independent level for the DJ's own monitors.

**A track whose level changes inside itself.** The method is "play a loud point and set
trim", but a track with a quiet intro needs the trim set on the part about to be mixed.
Traktor's own manual: base the setting on "the loudest section of the track", and what
matters is "the perceived loudness of the specific part of the track that you're about
to mix in"
([NI](https://www.native-instruments.com/fileadmin/ni_media/downloads/manuals/traktor/traktor_kontrol_s5_manual_english.pdf)).

**EQ and FX eating headroom.** A cut is free; a boosted band or a long reverb tail is
not, and the video never says so. Dex's isolator is cut-only, which sidesteps most of
this.

**How much more punishing the digital ceiling is.** On an analogue mixer, red is ugly but
recoverable. In a digital mixer, clipping at the ADC is already in the samples, and
clipping at the DAC cannot be undone afterwards. Floating point buys internal headroom,
not output headroom. Dex's limiter is the last chance; nothing upstream of it comes back.

## 8. What auto-gain in real software actually does

Useful because Dex's AUTO is a decision in a field of opaque ones.

| Software | Where | Value stored | Documented target | Travels on a USB stick? |
| --- | --- | --- | --- | --- |
| rekordbox | Preferences > Controller > Mixer > Auto Gain; per track in GRID EDIT | dB offset, as floats in `djmdMixerParam` (`GainHigh`, `GainLow`) | **None.** Staff say "peak levels near the 0 dB mark". A six-track third-party measurement read it as loudness matching to **-10 LUFS** | **No**: "Auto gain data is not stored on the export" |
| Serato DJ Pro | Setup > DJ Preferences > Use Auto Gain | Reference **89-98 dB, default 92**; track gain +/-24 dB | "Match the perceived loudness to a reference level". The 89-98 scale is not published in LUFS or dBFS | Library tag |
| Traktor | Preferences > Mixer > Level; `LOUDNESS` in `collection.nml` | Autogain value, added to channel gain (-inf to +12 dB) | "Even output level"; meter peaks into the orange | With the file |

Sources: [rekordbox 7 manual](https://cdn.rekordbox.com/files/20260807093645/rekordbox7.2.18_manual_EN.pdf),
[pyrekordbox db6](https://pyrekordbox.readthedocs.io/en/latest/formats/db6.html),
[the six-track measurement](https://dev.to/jphfa/rekordbox-auto-gain-evens-out-your-tracks-on-the-laptop-and-never-reaches-the-cdj-1mp2),
[Serato prefs](https://support.serato.com/hc/en-us/articles/223363407-DJ-Preferences),
[Serato track gain](https://support.serato.com/hc/en-us/articles/234774728-Track-Gain-Adjust),
[NI](https://support.native-instruments.com/support/solutions/articles/69000879529-traktor-setting-up-channel-gain-and-auto-gain).

Why DJs distrust it, in the manufacturers' own words: NI recommends turning autogain
**off**, because "under unfavorable conditions... this can lead to unwanted clipping or
limiting of the master output". The failure is structural and is the one that matters
here: loudness matching equalises the average, clipping is a peak event, so a track with
a wide crest factor can be matched in loudness and still clip. Traktor and Serato both
tell you to check the loudest section on the meters afterwards.

Dex's AUTO is loudness-based at -10 LUFS, the same family as rekordbox's observed
behaviour, and more conservative than either: it only attenuates on this bench, and a
hand-set trim is remembered per track. The lesson to keep is the one the bench already
shows. Loudness matching does not bound peaks, so the target must be chosen for peak
headroom (section 6), not only to make tracks sound equally loud.

## 9. Monitoring, and the hearing limits

The cue path is where a DJ spends the set, and the video omits it.

- Cue is pre-fader; cue/mix blends cue against master; split cue puts one in each ear;
  headphone level is its own control. Routing details vary by mixer, so do not generalise
  one model's behaviour ([A&H](https://support.allen-heath.com/hc/en-gb/articles/39799443772689-Xone-24-User-Guide),
  [Serato](https://support.serato.com/hc/en-us/articles/223446728-Mixer)).
- A safe default is fully down or muted and raised deliberately: AlphaTheta's setup flow
  starts with "HEADPHONES LEVEL fully counterclockwise". Serato ships a 10% default for
  its software cue volume with up to +12 dB available and a warning about hearing damage.
  That is a product setting, not a safe level, and no source gives a typical DJ headphone
  SPL, so a "safe percentage" would be invented.
- Exposure: NIOSH 85 dBA for 8 hours with a **3 dB** exchange rate, so 88 for 4 h, 91
  for 2 h, 94 for 1 h, 97 for 30 min, 100 for 15 min
  ([CDC](https://www.cdc.gov/niosh/bulletin/2016/noise.html)). OSHA's legal PEL is 90
  dBA for 8 h on a 5 dB rate ([OSHA](https://www.osha.gov/noise)). WHO's venue standard
  recommends **below 100 dB LAeq,15min**
  ([WHO](https://iris.who.int/bitstream/handle/10665/352277/9789240043114-eng.pdf)) and
  reports club averages of 104-112 dB. UK HSE recommends no more than 107 dB LAeq and
  140 dB(C) peak for audiences ([HSE](https://www.hse.gov.uk/Event-Safety/noise.htm)).
- **Dex cannot set the device's volume.** `AVAudioSession.outputVolume` is read-only and
  only the user sets system volume; `MPVolumeView` is the system control
  ([Apple](https://developer.apple.com/documentation/avfaudio/avaudiosession/outputvolume)).
  So on iPad the cue level must be Dex's own gain rather than the system slider, and no
  calibrated SPL ceiling can be imposed. Start low, make the control obvious, ramp rather
  than step.

## 10. What this implies for the controls

Set against what Dex already has, so an agent can tell a change from a given.

**Already right, leave alone.** The chain order is correct: TRIM is before the EQ, so the
headphones hear it; A and B meter before LEVEL, so trim is set with LEVEL down, which is
the video's step 2 and Pioneer's arrangement; LEVEL's top is 0 dB, so step 4 is true by
construction; L and R meter after VOLUME and before the limiter, so the master shows what
actually goes in. The isolator being cut-only means no EQ-induced headroom loss.

**The decision that changes everything else: the meter reference.** Because the four
meters are peak dBFS with red at 0, the video's vocabulary (top green, yellow, red) has
no fixed meaning. There are two ways to fix it, and the numbers are identical; only the
label differs.

- **Keep dBFS and state targets in dBFS**: per-deck peaks about **-6 dBFS** at unity
  LEVEL, master about **-3 dBFS**, red from **-6 dBFS** on the channel meters as
  "approaching", 0 dBFS as "limiter working".
- **Re-reference the scale so 0 dB = -12 dBFS.** That reproduces a Xone's geometry
  exactly: green to 0, yellow 0 to +6 (which is -12 to -6 dBFS), red from +6, hard
  ceiling at +12, which is 0 dBFS. The video's sentences then become literally true, and
  every number stays where it already is.

The second is more work and far easier to explain to the user, whose mental model is the
video's. It also turns the current red-from-0 rule into a clip indicator at the top of
the red zone rather than its start.

**Controls the sequence needs, and where they stand.**

| Step | Control | State in Dex |
| --- | --- | --- |
| 1 | Everything down | No such state. A calibration flow would have to save and restore the mix |
| 2 | Per-deck trim to target | TRIM +/-12 dB, LIVE, AUTO at -10 LUFS. Needs the target moved (section 6) and a meter reference to aim at |
| 3 | Peak check, no red | Meters exist. Needs the zones, and a held peak to read |
| 4 | Faders to unity | Already true: LEVEL's top is 0 dB |
| 5 | Master to target | MASTER in the VOLUME popover, 0-1.2, default 0.85. Needs a dB reading or a target mark to be settable this way |
| 6 | Amp or speaker level | **Does not exist.** See below |

**Stage 6 has no home in the app, and on iPad it cannot have one.** Dex has no amplifier
stage: the amp is the Bose SoundLink Flex's own knob, or the device's system volume, which
iOS will not let an app set. The fourth stage can therefore only be *instructed*, never
controlled. In ascending cost: leave it to a help topic behind the (i) key, which is
where instructions live by standing decision; show the target as text in the calibration
sheet; or generate a reference signal for the user to set the speaker against. Dex has no
tone generator today, so the third is new audio work rather than new UI.

**The cue stage needs a level that does not exist.** #71 PHONES is PLANNED in
[CONTROL-MAP](CONTROL-MAP.md): "Dex has cue mix and split/4-channel routing, but no cue
level." Given section 9, that is the gap that matters most in real use, and it should be
Dex's own gain, independent of master, defaulting low.

**Touch and pointer conventions**, for the calibration sheet specifically.

- 44 x 44 pt is Apple's default control size on iOS and 28 x 28 the minimum; macOS is 28
  x 28 default and 20 x 20 minimum, with about 12 pt of padding around bezelled controls
  and 24 pt around unbezelled ones
  ([HIG](https://developer.apple.com/design/human-interface-guidelines/accessibility)).
  The deck keys already overshoot their drawn edge by 2 pt to reach 44 pt of height, not
  yet tried by finger.
- Fine adjustment: modifier-drag on desktop (Avid documents Command/Ctrl-drag), and
  sideways-drag to refine on touch. Dex already has the second: the band faders drop to a
  quarter then a tenth of speed off the fader and read FINE.
- Double-tap reset already exists on FILTER, the bands, LEVEL, the crossfader and tempo.
- If MIDI is ever mapped to these, absolute controls need **pickup / soft takeover** or the
  app value jumps to the knob's position, and endless encoders need a selectable relative
  encoding, because signed-bit, binary-offset and two's-complement are all in use
  ([Ableton](https://www.ableton.com/en/live-manual/12/midi-and-key-remote-control),
  [Steinberg](https://www.steinberg.help/r/cubase-pro/15.0/en/cubase_nuendo/topics/midi_remote/midi_remote_item_properties_r.html)).

## 11. The sequence as a state machine

If a guided flow is built, this is the order and the gate at each step: the video's steps
with the digital substitutions from section 6.

1. **Capture.** Remember TRIM, LEVEL, MASTER and the crossfader. Gate: nothing audible
   changes until the user starts.
2. **Deck A trim.** LEVEL to 0 dB, crossfader to A, MASTER at the chosen target. Play a
   loud section and move TRIM until A's peak sits at the target, with the meter showing
   peak and held peak. Gate: within +/-1 dB of target, no red.
3. **Deck B trim.** The same, crossfader to B. Gate: within +/-1 dB, and within 1 dB of A.
4. **Both.** Crossfader to centre, both LEVEL at 0 dB. Gate: master peak at target +3
   once the sum is included. This is the step the video does not have and the one that
   matters, because it is where two decks overload.
5. **Master.** Set MASTER so the master peak returns to target with both decks open.
6. **Speaker.** Out of the app (section 10). Show the instruction; do not imply control.
7. **Restore.** Put the captured mix back, or leave the calibration in place. That is the
   user's call.

Every number in the flow is one constant, the peak target. Nothing else should be
hard-coded.

## 12. Open questions for the user

1. **The peak target and AUTO level.** Measured at -16: no deck above -6 dBFS, and the
   worst correlated pair at -0.7 dBFS, 0.6 dB under the limiter (section 6). The user
   proposed -12 to -14; -14 leaves 11 of 52 decks above -6 and 1.3 dB of overshoot, -12
   leaves 44. The app stays at -10 until the user chooses by ear.
2. **The meter reference.** Keep dBFS and label the zones, or re-reference 0 dB to -12
   dBFS so the video's language applies. The second changes every meter's appearance and
   changes what red means.
3. **Whether a calibration flow is wanted at all**, or only correct defaults plus the
   help topic. The flow is much more work than a set of defaults.
4. **Cue level** (#71) as its own control, and whether it defaults muted or low.
5. **Whether an in-app reference tone is acceptable**, which a real stage-6 procedure
   needs and which is new audio work.

## Sources

Manufacturer:

- [DJM-900NXS2 manual](https://jundc.com/wp-content/uploads/2022/06/djm900nxs2-1.pdf)
- [AlphaTheta DJM support](https://support.alphatheta.com/en-US/articles/4405910354201?product=4416490599449)
- [DJM-750MK2 help](https://support.alphatheta.com/en-US/articles/4408734012953?product=4416503568025)
- [DJM-A9 help](https://support.alphatheta.com/en-US/articles/15917625233561?product=15882401503257)
- [Xone:92 Mk2](https://www.allen-heath.com/content/uploads/2024/10/Xone92-Mk2-User-Guide.pdf)
- [Xone:96](https://support.allen-heath.com/hc/en-gb/articles/43053562464017-Xone-96-User-Guide)
- [Xone:43](https://www.allen-heath.com/content/uploads/2023/06/AP9968_2_X43_UG.pdf)
- [Xone:24](https://support.allen-heath.com/hc/en-gb/articles/39799443772689-Xone-24-User-Guide)
- [A&H gain and operating levels](https://support.allen-heath.com/hc/en-gb/articles/4403667037457-General-Gain-and-Operating-Levels)
- [Traktor S4 Mk3](https://www.native-instruments.com/fileadmin/ni_media/downloads/manuals/traktor/TRAKTOR_KONTROL_S4_MK3_Manual_English.pdf)
- [NI on levels](https://support.native-instruments.com/support/solutions/articles/69000879489-digital-djing-and-sound-quality-handling-levels-in-traktor)
- [Serato master output](https://support.serato.com/hc/en-us/articles/224966287-Master-Output-Level)
- [Serato gain structure](https://support.serato.com/hc/en-us/articles/202538480-Gain-Structure-for-DJs)
- [Serato prefs](https://support.serato.com/hc/en-us/articles/223363407-DJ-Preferences)
- [rekordbox 7 manual](https://cdn.rekordbox.com/files/20260807093645/rekordbox7.2.18_manual_EN.pdf)
- [Yamaha DZR](https://data.yamaha.com/files/download/other_assets/4/1177634/DZR_DXS-XLF_owners_manual_En_D0.pdf)
- [Electro-Voice ZLX](https://products.electrovoice.com/binary/ZLX_UM_en.pdf)
- [Biamp amp gain](https://support.biamp.com/General/Audio/Setting_amplifier_gain_for_optimal_sound_levels)
- [Extron levels](https://www.extron.com/product/files/helpfiles/dspconfig25/Content/mtrxpr_DMP128/Optimizing_Audio_Levels_mtrxpr.htm)

Standards and hearing:

- [EBU R 128](https://tech.ebu.ch/docs/r/r128.pdf)
- [EBU R 68](https://tech.ebu.ch/docs/r/r068.pdf)
- [AES TD1008](https://www.aes.org/wp-content/uploads/2024/01/20210924_TD1008_v3.13.pdf)
- [WHO venues](https://iris.who.int/bitstream/handle/10665/352277/9789240043114-eng.pdf)
- [NIOSH](https://www.cdc.gov/niosh/bulletin/2016/noise.html)
- [OSHA](https://www.osha.gov/noise)
- [HSE events](https://www.hse.gov.uk/Event-Safety/noise.htm)
- [Spotify loudness](https://support.spotify.com/us/artists/article/loudness-normalization/)

Platform:

- [Apple outputVolume](https://developer.apple.com/documentation/avfaudio/avaudiosession/outputvolume)
- [Apple headphone safety](https://support.apple.com/guide/iphone/check-your-headphone-audio-levels-iph0596a9152/ios)
- [Apple HIG accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [WCAG 2.2](https://www.w3.org/TR/WCAG22/)
- [Ableton MIDI](https://www.ableton.com/en/live-manual/12/midi-and-key-remote-control)
