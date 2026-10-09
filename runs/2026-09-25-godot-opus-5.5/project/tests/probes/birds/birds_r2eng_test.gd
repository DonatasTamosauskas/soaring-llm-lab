extends TestCase
## Round-2 engineering verifier probes for the birds area (read-only on the
## area's sources). Each probe states what it pins; metrics land in the
## report so the verifier can quote numbers.

const Geo := preload("res://tests/unit/birds/bird_geo.gd")
const DT := 1.0 / 72.0


func after_each() -> void:
	for c in get_children():
		c.free()
	BirdBatch.sync_all(DT)


## Contract/doc claim: slim species drawn up to ~1.4-1.6 deg when far and
## highlighted; the instance really is scaled to that angle, and not at all
## when unhighlighted.
func test_min_highlight_size_is_applied() -> void:
	var table := {}
	for sp in BirdSpecies.IDS:
		table[String(sp)] = snappedf(rad_to_deg(BirdModels.min_highlight_angle(sp)), 0.001)
	metric("min_highlight_deg", table)
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	BirdBatch.sync_all(DT)
	var m := BirdModels.create(&"moth")
	var span: float = SizeRules.species_data(&"moth")["span"]
	m.scale = Vector3.ONE * span
	add_child(m)
	m.position = Vector3(0, 0, -40)
	m.highlight = 1
	m.snap()
	BirdBatch.sync_all(DT)
	var ang := m._xf.basis.x.length() / 40.0
	near(ang, BirdModels.min_highlight_angle(&"moth"), 1e-4, "highlighted moth at 40 m drawn at its minimum angle")
	m.highlight = 0
	m.snap()
	BirdBatch.sync_all(DT)
	near(m._xf.basis.x.length(), span, 1e-5, "unhighlighted: true size")
	metric("moth_drawn_deg_40m", snappedf(rad_to_deg(ang), 0.001))


## BIRDS.md: "Perched, the head stays level (beak within 0.045 of the head
## centre)". How far would the beak rise if the head did NOT counter-pitch?
## If that is under 0.045 for every species, the suite cannot tell a level
## head from one pitched up with the body.
func test_head_counter_pitch_is_pinned() -> void:
	var rows := {}
	var undetectable := 0
	for sp in BirdSpecies.IDS:
		if sp == &"moth":
			continue
		var arr := Geo.arrays(sp)
		var rest: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var g := Geo.groups(arr)
		var beak := 0
		for i in rest.size():
			if rest[i].z < rest[beak].z:
				beak = i
		var hc := Vector3.ZERO
		var n := 0
		for i in rest.size():
			if g[i] == BirdPose.G_HEAD:
				hc += rest[i]
				n += 1
		hc /= n
		var rel := rest[beak] - hc
		var pitch_deg: float = BirdSpecies.data(sp)["anim"][3]
		# Without the counter-pitch the head turns with the body.
		var rot := BirdPose.rx(rel, deg_to_rad(pitch_deg))
		var dy_level := rel.y
		var dy_pitched := rot.y
		rows[String(sp)] = {"beak_minus_head_y_level": snappedf(dy_level, 0.001), "if_not_counter_pitched": snappedf(dy_pitched, 0.001), "body_pitch_deg": pitch_deg}
		if absf(dy_pitched) < 0.045:
			undetectable += 1
	metric("head_level_sensitivity", rows)
	metric("species_where_missing_counter_pitch_passes_0045", undetectable)
	check(true, "data only")


## WingTrails ranks trails per drawn frame via BirdBatch.syncs; headless
## runs never sync, so the per-frame list must not grow without bound.
func test_trail_budget_list_bounded_without_draws() -> void:
	var bird := Bird.new()
	bird.mass = 1.3
	add_child(bird)
	var m := BirdModels.create(&"hawk")
	m.scale = Vector3.ONE * 1.6
	bird.add_child(m)
	var tr := BirdFX.attach_trails(m)
	var cruise: float = SizeRules.performance(1.3)["cruise"]
	bird.velocity = Vector3(0, -cruise * 2.4, -cruise)
	var n0: int = WingTrails._want_now.size()
	for i in 600:
		bird.position += bird.velocity * DT
		tr.step(DT)
	var n1: int = WingTrails._want_now.size()
	metric("want_list_before_after_600_steps", [n0, n1])
	lt(n1 - n0, 50, "trail ranking list stays bounded when nothing draws (%d -> %d)" % [n0, n1])


## Moving a model into another World3D (a SubViewport with its own world)
## must move it to a batch of that scenario.
func test_world_change_moves_batch() -> void:
	var m := BirdModels.create(&"crow")
	m.lod_override = 0
	add_child(m)
	BirdBatch.sync_all(DT)
	var k0: String = m._batch.key
	var vp := SubViewport.new()
	vp.own_world_3d = true
	add_child(vp)
	remove_child(m)
	vp.add_child(m)
	BirdBatch.sync_all(DT)
	check(m._batch != null, "has a batch in the new world")
	var k1: String = m._batch.key if m._batch else ""
	check(k0 != k1 and k1.begins_with(str(vp.find_world_3d().scenario.get_id())), "batch of the SubViewport's scenario (%s -> %s)" % [k0, k1])
	eq(BirdBatch.count(), 1, "old batch released")


