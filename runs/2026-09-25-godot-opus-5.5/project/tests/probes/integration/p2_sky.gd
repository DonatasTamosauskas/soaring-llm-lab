extends Node
## VERIFIER PROBE (integration verify round 2, player-experience lens).
## Is the sky alive from the player's seat? The real main.tscn, the player
## cruising the valley (kit pilot, protected so it lives), for PLAY_S:
##  * NPC-on-NPC catches (Events.bird_caught, predator not the player): how
##    many, and how many the player could have SEEN (within SEE_M of the head
##    and inside a 100 deg cone round the view);
##  * per 10 s: NPCs by state (hunting, stooping, fleeing, flocking, perched,
##    soaring, hidden), and the ones in view within SEE_M by state;
##  * rendered runs: a shot whenever a hunt/stoop is in view close enough to
##    read (at most 4), a shot at the murmuration, a shot at perched birds.
##
##   tools/gd.sh p2sky --headless --fixed-fps 72 res://tests/probes/integration/p2_sky.tscn -- --fresh-settings --tag=full [--quality=quest] [--secs=300]
##   (rendered: --rendering-method forward_plus --resolution 1280x960)

const Kit := preload("res://tests/unit/integration/game_kit.gd")
const SEE_M := 60.0

var kit: Kit
var main: GameMain
var tag := "full"
var secs := 300.0
var out := {"rows": [], "npc_catches": [], "shots": []}
var shots_taken := 0
var rendered := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--tag="):
			tag = a.substr(6)
		elif a.begins_with("--secs="):
			secs = float(a.substr(7))
	rendered = DisplayServer.get_name() != "headless"
	_run.call_deferred()


func _in_view(p: Vector3, max_d := SEE_M) -> bool:
	var cam := main.player.camera
	var d := p - cam.global_position
	if d.length() > max_d:
		return false
	var f := -cam.global_basis.z
	return f.dot(d.normalized()) > cos(deg_to_rad(50.0))


func _look_at(p: Vector3) -> void:
	var cam := main.player.camera.global_position
	var d := p - cam
	var yaw_world := atan2(-d.x, -d.z)
	var rel := wrapf(yaw_world - main.player.rig_yaw - kit.bot.body.torso_yaw, -PI, PI)
	kit.bot.body.head_yaw = clampf(rel, deg_to_rad(-80.0), deg_to_rad(80.0))
	kit.bot.body.head_pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()), deg_to_rad(-60.0), deg_to_rad(30.0))


func _shot(name: String, extra := {}) -> void:
	if not rendered:
		return
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(Paths.artifacts("integration").path_join("verify/r2/p2_sky_%s_%s.png" % [tag, name]))
	extra["name"] = name
	out["shots"].append(extra)
	print("[integration] p2_sky shot %s %s" % [name, extra])


