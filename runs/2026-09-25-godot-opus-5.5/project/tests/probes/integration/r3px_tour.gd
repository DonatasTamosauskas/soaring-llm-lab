extends Node
## VERIFIER PROBE (integration, player-experience lens, round 1; re-run in round 3 as r3px_tour).
## A player's-eye tour of the real game (main.tscn, UI in its VR form, head
## camera at a headset's 90 deg): the menus, the first lesson, the valley's
## districts at sparrow size, the same vantage points as a pigeon and an
## eagle (does the world shrink?), and the NPCs around the player.
##
##   tools/gd.sh pxv_tour --rendering-method forward_plus --resolution 1280x960 --fixed-fps 72 res://tests/probes/integration/px_tour.tscn -- --fresh-settings
##
## Writes artifacts/integration/verify/r3px/tour_*.png and tour.json.

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var kit: Kit
var main: GameMain
var shots := []
var info := {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_run.call_deferred()


func _shot(name: String, extra := {}) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := Paths.artifacts("integration").path_join("verify/r3px/tour_%s.png" % name)
	img.save_png(path)
	var p := main.player
	var rec := {"name": name, "state": Game.state_name(), "species": String(p.species),
		"world_scale": snappedf(p.origin.world_scale, 0.001), "pos": [snappedf(p.global_position.x, 0.1),
		snappedf(p.global_position.y, 0.1), snappedf(p.global_position.z, 0.1)], "npcs_in_view": _npcs_in_view()}
	rec.merge(extra)
	shots.append(rec)
	print("[integration] px shot %s %s" % [name, rec])


func _npcs_in_view() -> int:
	var cam := main.player.camera
	var n := 0
	for b in main.ecosystem.get_npcs():
		if is_instance_valid(b) and b.alive and not cam.is_position_behind(b.global_position):
			var sp := cam.unproject_position(b.global_position)
			var r := get_viewport().get_visible_rect()
			if r.has_point(sp) and cam.global_position.distance_to(b.global_position) < 250.0:
				n += 1
	return n


func _look_at(p: Vector3) -> void:
	if kit.bot == null:
		return
	var cam := main.player.camera.global_position
	var d := p - cam
	var yaw_world := atan2(-d.x, -d.z)
	var rel := wrapf(yaw_world - main.player.rig_yaw - kit.bot.body.torso_yaw, -PI, PI)
	kit.bot.body.head_yaw = clampf(rel, deg_to_rad(-80.0), deg_to_rad(80.0))
	kit.bot.body.head_pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()), deg_to_rad(-60.0), deg_to_rad(30.0))


func _landmark(name: String) -> Dictionary:
	for l in main.world.get_landmarks():
		if String(l["name"]) == name:
			return l
	return {}


func _landmarks_kind(kind: String) -> Array:
	var o := []
	for l in main.world.get_landmarks():
		if String(l["kind"]) == kind:
			o.append(l)
	return o


## Put the bird in the air at `from` heading at `look`, the bot gliding /
## cruising straight, then look at `look` and shoot after `settle` s.
func _vantage(name: String, from: Vector3, look: Vector3, settle := 1.2, mode := &"glide", agl := 30.0) -> void:
	var p := main.player
	var d := look - from
	var yaw := atan2(-d.x, -d.z)
	p.start_flying(from, yaw, 0.0)
	main.game_loop.teleported(p)
	main.game_loop.set_protection(p, 9999.0)
	kit.pilot.set(&"heading", yaw)
	kit.pilot.set(&"target", Vector3.INF)
	kit.pilot.set(&"chase", false)
	kit.pilot.set(&"agl", agl)
	kit.pilot.set(&"min_agl", minf(8.0, agl))
	kit.nav = &"heading"
	kit.set_mode(mode)
	var t := 0.0
	while t < settle:
		_look_at(look)
		await kit.advance(0.1)
		t += 0.1
	_look_at(look)
	await kit.frames(3)
	await _shot(name, {"look": [snappedf(look.x, 1), snappedf(look.y, 1), snappedf(look.z, 1)]})


func _set_mass(m: float) -> void:
	main.game_loop._set_player_mass(main.player, m, &"probe")
	# world_scale ramps: give it time.
	await kit.advance(4.0)