## Bursts free themselves under the engine's own _process (the suite steps
## them by hand).
func test_bursts_free_with_real_process() -> void:
	var nodes0 := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	for i in 10:
		BirdFX.feather_burst(self, Vector3(i, 5, 0), Color(0, 0, 0, 0), 0.3, &"pigeon", Vector3.ZERO, i)
	gt(Performance.get_monitor(Performance.OBJECT_NODE_COUNT), nodes0, "bursts exist")
	await wait_seconds(2.8)
	await get_tree().process_frame
	eq(Performance.get_monitor(Performance.OBJECT_NODE_COUNT), nodes0, "all freed by their own _process")


## Worst case for the sync: every one of 60 birds changing LOD in the same
## frame (camera jumping across the thresholds), and 60 birds all at LOD0.
func test_sync_cost_worst_cases() -> void:
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	var models: Array[BirdModel] = []
	for i in 60:
		var sp: StringName = BirdSpecies.IDS[i % 10]
		var m := BirdModels.create(sp)
		m.scale = Vector3.ONE * float(SizeRules.species_data(sp)["span"])
		add_child(m)
		m.position = Vector3((i % 10) * 0.6 - 3.0, (i / 10) * 0.6, -6.0)
		models.append(m)
	BirdBatch.sync_all(DT)
	var near_t := PackedFloat32Array()
	var flip_t := PackedFloat32Array()
	var moves := 0
	for f in 120:
		for i in 60:
			models[i].flap_phase = fposmod(f * DT * 8.0 + i * 0.1, 1.0)
			models[i].flap_amount = 1.0
			models[i].highlight = i % 3
		if f >= 60:
			# Jump the camera near/far each frame: every bird changes LOD.
			cam.position = Vector3(0, 0, 0 if f % 2 == 0 else 400)
		var t0 := Time.get_ticks_usec()
		BirdBatch.sync_all(DT)
		var us := float(Time.get_ticks_usec() - t0)
		if f >= 10 and f < 60:
			near_t.append(us)
		elif f >= 62:
			flip_t.append(us)
			moves += BirdBatch.last_lod_moves
	var med := func(a: PackedFloat32Array) -> float:
		var s := Array(a)
		s.sort()
		return s[s.size() / 2]
	metric("sync_us_60_close", med.call(near_t))
	metric("sync_us_60_all_changing_lod", med.call(flip_t))
	metric("lod_moves_per_flip_frame", moves / float(flip_t.size()))
	lt(med.call(flip_t), 1000.0, "60 simultaneous LOD changes < 1 ms")


## Mesh generation is deterministic (same arrays when built twice).
func test_mesh_build_is_deterministic() -> void:
	var diff := 0
	for sp in BirdSpecies.IDS:
		var a: Dictionary = BirdMeshBuilder.build(sp, 0, {})
		var b: Dictionary = BirdMeshBuilder.build(sp, 0, {})
		var va: PackedVector3Array = a["arrays"][Mesh.ARRAY_VERTEX]
		var vb: PackedVector3Array = b["arrays"][Mesh.ARRAY_VERTEX]
		var ca: PackedColorArray = a["arrays"][Mesh.ARRAY_COLOR]
		var cb: PackedColorArray = b["arrays"][Mesh.ARRAY_COLOR]
		if va != vb or ca != cb:
			diff += 1
	eq(diff, 0, "every species builds identically twice")


## The UI-facing colour constants equal the shader's defaults.
func test_highlight_constants_match_shader() -> void:
	var code := BirdModels.SHADER.code
	for pair in [["prey_color", BirdModels.HIGHLIGHT_EDIBLE], ["threat_color", BirdModels.HIGHLIGHT_DANGER]]:
		var at := code.find("uniform vec3 %s" % pair[0])
		var v0 := code.find("vec3(", at + 10) + 5
		var parts := code.substr(v0, code.find(")", v0) - v0).split(",")
		var c := Color(float(parts[0]), float(parts[1]), float(parts[2]))
		var want: Color = pair[1]
		check(c.is_equal_approx(want) or (absf(c.r - want.r) < 0.002 and absf(c.g - want.g) < 0.002 and absf(c.b - want.b) < 0.002), "%s default %s == %s" % [pair[0], c.to_html(false), want.to_html(false)])


## lod_override changes are drawn at once with the matching mesh.
func test_lod_override_change_is_drawn() -> void:
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	var m := BirdModels.create(&"gull")
	add_child(m)
	m.position = Vector3(0, 0, -3)
	BirdBatch.sync_all(DT)
	eq(m.get_lod(), 0, "close: LOD0")
	m.lod_override = 2
	BirdBatch.sync_all(DT)
	eq(m.get_lod(), 2, "override: LOD2")
	check(m._batch.mesh == BirdModels.mesh(&"gull", 2), "drawing the LOD2 mesh")
	check(m._batch.gpu_in_sync(), "uploaded")
