extends TestCase
## Round-2 verifier probes (experience and requirements lens) for the birds
## area. Written by the verifier, not the builder. Depends only on the birds
## area under test (public API plus its batch buffers, which are what is
## drawn) and on core contracts (SizeRules).
##
##   tools/gd.sh birds_verify --headless res://tests/runner.tscn -- \
##       --dir=res://tests/probes/birds --suite=birds_r2
##
## What it tries to break:
##   1. size cue: a highlighted prey drawn bigger than the player's own
##      species at the same distance (the core loop is "eat smaller birds");
##   2. degenerate owner input (zero scale, NaN/INF fields) poisoning the
##      drawn data, and whether a bird recovers once the input is sane again;
##   3. the drawn wingbeat under jittery frame times, a varying beat rate and
##      intermittent (bounding) flight like NPCs fly it;
##   4. batch bookkeeping in a long soak across two worlds with every kind of
##      change (move, reparent across worlds, hide, species, LOD override,
##      layers, shadows, highlight, free/recreate, leave/enter tree).

const DT := 1.0 / 72.0

var cam: Camera3D


func before_all() -> void:
	cam = Camera3D.new()
	cam.name = "ProbeCam"
	add_child(cam)
	cam.global_position = Vector3.ZERO
	cam.make_current()


func after_each() -> void:
	for c in get_children():
		if c != cam:
			c.free()
	BirdBatch.sync_all(DT)


func _drawn_span(m: BirdModel) -> float:
	# Column x of the drawn 3x4 transform (row-major in the batch buffer).
	var o := m._slot * BirdBatch.STRIDE
	var b := m._batch.buf
	return Vector3(b[o], b[o + 4], b[o + 8]).length()


func _finite_slots(m: BirdModel) -> int:
	var bad := 0
	if m._batch == null:
		return -1
	var o := m._slot * BirdBatch.STRIDE
	for f in BirdBatch.STRIDE:
		if not is_finite(m._batch.buf[o + f]):
			bad += 1
	return bad


func _batch_nonfinite(b: BirdBatch) -> int:
	var bad := 0
	for i in b.models.size() * BirdBatch.STRIDE:
		if not is_finite(b.buf[i]):
			bad += 1
	return bad


# --- 1. Highlighted prey must not look bigger than the hunter ----------------

## GameLoop's highlight range (docs/ARCHITECTURE.md contract note, gameloop
## fix round: at least 70 player wingspans or 6 s of flight at cruise).
func _highlight_range(mass: float) -> float:
	return maxf(70.0 * SizeRules.wingspan_for_mass(mass), 6.0 * SizeRules.cruise_speed(mass))


func test_r2_highlighted_prey_is_never_drawn_bigger_than_the_hunter() -> void:
	var rows := []
	var worst := [0.0, ""]
	var offenders := 0
	for P: Dictionary in SizeRules.SPECIES:
		var pm: float = P["mass"]
		var ps: float = P["span"]
		var rng := _highlight_range(pm)
		for Q: Dictionary in SizeRules.SPECIES:
			var qm: float = Q["mass"]
			if not SizeRules.can_eat(pm, qm):
				continue
			if not SizeRules.is_worthwhile(pm, qm):
				continue
			var qs: float = Q["span"]
			for d: float in [rng, minf(40.0, rng), rng * 0.5]:
				var m := BirdModels.create(Q["id"])
				m.scale = Vector3.ONE * qs
				add_child(m)
				m.global_position = Vector3(0, 0, -d)
				m.highlight = 1
				m.snap()
				BirdBatch.sync_all(DT)
				var drawn := _drawn_span(m)
				m.free()
				var ratio_hunter := drawn / ps
				var ratio_true := drawn / qs
				var tag := "%s hunting %s at %.0f m" % [P["id"], Q["id"], d]
				rows.append([tag, snappedf(drawn, 0.001), snappedf(ratio_true, 0.01), snappedf(ratio_hunter, 0.01)])
				if ratio_hunter > worst[0]:
					worst = [ratio_hunter, tag]
				if ratio_hunter >= 1.0:
					offenders += 1
	# The band of the chase over which the prey's drawn angular size does not
	# grow at all (min-size clamp active), per slim species.
	var bands := {}
	for sp in [&"moth", &"swallow", &"gull", &"sparrow"]:
		var span: float = SizeRules.species_data(sp)["span"]
		bands[String(sp)] = {"min_angle_deg": snappedf(rad_to_deg(BirdModels.min_highlight_angle(sp)), 0.01),
			"constant_size_beyond_m": snappedf(span / BirdModels.min_highlight_angle(sp), 0.1)}
	metric("prey_drawn_vs_hunter", rows)
	metric("constant_size_bands", bands)
	metric("worst_prey_over_hunter", worst)
	print("[birds-r2] worst drawn prey / hunter span: %.2f (%s); %d cases >= 1.0" % [worst[0], worst[1], offenders])
	print("[birds-r2] constant-size bands: ", bands)
	for r in rows:
		if float(r[3]) >= 1.0:
			print("[birds-r2]   prey drawn bigger than hunter: ", r)
	eq(offenders, 0, "a highlighted prey is never drawn wider than the hunter's own span at the same distance")


