# Flight

The core mechanic. `FlightModel` is a real lift/drag simulation; `WingInput`
maps the controllers onto it.

## Gestures

| Gesture | Effect |
| --- | --- |
| Spread your arms | Wings open (the game learns your reach; until you have opened your arms once, hands together is not a tuck) |
| Bring your hands together | Tuck: lift collapses, you dive; speed builds fast |
| Beat both arms down | A wingbeat: thrust + lift, scaled by how fast the downstroke is. Each beat needs a real lift of the arms first (≥ 14 % of reach) |
| Roll both wrists nose-up | More angle of attack: flare, slow down, climb briefly. Past ~16° the wing stalls (lift collapses, drag explodes); roll the wrists back down to recover |
| Roll both wrists nose-down | Less attack: nose drops, speed builds |
| Roll wrists opposite ways | Ailerons: the wing whose leading edge drops loses lift and you roll toward it. Left up + right down = roll right = turn right |
| Drop one hand | Also banks that way |
| Beat one arm harder | Yaw flick away from that wing (for threading a gap with no room to bank) |
| Squeeze a grip | Cling: you can land at nearly twice the speed |

Keyboard: W/S attack, A/D bank, Space flap, Shift tuck, Q/E yaw, G grip.

## Physics
- Lift ⟂ airflow, in the plane of the banked body-up: banking tilts lift
  sideways, the sideways component curves the velocity: coordinated turns
  come out of the same force that holds you up (`ω = g·tan φ / V`, tested).
- Drag = parasite + induced (CL²/(π e AR)) + a stall penalty.
- Mass ~ size^2.4, area ~ size^2: big birds cruise faster and turn wider.
- Wingbeats: force along the heading + extra lift, proportional to wing area.
- `tests/test_flight.gd` pins: glide ratio 6–22, energy exchange (dive doubles
  speed; flare converts it back to height), stall + recovery, terminal
  velocity, size ordering, NaN resistance, turn-rate to within 15 % of textbook.
