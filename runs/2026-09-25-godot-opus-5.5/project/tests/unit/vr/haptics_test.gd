extends TestCase
## V6: haptics. Each game fact has its own feel (distinct pulse count,
## lengths, gaps, cadence), pulses are rate limited (40 ms per hand, per-
## pattern intervals, <= 30 % duty in any 1 s: never a constant buzz),
## priorities hold, the Settings "haptics" scale is respected (0 = silent),
## and the service is silent while paused. Uses a recording mock sink; the
## real XR call path is exercised in the simulator harness (tests/sim).

const StubPlayer := preload("res://scenes/dev/vr_stub_player.gd")
const DT := 1.0 / 90.0


class MockSink:
	extends RefCounted
	var service: VRHaptics
	var calls: Array[Dictionary] = []

	func pulse(hand: int, amplitude: float, duration: float) -> void:
		calls.append({"t": service.now(), "hand": hand, "amp": amplitude, "dur": duration})

	func hand(h: int) -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		for c in calls:
			if c["hand"] == h:
				out.append(c)
		return out


var _stub: Bird


func make(listen: bool = false, poll: bool = false) -> Array:
	var h := VRHaptics.new()
	h.listen_to_events = listen
	h.poll_player = poll
	h.auto_tick = false
	h.intensity_override = 1.0
	var sink := MockSink.new()
	sink.service = h
	h.sink = sink
	add_child(h)
	return [h, sink]


func run(h: VRHaptics, seconds: float) -> void:
	for i in int(round(seconds / DT)):
		h.tick(DT)


func stub() -> Bird:
	if _stub == null:
		_stub = StubPlayer.new()
		add_child(_stub)
	return _stub


func after_each() -> void:
	for c in get_children():
		if c is VRHaptics:
			c.queue_free()
	await wait_frames(1)


func after_all() -> void:
	if _stub != null:
		_stub.queue_free()


## Left-hand rhythm of a pattern: [count, durations ms, gaps ms, amps].
func signature(calls: Array[Dictionary]) -> Array:
	var durs: Array = []
	var gaps: Array = []
	var amps: Array = []
	for i in calls.size():
		durs.append(roundi(calls[i]["dur"] * 1000.0))
		amps.append(snappedf(calls[i]["amp"], 0.01))
		if i > 0:
			gaps.append(roundi((calls[i]["t"] - calls[i - 1]["t"]) * 1000.0))
	return [calls.size(), durs, gaps, amps]


func distinct(a: Array, b: Array) -> bool:
	if a[0] != b[0]:
		return true
	var n: int = a[0]
	for i in n:
		if absi(a[1][i] - b[1][i]) >= 8 or absf(a[3][i] - b[3][i]) >= 0.15:
			return true
	for i in n - 1:
		if absi(a[2][i] - b[2][i]) >= 20:
			return true
	return false


# -----------------------------------------------------------------------------

func test_patterns_are_distinct() -> void:
	var sigs := {}
	# One-shot patterns: 1 s after triggering. Continuous ones: 1.5 s of their
	# generator (their identity is the rhythm).
	for name in [&"flap", &"catch", &"collision", &"brush", &"caught", &"perch", &"confirm"]:
		var hs := make()
		(hs[0] as VRHaptics).play(name, VRHaptics.MASK_BOTH, 0.7)
		run(hs[0], 1.0)
		sigs[name] = signature((hs[1] as MockSink).hand(0))
	var gen := {
		&"stall": func(h: VRHaptics) -> void: h.set_stall(0.7),
		&"updraft": func(h: VRHaptics) -> void: h.set_updraft(3.0, 3.0),
		&"danger": func(h: VRHaptics) -> void: h.set_danger(0.8),
	}
	for name in gen:
		var hs := make()
		(gen[name] as Callable).call(hs[0])
		for i in int(1.5 / DT):
			if name == &"danger":
				(hs[0] as VRHaptics).set_danger(0.8)
			(hs[0] as VRHaptics).tick(DT)
		sigs[name] = signature((hs[1] as MockSink).hand(0))
	var names := sigs.keys()
	for i in names.size():
		gt(float(sigs[names[i]][0]), 0.0, "%s produces pulses" % names[i])
		metric(String(names[i]), sigs[names[i]])
		for j in range(i + 1, names.size()):
			check(distinct(sigs[names[i]], sigs[names[j]]), "%s and %s feel different: %s vs %s" % [names[i], names[j], str(sigs[names[i]]), str(sigs[names[j]])])


