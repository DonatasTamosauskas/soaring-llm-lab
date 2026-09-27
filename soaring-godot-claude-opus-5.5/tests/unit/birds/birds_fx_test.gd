extends TestCase
## B5: feather bursts behave like feathers (burst out, lose speed within a
## fraction of a second, sink slowly), shrink away, and free themselves -
## no nodes, orphans or RIDs left behind. Wingtip trails show only at speed.

const DT := 1.0 / 72.0


func test_burst_flies_out_sinks_and_frees_itself() -> void:
	var nodes0 := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var fb := BirdFX.feather_burst(self, Vector3(0, 10, 0), Color(0, 0, 0, 0), 0.24, &"sparrow", Vector3.ZERO, 7)
	check(fb is FeatherBurst, "a FeatherBurst")
	eq(fb.alive_count(), FeatherBurst.FEATHERS + FeatherBurst.DOWN, "all feathers and down alive")
	vnear(fb.global_position, Vector3(0, 10, 0), 1e-5, "at the catch point")
	var spread := []
	var sink := []
	for i in int(3.0 / DT):
		if not is_instance_valid(fb):
			break
		fb.step(DT)
		if i == int(0.25 / DT):
			spread.append(fb.spread())
		if i == int(0.3 / DT) or i == int(1.2 / DT):
			sink.append(fb.centroid().y)
	gt(spread[0], 0.24 * 0.5, "feathers burst out to half a wingspan within 0.25 s")
	lt(sink[1], sink[0], "then sink")
	var rate: float = (float(sink[0]) - float(sink[1])) / 0.9
	between(rate, 0.1, 1.2, "sinking slowly like feathers (m/s)")
	check(not is_instance_valid(fb) or fb.is_queued_for_deletion(), "freed itself after its lifetime")
	await get_tree().process_frame
	eq(Performance.get_monitor(Performance.OBJECT_NODE_COUNT), nodes0, "node count back to where it started")
	metric("spread_025s", snappedf(spread[0], 0.001))
	metric("sink_rate", snappedf(rate, 0.001))


func test_many_bursts_leave_nothing_behind() -> void:
	var nodes0 := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var orphans0 := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	var objs0 := Performance.get_monitor(Performance.OBJECT_COUNT)
	var bursts: Array[FeatherBurst] = []
	for i in 25:
		bursts.append(BirdFX.feather_burst(self, Vector3(i, 5, 0), Color(0.4, 0.3, 0.2), 0.1 + i * 0.08, &"", Vector3(3, 0, 0), i))
	var peak := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	gt(peak, nodes0, "bursts added nodes")
	var t := 0.0
	while t < 3.0:
		for b in bursts:
			if is_instance_valid(b) and not b.is_queued_for_deletion():
				b.step(DT)
		t += DT
	await get_tree().process_frame
	await get_tree().process_frame
	eq(Performance.get_monitor(Performance.OBJECT_NODE_COUNT), nodes0, "all 25 bursts freed")
	eq(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT), orphans0, "no orphan nodes")
	lt(Performance.get_monitor(Performance.OBJECT_COUNT), objs0 + 5, "no objects piling up")


func test_catch_burst_reads_the_prey() -> void:
	var prey := Bird.new()
	prey.species = &"starling"
	prey.mass = 0.1
	add_child(prey)
	prey.global_position = Vector3(2, 3, 4)
	prey.velocity = Vector3(8, 0, 0)
	var fb := BirdFX.catch_burst(prey)
	check(fb != null, "burst made")
	check(fb.get_parent() == self, "parented beside the prey (outlives it)")
	near(fb.span, prey.get_wingspan(), 1e-6, "sized by the prey's wingspan")
	vnear(fb.inherit_velocity, Vector3(8, 0, 0), 1e-6, "carries the prey's velocity")
	eq(fb.colors.size(), 7, "coloured from the starling palette")
	prey.free()
	fb.free()


