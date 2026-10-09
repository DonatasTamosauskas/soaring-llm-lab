extends TestCase
## SCREENSHOTS (integration round 1): the living sky from the player's head,
## the view straight along the flight (106 x 90 deg, as sky_view_test
## measures it), at both tiers, while the bot laps the verifier's orbit.
## Rendered (Forward+ on this Mac: the Mobile renderer paints MoltenVK tiles):
##
##   tools/gd.sh fx_shots --rendering-method forward_plus --resolution 1280x960 --fixed-fps 72 res://tests/runner.tscn -- --dir=res://tests/shots --suite=integration_sky_shots --fresh-settings
##
## Writes artifacts/integration/sky_<tier>_<n>.png and sky_shots.json (the
## birds a player notices in each image).

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var kit: Kit


func before_all() -> void:
	kit = Kit.new()
	check(await kit.boot(self, true), "the game loaded")


func after_all() -> void:
	if kit:
		await kit.teardown()
	await wait_frames(5)


func _seen() -> Array:
	var m := kit.main
	var cam := m.player.camera
	var eye := cam.global_position
	var inv := cam.global_basis.inverse()
	var th := tan(deg_to_rad(53.0))
	var tv := tan(deg_to_rad(45.0))
	var out := []
	for b in m.ecosystem.get_npcs():
		if not is_instance_valid(b) or not b.alive or b.hidden:
			continue
		var rel := b.global_position - eye
		var loc := inv * rel
		if loc.z > -0.1 or absf(loc.x / -loc.z) > th or absf(loc.y / -loc.z) > tv:
			continue
		if b.get_wingspan() / maxf(rel.length(), 0.01) >= deg_to_rad(0.37):
			out.append("%s %.0f m" % [b.species, rel.length()])
	return out


func _shot(name: String, res: Dictionary) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := Paths.artifacts("integration").path_join("sky_%s.png" % name)
	img.save_png(path)
	res[name] = _seen()
	print("[integration] sky shot %s: %d birds noticed %s" % [name, (res[name] as Array).size(), res[name]])


func test_sky_from_the_head() -> void:
	var m := kit.main
	m.player.camera.fov = 90.0
	var res := {}
	for tier: StringName in [&"quest", &"full"]:
		var q := QualityTier.new()
		if tier == &"quest":
			q.set_quest()
		q.apply_ecosystem(m.ecosystem)
		if Game.state != Game.State.PLAYING:
			check(await kit.click(&"main", &"play"), "Play")
			await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
		m.game_loop.restart_run()
		await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
		m.ui.onboarding.skip()
		m.game_loop.set_protection(m.player, 1e6)
		kit.fly_bot(9)
		kit.set_mode(&"climb")
		await kit.advance(3.0)
		kit.set_mode(&"cruise")
		kit.pilot.set(&"agl", 25.0)
		kit.orbit_radius = 90.0
		kit.cruise()
		await kit.advance(25.0)
		for i in 4:
			# The head along the flight, 5 deg down (the bot's head already
			# follows the body; the camera looks where the bird flies).
			kit.bot.body.head_yaw = 0.0
			kit.bot.body.head_pitch = deg_to_rad(-5.0)
			await kit.advance(6.0)
			await _shot("%s_%d" % [tier, i], res)
		# The murmuration (integration round 2: its NPCs plus the visual-only
		# mass, MurmurationSwarm): the head turned to it, as a player looks.
		for fl in m.ecosystem.get_flocks():
			if fl.kind == "murmuration" and fl.size() > 0:
				# A moment a player could look at it: within 70 deg of the
				# flight (the head turns 80 deg at most) and 20-90 m out (a
				# nearer flock is under the wing; round 2's first full-tier
				# shot was taken with it 16 m off, behind the wing). Up to
				# 60 s of the lap.
				for w in 120:
					var dv := fl.centroid() - m.player.camera.global_position
					var fwd := Vector3(m.player.velocity.x, 0.0, m.player.velocity.z)
					var ang := absf(fwd.signed_angle_to(Vector3(dv.x, 0.0, dv.z), Vector3.UP)) if fwd.length() > 0.5 else PI
					if ang < deg_to_rad(70.0) and dv.length() > 20.0 and dv.length() < 90.0:
						break
					await kit.advance(0.5)
				for k in 8:
					var d := fl.centroid() - m.player.camera.global_position
					var yaw_world := atan2(-d.x, -d.z)
					kit.bot.body.head_yaw = clampf(wrapf(yaw_world - m.player.rig_yaw - kit.bot.body.torso_yaw, -PI, PI), deg_to_rad(-80.0), deg_to_rad(80.0))
					kit.bot.body.head_pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()), deg_to_rad(-60.0), deg_to_rad(30.0))
					await kit.advance(0.05)
				await _shot("%s_murmuration" % tier, res)
				# The same, zoomed 3x (a 30 deg field of view): the mass itself.
				m.player.camera.fov = 30.0
				await kit.advance(0.05)
				await _shot("%s_murmuration_zoom" % tier, res)
				m.player.camera.fov = 90.0
				res["%s_murmuration_info" % tier] = {"npcs": fl.size(), "swarm": m.ecosystem.swarm.shown() if m.ecosystem.swarm else 0,
					"dist_m": snappedf(fl.centroid().distance_to(m.player.camera.global_position), 1.0)}
				break
	var f := FileAccess.open(Paths.artifacts("integration").path_join("sky_shots.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(res, "  "))
	QualityTier.new().apply_ecosystem(m.ecosystem)
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())
