extends Node
## Screenshots of the composed game's key moments, from the player's head
## (integration). Runs inside scenes/main.tscn:
##
##   tools/gd.sh integ --rendering-method forward_plus --resolution 1280x960 res://scenes/main.tscn -- --harness=shots --fresh-settings
##
## The UI is shown in its VR form (curved panels in the world, laser
## pointer), the head camera is widened to a headset's field of view, and
## the game is played by the bot (flight's BotPoseSource through the real
## WingInput) with prey and a predator staged on its path, as in the
## whole-game tests. Writes artifacts/integration/shot_*.png.

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var main: GameMain
var kit: Kit
var shots := []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	main = get_parent() as GameMain
	if not main.is_loaded:
		await main.loaded
	_run.call_deferred()


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := Paths.artifacts("integration").path_join("shot_%s.png" % name)
	img.save_png(path)
	var st: Dictionary = Capture.image_stats(img)
	shots.append({"name": name, "state": Game.state_name(), "species": main.player.species,
		"world_scale": main.player.origin.world_scale, "stats": st})
	print("[integration] shot %s (%s, %s, world_scale %.3f)" % [name, Game.state_name(), main.player.species, main.player.origin.world_scale])


## Turns the bot's head to look at a world point (yaw within +-80 deg of
## the body, like a person).
func _look_at(p: Vector3) -> void:
	if kit.bot == null:
		return
	var cam := main.player.camera.global_position
	var d := p - cam
	var yaw_world := atan2(-d.x, -d.z)
	var rel := wrapf(yaw_world - main.player.rig_yaw - kit.bot.body.torso_yaw, -PI, PI)
	kit.bot.body.head_yaw = clampf(rel, deg_to_rad(-80.0), deg_to_rad(80.0))
	kit.bot.body.head_pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()), deg_to_rad(-60.0), deg_to_rad(30.0))


func _look(yaw_deg: float, pitch_deg: float) -> void:
	# The bot's body turns its head (HumanPoseModel), the pose source writes
	# it into the XR camera like a real head.
	if kit.bot != null:
		kit.bot.body.head_yaw = deg_to_rad(yaw_deg)
		kit.bot.body.head_pitch = deg_to_rad(pitch_deg)


