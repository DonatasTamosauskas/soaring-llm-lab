class_name HapticPatterns
extends RefCounted
## The haptic vocabulary: what each game fact feels like in the hands.
##
## Quest's simple haptics ignore frequency (docs/research/QUEST.md §3.2), so
## a pattern is only amplitude x duration x rhythm. Each pattern is a list
## of pulses {t: start offset s, amp: 0..1, dur: s}. They are chosen to be
## told apart blind (different counts, lengths, gaps and cadences), and
## never to form a constant buzz (duty <= 30 %, enforced by VRHaptics).
##
## | pattern   | feel                                   | why                          |
## |-----------|----------------------------------------|------------------------------|
## | flap      | 1 x 35 ms thump, amp 0.2 + 0.6·credit  | "that stroke bit the air"    |
## | catch     | 2 x 45 ms, 110 ms apart, 0.8 then 1.0  | the double bite of a catch   |
## | collision | 1 x 90 ms crack at 0.35..1.0           | contact: long and hard       |
## | brush     | 1 x 12 ms tick at 0.25                 | a wingtip grazed something   |
## | stall     | 15 ms ticks every 100..150 ms, jittered| irregular buffet             |
## | updraft   | 15 ms throbs at 3..6 Hz, 0.10..0.25    | soft regular hum per wing    |
## | danger    | heartbeat pair 2 x 20 ms, 130 ms gap,  | predator near; faster and    |
## |           | repeating every 1.0..0.5 s             | stronger when closer         |
## | caught    | 1 x 280 ms at 1.0                      | you were eaten               |
## | perch     | 2 x 12 ms at 0.3, 60 ms apart          | "you are holding on"         |
## | confirm   | 2 x 15 ms at 0.35, 80 ms apart         | calibration captured         |

## Higher wins when two patterns want the same hand at the same time
## (flight_vr.md §13: collision > caught > catch > stall > flap > danger >
## updraft > ticks).
const PRIORITY := {
	&"collision": 90, &"caught": 80, &"catch": 70, &"stall": 60, &"flap": 50,
	&"danger": 40, &"updraft": 30, &"perch": 25, &"confirm": 25, &"brush": 20,
}

## Minimum time between two starts of the same pattern on one hand, s.
const MIN_INTERVAL := {
	&"flap": 0.12, &"catch": 0.30, &"collision": 0.15, &"brush": 0.10,
	&"caught": 1.0, &"perch": 0.4, &"confirm": 0.3,
}


static func pulses(name: StringName, strength: float = 1.0) -> Array[Dictionary]:
	var s := clampf(strength, 0.0, 1.0)
	var out: Array[Dictionary] = []
	match name:
		&"flap":
			out.append({"t": 0.0, "amp": 0.2 + 0.6 * s, "dur": 0.035})
		&"catch":
			out.append({"t": 0.0, "amp": 0.8, "dur": 0.045})
			out.append({"t": 0.110, "amp": 1.0, "dur": 0.045})
		&"collision":
			out.append({"t": 0.0, "amp": lerpf(0.35, 1.0, s), "dur": 0.090})
		&"brush":
			out.append({"t": 0.0, "amp": 0.25, "dur": 0.012})
		&"stall":
			# 15 ms at ~8 Hz: 12 % duty, inside the continuous share on its own
			# (VRHaptics.CONTINUOUS_DUTY; flight_vr.md's 20 ms every 50-90 ms
			# would take 28 % and leave nothing for a catch or a flap).
			out.append({"t": 0.0, "amp": lerpf(0.25, 0.45, s), "dur": 0.015})
		&"updraft":
			out.append({"t": 0.0, "amp": lerpf(0.10, 0.25, s), "dur": 0.015})
		&"danger":
			# flight_vr.md §13's 2 x 20 ms (it was 2 x 30): at the fastest
			# heartbeat (2 Hz) 8 % of a hand, a share VRHaptics keeps free
			# for it so its rate, which says how close the threat is, holds.
			var a := lerpf(0.15, 0.45, s)
			out.append({"t": 0.0, "amp": a, "dur": 0.020})
			out.append({"t": 0.150, "amp": a * 0.75, "dur": 0.020})
		&"caught":
			# 280 ms: the longest pulse, still inside the 30 % duty budget.
			out.append({"t": 0.0, "amp": 1.0, "dur": 0.280})
		&"perch":
			out.append({"t": 0.0, "amp": 0.3, "dur": 0.012})
			out.append({"t": 0.072, "amp": 0.3, "dur": 0.012})
		&"confirm":
			out.append({"t": 0.0, "amp": 0.35, "dur": 0.015})
			out.append({"t": 0.095, "amp": 0.35, "dur": 0.015})
	return out


## The mean fraction of time a continuous pattern vibrates a hand at a
## given intensity (its pulses' on-time over its mean repeat interval).
static func mean_duty(name: StringName, level: float) -> float:
	var on := 0.0
	for p in pulses(name, level):
		on += float(p["dur"])
	var l := clampf(level, 0.0, 1.0)
	var iv := 1.0
	match name:
		&"stall":
			iv = 0.125
		&"updraft":
			iv = 1.0 / lerpf(3.0, 6.0, l)
		&"danger":
			iv = lerpf(1.0, 0.5, l)
	return on / iv


static func names() -> Array[StringName]:
	return [&"flap", &"catch", &"collision", &"brush", &"stall", &"updraft", &"danger",
		&"caught", &"perch", &"confirm"]


## Seconds between repeats of a continuous pattern at a given intensity
## (0..1). rng jitters the stall buffet so it never feels like a motor.
static func repeat_interval(name: StringName, level: float, rng: RandomNumberGenerator) -> float:
	var l := clampf(level, 0.0, 1.0)
	match name:
		&"stall":
			return rng.randf_range(0.100, 0.150)
		&"updraft":
			return 1.0 / lerpf(3.0, 6.0, l)
		&"danger":
			return lerpf(1.0, 0.5, l)
	return 1.0