# --- 2. Degenerate owner input -----------------------------------------------

func test_r2_zero_scale_highlighted_bird_stays_finite() -> void:
	var others: Array[BirdModel] = []
	for i in 3:
		var o := BirdModels.create(&"crow")
		o.lod_override = 1
		add_child(o)
		o.global_position = Vector3(i * 2.0 - 2.0, 0, -30)
		o.scale = Vector3.ONE * 0.95
		others.append(o)
	var res := {}
	for sc: float in [0.0, 1e-9, 1e-4]:
		var m := BirdModels.create(&"crow")
		m.lod_override = 1
		add_child(m)
		m.global_position = Vector3(0, 1, -30)
		m.scale = Vector3.ONE * sc
		m.highlight = 1
		m.snap()
		BirdBatch.sync_all(DT)
		BirdBatch.sync_all(DT)
		var bad := _batch_nonfinite(m._batch)
		var drawn := _drawn_span(m)
		res[str(sc)] = {"nonfinite_floats_in_batch": bad, "drawn_span_m": drawn}
		eq(bad, 0, "scale %s, highlighted: the crow batch holds only finite numbers" % str(sc))
		m.free()
	metric("zero_scale", res)
	print("[birds-r2] zero/tiny scale highlighted: ", res)


func test_r2_nan_fields_do_not_poison_the_batch_and_recover() -> void:
	var res := {}
	for field: String in ["flap_phase", "flap_amount", "wing_fold", "bank"]:
		for bad_val: float in [NAN, INF]:
			var neigh := BirdModels.create(&"gull")
			neigh.lod_override = 0
			add_child(neigh)
			neigh.global_position = Vector3(2, 0, -10)
			var m := BirdModels.create(&"gull")
			m.lod_override = 0
			add_child(m)
			m.global_position = Vector3(0, 0, -10)
			m.flap_amount = 1.0
			m.snap()
			BirdBatch.sync_all(DT)
			# One frame of a bad value from the owner (e.g. a degenerate
			# velocity giving a NaN bank), then sane values for a second.
			m.set(field, bad_val)
			BirdBatch.sync_all(DT)
			var during := _batch_nonfinite(m._batch)
			m.flap_phase = 0.3
			m.flap_amount = 1.0
			m.wing_fold = 0.0
			m.bank = 0.1
			for i in 72:
				m.flap_phase = fposmod(0.3 + i * 8.0 * DT, 1.0)
				BirdBatch.sync_all(DT)
			var after := _batch_nonfinite(m._batch)
			var key := "%s=%s" % [field, str(bad_val)]
			res[key] = {"nonfinite_during": during, "nonfinite_1s_after": after}
			eq(after, 0, "%s for one frame: the batch is finite again 1 s after the owner sends sane values" % key)
			m.free()
			neigh.free()
	metric("nan_inputs", res)
	print("[birds-r2] NaN/INF owner input: ", res)


