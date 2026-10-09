# The sky, and what lives in it

The rule this whole area is built on is the one it inherited: **an NPC moves only
by flying**. Every bird owns a `FlightModel` and steers it with the same four
numbers the player's hands produce — bank, angle of attack, span, stroke speed —
and the only sanctioned exception is `BirdNPC._avoid_ground`, which comments its
own reasoning. Nothing here teleports, nudges a velocity, or follows a path.

That constraint is not a limitation to work around. It is the reason any of this
is legible: when a hawk climbs before it dives at you, you can see that it is
buying speed, because it is the same trade you are making with your own arms.

---

## The one thing that changed underneath everything

A bird's wingbeat used to be free. The player's costs a real arm and is gated by
`WingInput` to about one beat a second; an AI's cost nothing at all, and could be
sustained for ever. Every downstream problem in this area came from that one
asymmetry:

- prey escaped by climbing, flat out, indefinitely — the game-loop work measured
  seven chases in a row broken off with the hunter 20–37 m *below* its quarry and
  down at 6–14 m/s, and had to invent a panic-stamina timer in `GameManager` to
  make hunting possible at all;
- nothing in the world had any reason to land, so 4196 published perch points had
  nothing sitting on them and `State.PERCH` was unreachable;
- nothing had any reason to use a thermal.

`BirdNPC.energy` is the fix. Reserves run 0..1. Flapping spends
`FLAP_DRAIN` per second (about nine seconds of flat-out flapping empties a bird),
gliding pays back at about a third of that rate, gliding *in lift* rather better, and
a rest on a branch fastest of all. Below `TIRED_ENERGY` the stroke fades out
smoothly rather than switching off.

Everything else in this document falls out of that one number:

| behaviour | why it exists now |
|---|---|
| a stalk before a stoop | height is the only speed a bird can afford |
| prey diving for the deck | diving is free; climbing is not |
| circling in thermals | lift is height nobody pays for |
| roosting | reserves come back fastest sitting down |
| chases that end | the loser of a chase is whoever runs out first |

---

## Who knows what: `Flock`

`scripts/ai/Flock.gd` is a plain `RefCounted` that knows nothing about the
player. It owns:

- a **spatial hash** over the flock (120 m cells, rebuilt at 3.3 Hz);
- **who is looking at whom** — the nearest edible bird within `HUNT_RADIUS`
  (62 m), the nearest bird that could eat you within `THREAT_RADIUS` (50 m), with
  a `MEMORY` factor of 1.7 once something has already been noticed;
- **line of sight**, sampled against `WorldBuilder.height_at` — so a ridge really
  does break a chase;
- **perch claims**, so a branch belongs to one bird, plus the squabble rule;
- **who ate whom**, resolved with `GameRules.within_strike` — the same cone and
  reach the player is judged by.

`GameManager` still owns the player's part of it: whether a bird has noticed the
*player* is decided there, with the stamina constants the game-loop work measured
against a human. A bird merges the two in `BirdNPC._interest`, and the rule is
simple: the nearest thing that can eat you always beats the nearest thing you can
eat.

Two asymmetries do most of the work. A predator sees prey at 62 m; prey only
notices a predator at 50 m, and only if it is actually *closing* (`_is_closing`).
Birds share thermals and roosts with things that could eat them all day long;
what empties a roost is something turning toward it.

---

## What a bird does

`enum State { WANDER, HUNT, FLEE, PERCH, STALK, SOAR, LAND }`

**WANDER** — a goal 60–520 m out, held for 20–38 s. Nearly half the time the goal
is chosen by sampling the lift at half a dozen candidate points and taking the
best, so the flock visibly converges on the same columns the player is learning
to use.

**SOAR** — circling. Bank about 0.66 rad, and *flown slow*: angle of attack
`SOAR_ALPHA` above trim, which is the difference between a 50 m/min descent and a
70 m/min climb. Weak lift makes the bird turn *harder*, not open the circle out,
and it remembers where the lift was best and goes back to it when it falls out of
the side of a core. That is the whole of thermalling technique, and it is exactly
what a player can copy: spread, ease the nose up, hold the turn.

**STALK** — climb into a band above the quarry and sit behind it. A hunter that
beelines arrives level, slow and in front; one that climbs first arrives with
thirty metres of height to spend.

**HUNT** — committed. Lead pursuit (aim where it will be), tucked into a stoop
whenever there is height to spend, and never asking for more than
`INTERCEPT_CLIMB` of climb. It gives up if it stops making progress
(`HUNT_PATIENCE`), and gives up regardless after `HUNT_LIMIT`, then ignores that
particular bird for a while.

**FLEE** — away, downhill, and not in a straight line. Every couple of seconds it
picks the escape bearing whose ground rises most, because
`Flock.has_sight` tests terrain: running at a ridge really does put it between
you and the thing behind you.

