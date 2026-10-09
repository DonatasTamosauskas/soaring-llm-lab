extends "res://tests/unit/ai/ai_sim.gd"
## AI builder DIAGNOSTIC (fix round 3, not part of the suite): replays the
## first case of the verifier's r3x_contacts probe (eagle-sized mock player
## lapping the valley, seed 861) step for step and, whenever the A5 monitor
## flags a bird, prints that bird's last seconds tick by tick: position,
## velocity, state, perch/approach, flare, contact target, obstacle memory.
##   tools/gd.sh ai --headless res://tests/runner.tscn -- --dir=res://scenes/dev/ai_probes --suite=ai_trace
## Options: --tr_case=eagle|pigeon_hunting  --tr_s=140  --tr_bird=<name> (trace one bird by node name)

const Safety := preload("res://tests/unit/ai/safety_monitor.gd")
const Seeker := preload("res://tests/probes/ai/r3x_seeker_player.gd")
const KEEP := 216


func _snap(n: NpcBird, t: float) -> String:
	var br := n.brain
	var ps := "-"
	if n.perch_spot != null:
		ps = str(n.perch_spot.position.snapped(Vector3.ONE * 0.01))
	return "t=%.3f pos=%s v=%s st=%s fl=%s ph=%d near=%s agl=%.2f want=%s spd=%.1f eff=%.2f perch=%s obs_d=%s obs_n=%s slots=%.0f ignore=%s cr=%.2f hits=%d e=%.2f" % [
		t, n.global_position.snapped(Vector3.ONE * 0.01), n.velocity.snapped(Vector3.ONE * 0.1), n.state_name(),
		n.is_flaring(), br._perch_phase, n.near_geometry, n.agl(), n.want_dir.snapped(Vector3.ONE * 0.01), n.want_speed,
		n.max_effort, ps, str(snappedf(br.obs_plane_d(), 0.01)), str(br._ob_n), float(br._ob_p.size()),
		str(n._ignore_near.snapped(Vector3.ONE * 0.01)), n._contact_r, n.geo_hits, n.energy]


func test_trace() -> void:
	var rw := (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
	add_child(rw)
	await wait_physics(3)
	if not rw.is_generated:
		await rw.generated
	var which := Paths.arg("tr_case", "eagle")
	var dur := float(Paths.arg("tr_s", "140"))
	var only := Paths.arg("tr_bird", "")
	var c := rw.get_player_spawn().origin
	var p: Bird = null
	var seed_v := 861
	var hunting := which == "pigeon_hunting"
	if hunting:
		seed_v = 863
		var s := Seeker.new()
		add_child(s)
		s.setup(rw, 0.3, c)
		p = s
	else:
		var mp := MockPlayer.new()
		mp.mass = 3.0
		mp.path_center = Vector3(c.x, 0, c.z)
		mp.path_radius = 90.0
		var gmax := 0.0
		for k in 36:
			var a := TAU * k / 36.0
			gmax = maxf(gmax, rw.ground_height(c.x + cos(a) * 90.0, c.z + sin(a) * 90.0))
		mp.path_height = gmax + 22.0
		mp.speed = minf(SizeRules.cruise_speed(3.0), 14.0)
		add_child(mp)
		mp.step(0.0)
		p = mp
	var e := EcoScene.instantiate() as Ecosystem
	e.auto_step = false
	e.rng_seed = seed_v
	add_child(e)
	e.focus = p
	var chk: RefCounted = CatchChecker.new()
	chk.reach = 0.25
	var safety: RefCounted = Safety.new(rw)
	var hist := {}
	var flagged := {}
	var warm := 20.0
	for i in int(dur / DT):
		var t := i * DT
		if hunting:
			(p as Object).call("step", DT, e.get_npcs())
		else:
			(p as Object).call("step", DT)
		e.step(DT)
		chk.step(DT)
		for n in e.get_npcs():
			if only != "" and String(n.name) != only:
				continue
			var h: Array = hist.get(n, [])
			h.append(_snap(n, t))
			if h.size() > KEEP:
				h.pop_front()
			hist[n] = h
		if t >= warm:
			var before: int = safety.total()
			safety.step(DT, e.get_npcs())
			if safety.total() > before:
				print("[ai-trace] FLAG at t=%.2f: %s" % [t, safety.examples.slice(-1)])
				for n in e.get_npcs():
					if flagged.has(n) or not hist.has(n):
						continue
					# The flagged bird: the one the monitor's last example names by position.
					var ex: String = safety.examples[-1] if not safety.examples.is_empty() else ""
					if ex.contains(str(n.global_position.snapped(Vector3.ONE * 0.01))) or ex.contains(str(n.global_position.snapped(Vector3.ONE * 0.1))):
						flagged[n] = true
						print("[ai-trace] bird %s (%s, span %.2f, r %.3f) history:" % [n.name, n.species, n.get_wingspan(), n.get_body_radius()])
						for line in hist[n]:
							print("[ai-trace]   ", line)
	if only != "":
		for n in hist:
			for line in hist[n]:
				print("[ai-trace]   ", line)
	print("[ai-trace] safety %s %s" % [safety.counts, safety.examples])
	check(true, "traced")
	e.queue_free()
	remove_child(p)
	p.queue_free()
	rw.queue_free()
	Habitat.clear_cache()
	await wait_frames(2)