func test_events_map_to_patterns() -> void:
	var p := stub()
	var hs := make(true)
	var h: VRHaptics = hs[0]
	var sink: MockSink = hs[1]
	# Wingbeat on the left wing only.
	Events.player_flapped.emit(-1, 0.8)
	run(h, 0.3)
	eq(sink.hand(0).size(), 1, "left flap: one thump on the left")
	eq(sink.hand(1).size(), 0, "left flap: nothing on the right")
	near(sink.calls[0]["amp"], 0.2 + 0.6 * 0.8, 1e-4, "thump strength follows the stroke credit")
	near(sink.calls[0]["dur"], 0.035, 1e-6, "thump is 35 ms")
	# Catch: the double bite, only when the player is the predator.
	sink.calls.clear()
	var prey := StubPlayer.new()
	Events.bird_caught.emit(p, prey)
	run(h, 0.5)
	eq(sink.hand(0).size(), 2, "catch: two bites per hand")
	eq(sink.hand(1).size(), 2, "catch: on both hands")
	near(sink.hand(0)[1]["t"] - sink.hand(0)[0]["t"], 0.110, DT + 1e-4, "bites 110 ms apart")
	sink.calls.clear()
	var npc := Bird.new()
	Events.bird_caught.emit(npc, prey)
	run(h, 0.5)
	eq(sink.calls.size(), 0, "an NPC catch is not felt")
	prey.free()
	npc.free()
	# Collision: surface on the right -> right hand stronger.
	sink.calls.clear()
	var right := p.global_basis.x
	Events.player_collided.emit(6.0, -right)
	run(h, 0.3)
	eq(sink.hand(0).size(), 1, "collision: one crack left")
	eq(sink.hand(1).size(), 1, "collision: one crack right")
	gt(sink.hand(1)[0]["amp"], sink.hand(0)[0]["amp"] * 1.5, "the impact side cracks harder")
	near(sink.hand(1)[0]["dur"], 0.090, 1e-6, "crack is 90 ms")
	# Wing brush (impact 0) on the left: a tick on that hand only.
	sink.calls.clear()
	run(h, 0.3)
	Events.player_collided.emit(0.0, right)
	run(h, 0.2)
	eq(sink.hand(0).size(), 1, "brush: left tick")
	eq(sink.hand(1).size(), 0, "brush: not on the right")
	near(sink.hand(0)[0]["dur"], 0.012, 1e-6, "brush is a 12 ms tick")
	# Danger: heartbeat pairs while a predator is close.
	sink.calls.clear()
	for i in int(3.0 / DT):
		if i % 18 == 0:
			Events.threat_changed.emit(0.9, null)
		h.tick(DT)
	var d := sink.hand(0)
	gt(float(d.size()), 7.0, "danger: several heartbeats in 3 s")
	near(d[1]["t"] - d[0]["t"], 0.150, DT + 1e-4, "heartbeat pair 150 ms apart")
	var period: float = d[2]["t"] - d[0]["t"]
	near(period, lerpf(1.0, 0.5, (0.9 - 0.35) / 0.65), 2.0 * DT, "heartbeat rate rises with the threat")
	sink.calls.clear()
	run(h, 2.5)
	sink.calls.clear()
	for i in int(2.0 / DT):
		if i % 18 == 0:
			Events.threat_changed.emit(0.2, null)
		h.tick(DT)
	eq(sink.calls.size(), 0, "a distant threat (0.2) is not felt")
	# Caught: one long, full-strength pulse.
	sink.calls.clear()
	run(h, 1.2)
	Events.player_caught.emit(null)
	run(h, 0.6)
	eq(sink.hand(0).size(), 1, "caught: one long pulse")
	check(sink.hand(0).size() == 1 and sink.hand(0)[0]["dur"] >= 0.25 and sink.hand(0)[0]["amp"] >= 0.99, "caught: >= 250 ms at full strength")
	# Perch: the double tick.
	sink.calls.clear()
	run(h, 1.0)
	Events.player_perched.emit(Vector3.ZERO)
	run(h, 0.3)
	eq(sink.hand(0).size(), 2, "perch: double tick")
	# Stall entry starts the buffet.
	sink.calls.clear()
	Events.player_stalled.emit()
	run(h, 0.5)
	gt(float(sink.hand(0).size()), 3.0, "stall: buffet pulses")


## Events.threat_changed is a change signal: GameLoop re-emits it only when
## the level moves by >= 0.02 and sends 0.0 when the threat is over. A
## predator holding a steady distance must keep the heartbeat going.
func test_danger_heartbeat_holds_while_the_threat_is_steady() -> void:
	var hs := make(true)
	var h: VRHaptics = hs[0]
	var sink: MockSink = hs[1]
	# The hunter (a plain core Bird, never added to the tree).
	var pred := Bird.new()
	Game.set_state(Game.State.PLAYING)
	Events.threat_changed.emit(0.8, pred)
	run(h, 3.0)
	sink.calls.clear()
	run(h, 5.0)
	# 0.8 -> heartbeat every lerp(1.0, 0.5, 0.69) = 0.65 s, a pair each.
	var n3_8 := sink.hand(0).size()
	between(float(n3_8), 13.0, 17.0, "steady 0.8 threat: ~15 heartbeat pulses per hand in 3-8 s (got %d)" % n3_8)
	metric("danger_pulses_3_8s", n3_8)
	# The explicit all-clear stops it at once.
	Events.threat_changed.emit(0.0, null)
	sink.calls.clear()
	run(h, 3.0)
	eq(sink.calls.size(), 0, "threat_changed(0) silences the heartbeat")
	# A pause silences it; play resumes it without a new report.
	Events.threat_changed.emit(0.8, pred)
	run(h, 0.5)
	get_tree().paused = true
	sink.calls.clear()
	run(h, 2.0)
	eq(sink.calls.size(), 0, "silent while paused")
	get_tree().paused = false
	run(h, 2.0)
	gt(float(sink.hand(0).size()), 3.0, "the heartbeat resumes with play (same threat, no new report)")
	# Leaving play ends it (menu, caught, run over).
	Game.set_state(Game.State.ENDED)
	sink.calls.clear()
	run(h, 2.0)
	eq(sink.calls.size(), 0, "leaving play ends the heartbeat")
	eq(h.danger_level(), 0.0, "danger level cleared")
	# A hunter that vanishes without a final report ends it too.
	Game.set_state(Game.State.PLAYING)
	Events.threat_changed.emit(0.9, pred)
	run(h, 1.0)
	pred.alive = false
	sink.calls.clear()
	run(h, 2.0)
	eq(sink.calls.size(), 0, "a dead hunter ends the heartbeat")
	pred.free()
	Game.set_state(Game.State.BOOT)


