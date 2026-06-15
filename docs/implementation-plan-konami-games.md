# Implementation Plan — Adding Jungler, Tactician, Loco-Motion & Commando

> Branch: `morearcades`
> Goal: add support for **Jungler**, **Tactician** (tactcian), **Loco-Motion** (locomotn) and **Commando** (commsega) to the Arcade-RallyX MiSTer core.
> Status: planning. This document is the design spec; no RTL has been changed yet.

---

## 1. Executive summary

These four games are **not** Namco Rally-X hardware. In MAME they live in the same driver
(`src/mame/namco/rallyx.cpp`) because they **copy Rally-X's video**, but they run on
**Konami "Loco-Motion" hardware**, which differs from Rally-X in three load-bearing ways:

1. **Sound is a completely different subsystem** — a *second Z80 + two AY-3-8910 PSGs*
   (MAME `timeplt_audio` / `LOCOMOTN_AUDIO`), with an RC filter network. Rally-X's Namco
   WSG wavetable synth and the discrete "BANG" generator are **not present**.
2. **CPU memory map and interrupt model differ** — `jungler_map` (not `rallyx_map`):
   program ROM up to `0x7FFF`, DSW split across two ports, a sound-latch write port, an
   LS259 control latch with reassigned bits, and **NMI-on-VBLANK** instead of the Rally-X
   maskable IRQ + interrupt-vector latch.
3. **Video is Rally-X-derived but parameterised** — reversed tile bit-planes, extended
   tile/sprite codes (double-size GFX on locomotn/commsega), a single combined sprite flip
   bit, a different palette resistor network, an optional hardware **starfield**, different
   radar-dot attribute decoding, and **ROT90 (vertical) orientation**.

This is therefore a **substantial port**, not a set of MRA remaps. The realistic deliverable
is: extend the existing core into a **multi-game RBF** that selects between the Namco
(Rally-X / New Rally-X) datapath and the Konami (Loco-Motion) datapath via a game-select
byte delivered in the MRA, plus four new `.mra` files.

### Recommended architecture decision

**Single multi-game RBF with a game-select byte (MRA `<rom index="1">`).** This matches the
MiSTer convention (Pac-Man, Galaga-family cores) and the user's "add to *this* core" intent.
The alternative — a separate `locomotn` RBF — duplicates the shared video/CPU scaffolding and
splits maintenance. Cost of the single-RBF approach: both sound subsystems are synthesised and
the Konami one (2× AY + 2nd Z80) is gated off for Rally-X. Given the small device footprint of
these chips on a 5CSEBA6U23I7, this is acceptable.

> **Open question for the user:** confirm single-RBF multi-game vs. a dedicated `locomotn`
> core. The phases below assume single-RBF. If a separate core is preferred, Phases 1–3 are
> unchanged; only the scaffolding in Phase 0 and the `.qsf`/release naming differ.

---

## 2. Per-game hardware summary

| | Jungler | Tactician | Loco-Motion | Commando (commsega) |
|---|---|---|---|---|
| MAME set | `jungler` | `tactcian` | `locomotn` | `commsega` |
| Hardware | Konami Loco-Motion | Konami Loco-Motion | Konami Loco-Motion | Sega (same board family) |
| Orientation | **ROT90** | ROT90 | ROT90 | ROT90 |
| Prog ROM | 4×4K (0x0000-0x3FFF) | 6×4K (0x0000-0x5FFF) | 5×4K (0x0000-0x4FFF) | 5×4K (0x0000-0x4FFF) |
| GFX1 size | 0x1000 (256 chr/64 spr) | 0x2000 (512/128) | 0x2000 (512/128) | 0x2000 (512/128) |
| Sound ROM | 1×4K | **2×4K** (0x0000-0x1FFF) | 1×4K | 1×4K |
| Tile-priority | **off** (Jungler) | on | on | on |
| Starfield | enabled | allocated, unused | enabled | allocated, unused |
| Visible area | 36×28 (288×224) | 36×28 | **32×28 (256×224)** | **32×28 (256×224)** |
| Sprite slot base | 0x14 | 0x14 | 0x14 | **0x00** (more sprites/bullets) |
| Scroll regs used | yes (a130/a140) | yes | minimal | minimal |
| screen_update | `jungler` | `locomotn` | `locomotn` | `locomotn` |