func test_director_bursts_on_catches() -> void:
	var d := BirdFXDirector.new()
	add_child(d)
	var prey := Bird.new()
	prey.species = &"wren"
	add_child(prey)
	var nodes0 := get_child_count()
	Events.bird_caught.emit(null, prey)
	eq(d.bursts, 1, "one burst per catch")
	eq(get_child_count(), nodes0 + 1, "burst added to the director's parent")
	prey.free()
	d.free()
	for c in get_children():
		if c is FeatherBurst:
			c.free()


func test_wingtip_trails_only_at_speed() -> void:
	var bird := Bird.new()
	bird.mass = 1.3
	add_child(bird)
	var m := BirdModels.create(&"hawk")
	m.scale = Vector3.ONE * 1.6
	bird.add_child(m)
	var tr := BirdFX.attach_trails(m)
	check(BirdFX.attach_trails(m) == tr, "attach_trails is idempotent")
	var cruise: float = SizeRules.performance(1.3)["cruise"]
	bird.velocity = Vector3(0, 0, -cruise)
	for i in 30:
		bird.position += bird.velocity * DT
		BirdBatch.sync_all(DT)
		tr.step(DT)
	lt(tr.strength(), 0.01, "no trails at cruise")
	eq(tr.point_count(), 0, "no trail points at cruise")
	bird.velocity = Vector3(0, -cruise * 2.4, -cruise)
	for i in 40:
		bird.position += bird.velocity * DT
		BirdBatch.sync_all(DT)
		tr.step(DT)
	gt(tr.strength(), 0.9, "full trails in a fast stoop")
	gt(tr.point_count(), 10, "trail points recorded")
	bird.velocity = Vector3(0, 0, -cruise * 0.8)
	for i in 72:
		bird.position += bird.velocity * DT
		tr.step(DT)
	lt(tr.strength(), 0.05, "trails fade when slow again")
	eq(tr.point_count(), 0, "points expire")
	bird.free()


func test_burst_spread_scales_with_the_prey() -> void:
	# A moth and an eagle burst alike relative to their size: half a second
	# after the catch the feathers are spread over roughly a wingspan.
	var rows := {}
	for sp in BirdSpecies.IDS:
		var span: float = SizeRules.species_data(sp)["span"]
		var fb := BirdFX.feather_burst(self, Vector3.ZERO, Color(0, 0, 0, 0), span, sp, Vector3.ZERO, 7)
		for i in int(0.5 / DT):
			fb.step(DT)
		var rel := fb.spread() / span
		rows[String(sp)] = snappedf(rel, 0.01)
		between(rel, 0.4, 1.6, "%s: feathers spread %.2f wingspans at 0.5 s" % [sp, rel])
		fb.free()
	var vals: Array = rows.values()
	lt(float(vals.max()) / float(vals.min()), 2.5, "every species bursts alike relative to its size (%s)" % str(rows))
	metric("spread_over_span_05s", rows)