func _run() -> void:
	kit = Kit.new()
	if not await kit.boot(self, true):
		get_tree().quit()
		return
	main = kit.main
	var m := main
	m.player.camera.fov = 90.0
	await kit.click(&"main", &"play")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 5.0)
	m.ui.onboarding.skip()
	m.game_loop.set_protection(m.player, 1e6)
	kit.fly_bot(13)
	kit.set_mode(&"climb")
	await kit.advance(3.0)
	kit.set_mode(&"cruise")
	kit.orbit_radius = 120.0
	kit.pilot.set(&"agl", 25.0)
	var seen_catch := [0]
	var on_caught := func(pred: Bird, prey: Bird) -> void:
		if pred == m.player or prey == m.player:
			return
		var pos := prey.global_position
		var seen := _in_view(pos)
		var d := pos.distance_to(m.player.camera.global_position)
		if seen:
			seen_catch[0] += 1
		out["npc_catches"].append({"t": snappedf(Game.run_time, 0.1), "pred": String(pred.species), "prey": String(prey.species),
			"dist": snappedf(d, 1), "in_view": seen})
	Events.bird_caught.connect(on_caught)
	var t := 0.0
	var next := 10.0
	var hunt_in_view_s := 0.0
	var flee_in_view_s := 0.0
	var any_in_view_s := 0.0
	var shot_hunt := 0
	var murm_shot := false
	var perch_shot := false
	while t < secs:
		await kit.advance(1.0 / 12.0)
		t += 1.0 / 12.0
		kit.bot.body.head_yaw = 0.0
		kit.bot.body.head_pitch = deg_to_rad(-5.0)
		var hunt_v := false
		var flee_v := false
		var any_v := false
		var hunt_bird: NpcBird = null
		for b in m.ecosystem.get_npcs():
			if not is_instance_valid(b) or not b.alive or b.hidden:
				continue
			if not _in_view(b.global_position):
				continue
			any_v = true
			if b.state == NpcBird.State.HUNT or b.state == NpcBird.State.STOOP:
				if b.target != null and b.target != m.player:
					hunt_v = true
					hunt_bird = b
			if b.state == NpcBird.State.FLEE:
				flee_v = true
		if hunt_v:
			hunt_in_view_s += 1.0 / 12.0
		if flee_v:
			flee_in_view_s += 1.0 / 12.0
		if any_v:
			any_in_view_s += 1.0 / 12.0
		if rendered and hunt_bird != null and shot_hunt < 4 and hunt_bird.global_position.distance_to(m.player.camera.global_position) < 35.0:
			shot_hunt += 1
			for i in 3:
				_look_at(hunt_bird.global_position)
				await kit.advance(0.03)
			await _shot("hunt_%d" % shot_hunt, {"hunter": String(hunt_bird.species), "prey": String(hunt_bird.target.species) if is_instance_valid(hunt_bird.target) else "?",
				"dist": snappedf(hunt_bird.global_position.distance_to(m.player.camera.global_position), 0.1)})
		if rendered and not murm_shot and t > 60.0:
			for fl in m.ecosystem.get_flocks():
				if fl.kind == "murmuration" and fl.size() > 0:
					var c := fl.centroid()
					var d := c.distance_to(m.player.camera.global_position)
					if d < 120.0:
						murm_shot = true
						for i in 3:
							_look_at(c)
							await kit.advance(0.03)
						await _shot("murmuration", {"size": fl.size(), "dist": snappedf(d, 1)})
					break
		if rendered and not perch_shot and t > 90.0:
			for b in m.ecosystem.get_npcs():
				if is_instance_valid(b) and b.state == NpcBird.State.PERCHED:
					var d2 := b.global_position.distance_to(m.player.camera.global_position)
					if d2 < 15.0:
						perch_shot = true
						for i in 3:
							_look_at(b.global_position)
							await kit.advance(0.03)
						await _shot("perched", {"species": String(b.species), "dist": snappedf(d2, 0.1)})
						break
		if t >= next:
			next += 10.0
			var st := {}
			var vis := {}
			for b in m.ecosystem.get_npcs():
				if not is_instance_valid(b) or not b.alive:
					continue
				var k: String = "HIDDEN" if b.hidden else NpcBird.State.keys()[b.state]
				st[k] = int(st.get(k, 0)) + 1
				if not b.hidden and _in_view(b.global_position):
					vis[k] = int(vis.get(k, 0)) + 1
			var flocks := []
			for fl in m.ecosystem.get_flocks():
				flocks.append([fl.kind, String(fl.species), fl.size()])
			out["rows"].append({"t": snappedf(t, 1), "states": st, "in_view_60m": vis, "flocks": flocks})
	Events.bird_caught.disconnect(on_caught)
	var n_c: int = out["npc_catches"].size()
	out["summary"] = {"secs": secs, "npc_catches": n_c, "npc_catches_per_min": snappedf(n_c / (secs / 60.0), 0.01),
		"npc_catches_seen": seen_catch[0], "hunt_in_view_share": snappedf(hunt_in_view_s / secs, 0.001),
		"flee_in_view_share": snappedf(flee_in_view_s / secs, 0.001), "any_bird_in_view_60m_share": snappedf(any_in_view_s / secs, 0.001),
		"npcs": m.ecosystem.count(), "errors": kit.log.errors}
	print("[integration] p2_sky %s summary %s" % [tag, out["summary"]])
	var f := FileAccess.open(Paths.artifacts("integration").path_join("verify/r2/p2_sky_%s.json" % tag), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(out, "  "))
		f.close()
	await kit.teardown()
	get_tree().quit()