# --- 3. The drawn wingbeat under realistic, messy owners ----------------------

func test_r2_drawn_beat_under_jitter_and_bounding_flight() -> void:
	var m := BirdModels.create(&"sparrow")
	m.lod_override = 0
	add_child(m)
	m.global_position = Vector3(0, 0, -5)
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	var t := 0.0
	var owner_phase := rng.randf()
	var amount := 0.0
	var burst := 5.0
	var pause := 0.0
	m.flap_phase = owner_phase
	m.snap()
	BirdBatch.sync_all(DT)
	var prev_shown := m.displayed_pose().x
	var backwards := 0
	var big_jumps := 0
	var lags: Array[float] = []
	var beating_for := 0.0
	var frames := 72 * 120
	for f in frames:
		var dt := DT * rng.randf_range(0.8, 1.2)
		if f % 97 == 0:
			dt = DT * 2.5
		t += dt
		var hz := 8.0 + 5.0 * sin(0.7 * t)
		var owner_step := 0.0
		if pause > 0.0:
			pause -= dt
			amount = move_toward(amount, 0.0, 5.0 * dt)
			beating_for = 0.0
			if amount <= 0.0:
				var before := owner_phase
				owner_phase = move_toward(owner_phase, 0.25, dt * 2.0)
				owner_step = owner_phase - before
			if pause <= 0.0:
				burst = float(rng.randi_range(3, 6))
		else:
			owner_step = hz * dt
			owner_phase = fposmod(owner_phase + owner_step, 1.0)
			burst -= hz * dt
			amount = move_toward(amount, 1.0, 6.0 * dt)
			beating_for += dt
			if burst <= 0.0:
				pause = rng.randf_range(0.15, 0.6)
		m.flap_phase = owner_phase
		m.flap_amount = amount
		m.wing_fold = 0.85 if pause > 0.0 else 0.0
		var lag_before := fposmod(m._phase_prev - prev_shown + 0.5, 1.0) - 0.5
		BirdBatch.sync_all(dt)
		var shown := m.displayed_pose().x
		var fwd := fposmod(shown - prev_shown, 1.0)
		prev_shown = shown
		# The owner never steps more than 0.45 of a beat per frame here
		# (13 Hz x 2.5 frames), so a forward reading above 0.5 is the drawn
		# wing going backwards while the owner beats forwards.
		# Forward-consistent: the drawn step equals the owner's step plus the
		# lag it carried (a catch-up after a hitch can exceed half a beat).
		var expected := owner_step + lag_before
		var consistent := absf(fposmod(fwd - expected + 0.5, 1.0) - 0.5) < 0.02
		if owner_step > 0.0 and fwd > 0.5 and not consistent:
			backwards += 1
			print("[birds-r2]   backwards frame %d: dt %.4f owner_step %.4f owner %.4f shown %.4f (fwd %.4f) amount_shown %.3f" % [f, dt, owner_step, owner_phase, shown, fwd, m.displayed_pose().y])
		if owner_step >= 0.0 and fwd > 0.5 + 1e-6 and fwd < 0.999:
			pass
		# A drawn step far larger than the owner's own step is a visible snap.
		if owner_step > 0.0 and fwd < 0.5 and fwd > owner_step * 2.0 + 0.03:
			big_jumps += 1
		if pause <= 0.0 and beating_for > 0.25:
			var lag := absf(fposmod(owner_phase - shown + 0.5, 1.0) - 0.5)
			lags.append(lag)
	lags.sort()
	var p95 := lags[int(lags.size() * 0.95)] if not lags.is_empty() else 0.0
	var mx := lags[-1] if not lags.is_empty() else 0.0
	metric("jitter_beat", {"frames": frames, "backwards": backwards, "big_jumps": big_jumps, "lag_p95": p95, "lag_max": mx})
	print("[birds-r2] jittery bounding flight: backwards %d, snaps %d, lag p95 %.4f max %.4f (cycles)" % [backwards, big_jumps, p95, mx])
	eq(backwards, 0, "the drawn wing never plays backwards while the owner beats forwards")
	eq(big_jumps, 0, "no drawn step is more than twice the owner's own step (+0.03)")
	lt(p95, 0.03, "while beating steadily the drawn phase follows the owner (p95 lag, cycles)")
	lt(mx, 0.12, "worst lag while beating (cycles)")


