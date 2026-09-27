extends TestCase
## VERIFIER PROBE (vr, round 3, experience lens). Not part of the area suite:
##   tools/gd.sh vr_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/vr --suite=r3x_haptics
## Questions:
##  1. The brief wants each game fact to be FELT as its own pattern. When the
##     continuous patterns (stall buffet + updraft throb + danger heartbeat)
##     already use the 30 % duty budget, does a catch / collision / caught
##     still reach the hands? (The unit storm test only checks the caps.)
##  2. Does a stalled player still feel their flaps (flap = 50 < stall = 60)?
##  3. Long seeded soaks (60 s, 3 seeds, random mix of every event):
##     duty <= 30 % in every 1 s window of what the hand actually feels
##     (a new pulse replaces the playing one), no pulse starts < 40 ms after
##     another unless it outranks it, no pulse longer than 280 ms, and no
##     "constant buzz": the longest stretch of vibration with gaps < 40 ms.

const DT := 1.0 / 90.0


class Sink:
	extends RefCounted
	var service: VRHaptics
	var calls: Array[Dictionary] = []

	func pulse(hand: int, amplitude: float, duration: float) -> void:
		calls.append({"t": service.now(), "hand": hand, "amp": amplitude, "dur": duration})


var names: Array = [[], []]


func make() -> Array:
	var h := VRHaptics.new()
	h.listen_to_events = false
	h.poll_player = false
	h.auto_tick = false
	h.intensity_override = 1.0
	var sink := Sink.new()
	sink.service = h
	h.sink = sink
	add_child(h)
	names = [[], []]
	h.pulse_sent.connect(func(hand: int, _a: float, _d: float, pat: StringName) -> void: names[hand].append([h.now(), pat]))
	return [h, sink]


func after_each() -> void:
	for c in get_children():
		if c is VRHaptics:
			c.queue_free()
	await wait_frames(1)


func run(h: VRHaptics, seconds: float) -> void:
	for i in int(round(seconds / DT)):
		h.tick(DT)


## Pulses of `pat` on `hand` that started in [t0, t1).
func count(hand: int, pat: StringName, t0: float, t1: float) -> int:
	var n := 0
	for e in names[hand]:
		if e[1] == pat and float(e[0]) >= t0 - 1e-6 and float(e[0]) < t1:
			n += 1
	return n


func test_important_events_get_through_a_saturated_budget() -> void:
	var rows := {}
	for combo in [["stall"], ["stall", "updraft"], ["stall", "updraft", "danger"], ["updraft", "danger"]]:
		for pat in [&"catch", &"collision", &"caught"]:
			var hs := make()
			var h: VRHaptics = hs[0]
			if "stall" in combo:
				h.set_stall(1.0)
			if "updraft" in combo:
				h.set_updraft(4.0, 4.0)
			if "danger" in combo:
				h.set_danger(1.0)
			run(h, 2.0)
			var delivered := 0
			var full := 0
			var trials := 12
			var first_lat: Array[float] = []
			for k in trials:
				# Spread the event over the continuous rhythm's phase.
				run(h, 1.13 + 0.037 * k)
				var t0 := h.now()
				h.play(pat, VRHaptics.MASK_BOTH, 1.0)
				run(h, 0.3)
				for hand in 2:
					var n := count(hand, pat, t0, t0 + 0.3)
					if n > 0:
						delivered += 1
					var want := 2 if pat == &"catch" else 1
					if n >= want:
						full += 1
			var tag := "%s during %s" % [pat, "+".join(combo)]
			rows[tag] = {"hands_with_any_pulse": "%d/%d" % [delivered, trials * 2], "hands_with_full_pattern": "%d/%d" % [full, trials * 2],
				"stats": h.stats.duplicate()}
			print("[vr-verify] ", tag, " ", rows[tag])
			# A catch must always be felt: the core reward of the loop.
			eq(delivered, trials * 2, "%s: felt on both hands every time" % tag)
			check(float(full) >= 0.9 * trials * 2, "%s: the whole pattern (catch = double bite) felt >= 90 %% of the time (%d/%d)" % [tag, full, trials * 2])
			h.queue_free()
			await wait_frames(1)
	metric("important_events_under_load", rows)


