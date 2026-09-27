extends Node
## VERIFIER PROBE (integration, player-experience lens, round 1).
## What the sky looks like from the player's head (90 deg, a headset's
## field): after the sky has filled round the cruising player, how many NPC
## birds are in view and how many of them are big enough to see (projected
## wingspan in pixels), plus shots straight ahead, at the biggest flock, and
## at the nearest bird. Run at full and at the Quest tier.
##
##   tools/gd.sh pxv_sky --rendering-method forward_plus --resolution 1280x960 --fixed-fps 72 res://tests/probes/integration/px_sky.tscn -- --fresh-settings [--quality=quest] --tag=full

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var kit: Kit
var main: GameMain
var out := {"views": []}
var tag := "full"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--tag="):
			tag = a.substr(6)
	_run.call_deferred()


func _view_stats() -> Dictionary:
	var cam := main.player.camera
	var vp := get_viewport().get_visible_rect()
	var px_per_rad := vp.size.y / deg_to_rad(cam.fov)
	var in_view := 0
	var ge4 := 0
	var ge8 := 0
	var ge16 := 0
	for b in main.ecosystem.get_npcs():
		if not is_instance_valid(b) or not b.alive or b.hidden:
			continue
		if cam.is_position_behind(b.global_position):
			continue
		var sp := cam.unproject_position(b.global_position)
		if not vp.has_point(sp):
			continue
		in_view += 1
		var d := cam.global_position.distance_to(b.global_position)
		var px := b.get_wingspan() / maxf(d, 0.01) * px_per_rad
		if px >= 4.0:
			ge4 += 1
		if px >= 8.0:
			ge8 += 1
		if px >= 16.0:
			ge16 += 1
	return {"in_view": in_view, "span_ge_4px": ge4, "span_ge_8px": ge8, "span_ge_16px": ge16, "npcs": main.ecosystem.count()}


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(Paths.artifacts("integration").path_join("verify/px_sky_%s_%s.png" % [tag, name]))
	var st := _view_stats()
	st["name"] = name
	out["views"].append(st)
	print("[integration] px_sky %s %s %s" % [tag, name, st])


func _look_at(p: Vector3) -> void:
	var cam := main.player.camera.global_position
	var d := p - cam
	var yaw_world := atan2(-d.x, -d.z)
	var rel := wrapf(yaw_world - main.player.rig_yaw - kit.bot.body.torso_yaw, -PI, PI)
	kit.bot.body.head_yaw = clampf(rel, deg_to_rad(-80.0), deg_to_rad(80.0))
	kit.bot.body.head_pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()), deg_to_rad(-60.0), deg_to_rad(30.0))


func _run() -> void:
	kit = Kit.new()
	if not await kit.boot(self, true):
		get_tree().quit()
		return
	main = kit.main
	main.player.camera.fov = 90.0
	await kit.click(&"main", &"play")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	main.ui.onboarding.skip()
	main.game_loop.set_protection(main.player, 1e6)
	kit.fly_bot(9)
	kit.set_mode(&"climb")
	await kit.advance(3.0)
	kit.set_mode(&"cruise")
	kit.orbit_radius = 90.0
	kit.pilot.set(&"agl", 25.0)
	await kit.advance(30.0)
	# Straight ahead, sampled over 20 s (a stat per second, shots at 3 moments).
	var sums := {"in_view": 0.0, "span_ge_4px": 0.0, "span_ge_8px": 0.0, "span_ge_16px": 0.0}
	var n := 0
	for i in 20:
		kit.bot.body.head_yaw = 0.0
		kit.bot.body.head_pitch = deg_to_rad(-5.0)
		await kit.advance(1.0)
		var st := _view_stats()
		for k in sums:
			sums[k] += float(st[k])
		n += 1
		if i in [4, 12, 19]:
			await _shot("ahead_%d" % i)
	for k in sums:
		sums[k] = snappedf(sums[k] / n, 0.01)
	out["ahead_mean"] = sums
	# The biggest flock.
	var best: FlockGroup = null
	for f in main.ecosystem.get_flocks():
		if best == null or f.size() > best.size():
			best = f
	if best != null and best.size() > 0:
		var c := Vector3.ZERO
		var m := 0
		for b in best.members:
			if is_instance_valid(b):
				c += b.global_position
				m += 1
		if m > 0:
			c /= m
			out["flock"] = {"size": m, "dist": snappedf(c.distance_to(main.player.camera.global_position), 0.1)}
			for i in 4:
				_look_at(c)
				await kit.advance(0.1)
			await _shot("flock")
	# The nearest bird.
	var near: NpcBird = null
	var nd := INF
	for b in main.ecosystem.get_npcs():
		if is_instance_valid(b) and b.alive and not b.hidden:
			var d := b.global_position.distance_to(main.player.camera.global_position)
			if d < nd:
				nd = d
				near = b
	if near != null:
		out["nearest"] = {"species": String(near.species), "dist": snappedf(nd, 0.1)}
		for i in 3:
			_look_at(near.global_position)
			await kit.advance(0.05)
		await _shot("nearest")
	out["errors"] = kit.log.errors
	var f := FileAccess.open(Paths.artifacts("integration").path_join("verify/px_sky_%s.json" % tag), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(out, "  "))
		f.close()
	print("[integration] px_sky %s done: ahead mean %s flock %s nearest %s; %s" % [tag, sums, out.get("flock"), out.get("nearest"), kit.log.summary()])
	await kit.teardown()
	get_tree().quit()