# --- 4. Long soak across two worlds -----------------------------------------

func test_r2_soak_two_worlds_every_kind_of_change() -> void:
	var worlds: Array[SubViewport] = []
	var holders: Array[Node3D] = []
	var cams: Array[Camera3D] = []
	for w in 2:
		var vp := SubViewport.new()
		vp.own_world_3d = true
		vp.size = Vector2i(64, 64)
		add_child(vp)
		var c := Camera3D.new()
		vp.add_child(c)
		c.global_position = Vector3(w * 50.0, 0, 0)
		c.make_current()
		cams.append(c)
		var h := Node3D.new()
		vp.add_child(h)
		worlds.append(vp)
		holders.append(h)
	var rng := RandomNumberGenerator.new()
	rng.seed = 90210
	var carriers: Array[Node3D] = []
	var models: Array[BirdModel] = []
	var detached: Array[Node3D] = []
	for i in 80:
		var car := Node3D.new()
		holders[i % 2].add_child(car)
		var m := BirdModels.create(BirdSpecies.IDS[rng.randi() % 10])
		car.add_child(m)
		m.scale = Vector3.ONE * rng.randf_range(0.1, 2.1)
		carriers.append(car)
		models.append(m)
	var violations := {}
	var note := func(k: String) -> void:
		violations[k] = int(violations.get(k, 0)) + 1
	var frames := 2400
	var ops := 0
	for f in frames:
		for k in 8:
			var i := rng.randi() % models.size()
			var m: BirdModel = models[i]
			var car: Node3D = carriers[i]
			ops += 1
			match rng.randi() % 12:
				0, 1, 2:
					var c: Camera3D = cams[0] if car.get_viewport() == worlds[0] or not car.is_inside_tree() else cams[1]
					var dir := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.3, 0.6), rng.randf_range(-1, 1)).normalized()
					car.position = c.global_position + dir * rng.randf_range(0.5, 400.0)
				3:
					if car.is_inside_tree():
						var other := holders[1] if car.get_parent() == holders[0] else holders[0]
						car.reparent(other)
				4:
					car.visible = not car.visible
				5:
					m.species = BirdSpecies.IDS[rng.randi() % 10]
				6:
					m.lod_override = -1 if rng.randf() < 0.6 else rng.randi() % 3
				7:
					m.render_layers = 1 if rng.randf() < 0.7 else 3
				8:
					m.cast_shadows = rng.randf() < 0.7
				9:
					m.highlight = rng.randi() % 3
					m.flap_amount = rng.randf()
					m.wing_fold = rng.randf()
					m.perched = rng.randf() < 0.3
					m.bank = rng.randf_range(-1.0, 1.0)
					m.flap_phase = rng.randf()
				10:
					# Free and recreate (a pooled NPC re-spawned as another species).
					m.free()
					var nm := BirdModels.create(BirdSpecies.IDS[rng.randi() % 10])
					car.add_child(nm)
					nm.scale = Vector3.ONE * rng.randf_range(0.1, 2.1)
					models[i] = nm
				11:
					if car.is_inside_tree():
						car.get_parent().remove_child(car)
						detached.append(car)
					elif detached.has(car):
						detached.erase(car)
						holders[rng.randi() % 2].add_child(car)
		BirdBatch.sync_all(DT)
		# Invariants after every sync.
		var drawn := 0
		for m: BirdModel in models:
			var should := m.is_inside_tree() and m.is_visible_in_tree()
			if should:
				drawn += 1
				if m._batch == null:
					note.call("visible model not in a batch")
					continue
				if m._slot < 0 or m._slot >= m._batch.models.size() or m._batch.models[m._slot] != m:
					note.call("slot bookkeeping")
					continue
				var key_scn := int(m._batch.key.split("|")[0])
				if key_scn != m.get_world_3d().scenario.get_id():
					note.call("drawn in the other world's scenario")
				if m._batch.mesh != BirdModels.mesh(m.species, m.get_lod()):
					note.call("drawn mesh != mesh of get_lod()")
				var parts := m._batch.key.split("|")
				if int(parts[2]) != m.render_layers:
					note.call("wrong render layers")
				if (parts[3] == "1") != (m.cast_shadows and m.get_lod() < 2):
					note.call("wrong shadow setting")
				if _finite_slots(m) != 0:
					note.call("non-finite drawn data")
				if m.lod_override < 0:
					var c := m.get_viewport().get_camera_3d().global_position
					var ang := _drawn_span(m) / maxf(m.global_position.distance_to(c), 0.001)
					var l := m.get_lod()
					var ok := true
					if l == 0 and ang < BirdModel.LOD0_ANGLE * (1.0 - BirdModel.LOD_HYSTERESIS) - 1e-6:
						ok = false
					if l == 1 and (ang >= BirdModel.LOD0_ANGLE * (1.0 + BirdModel.LOD_HYSTERESIS) + 1e-6 or ang < BirdModel.LOD1_ANGLE * (1.0 - BirdModel.LOD_HYSTERESIS) - 1e-6):
						ok = false
					if l == 2 and ang >= BirdModel.LOD1_ANGLE * (1.0 + BirdModel.LOD_HYSTERESIS) + 1e-6:
						ok = false
					if not ok:
						note.call("LOD outside its distance band")
			elif m._batch != null:
				note.call("hidden/detached model still in a batch")
		if BirdBatch.instance_total() != drawn:
			note.call("instance_total != drawn models")
		for b: BirdBatch in BirdBatch.all():
			if b.models.is_empty():
				note.call("empty batch kept")
			if not b.gpu_in_sync():
				note.call("GPU buffer != CPU buffer after sync")
	var batches_live := BirdBatch.count()
	for car in detached:
		car.free()
	for vp in worlds:
		vp.free()
	BirdBatch.sync_all(DT)
	metric("soak", {"frames": frames, "ops": ops, "violations": violations, "batches_while_live": batches_live,
		"batches_after_free": BirdBatch.count()})
	print("[birds-r2] soak: %d frames, %d ops, violations %s, batches live %d, after free %d" % [frames, ops, violations, batches_live, BirdBatch.count()])
	eq(violations.size(), 0, "no invariant broken in %d frames of churn across two worlds (%s)" % [frames, violations])
	eq(BirdBatch.count(), 0, "every batch released once all birds are gone")


func test_r2_highlight_fades_after_a_zero_scale_frame() -> void:
	var m := BirdModels.create(&"crow")
	m.lod_override = 0
	add_child(m)
	m.global_position = Vector3(0, 0, -9)
	m.scale = Vector3.ONE * 0.95
	m.snap()
	BirdBatch.sync_all(1.0 / 60.0)
	m.scale = Vector3.ZERO
	m.highlight = 1
	for i in 2:
		BirdBatch.sync_all(1.0 / 60.0)
	m.scale = Vector3.ONE * 0.95
	m.highlight = 0
	for i in 33:
		BirdBatch.sync_all(1.0 / 60.0)
	var h := m.displayed_highlight()
	print("[birds-r2] highlight shown 33 frames after clearing (after a zero-scale frame): ", h, " inst.w ", m._inst.w)
	lt(maxf(h.x, h.y), 0.02, "the tint has faded 0.55 s after highlight = 0")