func test_flaps_are_felt_while_stalled() -> void:
	var hs := make()
	var h: VRHaptics = hs[0]
	h.set_stall(1.0)
	run(h, 1.0)
	var t0 := h.now()
	var flaps := 0
	for k in 20:
		h.play(&"flap", VRHaptics.MASK_BOTH, 1.0)
		flaps += 1
		run(h, 0.625)   # 1.6 Hz frantic flapping to recover from the stall
	var felt := count(0, &"flap", t0, h.now() + 1.0)
	var frac := float(felt) / flaps
	print("[vr-verify] flaps felt while stalled: %d/%d  stats %s" % [felt, flaps, str(h.stats)])
	metric("flaps_felt_while_stalled", frac)
	gt(frac, 0.8, "a stalled player still feels >= 80 %% of their flaps (felt %d/%d)" % [felt, flaps])


## The vibration a hand actually feels: a new pulse replaces the playing one.
func felt_intervals(calls: Array[Dictionary], hand: int) -> Array:
	var out: Array = []
	for c in calls:
		if c["hand"] != hand:
			continue
		var t: float = c["t"]
		if not out.is_empty() and float(out[-1][1]) > t:
			out[-1][1] = t
		out.append([t, t + float(c["dur"])])
	return out


func test_long_random_soak() -> void:
	var prio := HapticPatterns.PRIORITY
	var rows := {}
	for s in [3, 1234, 777777]:
		var hs := make()
		var h: VRHaptics = hs[0]
		var sink: Sink = hs[1]
		var rng := RandomNumberGenerator.new()
		rng.seed = s
		h.rng.seed = s
		var n := int(60.0 / DT)
		for i in n:
			var r := rng.randf()
			if r < 0.03:
				h.play(&"flap", [1, 2, 3][rng.randi() % 3], rng.randf())
			elif r < 0.034:
				h.play(&"catch")
			elif r < 0.037:
				h.play(&"collision", VRHaptics.MASK_BOTH, rng.randf(), [rng.randf_range(0.5, 1.0), rng.randf_range(0.5, 1.0)])
			elif r < 0.040:
				h.play(&"brush", [1, 2][rng.randi() % 2])
			elif r < 0.041:
				h.play(&"caught")
			elif r < 0.043:
				h.play(&"perch")
			if i % 90 == 0:
				h.set_stall(1.0 if rng.randf() < 0.4 else 0.0)
				h.set_updraft(rng.randf_range(0.0, 5.0), rng.randf_range(0.0, 5.0))
				h.set_danger(rng.randf())
			h.tick(DT)
		for hand in 2:
			var iv := felt_intervals(sink.calls, hand)
			var worst_duty := 0.0
			var t := 0.0
			while t < 59.0:
				var on := 0.0
				for e in iv:
					on += maxf(0.0, minf(float(e[1]), t + 1.0) - maxf(float(e[0]), t))
				worst_duty = maxf(worst_duty, on)
				t += 0.02
			var longest := 0.0
			var run_start := -1.0
			var run_end := -1.0
			for e in iv:
				if run_start < 0.0 or float(e[0]) - run_end >= 0.040:
					run_start = float(e[0])
				run_end = maxf(run_end, float(e[1]))
				longest = maxf(longest, run_end - run_start)
			var max_dur := 0.0
			var gap_violations := 0
			var starts: Array = names[hand]
			for i in sink.calls.size():
				pass
			for c in sink.calls:
				if c["hand"] == hand:
					max_dur = maxf(max_dur, float(c["dur"]))
			for i in range(1, starts.size()):
				var gap := float(starts[i][0]) - float(starts[i - 1][0])
				if gap < 0.040 - 1e-6 and not (prio[starts[i][1]] > prio[starts[i - 1][1]]):
					gap_violations += 1
			var tag := "seed %d hand %d" % [s, hand]
			rows[tag] = {"pulses": iv.size(), "worst_duty": snappedf(worst_duty, 0.001), "longest_buzz_s": snappedf(longest, 0.001),
				"max_pulse_s": snappedf(max_dur, 0.001), "gap_violations": gap_violations}
			print("[vr-verify] soak ", tag, " ", rows[tag])
			lt(worst_duty, 0.30 + 1e-4, "%s: felt duty <= 30 %% in every 1 s window" % tag)
			lt(max_dur, 0.280 + 1e-6, "%s: no pulse longer than the caught thud" % tag)
			lt(longest, 0.40, "%s: never a constant buzz (longest near-continuous vibration %.3f s)" % [tag, longest])
			eq(gap_violations, 0, "%s: no start within 40 ms of another unless it outranks it" % tag)
		h.queue_free()
		await wait_frames(1)
	metric("soak", rows)