Shared by all four: Konami `jungler_map`, NMI-on-VBLANK, `timeplt`/`locomotn` audio,
`jungler_charlayout`/`jungler_spritelayout` (planes `{4,0}`), `jungler_palette` (1k pull-down
on R, G **and** B + 64 star pens), the right-side non-scrolling radar/fg strip (column 28×8),
master clock 18.432 MHz, Z80 @ 3.072 MHz, pixel clock 6.144 MHz, audio sub-board 14.318 MHz.

---

## 3. Gap analysis against the existing core

Existing core (`rtl/fpga_nrx.v`, `nrx_video.v`, `nrx_sprite.v`, `nrx_sound.v`,
`Arcade-RallyX.sv`):

| Area | Rally-X (today) | Konami games (needed) | Effort |
|---|---|---|---|
| Prog ROM decode | `ad[15:14]==00` (16K) | up to `0x7FFF` (32K) | small |
| Inputs | DSW at `$A1xx`, CTR1/CTR2 at `$A0xx` | P1 `$A000`, P2 `$A080`, DSW1 `$A100`, DSW2 `$A180` | small |
| Control latch | inline at `$A18x` (BANG/IE/FLIP/lamps) | LS259 `$A180-7` (SOUNDON/NMImask/MUT/FLIP/coin1/-/coin2/STARSON) | small |
| Interrupt | VBLANK→maskable IRQ + IO vector latch | VBLANK→**NMI**, masked by latch Q1; no vector latch | small |
| Sound | Namco WSG + BANG | **2nd Z80 + 2× AY-3-8910 + RC filters** | **large** |
| Tile planes | `{CHRO[4],CHRO[0]}` (planes 0,4) | planes `{4,0}` reversed | small (swap) |
| Tile code | 8-bit `CHRC` | 9-bit extended (locomotn/commsega) | medium |
| Sprite code | 6-bit | 7-bit + bank (locomotn) | medium |
| Sprite flip | independent X/Y | single combined bit (locomotn) | small |
| Palette→RGB | 3R/3G/2B bit weighting | 1k pull-down on all 3 (Konami) | small (game-select weighting) |
| Starfield | none | LFSR starfield (jungler/locomotn) | medium |
| Bullet/dot decode | radarattr bit0, code bits 3:1 | radarattr bit3, code bits 2:0; locomotn `y=252` | small |
| Orientation | ROT0 | **ROT90** (use `arcade_video` rotate or MRA) | small |
| Visible area | 288×224 | 256×224 for locomotn/commsega | small |

---

## 4. Implementation phases

### Phase 0 — Game-select scaffolding (`Arcade-RallyX.sv`)

1. Add a `<rom index="1">` one-byte game-select read in `emu`, mirroring the existing
   `dips` pattern:
   ```verilog
   reg [3:0] game;       // 0=Rally-X, 1=New Rally-X, 2=Jungler, 3=Tactician,
   always @(posedge clk_sys)   // 4=Loco-Motion, 5=Commando
       if (ioctl_wr && (ioctl_index==1) && (ioctl_addr==0)) game <= ioctl_dout[3:0];
   ```
   (New Rally-X today carries an empty `<rom index="1">`; reuse this slot.)
2. Derive a one-hot/category signal: `wire is_konami = (game >= 2);`. Thread `game`/`is_konami`
   into `fpga_NRX` as a new input port.
3. Add the Konami sound-board clock. The audio sub-board runs at **14.318181 MHz**, independent
   of the 18.432 MHz main clock. Add a PLL output (extend `rtl/pll`) for ~14.318 MHz, or derive
   the AY/Z80 enables from the existing clocks via a fractional CE — **prefer a real PLL output**
   for fidelity (sound CPU 1.7898 MHz, AY 1.7898 MHz). Keep the user PLL module/instance named
   `pll` (SDC contract).