func test_flap_spam_is_rate_limited() -> void:
	var hs := make(true)
	var h: VRHaptics = hs[0]
	var sink: MockSink = hs[1]
	for i in int(2.0 / DT):
		Events.player_flapped.emit(0, 1.0)
		h.tick(DT)
	for hand in 2:
		var c := sink.hand(hand)
		lt(float(c.size()), 2.0 / 0.12 + 1.5, "hand %d: flap thumps capped by the 120 ms interval" % hand)
		var min_gap := 10.0
		for i in range(1, c.size()):
			min_gap = minf(min_gap, c[i]["t"] - c[i - 1]["t"])
		gt(min_gap, 0.12 - 1e-6, "hand %d: >= 120 ms between thumps" % hand)
	metric("thumps_per_hand_2s", sink.hand(0).size())


## On-time of a hand over [t0, t0 + 1 s], each pulse ending early if a later
## one replaced it (OpenXR semantics).
func window_duty(c: Array[Dictionary], t0: float) -> float:
	var total := 0.0
	for i in c.size():
		var s: float = c[i]["t"]
		var e: float = s + c[i]["dur"]
		if i + 1 < c.size():
			e = minf(e, c[i + 1]["t"])
		total += maxf(0.0, minf(e, t0 + 1.0) - maxf(s, t0))
	return total


func test_storm_never_becomes_a_buzz() -> void:
	var hs := make(true)
	var h: VRHaptics = hs[0]
	var sink: MockSink = hs[1]
	var p := stub()
	var names: Array = [[], []]
	h.pulse_sent.connect(func(hand: int, _a: float, _d: float, pat: StringName) -> void: names[hand].append(pat))
	h.set_stall(1.0)
	h.set_updraft(5.0, 5.0)
	for i in int(5.0 / DT):
		h.set_danger(1.0)
		Events.player_flapped.emit(0, 1.0)
		if i % 27 == 0:
			Events.player_collided.emit(8.0, Vector3.LEFT)
		if i % 45 == 0:
			Events.bird_caught.emit(p, p)
		h.tick(DT)
	for hand in 2:
		var c := sink.hand(hand)
		var worst := 0.0
		var t := 0.0
		while t < 4.0:
			worst = maxf(worst, window_duty(c, t))
			t += 0.01
		# The brief's numbers, not the implementation's constants: a mutated
		# MAX_DUTY / MIN_GAP must fail here.
		lt(worst, 0.30 + 1e-6, "hand %d: duty <= 30%% in every 1 s window" % hand)
		metric("worst_duty_hand%d" % hand, worst)
		var prio := HapticPatterns.PRIORITY
		for i in range(1, c.size()):
			var gap: float = c[i]["t"] - c[i - 1]["t"]
			if gap < 0.040 - 1e-6:
				check(prio[names[hand][i]] > prio[names[hand][i - 1]], "hand %d: a pulse within 40 ms only when it outranks the last (%s after %s)" % [hand, names[hand][i], names[hand][i - 1]])
	gt(float(h.stats["dropped_duty"] + h.stats["dropped_rate"] + h.stats["dropped_priority"]), 50.0, "the storm was actually throttled")
	metric("stats", h.stats)


func test_priorities() -> void:
	var hs := make()
	var h: VRHaptics = hs[0]
	var sink: MockSink = hs[1]
	var sent: Array[StringName] = []
	h.pulse_sent.connect(func(_hand: int, _a: float, _d: float, pat: StringName) -> void: sent.append(pat))
	h.set_updraft(4.0, 4.0)
	run(h, 0.3)
	h.play(&"collision", VRHaptics.MASK_BOTH, 1.0)
	h.play(&"flap", VRHaptics.MASK_BOTH, 1.0)
	h.tick(DT)
	check(sent.has(&"collision"), "collision preempts the updraft hum")
	var t_col := h.now()
	sent.clear()
	sink.calls.clear()
	run(h, 0.085)
	check(not sent.has(&"updraft"), "no updraft pulse cuts the 90 ms crack")
	check(not sent.has(&"flap"), "a flap queued with it loses to the collision")
	run(h, 0.3)
	check(sent.has(&"updraft"), "the hum resumes after the crack (%.3f s)" % (h.now() - t_col))


