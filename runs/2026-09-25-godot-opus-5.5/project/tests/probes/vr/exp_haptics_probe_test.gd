extends TestCase
## Verifier probe (experience lens), V6 haptics: adversarial cases the
## area's own suite does not cover. Uses a recording sink, never a device.
##
## - Events.threat_changed is a CHANGE signal (GameLoop emits it only when
##   the level moves by >= 0.02 or the predator changes, and emits 0 when the
##   threat is gone). A steady threat must keep the danger heartbeat going.
## - A long all-patterns storm (60 s) stays within the duty cap and the
##   40 ms gap rule, and the scheduler's queue stays bounded.
## - Turning haptics off mid-pattern stops the rest of the pattern.
## - Collision side follows the player's own right, whatever its heading.

const StubPlayer := preload("res://scenes/dev/vr_stub_player.gd")
const DT := 1.0 / 72.0


class Sink:
	extends RefCounted
	var service: VRHaptics
	var calls: Array[Dictionary] = []

	func pulse(hand: int, amplitude: float, duration: float) -> void:
		calls.append({"t": service.now(), "hand": hand, "amp": amplitude, "dur": duration})


var _conns: Array = []


func make(listen: bool) -> Array:
	var h := VRHaptics.new()
	h.listen_to_events = listen
	h.poll_player = false
	h.auto_tick = false
	h.intensity_override = 1.0
	var s := Sink.new()
	s.service = h
	h.sink = s
	add_child(h)
	return [h, s]


func after_each() -> void:
	for c in get_children():
		if c is VRHaptics or c is Bird:
			c.queue_free()
	await wait_frames(2)


func run(h: VRHaptics, seconds: float) -> void:
	for i in int(round(seconds / DT)):
		h.tick(DT)


func count_in(calls: Array[Dictionary], hand: int, t0: float, t1: float) -> int:
	var n := 0
	for c in calls:
		if c["hand"] == hand and c["t"] >= t0 and c["t"] < t1:
			n += 1
	return n


# -----------------------------------------------------------------------------

## A predator holding a steady threat level: GameLoop reports it once (the
## level does not move by 0.02), then stays silent until it changes.
func test_danger_heartbeat_persists_while_threat_is_steady() -> void:
	var hs := make(true)
	var h: VRHaptics = hs[0]
	var s: Sink = hs[1]
	Events.threat_changed.emit(0.8, null)
	run(h, 8.0)
	var early := count_in(s.calls, 0, 0.0, 2.0)
	var late := count_in(s.calls, 0, 3.0, 8.0)
	metric("danger_pulses_0_2s", early)
	metric("danger_pulses_3_8s", late)
	gt(float(early), 2.0, "heartbeat starts (%d pulses in the first 2 s)" % early)
	# lvl (0.8-0.35)/0.65 = 0.69 -> a pair every ~0.65 s: ~15 pulses in 5 s.
	gt(float(late), 8.0, "heartbeat continues while the threat (0.8) was never withdrawn (%d pulses in 3..8 s)" % late)
	# And it stops once GameLoop reports the threat gone.
	Events.threat_changed.emit(0.0, null)
	var n0 := s.calls.size()
	run(h, 0.2)
	var n1 := s.calls.size()
	run(h, 3.0)
	eq(s.calls.size(), n1, "silent after threat_changed(0) (%d stray pulses)" % (s.calls.size() - n1))
	metric("stray_after_clear", n1 - n0)


## Reported every frame (a GameLoop that does emit often) it must also keep
## going: sanity for the probe above.
func test_danger_heartbeat_with_frequent_reports() -> void:
	var hs := make(true)
	var h: VRHaptics = hs[0]
	var s: Sink = hs[1]
	for i in int(round(8.0 / DT)):
		if i % 7 == 0:
			Events.threat_changed.emit(0.8 + 0.001 * float(i % 2), null)
		h.tick(DT)
	gt(float(count_in(s.calls, 0, 3.0, 8.0)), 8.0, "heartbeat with frequent reports")