4. Audio width: today `AOUT = {oSND,8'h0}` (unsigned 8-bit). The Konami path produces signed
   mixed PCM. Add a mux selecting the active sound source and set `AUDIO_S` accordingly
   (Namco = unsigned, Konami AY mix = treat as signed after centering). Per-channel feed for the
   framework mixer is preferred but mono is acceptable (this hardware is mono).

### Phase 1 — CPU memory map, IO & interrupts (`rtl/fpga_nrx.v`)

Make the address decode and interrupt logic conditional on `is_konami`. Concretely:

1. **Program ROM**: widen `cpurom` to 15 bits (`DLROM #(15,8)`) and decode `ad[15]==0`
   (0x0000-0x7FFF) when Konami, keeping `ad[15:14]==00` for Namco. The ROM download gate
   becomes `ROMEN & (ROMAD[15]==0)` for the 32K window.
2. **Inputs** (Konami): `$A000`→P1, `$A080`→P2, `$A100`→DSW1, `$A180`→DSW2. Note `$A100`
   is *read* DSW1 but *write* sound-latch, and `$A080` is *read* P2 but *write* watchdog —
   split read/write decode. Build `iCTR1/iCTR2/iDSW1/iDSW2` from the joystick bits with the
   correct per-game bit order (see §2 of the MAME input report — directions, COIN1=0x80,
   COIN2=0x40, START in P2, SERVICE1 on P1 bit2).
3. **Radar/bullet attr** at `$A000-$A00F`, **mirrored to `$A0F0`** (Konami writes `$A03x`):
   decode `ad[15:8]==8'hA0 & (ad[7:4]==0 || mirror)`. The existing `aram0` write decode
   (`CEAT` in `nrx_video.v`, `CPUADDR[15:4]==12'hA00`) already covers `$A00x`; extend its mask
   to ignore `ad[7:4]` for the mirror.
4. **Scroll**: `$A130`→scrollx, `$A140`→scrolly (already handled in `nrx_video.v`, but it
   subtracts 3 from HSCR — that −3 is a *Rally-X-only* `set_scrolldx(3,3)`; gate it off for
   Konami).
5. **LS259 control latch** `$A180-$A187` (`write_d0`, bit = `odt[0]`, addr low 3 bits select):
   - Q0 `SOUNDON` → rising-edge → pulse sound-CPU IRQ trigger (Phase 3)
   - Q1 `INTST` → **NMI mask** (`inte`)
   - Q2 `MUT` → sound mute
   - Q3 `FLIP` → screen flip
   - Q4 coin counter 1, Q5 unused, Q6 coin counter 2, Q7 `STARSON` → starfield enable
   Replace the Rally-X latch block (BANG/iewr/flip/lamps) with a `game`-selected version.
6. **Interrupt**: Konami asserts **NMI** on VBLANK gated by Q1. Wire `T80s.NMI_n` low on the
   VBLANK edge when enabled, instead of the IRQ path. Drop the IO-port interrupt-vector latch
   (`intv`/`iowr`) for Konami — there is no `AS_IO` map and no IM2 vector. Keep `irq_n` =1.
7. **Watchdog** `$A080` write: tie to a reset-suppression counter or simply ignore (MiSTer
   cores typically no-op the watchdog; safe because reset is host-driven).

### Phase 2 — Video (`rtl/nrx_video.v`, `rtl/nrx_sprite.v`)

Parameterise the existing pipeline by `game`/`is_konami`. The radar split-screen structure,
the BG/FG tilemaps, the 3-pass bullet/sprite mixer and the CLUT/palette PROM lookups are all
**reused** — the Konami games keep them.

1. **Tile bit-plane order**: today `BGCOL <= { BGPL, CHRO[4], CHRO[0] }`. Konami uses planes
   `{4,0}` reversed → `{ BGPL, CHRO[0], CHRO[4] }`. Swap the two color bits when `is_konami`.
   Apply the same swap in `nrx_sprite.v` for sprite pixels.