func _run() -> void:
	kit = Kit.new()
	var ok := await kit.boot(self, true)
	main = kit.main
	if not ok:
		print("[integration] px_tour: boot failed")
		get_tree().quit()
		return
	info["load"] = main.load_report.duplicate(true)
	main.player.camera.fov = 90.0
	await kit.advance(1.0)
	# --- menus
	kit.aim_at(kit.button(&"main", &"play"))
	await kit.frames(6)
	await _shot("menu")
	await kit.click(&"main", &"howto")
	await kit.advance(1.0)
	await _shot("howto")
	# the How to fly tabs a player would open
	info["howto_screen"] = String(main.ui.current_screen_id())
	for tab: StringName in [&"tab_speed", &"tab_turn", &"tab_hunt", &"tab_controls"]:
		if kit.button(main.ui.current_screen_id(), tab) != null:
			await kit.click(main.ui.current_screen_id(), tab)
			await kit.advance(0.8)
			await _shot("howto_%s" % String(tab).substr(4))
	if main.ui.current_screen_id() != &"main":
		await kit.click(main.ui.current_screen_id(), &"back")
		await kit.advance(0.6)
	await kit.click(&"main", &"settings")
	await kit.advance(1.0)
	await _shot("settings")
	info["settings_screen"] = String(main.ui.current_screen_id())
	await kit.click(main.ui.current_screen_id(), &"back")
	await kit.advance(0.6)
	# --- play: the first lesson on the perch
	await kit.click(&"main", &"play")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	await kit.advance(1.5)
	await _shot("play_perched")
	kit.fly_bot(7)
	kit.set_mode(&"climb")
	await kit.advance(3.0)
	await _shot("takeoff")
	kit.set_mode(&"cruise")
	main.ui.onboarding.skip()
	await kit.advance(2.0)
	# --- the valley's districts as a sparrow
	var sq := Vector3(WorldLayout.SQUARE.x, main.world.ground_height(WorldLayout.SQUARE.x, WorldLayout.SQUARE.y), WorldLayout.SQUARE.y)
	var gh := func(x: float, z: float) -> float: return main.world.ground_height(x, z)
	await _vantage("village_street", Vector3(-210, gh.call(-210, 30) + 5.0, 30), Vector3(-120, gh.call(-120, 30) + 4.0, 30), 1.2, &"cruise", 5.0)
	var wins := _landmarks_kind("window")
	info["windows"] = wins.size()
	if not wins.is_empty():
		var w: Dictionary = wins[wins.size() / 2]
		var wp: Vector3 = w["position"]
		var ex: Vector3 = w.get("exit", wp)
		var axis := (ex - wp).normalized() if ex.distance_to(wp) > 0.1 else Vector3.FORWARD
		info["window_sample"] = {"name": w["name"], "radius": w["radius"], "max_span": w.get("max_span", -1)}
		await _vantage("window_approach", wp - axis * 7.0, ex, 0.3, &"glide", 3.0)
	var belfry := _landmark("belfry")
	if not belfry.is_empty():
		var bp: Vector3 = belfry["position"]
		await _vantage("belfry", bp + Vector3(0, 3, 26), bp, 0.8)
	var pl := _landmark("power_line")
	if not pl.is_empty():
		var pp: Vector3 = pl["position"]
		await _vantage("power_line", pp + Vector3(-40, 4, 25), pp + Vector3(30, 0, 0), 0.8, &"cruise", 10.0)
	var ride := _landmark("forest_ride_0")
	if not ride.is_empty():
		var rp: Vector3 = ride["position"]
		await _vantage("forest_ride", Vector3(-128, gh.call(-128, -322) + 3.0, -322), rp + Vector3(0, 3, 0), 0.5, &"glide", 3.0)
	var ow := _landmark("old_wood")
	if not ow.is_empty():
		var op: Vector3 = ow["position"]
		await _vantage("old_wood_canopy", op + Vector3(80, 40, 80), op, 1.0)
	var col := _landmark("swallow_colony")
	if not col.is_empty():
		var cp: Vector3 = col["position"]
		await _vantage("swallow_colony", cp + Vector3(30, 2, 0), cp, 0.8)
	var cliff := _landmark("west_cliff")
	if not cliff.is_empty():
		var clp: Vector3 = cliff["position"]
		await _vantage("west_cliff", clp + Vector3(110, 25, 40), clp, 1.0)
	var can := _landmark("canyon")
	if not can.is_empty():
		await _vantage("canyon", Vector3(118, gh.call(118, -300) + 25.0, -300), Vector3(150, 25, -420), 1.0, &"glide")
	var arch := _landmark("canyon_arch")
	if not arch.is_empty():
		var ap: Vector3 = arch["position"]
		await _vantage("canyon_arch", ap + Vector3(0, 4, 45), ap, 0.8)
	var br := _landmark("bridge")
	if not br.is_empty():
		var brp: Vector3 = br["position"]
		await _vantage("bridge", brp + Vector3(0, -1, 45), brp, 0.8, &"glide", 4.0)
	var lk := _landmark("lake")
	if not lk.is_empty():
		var lp: Vector3 = lk["position"]
		await _vantage("lake", lp + Vector3(-120, 35, -110), lp, 1.0)
	var la := Vector3(WorldLayout.LAKE_ARCH.x, gh.call(WorldLayout.LAKE_ARCH.x, WorldLayout.LAKE_ARCH.y) + 6.0, WorldLayout.LAKE_ARCH.y)
	await _vantage("lake_arch", la + Vector3(-40, 6, -20), la, 0.8)
	var wt := _landmark("water_tower")
	if not wt.is_empty():
		var wtp: Vector3 = wt["position"]
		await _vantage("water_tower", wtp + Vector3(20, 2, 20), wtp, 0.8)
	var mast := _landmark("radio_mast")
	if not mast.is_empty():
		var mp: Vector3 = mast["position"]
		await _vantage("radio_mast", mp + Vector3(-60, -20, -30), mp + Vector3(0, -30, 0), 0.8)
	var th: Array = main.world.get_thermals()
	info["thermals"] = th.size()
	if not th.is_empty():
		var t0: Dictionary = th[2] if th.size() > 2 else th[0]
		var tp: Vector3 = t0["position"]
		await _vantage("thermal", tp + Vector3(70, gh.call(tp.x + 70, tp.z) + 25.0 - tp.y, 40), tp + Vector3(0, 40, 0), 1.0)
	# --- the sky around the player after it had time to fill (orbit the square)
	kit.orbit_centre = sq
	kit.orbit_radius = 70.0
	kit.cruise()
	kit.pilot.set(&"agl", 25.0)
	kit.set_mode(&"cruise")
	main.player.start_flying(sq + Vector3(70, 30, 0), 0.0, 0.0)
	main.game_loop.teleported(main.player)
	await kit.advance(12.0)
	kit.bot.body.head_yaw = 0.0
	kit.bot.body.head_pitch = deg_to_rad(-10.0)
	await kit.advance(0.5)
	await _shot("sky_sparrow")
	# --- growth: the same vantage as sparrow, pigeon, eagle
	var vp := sq + Vector3(0, 0, 110)
	var ch := Vector3(WorldLayout.CHURCH.x, gh.call(WorldLayout.CHURCH.x, WorldLayout.CHURCH.y) + 10.0, WorldLayout.CHURCH.y)
	for sp: Array in [["sparrow", 0.030], ["pigeon", 0.300], ["eagle", 3.0]]:
		await _set_mass(float(sp[1]))
		info["ws_" + String(sp[0])] = main.player.origin.world_scale
		await _vantage("scale_%s" % sp[0], Vector3(vp.x, gh.call(vp.x, vp.z) + 20.0, vp.z), ch, 1.0)
	# eagle's sky
	main.player.start_flying(sq + Vector3(120, 80, 0), 0.0, 0.0)
	main.game_loop.teleported(main.player)
	kit.cruise()
	kit.orbit_radius = 140.0
	kit.pilot.set(&"agl", 70.0)
	await kit.advance(15.0)
	kit.bot.body.head_yaw = 0.0
	kit.bot.body.head_pitch = deg_to_rad(-15.0)
	await kit.advance(0.5)
	await _shot("sky_eagle")
	info["shots"] = shots
	info["errors"] = kit.log.errors
	info["warnings"] = kit.log.warnings
	info["log"] = kit.log.samples
	var f := FileAccess.open(Paths.artifacts("integration").path_join("verify/r3px/tour.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(info, "  "))
		f.close()
	print("[integration] px_tour done: %d shots, %s" % [shots.size(), kit.log.summary()])
	await kit.teardown()
	get_tree().quit()