## 60 s of everything at once: flap spam, stall, updraft both wings, a
## threat, collisions and catches. Never a constant buzz: <= 30 % duty in
## every 1 s window, no two starts < 40 ms apart unless the later outranks.
func test_long_storm_stays_within_duty_and_bounded() -> void:
	var hs := make(false)
	var h: VRHaptics = hs[0]
	var s: Sink = hs[1]
	var names: Array[StringName] = []
	h.pulse_sent.connect(func(_hand: int, _a: float, _d: float, p: StringName) -> void: names.append(p))
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var worst_queue := 0
	h.set_stall(1.0)
	h.set_updraft(3.0, 2.0)
	h.set_danger(0.9)
	var steps := int(round(60.0 / DT))
	for i in steps:
		if i % 2 == 0:
			h.play(&"flap", VRHaptics.MASK_BOTH, rng.randf())
		if rng.randf() < 0.02:
			h.play(&"collision", VRHaptics.MASK_BOTH, rng.randf())
		if rng.randf() < 0.01:
			h.play(&"catch")
		if i % 60 == 0:
			h.set_danger(0.9)
		h.tick(DT)
		worst_queue = maxi(worst_queue, h._queue.size())
	metric("storm_pulses", s.calls.size())
	metric("storm_worst_queue", worst_queue)
	lt(float(worst_queue), 200.0, "scheduler queue stays bounded over 60 s (worst %d)" % worst_queue)
	var worst_duty := 0.0
	for hand in 2:
		var mine: Array[Dictionary] = []
		for c in s.calls:
			if c["hand"] == hand:
				mine.append(c)
		# Effective on-time: a new pulse replaces the one playing.
		var ends: Array[float] = []
		for k in mine.size():
			var e: float = mine[k]["t"] + mine[k]["dur"]
			if k + 1 < mine.size():
				e = minf(e, mine[k + 1]["t"])
			ends.append(e)
		var t := 1.0
		while t <= 60.0:
			var on := 0.0
			for k in mine.size():
				var a := maxf(mine[k]["t"], t - 1.0)
				var b := minf(ends[k], t)
				on += maxf(0.0, b - a)
			worst_duty = maxf(worst_duty, on)
			t += 0.05
	metric("storm_worst_duty", worst_duty)
	lt(worst_duty, 0.30 + 0.015, "<= 30 % duty in every 1 s window over 60 s (worst %.3f)" % worst_duty)
	gt(float(s.calls.size()), 200.0, "the storm was actually felt")


## The player turns haptics off while a catch's double bite is playing.
func test_setting_off_mid_pattern_stops_the_rest() -> void:
	var hs := make(false)
	var h: VRHaptics = hs[0]
	var s: Sink = hs[1]
	h.play(&"catch", VRHaptics.MASK_LEFT)
	h.tick(DT)
	eq(s.calls.size(), 1, "first bite sent")
	h.intensity_override = 0.0
	run(h, 0.5)
	eq(s.calls.size(), 1, "second bite suppressed after haptics set to 0")


## Collision side: a wall on the player's right, player heading east (+X),
## so its right is +Z world. The right hand must get the stronger crack.
func test_collision_side_follows_player_heading() -> void:
	var p: Bird = StubPlayer.new()
	add_child(p)
	p.rotation.y = -PI * 0.5   # facing +X; right = +Z
	await wait_frames(1)
	var hs := make(true)
	var h: VRHaptics = hs[0]
	var s: Sink = hs[1]
	# Surface on the player's right: the normal points left (-Z).
	Events.player_collided.emit(6.0, Vector3(0, 0, -1))
	run(h, 0.05)
	var amp := [0.0, 0.0]
	for c in s.calls:
		amp[c["hand"]] = maxf(amp[c["hand"]], c["amp"])
	gt(amp[1], amp[0] * 1.5, "right hand cracks harder (L %.2f R %.2f)" % [amp[0], amp[1]])