2. **Tile code extension** (locomotn/commsega, GFX1 = 0x2000): MAME forms
   `code = (code & 0x7f) + 2*(attr & 0x40) + 2*(code & 0x80)` (9-bit). Widen `chrrom` to
   13 address bits (`DLROM #(13,8)`) and build `CHRA` accordingly when the game uses the
   double-size GFX. Jungler keeps the 12-bit/256-char layout.
3. **Tile flip** (locomotn family): single combined bit — flip both X and Y from `attr[7]`,
   vs Rally-X independent `attr[6]`/`attr[7]`. Gate the `BGFX`/`BGFY` derivation on game.
4. **Tile priority**: Rally-X / locomotn / commsega / tactcian use the priority pass; **Jungler
   disables it**. Add a `tile_prio_en` game flag controlling the second draw pass / `BGF` use.
5. **Sprites** (`nrx_sprite.v`): Konami forms
   `code = ((spr&0x7c)>>2) + 0x20*(spr&0x01) + ((spr&0x80)>>1)` (7-bit + bank) and a single
   flip bit (`spr&2` drives both X and Y). Extend `SPCHRADR` width and the flip logic by game.
   Set the sprite-scan base: `0x14` for jungler/tactcian/locomotn, **`0x00` for commsega**.
6. **Bullets / radar dots**: Konami X high-bit from `radarattr` **bit3** (`<<5`) and dot code
   from bits **2:0** (vs Rally-X bit0 and bits 3:1); locomotn family uses `y = 252 - radary`
   (Rally-X/jungler use 253); drop the Rally-X `flip ? x-=3` fixup. Game-select these.
7. **Palette → RGB weighting**: Rally-X = 1k pull-down on B only; Konami = 1k pull-down on R,
   G **and** B. Today the conversion is the fixed bit-spread in `Arcade-RallyX.sv:419`
   (`{oPIX[7:6],2'b00,oPIX[5:3],1'b0,oPIX[2:0],1'b0}`). Add a Konami weighting variant (or a
   small per-bit resistor-weight LUT) selected by `is_konami`. This is a color-accuracy nicety;
   first bring-up can reuse the Rally-X spread.
8. **Starfield** (jungler, locomotn when `STARSON`): add a Scramble/Galaxian-style LFSR star
   generator producing the 64 star pens (palette indirect `0x20-0x5F`, pens `0x104-0x143`),
   mixed where no opaque tile/sprite/bullet pixel is present, gated by Q7. New small module
   `rtl/nrx_stars.v`. Tactician/commsega allocate the pens but never enable — safe to leave
   star output forced off for those.
9. **Orientation / visible area**: all four are ROT90. Handle rotation via `arcade_video`'s
   built-in CW/CCW framebuffer rotate (set the rotate option + `VIDEO_ARX/ARY`) **or** via the
   MRA `<rotation>` + screen_rotate module. For locomotn/commsega, constrain the visible width
   to 256 (32×8); for jungler/tactcian keep 288 (36×8). Adjust `HVGEN` blanking or the active
   window by game.

### Phase 3 — Konami sound subsystem (new RTL)

This is the largest new piece. Build it as a self-contained module `rtl/locomotn_sound.v`
that is instantiated alongside `NRX_SOUND` in `fpga_NRX` and selected by `is_konami`.

Building blocks:
- **2nd Z80**: instantiate another `T80s` (the core already vendors T80 in `rtl/cpu/`).
  Clock/CE ≈ **1.789773 MHz** (14.318181 MHz ÷ 8).
- **2× AY-3-8910**: use **jotego `jt49`** (`jt49_bus` wrapper presents the AY address/data bus;
  exposes the three channels individually, which we need for the per-channel filters). Add as a
  git submodule under `rtl/` (with its `.qip`) or vendor the sources; register in `files.qip`.
  Both clocked at ≈ 1.789773 MHz.

