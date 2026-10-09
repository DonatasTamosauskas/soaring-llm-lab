extends TestCase
## Verifier probe (birds, round 1): B2 "no pops" and B3 "60 birds <= 1 ms"
## under harsher conditions than the builder's suite.
##  * Pops at 30, 72 and 120 fps; bank flipped -1.2 -> +1.2 rad; perch
##    toggled on while flapping hard; phase jumps mid-beat at the AI's
##    fastest beat (16 Hz); a 50 ms frame hitch mid-beat.
##  * CPU: 60 birds all highlighted, all flapping, flying fast towards and
##    away from the camera (LOD re-attach churn every frame); and the same
##    with BirdFX wingtip trails on all 60 (trails run in _process, outside
##    BirdBatch.sync_all, so the builder's measurement never included them).

const DT := 1.0 / 72.0


func after_each() -> void:
	for c in get_children():
		c.free()
	BirdBatch.sync_all(DT)


func _model(sp: StringName) -> BirdModel:
	var m := BirdModels.create(sp)
	add_child(m)
	m.snap()
	BirdBatch.sync_all(DT)
	return m


## Largest per-frame wingtip step as a share of the total move for a switch.
func _pop(m: BirdModel, dt: float, frames: int, setup: Callable, change: Callable, beat_hz: float = 0.0) -> Array:
	m.flap_amount = 0.0
	m.wing_fold = 0.0
	m.perched = false
	m.bank = 0.0
	m.flap_phase = 0.2
	setup.call()
	m.snap()
	var ph := m.flap_phase
	for f in 3:
		BirdBatch.sync_all(dt)
	var path := PackedVector3Array()
	path.append(m.get_wingtip(1))
	change.call()
	for f in frames:
		if beat_hz > 0.0:
			ph = fposmod(ph + beat_hz * dt, 1.0)
			m.flap_phase = ph
		BirdBatch.sync_all(dt)
		path.append(m.get_wingtip(1))
	var total := path[0].distance_to(path[path.size() - 1])
	var worst := 0.0
	for i in range(1, path.size()):
		worst = maxf(worst, path[i].distance_to(path[i - 1]))
	return [total, worst / maxf(total, 1e-6)]


func test_no_pops_at_other_frame_rates_and_harsher_switches() -> void:
	var m := _model(&"eagle")
	var report := {}
	for fps in [30.0, 72.0, 120.0]:
		var dt: float = 1.0 / fps
		var frames: int = int(0.8 * fps)
		var cases := {
			"amount_0_1": [func() -> void: pass, func() -> void: m.flap_amount = 1.0],
			"fold_0_1": [func() -> void: pass, func() -> void: m.wing_fold = 1.0],
			"bank_-1.2_+1.2": [func() -> void: m.bank = -1.2, func() -> void: m.bank = 1.2],
			"perch_on_while_flapping": [func() -> void: m.flap_amount = 1.0, func() -> void:
				m.perched = true
				m.wing_fold = 1.0
				m.flap_amount = 0.0],
		}
		for k in cases:
			var r := _pop(m, dt, frames, cases[k][0], cases[k][1])
			report["%d_%s" % [int(fps), k]] = [snappedf(r[0], 0.001), snappedf(100.0 * r[1], 0.1)]
			# 72 fps is the builder's 25% bar; at 30 fps each frame covers 2.4x
			# the time, so allow proportionally more (60%) -- a pop is 100%.
			var bar: float = 0.25 * maxf(1.0, 72.0 / fps)
			lt(r[1], bar, "%d fps %s: largest frame step %.1f%% of the way" % [int(fps), k, 100.0 * r[1]])
	metric("pop_pct", report)