**LAND** — glide to a claimed perch, flare on final (angle of attack ramps toward
the stall as the range closes), touch down within a few metres of the point. The
ground-clearance rule is suspended on final approach, or the bird circles the
tree it is trying to land in. Everything has a timeout: `LAND_TIMEOUT` exists so
that a bird which cannot get down eventually stops trying.

**PERCH** — sitting: nose up, wings shut, reserves coming back at
`ROOST_RECOVER`. It leaves when it is rested, or immediately if something that
eats birds comes within `FLUSH_RADIUS`.

Separation is expressed the only way a bird is allowed to move — as an offset to
the place it was already flying to, re-measured at 10 Hz. It does not apply
between a hunter and its quarry: nothing keeps its distance from the thing it is
trying to eat.

---

## Squabbles and roosts

Roosts are communal. `Flock.find_perch` scores a branch by distance, by the climb
it would cost, and by whether it is part of a place the flock already sleeps
(`_roost_sites`, remembered as birds land). A bird coming down on a crowded tree
therefore lands next to somebody, and the pecking order settles it: anything
smaller within `SQUABBLE_TOUCH` gets up and leaves.

Only birds that are bigger *but cannot eat the resident* squabble. If it could
eat it there would be no argument, only a meal.

Honestly: this is the rarest thing in the model. A five-minute run of the
ecosystem produces zero to two squabbles. The mechanism is unit-tested
(`_test_a_perch_belongs_to_one_bird`, `_test_a_bigger_bird_takes_the_branch`);
seeing one in the wild is a matter of being in the right tree.

---

## Running it with nobody in it

```bash
godot --headless --xr-mode off --script res://tests/ecosystem.gd -- --minutes=8
godot --xr-mode off --script res://tests/wildlife.gd -- --out=/tmp/w
```

`tests/EcosystemSim.gd` flies a real `Flock` of real `BirdNPC`s over the real
world with no player, no `GameManager` and no rendering, at 90 Hz, about
seventeen times faster than real time. The only thing it fakes is population: a
bird that gets eaten is re-configured somewhere else, exactly as
`GameManager._maintain_population` would.

A representative eight minutes of twenty-six birds:

```
  npc-vs-npc catches     39  (4.87 per minute)
  landings               75   (all 26 birds, 69 distinct perches, 1 squabble)
  share of bird-time perched 14.3 %
  thermals entered      349,  6969 m of height won from lift
  birds going nowhere    16   (longest run: one 40 s window)
  birds outside the world 0   non-finite states 0   closest pass 4.4 m
```

and the sky is doing several things at once rather than one: across the run,
between one and eight birds are crossing country, one to six hunting, four to
twelve circling in lift, three to seven on approach to a branch and two to six
sitting on one.

The "going nowhere" figure is worth reading carefully: it counts any bird that
covered less than 40 m of ground in 40 s while not perched, circling or landing,
which a bird in a turning fight does routinely. What matters is the streak — no
bird has ever failed two windows in a row. Every state that could hang has a
timeout, and that number is what proves the timeouts work.

`tests/wildlife.gd` photographs the same simulation: it finds the bird on a
branch with the most neighbours, the bird circling in the strongest lift, and the
closest chase, and points a camera at each.

---

## Two things this work changed outside its own area

**Thermals did not work.** Not for birds and not for the player. The lift profile
was `(1 - d/r)²`, which gave a bird circling thirty metres from the middle of a
fifty-metre core eighteen percent of the core's strength — less than its own sink
rate at *every* bank angle and angle of attack the flight model affords. A sweep
over both, against the real world, produced fifteen descents out of fifteen. The
profile is now flat-topped and the cores are stronger
(`WorldBuilder.wind_at`, `_build_thermals`), and a bird that flies the technique
above climbs 60–110 m a minute. The ground-bleach tell was widened to match, so
what is pale is what lifts; `WorldTests` passes unmodified.

**The flock cost twice what it needed to.** `WorldBuilder.wind_at` walks
forty-four thermals and takes five terrain samples for its ridge term, and every
bird was calling it ninety times a second. It is a field that varies over tens of
metres and a bird covers two metres between samples; sampling it at 10 Hz halved
the whole simulation's cost. Crowding queries went the same way.

---

## What is not here

- Birds do not flock in formation. Separation and a weak pull toward their own
  kind produce loose parties; there is no alignment term and no V.
- Trees and buildings do not block line of sight — only terrain does. A raycast
  would need a physics space, which the headless ecosystem does not have.
- Species is still a function of size alone (see `docs/ART-DIRECTION.md` and
  `BirdMesh`); a seabird does not soar differently from a corvid.
- Nothing calls. There are no bird sounds at all; that belongs to the audio work,
  and a roost that scattered *audibly* would be worth more than most of this.
