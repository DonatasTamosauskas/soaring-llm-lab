# UI and game flow

Everything a player touches that is not a wingbeat.

## The one rule

**Nothing that a player has to read is bolted to their face.**

A full-screen panel locked to the head cannot be looked away from, moves with
every twitch, and fights the vestibular system for as long as it is up. So every
menu in this game is an object standing in the sky: it is placed in front of the
player when it opens and then it stays exactly where it is, in the world, while
they look around it, lean past it and point at it.

The one exception is the in-flight readout (`HUD`), which is head-referenced
because it has to be glanceable at 50 m/s — and it is held to two lines, one
bar, one arrow and one transient banner for exactly that reason. It got
*smaller* during this work: the end-of-run summary used to be an eight-line
head-locked wall of text and is now a world-space panel.

## The flow

```
launch ──► MAIN ──FLY──► flying ──menu button──► PAUSE ──KEEP FLYING──► flying
             │                       │                    │
             ├─► HOW TO FLY ─BACK────┤                    ├─► HOW TO FLY ─BACK─┐
             ├─► COMFORT ────BACK────┤                    ├─► COMFORT ───BACK──┤
             └─► QUIT                │                    └─► START A NEW RUN ─┘
                                     │
                       lives run out ▼
                                  SUMMARY ──FLY AGAIN──► flying
                                     │      (or a wingbeat)
                                     └─► COMFORT / QUIT
```

Two invariants hold this together and both are asserted:

- **Every screen has a way out.** `MenuModel.escape_of()` returns the row that
  hands the sky back, and `UITests` fails if any screen ever returns -1 — this
  is the whole "no dead ends" rule in one line. It also checks that the way out
  is at one end of the list rather than buried in the middle of it.
- **Back returns where you came from.** The screen stack means `COMFORT` opened
  from the pause menu returns to the pause menu, and `COMFORT` opened from the
  summary returns to the summary. Closing a pause screen over a finished run
  lands back on the summary rather than in a sky with nothing left to play.

## Pausing

`get_tree().paused = true`, with `GameMenu` set to `PROCESS_MODE_ALWAYS`. The
world, the flock, the player and the HUD all stop, and `MenuProbe` proves it by
measuring that the bird moves less than a millimetre across half a second of
paused frames.

**The XR trackers are deliberately exempt.** `GameMenu.attach()` sets
`PROCESS_MODE_ALWAYS` on `XROrigin3D`, `XRCamera3D` and both `XRController3D`s,
because pausing the tree otherwise stops them copying tracker poses into
transforms — which freezes the view inside the headset while the player's actual
head keeps moving. That is the single most reliable way to make somebody ill
that this codebase contains, and it is invisible on a desktop.

The audio generator stops being filled while paused and therefore goes quiet.
That is the wanted behaviour and it is free.

The summary is the one screen that does **not** pause: the bird keeps gliding,
because freezing a player in mid-air in a headset is how you get one taken off,
and because a wingbeat is what starts the next run.

## Pointing

`MenuLayout` is pure geometry with no scene in it, for the same reason
`FlightModel` has none: "can a player hit this row from a metre and a half away
with a hand that wobbles" is a question with a numeric answer.

| | |
|---|---|
| Panel distance | 1.55 m, centre 10 cm below eye level |
| Row height | 0.10 m — **3.7°** of visual angle |
| Row text | 0.056 m — **2.1°** |
| Body text | 0.044 m — **1.6°** |
| Panel width | 1.02 m — **37°**, a panel and not a wall |

`UITests` fires a ray from the player's head at every row of every screen, at
five head poses including a 70° bank and looking straight up, and asserts the
ray lands on the row it was aimed at — and still does with a degree of wobble
either way. The same test rejects NaN origins, zero-length directions and rays
parallel to the panel, because a controller set down mid-menu hands you a basis
full of NaN.

In a headset the ray comes from the **aim** pose, not the grip pose the wings
hang off: grip points where the fist points, aim points where a person thinks
they are pointing. The beam stops at the panel and a dot marks the landing
point.

| Input | Does |
|---|---|
| `menu_button` / `by_button` | open the menu, or back out of where you are |
| `trigger_click` / `ax_button` / `select_button` | press the row you are pointing at |
| Escape (desktop) | the same as the menu button |
| Mouse (desktop) | point and click; arrow keys and Enter also work |

## Settings

Every knob is declared once in `PlayerSettings.SPECS` — range, step, wording,
and which `Tuning` field it drives — and the settings screen is built from that
declaration. A new comfort option is one entry rather than an entry plus a row
plus a save line plus a load line, which is how settings screens fall out of
step with what they claim to control. `UITests` reads `Tuning.gd` and fails if a
setting names a field that does not exist or disagrees with its default.

| Setting | Range | Drives |
|---|---|---|
| Comfort vignette | 0–100 % | `Tuning.comfort_vignette` |
| Horizon roll | 0–100 % | `Tuning.visual_roll_fraction` |
| Turn sensitivity | 0.5×–1.6× | `Tuning.tilt_sensitivity` |
| Pointing hand | left / right | which controller aims |
| Prey marker | on / off | the HUD's guidance chevron |

Plus `RECENTRE MY WINGS`, which finally binds `WingInput.recentre()` — it had
been sitting there unbound since the input work — and, in a headset, recentres
the view as well.

**Numbers wrap.** In a headset the only input the menu has is "press the row",
so a value that stopped dead at its ceiling would be a comfort setting a player
could turn up and never turn back down.

Settings persist to `user://soaring.cfg`. Comfort settings that reset every
launch are worse than none: a player who has found the vignette strength that
stops them feeling ill will not go looking for it twice.

## Teaching

`Coach` watches for the four gestures in the order that stops you falling out of
the sky — spread, flap, bank, tuck — asks for one at a time, and each prompt
disappears the moment the player actually does it. It is pure and scene-free, so
"does shaking the controllers count as a wingbeat" is a question the test suite
already knows how to ask (it does not: the coach counts rising edges of
`FlightCommand.stroke_speed`, which `WingInput` only produces for a real
downstroke after a real arm-raise).

- A lesson never disappears before it has been up for 1.4 s, so nothing flashes
  past unread.
- One lesson that a player will not do does not block the rest: after 32 s it
  moves on.
- The whole thing expires after three minutes, and is remembered as done in the
  settings file, so a returning player is never taught again. `HOW TO FLY →
  TEACH ME AS I FLY` asks for it back.
- It never speaks over the `WINGS FOLDED` / `PERCHED` / `STALL` status line —
  an instruction and a warning saying the same thing at the same moment is this
  game shouting.

## Colour

`UITheme` is the UI's palette, separate from the world's `Palette` because a
menu has to stay legible against a snowfield, a gorge and a night sky alike.
`UITests` scans `scripts/ui/` and fails if any other file names a colour — the
same discipline `PaletteTests` holds the world to.

## Running it

```bash
tests/ui.sh                    # the menu probe: 35 checks through the real game
godot --xr-mode off -- --menu=main|pause|settings|controls \
      --capture=/tmp/m.png --capture_delay=6
godot --xr-mode off -- --demo=ended --capture=/tmp/s.png --capture_delay=9
godot --xr-mode off -- --menu=0    # skip the menu, drop straight into flight
```

## What is not here

- No quit confirmation, no credits, no key rebinding, no audio settings (there
  is no mixer to bind them to yet).
- No thumbstick input: a setting is changed by pressing its row, which is why
  numbers wrap.
- The summary is per-run. Only the best score persists between sessions.
- Button presses on real hardware are unverified — the pointing path was
  verified against the Meta XR Simulator, but nobody has pulled a physical
  trigger on this menu.