Sound-CPU memory map (`locomotn_sound_map`):
| Range | Function |
|---|---|
| `0x0000-0x1FFF` | sound ROM (4K for 3 games, 8K for tactcian) |
| `0x2000-0x23FF` (mirror +0x0C00) | work RAM (1K) |
| `0x3000-0x3FFF` | filter control — **the low 12 address bits are the data** |
| `0x4000` (mirror +0x0FFF) | AY1 data r/w |
| `0x5000` (mirror +0x0FFF) | AY1 address latch |
| `0x6000` (mirror +0x0FFF) | AY2 data r/w |
| `0x7000` (mirror +0x0FFF) | AY2 address latch |

Glue logic:
- **Command latch**: main CPU write `$A100` → 8-bit latch. Sound CPU reads it via **AY1 port A**
  (`port_a` read). Cross-domain: latch is written in the main-CPU clock domain and read in the
  sound-CPU domain — use a simple register; a 2-FF synchronizer is unnecessary for a stable
  byte but add one on the strobe if needed (see HDL guide §23).
- **IRQ trigger**: LS259 Q0 (`SOUNDON`) rising edge → assert sound-Z80 INT with vector `0xFF`
  (RST 38h), HOLD_LINE/auto-ack on the Z80's interrupt-acknowledge. Track previous Q0 state for
  edge detection.
- **AY1 port B timer**: free-running counter — `÷512` of the sound-Z80 clock feeding a `÷10`
  decade, upper nibble read back through a 10-entry LUT
  `{00,10,20,30,40,90,A0,B0,A0,D0}` indexed by `(cycles/512)%10`. The sound program polls this
  for tempo. Implement as a cycle counter (or CE counter) + LUT.
- **Filter network**: 6 channels (3 per AY), each a switched-RC low-pass. The 12-bit address
  written to `$3000` carries 2 bits/channel:
  `ay2ch0=[1:0] ay2ch1=[3:2] ay2ch2=[5:4] ay1ch0=[7:6] ay1ch1=[9:8] ay1ch2=[11:10]`.
  Cap select: `00`→pass-through, `01`→0.22 µF, `10`→0.047 µF, `11`→both. Model each as a
  first-order IIR low-pass (LOWPASS_3R: R1=1000, R2=5100, R3=0 → R≈837 Ω; cutoffs ≈ 864 Hz /
  4046 Hz / 712 Hz / none). Reprogram the coefficient on each `$3000` write.
- **Mixing**: 6 channels × 0.60 gain → per-channel filter → sum → mono → apply `MUT` mute.
  Output 16-bit signed to the Phase-0 audio mux.

