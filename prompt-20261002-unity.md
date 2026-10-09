# Soaring — build prompt (v2)

Build a VR game in Unity for Meta Quest: Gorilla Tag's body-driven movement meets agar.io's eat-or-be-eaten growth, as a bird. You fly with your arms, catch birds smaller than you, avoid bigger ones, and grow. As you grow, the world shrinks around you and your flight and goals change.

## Feel (fun over realism)
- **Flight is the core.** Flapping (the controllers) gives strong, immediate lift; Extending both wings works like angle of attack (extend: brief balloon, then slower; bringing wings closer: faster). Opposite hand lifts or one hand lower make a coordinated, banked turn.
- Inspired by real aerodynamics, but **fun wins**. The player should feel fast and powerful, at least as fast and agile as NPC birds of the same size. Reaching high speed, accelerating and climbing should be easy; big flaps give big lift.
- **Comfortable for minutes on end.** Gliding uses a relaxed pose (upper arms down, forearms out). Full extension is a momentary power move. Turning has a dead zone and a non-linear response. The camera never pitches or rolls from flight.
- Updrafts lift you without flapping. Size changes handling: small is nimble, big is fast and heavy.

## World and loop
- Vast open air plus places that demand acrobatics: tree branches, power lines, open windows, tall buildings, nests with tight entrances, lots of opportunity for fly-through at high speed. Low-poly style. The arena is closed.
- NPCs hunt smaller birds and flee bigger ones, including each other; the sky should feel alive in the player's view.
- Plentiful easy food early. Being hunted happens regularly, is telegraphed and can be escaped. Growth shifts what is worth chasing.
- Target pacing (adjustable): first growth within ~2 min, mid-size by ~5–8 min, apex by ~20–30 min, then an apex goal.
- UI: menu, pause, restart, settings, a short how-to-fly, explicit prompted calibration, haptics. Include an **in-game developer/tuning menu** from day one for flight feel as getting the right flight feel without human feedback is almost impossible, therefore the developer menu needs to allow easy and broad experimentation of the flight feel nuances.

## Approach
- **Vertical slice first:** flight, a small arena and one catchable bird, installed on the Quest simulator.
- Milestones, each with a few measurable acceptance criteria, a git commit and a short `docs/PROGRESS.md` update:
  1. Flight slice on device.
  2. World and NPC ecosystem.
  3. Game loop and UI.
  4. Polish and performance.
- Use parallel work where areas are independent; keep one owner for anything that spans areas, like the core loop. Shared contracts go in a short architecture doc.
- Verify with automated tests and screenshots wherever feasible, plus Meta XR Simulator runs.

## Budget and stop rules
- Do not chase perfection, but a high level of polish is expected. An area is done when its acceptance criteria pass and no critical, significant or medium issue remains; list the rest as known issues, but only if they are low severity.
- Fix what a player would notice first.

## Environment facts (macOS dev, Quest Pro target)
- Use Unity CLI for your work. Locally Unity 6.6 is installed.
- Use MetaXRSimulator to simulate a VR device (Meta Quest Pro).
- Review the following repository for an example and learnings how to set up a Meta Quest project in Unity via CLI: /Users/don/Projects/Soaring/vr-unity-example 