func test_setting_scales_and_zero_silences() -> void:
	var hs := make(true)
	var h: VRHaptics = hs[0]
	var sink: MockSink = hs[1]
	var p := stub()
	h.intensity_override = 0.0
	h.set_stall(1.0)
	h.set_updraft(5.0, 5.0)
	h.set_danger(1.0)
	for i in int(2.0 / DT):
		Events.player_flapped.emit(0, 1.0)
		if i % 30 == 0:
			Events.player_collided.emit(8.0, Vector3.LEFT)
			Events.bird_caught.emit(p, p)
		h.tick(DT)
	eq(sink.calls.size(), 0, "haptics 0: not a single pulse")
	h.intensity_override = 0.5
	run(h, 1.0)
	h.stop_all()
	run(h, 0.5)
	sink.calls.clear()
	h.play(&"flap", VRHaptics.MASK_LEFT, 1.0)
	run(h, 0.1)
	eq(sink.calls.size(), 1, "one thump")
	if not sink.calls.is_empty():
		near(sink.calls[0]["amp"], 0.5 * 0.8, 1e-5, "haptics 0.5 halves the amplitude")
	h.intensity_override = -1.0
	near(h.intensity(), clampf(float(Settings.get_value("haptics", 1.0)), 0.0, 1.0), 1e-6, "production reads Settings 'haptics'")


## The player's "haptics" setting, read through the settings source
## production uses (not the override): 0 sends nothing at all, 0.5 halves
## every amplitude.
func test_setting_is_read_from_settings() -> void:
	var MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
	var hs := make(true)
	var h: VRHaptics = hs[0]
	var sink: MockSink = hs[1]
	var p := stub()
	var store := MemoryStore.new()
	h.store = store
	h.intensity_override = -1.0
	store.set_value("haptics", 0.0)
	h.set_stall(1.0)
	h.set_updraft(5.0, 5.0)
	h.set_danger(1.0)
	for i in int(2.0 / DT):
		Events.player_flapped.emit(0, 1.0)
		if i % 30 == 0:
			Events.player_collided.emit(8.0, Vector3.LEFT)
			Events.bird_caught.emit(p, p)
		h.tick(DT)
	eq(sink.calls.size(), 0, "Settings haptics 0: not a single pulse")
	h.stop_all()
	store.set_value("haptics", 0.5)
	run(h, 0.5)
	h.play(&"flap", VRHaptics.MASK_LEFT, 1.0)
	run(h, 0.1)
	eq(sink.calls.size(), 1, "one thump")
	if not sink.calls.is_empty():
		near(sink.calls[0]["amp"], 0.5 * 0.8, 1e-5, "Settings haptics 0.5 halves the amplitude")


## A run ending and a respawn end every continuous pattern (a new body is
## not stalled, in a thermal or hunted), without waiting for new reports.
func test_run_end_and_respawn_end_continuous_patterns() -> void:
	var hs := make(true)
	var h: VRHaptics = hs[0]
	var sink: MockSink = hs[1]
	Game.set_state(Game.State.PLAYING)
	Events.threat_changed.emit(0.8, null)
	run(h, 1.5)
	gt(float(sink.calls.size()), 0.0, "(setup) the heartbeat plays")
	Events.run_ended.emit({})
	sink.calls.clear()
	run(h, 2.0)
	eq(sink.calls.size(), 0, "run_ended ends the heartbeat")
	h.set_stall(1.0)
	h.set_updraft(4.0, 4.0)
	Events.threat_changed.emit(0.9, null)
	run(h, 0.5)
	gt(float(sink.calls.size()), 0.0, "(setup) stall, updraft and danger play")
	Events.player_spawned.emit(stub())
	sink.calls.clear()
	run(h, 2.0)
	eq(sink.calls.size(), 0, "player_spawned ends stall, updraft and danger")
	Game.set_state(Game.State.BOOT)


## Two catches within 300 ms (a flock strike) give one double bite, not a
## four-pulse buzz; a later catch bites again.
func test_catch_has_a_minimum_interval() -> void:
	var hs := make(true)
	var h: VRHaptics = hs[0]
	var sink: MockSink = hs[1]
	var p := stub()
	Events.bird_caught.emit(p, p)
	run(h, 0.15)
	Events.bird_caught.emit(p, p)
	run(h, 0.5)
	eq(sink.hand(0).size(), 2, "two catches 150 ms apart: one double bite")
	Events.bird_caught.emit(p, p)
	run(h, 0.4)
	eq(sink.hand(0).size(), 4, "a catch 650 ms later bites again")