func test_wingtip_trails_are_cheap_in_a_flock() -> void:
	# 60 birds with trails attached (the trails read their Bird's cruise
	# speed), 10 of them stooping at 2.4x cruise so their trails draw: the
	# birds' whole per-frame CPU work (trails + BirdBatch sync) stays within
	# the 1 ms budget, and a trail that is not showing costs next to nothing.
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	var birds: Array[Bird] = []
	var models: Array[BirdModel] = []
	var trails: Array[WingTrails] = []
	for i in 60:
		var sp: StringName = BirdSpecies.IDS[i % 10]
		var b := Bird.new()
		b.species = sp
		b.mass = float(SizeRules.species_data(sp)["mass"])
		add_child(b)
		var m := BirdModels.create(sp)
		m.scale = Vector3.ONE * b.get_wingspan()
		b.add_child(m)
		trails.append(BirdFX.attach_trails(m))
		birds.append(b)
		models.append(m)
	var idle := PackedFloat32Array()
	var busy := PackedFloat32Array()
	var total := PackedFloat32Array()
	var t := 0.0
	for f in 240:
		t += DT
		var stooping := 10 if f >= 120 else 0
		for i in 60:
			var cruise: float = SizeRules.performance(birds[i].mass)["cruise"]
			var v := cruise * (2.4 if i < stooping else 1.0)
			birds[i].velocity = Vector3(0, -v * 0.5, -v * 0.87) if i < stooping else Vector3(0, 0, -v)
			birds[i].position = Vector3(i * 3.0 - 90.0, 20.0, -40.0) + birds[i].velocity * t
			models[i].flap_phase = fposmod(t * 8.0 + i * 0.1, 1.0)
			models[i].flap_amount = 0.0 if i < stooping else 1.0
			models[i].wing_fold = 0.6 if i < stooping else 0.0
		var t0 := Time.get_ticks_usec()
		for tr in trails:
			tr.step(DT)
		var t1 := Time.get_ticks_usec()
		BirdBatch.sync_all(DT)
		var t2 := Time.get_ticks_usec()
		if f >= 20 and f < 120:
			idle.append(float(t1 - t0))
		elif f >= 140:
			busy.append(float(t1 - t0))
			total.append(float(t2 - t0))
	var on := 0
	for tr in trails:
		if tr.strength() > 0.5:
			on += 1
	eq(on, 10, "the 10 stooping birds' trails show, the 50 cruising ones do not")
	var med := func(a: PackedFloat32Array) -> float:
		var s := Array(a)
		s.sort()
		return s[s.size() / 2]
	var idle_us: float = med.call(idle)
	var busy_us: float = med.call(busy)
	var total_us: float = med.call(total)
	lt(idle_us / 60.0, 2.0, "an idle trail costs < 2 us per frame (%.2f)" % (idle_us / 60.0))
	lt((busy_us - idle_us * 50.0 / 60.0) / 10.0, 60.0, "a drawing trail costs < 60 us per frame")
	lt(total_us, 1000.0, "60 birds with 10 trails drawing: < 1 ms of CPU per frame (%.0f us)" % total_us)
	metric("trail_us_idle_per_bird", snappedf(idle_us / 60.0, 0.01))
	metric("trail_us_per_active_trail", snappedf((busy_us - idle_us * 50.0 / 60.0) / 10.0, 0.1))
	metric("birds_plus_trails_us_median", total_us)
	for b in birds:
		b.free()
	cam.free()


func test_trails_draw_at_most_the_nearest_few() -> void:
	# However many birds fly fast at once, at most MAX_ACTIVE trails draw -
	# the nearest to the camera - so the cost stays bounded.
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	var models: Array[BirdModel] = []
	var trails: Array[WingTrails] = []
	for i in 40:
		var h := Node3D.new()
		add_child(h)
		var m := BirdModels.create(&"hawk")
		h.add_child(m)
		var t := BirdFX.attach_trails(m)
		t.min_speed = 1.0  # no Bird parent: speed from motion, all fast
		models.append(m)
		trails.append(t)
	var times := PackedFloat32Array()
	for f in 90:
		for i in 40:
			(models[i].get_parent() as Node3D).position = Vector3(i * 2.0 - 40.0, 0.0, -10.0 - i * 3.0 - f * 0.5)
		var t0 := Time.get_ticks_usec()
		for tr in trails:
			tr.step(DT)
		BirdBatch.sync_all(DT)
		if f >= 45:
			times.append(float(Time.get_ticks_usec() - t0))
	var drawing := []
	for i in 40:
		if trails[i].strength() > 0.5:
			drawing.append(i)
	eq(drawing.size(), WingTrails.MAX_ACTIVE, "exactly the budget draws (%d of 40)" % drawing.size())
	check(drawing.max() < WingTrails.MAX_ACTIVE, "the nearest ones (%s)" % str(drawing))
	var s := Array(times)
	s.sort()
	lt(float(s[s.size() / 2]), 1000.0, "40 fast birds with trails: < 1 ms per frame (%.0f us)" % s[s.size() / 2])
	metric("forty_fast_birds_with_trails_us", s[s.size() / 2])