func _run() -> void:
	kit = Kit.new()
	kit.attach(self, main)
	OS.low_processor_usage_mode_sleep_usec = 1000
	main.ui.set_vr_mode(true)
	kit.left = UIPointerSource.new(&"left_hand")
	kit.right = UIPointerSource.new(&"right_hand")
	main.ui.set_pointer_sources(kit.left, kit.right)
	kit.park_hands()
	# A headset's view (the Quest Pro's is ~96 deg tall); keep the aspect.
	main.player.camera.fov = 90.0
	await kit.advance(2.0)
	# 1. The main menu in the world, the laser on Play.
	kit.aim_at(kit.button(&"main", &"play"))
	await kit.frames(6)
	await _shot("menu")
	# 1b. Settings (integration round 2: the Turn speed bar), then back.
	await kit.click(&"main", &"settings")
	await kit.frames(6)
	kit.aim_at(main.ui.get_screen(&"settings").get_bar("turn_comfort"))
	await kit.frames(6)
	await _shot("settings")
	await kit.click(&"settings", &"back")
	await kit.frames(4)
	# 2. Play, the first lesson, the first flight over the village.
	main.ui.onboarding.reset()
	await kit.click(&"main", &"play")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	kit.fly_bot(7)
	kit.orbit_centre = Vector3(WorldLayout.SQUARE.x, 0, WorldLayout.SQUARE.y)
	kit.orbit_radius = 70.0
	kit.set_mode(&"climb")
	await kit.advance(4.0)
	kit.set_mode(&"cruise")
	# Look along the flight, a little right and down: since UI fix round 5
	# the HUD's centre line is the flight direction and the lesson card sits
	# beside it, 10-52 deg to the right (a look at the church, inside the
	# orbit, left both out of the picture: the round-1 verifier's image).
	# The orbit circles the square, so the village is below and ahead.
	var t_ff := 0.0
	while t_ff < 8.0:
		_look(-18.0, -12.0)
		await kit.advance(0.1)
		t_ff += 0.1
	await kit.frames(3)
	await _shot("first_flight")
	main.ui.onboarding.skip()
	# 3. A chase: a wren ahead (edible: highlighted), then the catch and
	# its feathers. A pass that misses is flown again with a new wren.
	var caught := [false]
	var catch_at := [Vector3.ZERO]
	var on_catch := func(pred: Bird, p: Bird) -> void:
		if pred == main.player:
			caught[0] = true
			catch_at[0] = p.get_body_position()
	Events.bird_caught.connect(on_catch)
	var took_chase := false
	for attempt in 4:
		_look(0.0, 0.0)
		kit.fly_straight()
		await kit.advance(2.0)
		var prey := kit.stage_prey(&"wren", 26.0)
		for i in 500:
			await get_tree().physics_frame
			if is_instance_valid(prey):
				_look_at(prey.global_position)
				var d := prey.global_position.distance_to(main.player.get_body_position())
				if not took_chase and d < 1.3:
					took_chase = true
					await _shot("chase")
				var rel := prey.global_position - main.player.get_body_position()
				if rel.dot(main.player.velocity) < 0.0 and d > 1.5:
					break
			if caught[0]:
				break
		if caught[0]:
			# The burst is where the bird was, i.e. at the player's head: an
			# observer camera beside the catch shows it (evidence only; the
			# player sees the feathers fly past).
			var at: Vector3 = catch_at[0]
			var obs := Camera3D.new()
			obs.fov = 60.0
			obs.near = 0.01
			add_child(obs)
			var side := main.player.global_basis.x
			obs.global_position = at + side * 1.1 + Vector3.UP * 0.35 - main.player.velocity.normalized() * 0.6
			obs.look_at(at, Vector3.UP)
			obs.make_current()
			await kit.advance(0.12)
			await _shot("catch_feathers")
			await kit.advance(0.35)
			await _shot("catch_feathers_later")
			obs.clear_current()
			obs.queue_free()
			main.player.camera.make_current()
			break
		if is_instance_valid(prey):
			kit.release(prey)
		kit.cruise()
	kit.cruise()
	_look(0.0, 0.0)
	# 4. Growing into a swallow: the tier-up celebration.
	var tier := SizeRules.tier_for_mass(main.player.mass)
	for k in 6:
		if SizeRules.tier_for_mass(main.player.mass) > tier:
			break
		kit.fly_straight()
		await kit.advance(1.5)
		var c0: int = kit.stats()["catches"]
		var w := kit.stage_prey(&"wren", 28.0)
		await kit.wait_until(func() -> bool: return int(kit.stats()["catches"]) > c0, 6.0)
		if is_instance_valid(w) and w.alive:
			kit.release(w)
		kit.cruise()
	await kit.advance(0.8)
	await _shot("tier_up")
	await kit.advance(3.0)
	# 5. A predator: the danger cue, then caught.
	if main.game_loop.protection_left(main.player) > 0.0:
		main.game_loop.set_protection(main.player, 0.0)
	kit.fly_straight()
	await kit.advance(1.5)
	var hawk := kit.stage_strike(&"hawk", 34.0, 8.0)
	var shot_danger := false
	for i in 600:
		await get_tree().physics_frame
		if not shot_danger and is_instance_valid(hawk) and hawk.global_position.distance_to(main.player.get_body_position()) < 9.0:
			shot_danger = true
			await _shot("danger")
		if Game.state == Game.State.CAUGHT:
			break
	await kit.advance(0.6)
	await _shot("caught")
	kit.free_staged()
	# 6. Caught until the run ends: the summary.
	for n in 5:
		if Game.state == Game.State.ENDED:
			break
		await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 5.0)
		kit.set_mode(&"climb")
		await kit.advance(3.0)
		kit.set_mode(&"cruise")
		main.game_loop.set_protection(main.player, 0.0)
		kit.fly_straight()
		await kit.advance(1.0)
		kit.stage_strike(&"hawk", 30.0, 12.0)
		await kit.wait_until(func() -> bool: return Game.state == Game.State.CAUGHT or Game.state == Game.State.ENDED, 8.0)
		kit.free_staged()
		await kit.wait_until(func() -> bool: return Game.state != Game.State.CAUGHT, 4.0)
	await kit.advance(1.0)
	kit.park_hands()
	await kit.frames(4)
	await _shot("summary")
	Events.bird_caught.disconnect(on_catch)
	var f := FileAccess.open(Paths.artifacts("integration").path_join("shots.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"shots": shots, "errors": kit.log.errors, "warnings": kit.log.warnings,
			"log": kit.log.summary()}, "  "))
	print("[integration] shots done: %d, %s" % [shots.size(), kit.log.summary()])
	kit.log.uninstall()
	main.quit_for_real = true
	main.quit_game()