func test_stall_buffet_is_irregular() -> void:
	var hs := make()
	var h: VRHaptics = hs[0]
	var sink: MockSink = hs[1]
	h.set_stall(1.0)
	run(h, 3.0)
	var c := sink.hand(0)
	gt(float(c.size()), 20.0, "buffet keeps going while stalled")
	var gaps: Array[float] = []
	for i in range(1, c.size()):
		gaps.append(c[i]["t"] - c[i - 1]["t"])
	var mean := 0.0
	for g in gaps:
		mean += g
	mean /= gaps.size()
	var sd := 0.0
	for g in gaps:
		sd += (g - mean) ** 2
	sd = sqrt(sd / gaps.size())
	for g in gaps:
		# 100-150 ms, a beat waiting at most a few ticks for its duty share.
		between(g, 0.100 - 1e-6, 0.150 + 0.03, "buffet interval in 100..150 ms (+ a short wait)")
	gt(sd, 0.006, "jittered, not a motor (sd of intervals)")
	metric("buffet_interval_mean", mean)
	metric("buffet_interval_sd", sd)


func test_updraft_throbs_per_wing() -> void:
	var hs := make()
	var h: VRHaptics = hs[0]
	var sink: MockSink = hs[1]
	h.set_updraft(3.0, 0.0)
	run(h, 2.0)
	eq(sink.hand(1).size(), 0, "no lift on the right wing: right hand quiet")
	var c := sink.hand(0)
	var rate: float = (c.size() - 1) / (float(c[c.size() - 1]["t"]) - float(c[0]["t"]))
	between(rate, 3.0, 6.0, "left wing throbs at 3-6 Hz")
	near(rate, lerpf(3.0, 6.0, (3.0 - 0.5) / 3.5), 0.4, "rate grows with lift")
	metric("updraft_hz", rate)


func test_paused_is_silent() -> void:
	var hs := make(true)
	var h: VRHaptics = hs[0]
	var sink: MockSink = hs[1]
	get_tree().paused = true
	h.set_stall(1.0)
	h.set_updraft(5.0, 5.0)
	Events.player_flapped.emit(0, 1.0)
	run(h, 0.5)
	eq(sink.calls.size(), 0, "paused: gameplay haptics stop")
	h.play(&"confirm")
	run(h, 0.3)
	eq(sink.hand(0).size(), 2, "paused: a calibration confirm still plays")
	get_tree().paused = false


func test_telemetry_drives_continuous_patterns() -> void:
	var p := stub()
	var hs := make(false, true)
	var h: VRHaptics = hs[0]
	var sink: MockSink = hs[1]
	var old_state := Game.state
	# In play (the verifier's mutant E44 stopped polling in PLAYING and
	# survived: this test ran in BOOT).
	Game.state = Game.State.PLAYING
	p.set("telemetry_data", {"stalled": true})
	run(h, 1.0)
	gt(float(sink.hand(0).size()), 5.0, "telemetry stalled -> buffet")
	sink.calls.clear()
	p.set("telemetry_data", {"stalled": true, "perched": true})
	run(h, 1.0)
	eq(sink.calls.size(), 0, "perched: no buffet")
	# Perched in a thermal (on a sun-warmed roof): holding on, not soaring.
	p.set("telemetry_data", {"in_updraft": 3.0, "wind_l_y": 3.0, "wind_r_y": 3.0, "perched": true})
	run(h, 1.0)
	eq(sink.calls.size(), 0, "perched in rising air: no updraft throb (E10)")
	p.set("telemetry_data", {"in_updraft": 3.0, "wind_l_y": 3.0, "wind_r_y": 0.2})
	run(h, 1.0)
	gt(float(sink.hand(0).size()), 2.0, "left wingtip in the thermal: left throbs")
	eq(sink.hand(1).size(), 0, "right wingtip outside: right quiet")
	sink.calls.clear()
	p.set("telemetry_data", {"in_updraft": 3.0})
	run(h, 1.0)
	gt(float(sink.hand(1).size()), 2.0, "no per-wing data: both hands throb")
	Game.state = Game.State.MENU
	sink.calls.clear()
	run(h, 1.0)
	eq(sink.calls.size(), 0, "menus: telemetry haptics off")
	Game.state = old_state
	p.set("telemetry_data", {})


## Both wings in a thermal throb in turn, half a period apart, not as one
## buzz on both hands (the verifier's mutant E12 put them in phase).
func test_updraft_wings_throb_in_turn() -> void:
	var hs := make()
	var h: VRHaptics = hs[0]
	var sink: MockSink = hs[1]
	h.set_updraft(4.0, 4.0)
	run(h, 3.0)
	var l := sink.hand(0)
	var r := sink.hand(1)
	gt(float(l.size()), 8.0, "(setup) left throbs")
	gt(float(r.size()), 8.0, "(setup) right throbs")
	var period := 1.0 / lerpf(3.0, 6.0, (4.0 - 0.5) / 3.5)
	var offs: Array[float] = []
	for c in r:
		var best := 10.0
		for d in l:
			best = minf(best, absf(float(c["t"]) - float(d["t"])))
		offs.append(best)
	offs.sort()
	var median := offs[offs.size() / 2]
	gt(median, 0.35 * period, "right beats fall between the left ones (median offset %.0f ms of a %.0f ms period)" % [median * 1000.0, period * 1000.0])
	metric("updraft_offset_ms", snappedf(median * 1000.0, 0.1))