func test_fast_beat_is_drawn_without_lag_or_reversal() -> void:
	# NpcBird beats at up to 14 * 1.15 = 16 Hz. The displayed phase must
	# track it (no lag building up) and never run backwards.
	var m := _model(&"wren")
	m.flap_amount = 1.0
	var report := {}
	for hz in [8.0, 16.0]:
		m.snap()
		var ph := 0.0
		var lag := 0.0
		var backwards := 0
		var prev := m.displayed_pose().x
		for f in 144:
			var dt := DT
			if f == 72:
				dt = 0.05  # a frame hitch
			ph = fposmod(ph + hz * dt, 1.0)
			m.flap_phase = ph
			BirdBatch.sync_all(dt)
			var shown := m.displayed_pose().x
			if wrapf(shown - prev, -0.5, 0.5) < -1e-6:
				backwards += 1
			prev = shown
			if f > 10 and (f < 72 or f > 90):
				lag = maxf(lag, absf(wrapf(shown - ph, -0.5, 0.5)))
		report["%d_hz" % int(hz)] = {"max_lag_cycles": snappedf(lag, 0.0001), "backwards_frames": backwards}
		lt(lag, 0.02, "%d Hz beat: displayed phase tracks the owner (lag %.4f cycles)" % [int(hz), lag])
		eq(backwards, 0, "%d Hz beat: displayed phase never runs backwards" % int(hz))
	metric("fast_beat", report)


func _flock(with_trails: bool) -> Dictionary:
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	var holders: Array[Node3D] = []
	var models: Array[BirdModel] = []
	var trails: Array[WingTrails] = []
	for i in 60:
		var h := Node3D.new()
		add_child(h)
		var sp: StringName = BirdSpecies.IDS[i % 10]
		var m := BirdModels.create(sp)
		m.scale = Vector3.ONE * float(SizeRules.species_data(sp)["span"])
		h.add_child(m)
		holders.append(h)
		models.append(m)
		if with_trails:
			var t := BirdFX.attach_trails(m)
			t.min_speed = 1.0  # no Bird parent: speed from motion; always on
			trails.append(t)
	var dt := DT
	var times := PackedFloat32Array()
	var t := 0.0
	var reattaches := 0
	for f in 150:
		t += dt
		for i in 60:
			# Radial dive in and out: 2 .. 250 m, fast, so LODs change a lot.
			var r := 2.0 + 124.0 * (1.0 + sin(t * 3.0 + i))
			var a := i * 0.41
			holders[i].position = Vector3(cos(a) * r, 5.0 + sin(t + i), sin(a) * r)
			var m := models[i]
			m.flap_phase = fposmod(t * 8.0 + i * 0.1, 1.0)
			m.flap_amount = 1.0
			m.bank = sin(t * 2.0 + i) * 0.8
			m.highlight = 1 + (i % 2)
		var lods_before := []
		for m in models:
			lods_before.append(m.get_lod())
		var t0 := Time.get_ticks_usec()
		if with_trails:
			for tr in trails:
				tr.step(dt)
		BirdBatch.sync_all(dt)
		var us := float(Time.get_ticks_usec() - t0)
		for i in 60:
			if models[i].get_lod() != lods_before[i]:
				reattaches += 1
		if f >= 10:
			times.append(us)
	var sorted := Array(times)
	sorted.sort()
	var out := {"median_us": sorted[sorted.size() / 2], "p95_us": sorted[int(sorted.size() * 0.95)],
		"max_us": sorted[sorted.size() - 1], "lod_changes": reattaches}
	for h in holders:
		h.free()
	cam.free()
	return out


func test_sixty_birds_worst_case_cpu() -> void:
	var plain := _flock(false)
	var trails := _flock(true)
	metric("worst_case_no_trails", plain)
	metric("worst_case_with_trails", trails)
	print("[birds-verify] 60 birds churn: %s | with trails: %s" % [str(plain), str(trails)])
	lt(plain["median_us"], 1000.0, "60 birds, all highlighted, LOD churn: median < 1 ms (%.0f us)" % plain["median_us"])
	lt(trails["median_us"], 1000.0, "60 birds + wingtip trails on all: median < 1 ms (%.0f us)" % trails["median_us"])