> Reference: jotego/jt49 (https://github.com/jotego/jt49). This is the standard AY core across
> MiSTer arcade cores and exposes per-channel outputs.

### Phase 4 — MRA files (`releases/`)

One `.mra` per game. ROM part order **must** follow the MAME `ROM_START` sequence (§5). Use:
- `<rbf>rallyx</rbf>` (same RBF) — or the new core name if a separate RBF is chosen.
- `<setname>` = MAME set name (jungler/tactcian/locomotn/commsega) for per-game saves/DIPs.
- `<rom index="1">` carrying the one game-select byte (Phase 0 mapping).
- `<rotation>vertical (cw)</rotation>` metadata; actual rotation handled in core/arcade_video.
- Per-game `<switches>`/`<dip>` from the MAME INPUT_PORTS (§3 of the driver report).
- ROM stream layout (index 0), concatenated in this order: **maincpu → gfx1 → gfx2(dots) →
  proms(palette 0x20 + CLUT 0x100 + 2 unused PROMs) → sound ROM(s)**, matching the FPGA download
  address decode chosen in Phases 1–3. Pin down each part's `crc`, `name`, `length`.

The existing `New Rally-X.mra` / `Rally-X (32k Ver).mra` get a non-empty `<rom index="1">`
game-select byte (0 / 1) so they keep working with the multi-game decode.

### Phase 5 — CONF_STR, DIPs, build, release

1. **CONF_STR** (`Arcade-RallyX.sv`): the OSD `DIP;` block is driven by the MRA `<switches>`,
   so per-game DIPs come from the MRA. Keep the Aspect/Pause/Hiscore options. Consider an
   explicit core title rename only if shipping a separate RBF.
2. **Hiscore**: `rtl/hiscore.v` is generic and table-driven via the MRA `<rom index="3">` config
   blob — provide per-game hiscore config bytes in each MRA (or omit hiscore for the Konami games
   initially).
3. **Build** (Quartus 17.0.x, top `sys_top`, all new RTL in `files.qip` — **not** the `.qsf`).
   Add: `rtl/locomotn_sound.v`, `rtl/nrx_stars.v`, the jt49 sources/`.qip`, and a second T80 is
   just another instance (no new files). Verify M10K budget after adding the sound ROM/RAM and
   widened GFX ROM (553-block budget on 5CSEBA6U23I7).
4. **Release**: `clean.bat` then recompile to refresh `build_id.v`; name the `.rbf`
   `Arcade-RallyX_YYYYMMDD.rbf` (or the new core name).

---

## 5. Per-game ROM maps (for the MRA `<rom index="0">` streams)

Part order = MAME `ROM_LOAD` order. Offsets are the running concatenation offset in the FPGA
download stream; the FPGA decode in Phases 1–3 must match these region boundaries. (CRCs from
the MAME research — verify against the MAME version targeted.)

### Jungler (`jungler`) — game byte 2
```
maincpu (0x0000): jungr1 4K, jungr2 4K, jungr3 4K, jungr4 4K          -> 0x0000-0x3FFF
gfx1    (0x4000): 5k 2K, 5m 2K                                        -> 0x4000-0x4FFF
gfx2    (dots)  : 82s129.10g 256B
proms           : 18s030.8b 32B (palette), tbp24s10.9d 256B (CLUT),
                  18s030.7a 32B, 6331-1.10a 32B (both unused)
sound (tpsound) : 1b 4K
```

### Tactician (`tactcian`) — game byte 3
```
maincpu : tacticia.001..006  6×4K                                     -> 0x0000-0x5FFF
gfx1    : tacticia.c1 4K, tacticia.c2 4K  (0x2000)
gfx2    : tact6301.004 256B
proms   : tact6331.002 32B, tact6301.003 256B, tact6331.001 32B
sound   : tacticia.s2 4K, tacticia.s1 4K  (0x0000-0x1FFF, TWO ROMs)
```

### Loco-Motion (`locomotn`) — game byte 4
```
maincpu : 1a.cpu,2a.cpu,3.cpu,4.cpu,5.cpu  5×4K                       -> 0x0000-0x4FFF
gfx1    : 5l_c1.bin 4K, c2.cpu 4K  (0x2000)
gfx2    : 10g.bpr 256B
proms   : 8b.bpr 32B, 9d.bpr 256B, 7a.bpr 32B, 10a.bpr 32B
sound   : 1b_s1.bin 4K
```

### Commando / commsega (`commsega`) — game byte 5
```
maincpu : csega1..csega5  5×4K                                        -> 0x0000-0x4FFF
gfx1    : csega7 4K, csega6 4K  (0x2000)   [note: 7 then 6]
gfx2    : gg3.bpr 256B
proms   : gg1.bpr 32B, gg2.bpr 256B, gg0.bpr 32B, tt3.bpr 32B
sound   : csega8 4K
```

---

## 6. Risks, unknowns & decisions

- **[Decision] Single RBF vs separate core** — see §1. Confirm with user before Phase 0.
- **[Risk] Sound subsystem is the critical path.** A 2nd Z80 + 2× AY + filters is the bulk of
  the work and the biggest fidelity risk. Mitigate by bringing it up standalone (feed it canned
  command bytes, scope the AY register writes) before integrating. jt49 is well-proven, lowering
  risk on the PSG itself; the filter network and the port-B timer are the bespoke parts.
- **[Risk] ROT90 + radar split interaction.** Rotation plus the right-side non-scrolling radar
  strip and the per-game visible-width difference need careful handling — verify against MAME
  screenshots early.
- **[Risk] Palette resistor weighting** is approximate today (fixed bit spread). The Konami
  1k-on-all-three pull-down changes color balance; first bring-up can ignore it, but plan a
  weighting LUT for accuracy.
- **[Unknown] Exact 14.318 MHz PLL realisation** — confirm the existing `rtl/pll` can add a
  third output at the needed frequency within Cyclone V PLL constraints, or derive a clock-enable.
- **[Unknown] CRCs / MAME version** — lock the target MAME version and re-verify every ROM CRC
  and part length before finalising the MRAs (CRCs drift across MAME releases; use `crc` +
  `zip` pipe-fallback for resilience).
- **[Verify] Watchdog** — confirm ignoring the `$A080` watchdog write is safe (host-driven reset
  makes this standard for MiSTer ports).

---

## 7. Verification plan

1. **CPU/IO bring-up**: load a Konami program ROM, confirm it runs past its RAM/ROM test and
   reaches attract mode (NMI firing, inputs read at the right ports).
2. **Video**: compare attract-mode frames against MAME for each game — tiles (plane order),
   sprites (code/flip), bullets/dots, palette, radar strip, starfield (jungler/locomotn),
   visible width (256 vs 288), ROT90 orientation.
3. **Sound**: standalone sound-CPU sim first (AY register write trace vs MAME), then in-system —
   confirm music/SFX trigger on the right commands and the filters/timer behave.
4. **DIPs**: toggle each MRA `<dip>` and confirm the documented effect (coinage, lives,
   difficulty, cabinet).
5. **Regression**: confirm Rally-X and New Rally-X still boot and play correctly through the
   multi-game decode (game bytes 0/1).
6. **Hardware**: `/media/fat/MiSTer rallyx.rbf <game>.mra` on a DE10-Nano; check the loader log
   (part offsets, bytes sent), OSD DIPs, joystick mapping, audio.

---

## 8. File-change checklist

| File | Change |
|---|---|
| `Arcade-RallyX.sv` | game-select byte (idx 1), `is_konami`, 14.318 MHz PLL out, audio source mux, ROT90/aspect, palette-weight select, thread `game` into core |
| `rtl/fpga_nrx.v` | conditional memory map (32K ROM, split DSW, sound latch, LS259 reassign), NMI-on-VBLANK, instantiate `locomotn_sound`, drop IO vector latch for Konami |
| `rtl/nrx_video.v` | plane-order swap, tile-code extension, combined flip, tile-priority gate, bullet decode, scroll −3 gate, star mix |
| `rtl/nrx_sprite.v` | extended sprite code + bank, combined flip, commsega base 0x00 |
| `rtl/nrx_stars.v` | **new** — LFSR starfield generator |
| `rtl/locomotn_sound.v` | **new** — 2nd Z80 + 2× AY (jt49) + filters + timer + latch + IRQ |
| `rtl/jt49/*` + `.qip` | **new** — vendored/submoduled AY-3-8910 core |
| `files.qip` | register `locomotn_sound.v`, `nrx_stars.v`, jt49 qip |
| `rtl/pll/*` | add ~14.318 MHz output |
| `releases/Jungler.mra` … `Commando.mra` | **new** — 4 MRAs |
| `releases/New Rally-X.mra`, `Rally-X (32k Ver).mra` | add game-select byte (idx 1 = 1 / 0) |
| `CLAUDE.md` | document the multi-game architecture once implemented |

---

## 9. References

- MAME driver: `src/mame/namco/rallyx.cpp`, `src/mame/namco/rallyx_v.cpp`
- MAME audio: `src/mame/shared/timeplt_a.cpp` / `.h` (`timeplt_audio` / `LOCOMOTN_AUDIO`)
- AY-3-8910 FPGA core: jotego/jt49 — https://github.com/jotego/jt49
- MiSTer framework rules: `docs/mister-framework-reference/` (MRA §52, CONF_STR §11, audio §41,
  video §40, porting checklist §91)
- HDL guidelines: `docs/hdl-coding-guidelines/` (CDC §23, memory inference §30, FSMs §14)
</content>
</invoke>