## Fix round 3 (a verifier's saturation probe): with the continuous
## rhythms busy (stall + updraft + danger, the moments a catch or a crash
## happens), a catch, a collision and being caught are felt whole on both
## hands every time, whatever the phase of the rhythms.
func test_important_events_get_through_a_saturated_budget() -> void:
	var rows := {}
	for combo in [["stall"], ["stall", "updraft"], ["stall", "updraft", "danger"], ["updraft", "danger"]]:
		for pat in [&"catch", &"collision", &"caught"]:
			var hs := make()
			var h: VRHaptics = hs[0]
			var got: Array = [[], []]
			h.pulse_sent.connect(func(hand: int, _a: float, dur: float, p: StringName) -> void:
				if p == pat:
					got[hand].append([h.now(), dur]))
			if "stall" in combo:
				h.set_stall(1.0)
			if "updraft" in combo:
				h.set_updraft(4.0, 4.0)
			if "danger" in combo:
				h.set_danger(1.0)
			run(h, 2.0)
			var whole := 0
			var shortest := 1.0
			for k in 12:
				run(h, 1.13 + 0.037 * k)
				(got[0] as Array).clear()
				(got[1] as Array).clear()
				h.play(pat, VRHaptics.MASK_BOTH, 1.0)
				run(h, 0.3)
				for hand in 2:
					var want := 2 if pat == &"catch" else 1
					var nominal := 0.045 if pat == &"catch" else (0.090 if pat == &"collision" else 0.280)
					var ok: bool = (got[hand] as Array).size() >= want
					for e in got[hand]:
						shortest = minf(shortest, float(e[1]))
						ok = ok and (pat == &"caught" or float(e[1]) >= nominal - 1e-6)
					whole += 1 if ok else 0
			var tag := "%s during %s" % [pat, "+".join(combo)]
			rows[tag] = {"whole": "%d/24" % whole, "shortest_ms": snappedf(shortest * 1000.0, 0.1), "stats": h.stats.duplicate()}
			eq(whole, 24, "%s: felt whole on both hands every time (%d/24)" % [tag, whole])
			if pat == &"caught":
				# The one long pulse may be cut to the room left: with the
				# continuous rhythms held to 15 %, at least 150 ms of it.
				gt(shortest, 0.150 - 1e-6, "%s: caught lasts >= 150 ms (%.0f ms)" % [tag, shortest * 1000.0])
			h.queue_free()
			await wait_frames(1)
	metric("important_events_under_load", rows)


## A stalled player flapping hard to recover feels every flap (a flap met
## the 40 ms rule after a buffet tick and was dropped: 15 of 20 felt), and
## the buffet goes on around the flaps.
func test_flaps_are_felt_while_stalled() -> void:
	var hs := make()
	var h: VRHaptics = hs[0]
	var names: Array = [[], []]
	h.pulse_sent.connect(func(hand: int, _a: float, _d: float, p: StringName) -> void: names[hand].append([h.now(), p]))
	h.set_stall(1.0)
	run(h, 1.0)
	var lat: Array[float] = []
	for k in 20:
		var t0 := h.now()
		h.play(&"flap", VRHaptics.MASK_BOTH, 1.0)
		run(h, 0.625)
		for e in names[0]:
			if e[1] == &"flap" and float(e[0]) >= t0 - 1e-6 and float(e[0]) < t0 + 0.5:
				lat.append(float(e[0]) - t0)
				break
	var buffet := 0
	for e in names[0]:
		buffet += 1 if e[1] == &"stall" else 0
	eq(lat.size(), 20, "every flap felt while stalled (%d/20)" % lat.size())
	lat.sort()
	lt(lat[lat.size() - 1], VRHaptics.MAX_DEFER + DT, "a flap waits at most %.0f ms for its turn (worst %.0f ms)" % [VRHaptics.MAX_DEFER * 1000.0, lat[lat.size() - 1] * 1000.0])
	gt(float(buffet), 60.0, "the buffet goes on between the flaps (%d beats in 13.5 s)" % buffet)
	metric("flap_latency_ms_worst", snappedf(lat[lat.size() - 1] * 1000.0, 0.1))