func test_trail_budget_holds_from_the_first_frame() -> void:
	# 40 trails that all start wanting to draw in the same frame never draw
	# more than MAX_ACTIVE, in any frame (round-3 verifier: all 40 drew for
	# 30 frames, each rebuilding a near-invisible strip). Then 12 nearer
	# birds overtake the drawing ones: the budget hands over, the cut trails
	# fade out within ~0.1 s and are dropped, and it is back to MAX_ACTIVE.
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	var holders: Array[Node3D] = []
	var trails: Array[WingTrails] = []
	for i in 52:
		var h := Node3D.new()
		add_child(h)
		var m := BirdModels.create(&"hawk")
		h.add_child(m)
		var tr := BirdFX.attach_trails(m)
		tr.min_speed = 1.0
		holders.append(h)
		trails.append(tr)
	var per_frame := []
	var worst_start := 0
	var worst_handover := 0
	var back_after := -1
	for f in 90:
		for i in 52:
			var z := -10.0 - i * 3.0 - f * 0.5
			# Birds 40-51 are parked (slow, no trail) until frame 45, then fly
			# fast right in front of the camera.
			if i >= 40:
				z = -2.0 - (i - 40) * 0.5 - (f * 0.5 if f >= 45 else 0.0)
			holders[i].position = Vector3(i * 2.0 - 50.0, 0.0, z)
		for tr in trails:
			tr.step(DT)
		BirdBatch.sync_all(DT)
		var n := 0
		for tr in trails:
			if tr._drawn:
				n += 1
		per_frame.append(n)
		if f < 45:
			worst_start = maxi(worst_start, n)
		else:
			worst_handover = maxi(worst_handover, n)
			if back_after < 0 and n <= WingTrails.MAX_ACTIVE and f > 46:
				back_after = f - 45
	metric("trails_drawing_per_frame", per_frame)
	lt(worst_start, WingTrails.MAX_ACTIVE + 1, "a simultaneous start draws at most the budget (%d)" % worst_start)
	lt(worst_handover, 2 * WingTrails.MAX_ACTIVE + 1, "a handover draws at most the new and the fading (%d)" % worst_handover)
	check(back_after >= 0 and back_after <= 12, "back to the budget within 12 frames of the handover (%d)" % back_after)
	var near := 0
	for i in range(40, 52):
		if trails[i].strength() > 0.5:
			near += 1
	eq(near, WingTrails.MAX_ACTIVE, "the 12 nearest draw after the handover")
	metric("trails_simultaneous_start_max", worst_start)
	metric("trails_handover_max_and_frames", [worst_handover, back_after])


func test_trail_ranking_holds_one_frame() -> void:
	# The nearest-first ranking keeps one frame's trails: stepped by hand
	# without the birds ever syncing (a headless run), a fast trail must not
	# grow the list step after step, and 40 fast trails in one frame list 40.
	var bird := Bird.new()
	bird.mass = 1.3
	add_child(bird)
	var m := BirdModels.create(&"hawk")
	m.scale = Vector3.ONE * 1.6
	bird.add_child(m)
	var tr := BirdFX.attach_trails(m)
	var cruise: float = SizeRules.performance(1.3)["cruise"]
	bird.velocity = Vector3(0, -cruise * 2.4, -cruise)
	var most := 0
	for i in 600:
		bird.position += bird.velocity * DT
		tr.step(DT)
		most = maxi(most, WingTrails._want_now.size())
	lt(most, 2, "one trail stepped 600 times without a sync lists at most itself (%d)" % most)
	bird.free()
	var trails: Array[WingTrails] = []
	for i in 40:
		var h := Node3D.new()
		add_child(h)
		var mm := BirdModels.create(&"hawk")
		h.add_child(mm)
		var t := BirdFX.attach_trails(mm)
		t.min_speed = 1.0
		trails.append(t)
	most = 0
	for f in 30:
		for i in 40:
			(trails[i].get_parent().get_parent() as Node3D).position = Vector3(i * 2.0, 0.0, -10.0 - f * 0.5)
			trails[i].step(DT)
			most = maxi(most, WingTrails._want_now.size())
	lt(most, 42, "40 trails, no syncs: the list holds one frame of them, plus at most the last one's leftover (%d)" % most)
	metric("trail_ranking_list_max", most)
