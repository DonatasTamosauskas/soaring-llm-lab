extends TestCase
## DIAGNOSTIC (integration round 1, not in the unit suites): one-on-one
## chases through the REAL chain - the player bird flown by a pilot through
## BotPoseSource and WingInput - against one live NpcBird (its own brain,
## flight and flee), through GameLoop's real catch rule with no assist
## (assist_override 0), in open air over the meadow with the rest of the sky
## emptied. Which lever decides the catch rate: the pilot, the prey's
## evasion, the player's turn.
##
##   tools/gd.sh fx_lab --headless --fixed-fps 72 res://tests/runner.tscn -- --dir=res://tests/shots --suite=integration_chase_lab --fresh-settings [--lab_prey=wren] [--lab_pilot=chase|stock] [--lab_trials=12] [--lab_tag=x]

const Kit := preload("res://tests/unit/integration/game_kit.gd")
const ChasePilot := preload("res://tests/unit/integration/integration_chase_pilot.gd")
var TRIAL_S := float(Paths.arg("lab_secs", "30"))

var kit: Kit


func before_all() -> void:
	kit = Kit.new()
	check(await kit.boot(self), "the game loaded")


func after_all() -> void:
	if kit:
		await kit.teardown()
	await wait_frames(5)


func test_chase_lab() -> void:
	var m := kit.main
	check(await kit.click(&"main", &"play"), "Play")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	m.ui.onboarding.skip()
	# An empty sky: only the bird being chased.
	m.ecosystem.max_npcs = 0
	m.ecosystem.reset()
	await kit.advance(0.5)
	var prey_sp := StringName(Paths.arg("lab_prey", "wren"))
	var pilot_kind := Paths.arg("lab_pilot", "chase")
	var trials := int(Paths.arg("lab_trials", "12"))
	var tag := Paths.arg("lab_tag", "%s_%s" % [prey_sp, pilot_kind])
	var player_mass := float(Paths.arg("lab_mass", "0.03"))
	m.game_loop._set_player_mass(m.player, player_mass, &"diag")
	m.game_loop.assist_override = float(Paths.arg("lab_assist", "0.0"))
	var catches := [0]
	var on_caught := func(pred: Bird, _prey: Bird) -> void:
		if pred == m.player:
			catches[0] += 1
	Events.bird_caught.connect(on_caught)
	var rows := []
	var start := Vector3(-60.0, 0.0, 380.0)  # over the meadow
	start.y = m.world.ground_height(start.x, start.z) + 40.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	for trial in trials:
		m.game_loop.set_protection(m.player, 1e6)
		var yaw := rng.randf_range(-PI, PI)
		m.player.start_flying(start, yaw)
		m.game_loop.teleported(m.player)
		kit.fly_bot(30 + trial, ChasePilot if pilot_kind == "chase" else null)
		kit.set_mode(&"cruise")
		kit.pilot.set(&"heading", yaw)
		kit.fly_straight()
		kit.pilot.set(&"heading", yaw)
		await kit.advance(2.5)
		m.game_loop.set_protection(m.player, 0.0)
		# The prey: 22-28 m ahead, level +-3 m, flying its own way.
		var pp := m.player.get_body_position()
		var f := m.player.velocity
		f = Vector3(f.x, 0.0, f.z).normalized()
		var side := Vector3(-f.z, 0.0, f.x)
		var at := pp + f * rng.randf_range(22.0, 28.0) + side * rng.randf_range(-6.0, 6.0) + Vector3.UP * rng.randf_range(-3.0, 3.0)
		var heading := f.rotated(Vector3.UP, rng.randf_range(-1.2, 1.2))
		var b := NpcBird.new()
		b.configure(prey_sp, -1.0, 500 + trial, Habitat.for_world(m.world))
		b.name = "LabPrey_%d" % trial
		m.add_child(b)
		b.global_position = at
		var v0 := heading * b.flight.cruise
		b.flight.set_velocity(v0)
		b.velocity = v0
		b.global_transform = Transform3D(Basis.looking_at(heading, Vector3.UP), at)
		b.energy = float(Paths.arg("lab_energy", "1.0"))
		if Paths.arg("lab_static", "") != "":
			# A hovering target (frozen): the pilot's and the flight's own
			# precision, nothing else.
			b.set_physics_process(false)
			b.velocity = Vector3.ZERO
		if pilot_kind == "chase":
			(kit.pilot as ChasePilot).chase_prey(b)
		else:
			kit.chase_bird(b)
		var c0: int = catches[0]
		var rec := {"trial": trial, "closest": INF, "closest_h": 0.0, "closest_v": 0.0, "caught": false, "t": TRIAL_S,
			"need": m.game_loop.rule.contact_distance(m.player.get_body_radius(), m.player.get_wingspan(), true, b.get_body_radius()),
			"prey_states": {}, "jinks": 0, "glide_ticks": 0}
		b.behaviour.connect(func(_n: NpcBird, what: StringName) -> void:
			if what == &"jink":
				rec["jinks"] += 1)
		var t := 0.0
		while t < TRIAL_S:
			await kit.advance(1.0 / 72.0)
			t += 1.0 / 72.0
			if int(catches[0]) > c0:
				rec["caught"] = true
				rec["t"] = snappedf(t, 0.01)
				break
			if not is_instance_valid(b) or not b.alive or b.hidden:
				break
			var rel := b.get_body_position() - m.player.get_body_position()
			if rel.length() < float(rec["closest"]):
				rec["closest"] = rel.length()
				rec["closest_h"] = Vector2(rel.x, rel.z).length()
				rec["closest_v"] = rel.y
				rec["prey_speed"] = b.velocity.length()
				rec["player_speed"] = m.player.velocity.length()
			if Paths.arg("lab_trace", "") != "" and fmod(t, float(Paths.arg("lab_trace", "1"))) < 1.0 / 72.0:
				var pl: Vector3 = m.player.get_body_position()
				print("[integration]   t %.1f d %.1f dh %.1f | me %s v %s | prey %s v %s %s | tgt %s roll %.2f eff %.2f flap %s pitch %.2f mode %s" % [t, rel.length(), rel.y,
					pl.snappedf(0.1), m.player.velocity.snappedf(0.1), b.get_body_position().snappedf(0.1), b.velocity.snappedf(0.1), b.state_name(),
					(kit.pilot.get(&"target") as Vector3).snappedf(0.1), kit.pilot.roll, kit.pilot.effort, kit.pilot.flapping, kit.pilot.pitch, m.player.mode_name()])
			var st := b.state_name()
			rec["prey_states"][st] = int(rec["prey_states"].get(st, 0)) + 1
			if pilot_kind == "chase" and (kit.pilot as ChasePilot).gliding:
				rec["glide_ticks"] += 1
		for k in ["closest", "closest_h", "closest_v"]:
			rec[k] = snappedf(float(rec[k]), 0.01)
		rec["need"] = snappedf(float(rec["need"]), 0.01)
		rows.append(rec)
		print("[integration] lab %s trial %d: %s" % [tag, trial, rec])
		if pilot_kind == "chase":
			(kit.pilot as ChasePilot).stop_chase()
		kit.cruise()
		if is_instance_valid(b):
			b.alive = false
			b.queue_free()
		await kit.advance(0.2)
	Events.bird_caught.disconnect(on_caught)
	var n_c := 0
	var cl: Array[float] = []
	for r: Dictionary in rows:
		n_c += 1 if r["caught"] else 0
		cl.append(float(r["closest"]))
	cl.sort()
	print("[integration] lab %s: %d of %d caught; closest median %.2f m (need ~%.2f)" % [tag, n_c, rows.size(), cl[cl.size() / 2], rows[0]["need"]])
	var f2 := FileAccess.open(Paths.artifacts("integration").path_join("chase_lab_%s.json" % tag), FileAccess.WRITE)
	if f2:
		f2.store_string(JSON.stringify({"tag": tag, "caught": n_c, "trials": rows.size(), "rows": rows}, "  "))
	m.game_loop.assist_override = -1.0