## Frantic flapping (a thump every 125 ms, near the flap's own 120 ms
## limit: 28 % of a hand on its own) with the stall buffet, a thermal and a
## hunter: routine pulses stop at their share (21 %), so a catch is still
## felt whole; and at a hard 1.6 Hz every flap is felt through all three
## rhythms, none waiting more than 60 ms (the rhythms wait in turn,
## longest overdue first, rather than a quick one jumping a waiting one).
func test_busy_hands_still_feel_catches_and_flaps() -> void:
	for c in [[11, 0x5EED], [56, 1], [56, 2], [56, 0x5EED]]:
		var every: int = c[0]
		var hs := make()
		var h: VRHaptics = hs[0]
		h.rng.seed = c[1]
		var st := {"flaps": 0, "catch": []}
		h.pulse_sent.connect(func(hand: int, _a: float, dur: float, p: StringName) -> void:
			if hand != 0:
				return
			if p == &"flap":
				st["flaps"] += 1
			elif p == &"catch":
				(st["catch"] as Array).append(dur))
		h.set_stall(1.0)
		h.set_updraft(4.0, 4.0)
		h.set_danger(1.0)
		var sent := 0
		var whole := 0
		var trials := 0
		for i in int(20.0 / DT):
			if i % every == 0:
				h.play(&"flap", VRHaptics.MASK_BOTH, 1.0)
				sent += 1
			if i % 97 == 50:
				(st["catch"] as Array).clear()
				h.play(&"catch")
			if i % 97 == 70:
				trials += 1
				var bites: Array = st["catch"]
				if bites.size() == 2 and float(bites[0]) >= 0.045 - 1e-6 and float(bites[1]) >= 0.045 - 1e-6:
					whole += 1
			h.tick(DT)
		var tag := "a flap every %.0f ms (buffet jitter seed %d)" % [every * DT * 1000.0, c[1]]
		eq(whole, trials, "%s: every catch felt whole (%d/%d)" % [tag, whole, trials])
		if every == 56:
			eq(int(st["flaps"]), sent, "%s: every flap felt through stall + thermal + hunter (%d/%d)" % [tag, st["flaps"], sent])
		h.queue_free()
		await wait_frames(1)


## The continuous rhythms share their part of the budget: all three at
## once never take more than CONTINUOUS_DUTY of a hand; the heartbeat keeps
## its own rhythm (its rate is how close the threat is: a round-2
## verifier's probe wanted it kept while flapping in a thermal), and the
## buffet and the throb slow down together in what it leaves (neither
## silences the other).
func test_continuous_rhythms_share_the_budget() -> void:
	for flapping in [false, true]:
		var hs := make()
		var h: VRHaptics = hs[0]
		var sink: MockSink = hs[1]
		var counts := {}
		var beats: Array[float] = []
		h.pulse_sent.connect(func(hand: int, _a: float, _d: float, p: StringName) -> void:
			counts[p] = int(counts.get(p, 0)) + 1
			if p == &"danger" and hand == 0:
				beats.append(h.now()))
		h.set_stall(1.0)
		h.set_updraft(5.0, 5.0)
		h.set_danger(1.0)
		for i in int(6.0 / DT):
			if flapping and i % 60 == 0:
				h.play(&"flap", VRHaptics.MASK_BOTH, 1.0)
			h.tick(DT)
		var tag := "with 1.5 Hz flapping" if flapping else "no flapping"
		gt(h.continuous_stretch, 1.5, "%s: all three together: buffet and throb slow down (x%.2f)" % [tag, h.continuous_stretch])
		for p in [&"stall", &"updraft"]:
			gt(float(counts.get(p, 0)), 8.0, "%s: %s still plays (%d pulses in 6 s)" % [tag, p, counts.get(p, 0)])
		# The heartbeat at level 1: a pair every 0.5 s = 24 beats per hand in
		# 6 s; it keeps >= 90 % of them.
		gt(float(beats.size()), 0.9 * 24.0, "%s: the heartbeat keeps its rhythm (%d of 24 beats; %s)" % [tag, beats.size(), str(h.stats)])
		for hand in 2:
			var cont: Array[Dictionary] = []
			var c := sink.hand(hand)
			var worst := 0.0
			var t := 1.0
			while t < 5.0:
				worst = maxf(worst, window_duty(c, t))
				t += 0.01
			lt(worst, 0.30 + 1e-6, "%s, hand %d: duty <= 30 %% (worst %.3f)" % [tag, hand, worst])
		metric("continuous_counts_6s_" + ("flapping" if flapping else "still"), counts)
		h.queue_free()
		await wait_frames(1)


## The duty cap shortens an important pulse to the room left rather than
## dropping it (the verifier's mutant E13, which dropped it, survived).
func test_duty_cap_shortens_important_pulses() -> void:
	var hs := make()
	var h: VRHaptics = hs[0]
	var sink: MockSink = hs[1]
	h.set_stall(1.0)
	h.set_danger(1.0)
	for i in int(2.0 / DT):
		if i % 56 == 0:
			h.play(&"flap", VRHaptics.MASK_BOTH, 1.0)
		h.tick(DT)
	sink.calls.clear()
	var before := int(h.stats["shortened"])
	h.play(&"caught")
	run(h, 0.05)
	var c := sink.hand(0)
	check(c.size() >= 1, "caught sent while the hand was busy")
	if c.size() >= 1:
		between(float(c[0]["dur"]), 0.090 - 1e-6, 0.280 - 1e-3, "caught shortened to the room left (%.0f ms)" % (float(c[0]["dur"]) * 1000.0))
	gt(float(int(h.stats["shortened"]) - before), 0.0, "counted as shortened, not dropped")


