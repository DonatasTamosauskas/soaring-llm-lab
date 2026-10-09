extends TestCase
## Verifier probe (birds, round 1): CPU cost of BirdFX wingtip trails in a
## realistic flock: 60 Birds (core Bird parents, so trails use the true
## cruise-speed threshold), each with trails attached; most cruise (trails
## idle), N of them stoop at 2.4x cruise (trails drawn). Measures the trails'
## per-frame _process work plus BirdBatch.sync_all, which B3's 1 ms budget
## is about ("60 animated birds' CPU cost").

const DT := 1.0 / 72.0


func after_each() -> void:
	for c in get_children():
		c.free()
	BirdBatch.sync_all(DT)


func _run(stooping: int) -> Dictionary:
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
	var times := PackedFloat32Array()
	var trail_times := PackedFloat32Array()
	var t := 0.0
	for f in 120:
		t += DT
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
		if f >= 20:
			times.append(float(t2 - t0))
			trail_times.append(float(t1 - t0))
	var s := Array(times)
	s.sort()
	var st := Array(trail_times)
	st.sort()
	var on := 0
	for tr in trails:
		if tr.strength() > 0.5:
			on += 1
	var out := {"stooping": stooping, "trails_on": on, "total_median_us": s[s.size() / 2], "trails_median_us": st[st.size() / 2]}
	for b in birds:
		b.free()
	cam.free()
	return out


func test_trails_cost_in_a_realistic_flock() -> void:
	var rows := []
	for n in [0, 3, 10]:
		var r := _run(n)
		rows.append(r)
		print("[birds-verify] trails: %s" % str(r))
	metric("trails_cost", rows)
	lt(rows[0]["total_median_us"], 1000.0, "60 birds with idle trails attached: < 1 ms (%.0f us)" % rows[0]["total_median_us"])
	lt(rows[1]["total_median_us"], 1000.0, "60 birds, 3 stooping with trails: < 1 ms (%.0f us)" % rows[1]["total_median_us"])
	lt(rows[2]["total_median_us"], 1000.0, "60 birds, 10 stooping with trails: < 1 ms (%.0f us)" % rows[2]["total_median_us"])