func test_xr_sink_is_a_noop_without_a_runtime() -> void:
	var s := VRHaptics.XRSink.new()
	s.pulse(0, 1.0, 0.1)
	eq(s.calls, 0, "no XR interface: nothing sent, no error")
	check(not VR.active, "headless tests run without a runtime")


## A recorder standing in for the OpenXR interface (XRSink.xr).
class XRRecorder:
	extends RefCounted
	var calls: Array = []

	func trigger_haptic_pulse(action: String, tracker: StringName, frequency: float, amplitude: float, duration: float, delay: float) -> void:
		calls.append([action, tracker, frequency, amplitude, duration, delay])


## The real sink's call path (mutant R17 sent left pulses to the right
## controller and survived): a left-hand pattern reaches the "left_hand"
## tracker's "haptic" action, a right-hand one "right_hand", with the
## pattern's amplitude and duration (frequency and delay 0: QUEST.md §3.2).
func test_xr_sink_sends_each_hand_to_its_controller() -> void:
	var h := VRHaptics.new()
	h.listen_to_events = false
	h.poll_player = false
	h.auto_tick = false
	h.intensity_override = 1.0
	var sink := VRHaptics.XRSink.new()
	var rec := XRRecorder.new()
	sink.xr = rec
	h.sink = sink
	add_child(h)
	h.play(&"flap", VRHaptics.MASK_LEFT, 1.0)
	run(h, 0.2)
	eq(rec.calls.size(), 1, "one pulse for a left flap")
	if rec.calls.size() == 1:
		eq(rec.calls[0][0], "haptic", "the OpenXR haptic action")
		eq(rec.calls[0][1], &"left_hand", "left hand -> left controller")
		near(float(rec.calls[0][4]), 0.035, 1e-6, "the flap's 35 ms")
		eq(float(rec.calls[0][2]), 0.0, "frequency: the runtime's default")
	rec.calls.clear()
	h.play(&"flap", VRHaptics.MASK_RIGHT, 1.0)
	run(h, 0.2)
	eq(rec.calls.size(), 1, "one pulse for a right flap")
	if rec.calls.size() == 1:
		eq(rec.calls[0][1], &"right_hand", "right hand -> right controller")
	eq(sink.calls, 2, "both counted")
	eq(VRHaptics.XRSink.tracker_for(0), &"left_hand", "tracker of hand 0")
	eq(VRHaptics.XRSink.tracker_for(1), &"right_hand", "tracker of hand 1")


## VR.md §2.7: the stall buffet starts at telemetry stall_warning > 0.6
## (mutant R01 dropped the threshold and survived): 0.3 and 0.55 are
## silent, 0.8 buffets, `stalled` buffets at any warning.
func test_stall_warning_threshold() -> void:
	var p := stub()
	var hs := make(false, true)
	var h: VRHaptics = hs[0]
	var n := [0]
	h.pulse_sent.connect(func(_hand: int, _a: float, _d: float, pat: StringName) -> void:
		if pat == &"stall":
			n[0] += 1)
	var old := Game.state
	Game.state = Game.State.PLAYING
	var rows := {}
	for w in [0.3, 0.55, 0.8, 1.0]:
		n[0] = 0
		h.clear_continuous()
		p.set("telemetry_data", {"stall_warning": w})
		run(h, 1.0)
		rows[str(w)] = n[0]
	eq(int(rows["0.3"]), 0, "stall_warning 0.3: no buffet")
	eq(int(rows["0.55"]), 0, "stall_warning 0.55: no buffet")
	gt(float(rows["0.8"]), 2.0, "stall_warning 0.8: buffet (%d pulses/s)" % rows["0.8"])
	gt(float(rows["1.0"]), float(rows["0.8"]) - 1.0, "and at least as much at 1.0")
	metric("stall_pulses_per_s_by_warning", rows)
	Game.state = old
	p.set("telemetry_data", {})


## Being caught stops every background rhythm at once, whatever the game
## state does (mutant R18 left the buffet and the heartbeat running after
## player_caught and survived: the old test had none running). Only the
## long "caught" pulse follows.
func test_being_caught_stops_the_rhythms() -> void:
	var hs := make(true)
	var h: VRHaptics = hs[0]
	var pats: Array[StringName] = []
	h.pulse_sent.connect(func(_hand: int, _a: float, _d: float, pat: StringName) -> void: pats.append(pat))
	var old := Game.state
	Game.state = Game.State.PLAYING
	Events.player_stalled.emit()
	for i in int(1.5 / DT):
		if i % 18 == 0:
			Events.threat_changed.emit(0.9, null)
		h.tick(DT)
	check(pats.has(&"stall") and pats.has(&"danger"), "(setup) buffet and heartbeat running (%s)" % str(pats))
	pats.clear()
	Events.player_caught.emit(null)
	run(h, 1.5)
	var others := pats.filter(func(p: StringName) -> bool: return p != &"caught")
	eq(others.size(), 0, "after being caught only the caught pulse (%s)" % str(pats))
	check(pats.has(&"caught"), "the caught pulse itself")
	Game.state = old
