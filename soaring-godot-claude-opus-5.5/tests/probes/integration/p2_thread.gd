extends Node
## VERIFIER PROBE (integration verify round 2, player-experience lens).
## "Open windows you can fly through": can the real bird (the real chain:
## BotPoseSource arms -> WingInput -> FlightModel, collisions and all) be
## flown through the valley's fly-through openings by a steady pilot lined
## up on the axis? For a set of openings (house windows, the belfry, the
## barn's broken boards, hedge tunnels, nest-box-sized holes excluded), the
## sparrow starts 14 m out on the opening's axis at its centre height,
## cruising, and the pilot steers at a point 12 m beyond the exit at the
## centre's height. Recorded: passed (crossed beyond the exit), stuns /
## bumps, closest miss of the centre line; rendered: approach and inside.
##
##   tools/gd.sh p2thread --rendering-method forward_plus --resolution 1280x960 --fixed-fps 72 res://tests/probes/integration/p2_thread.tscn -- --fresh-settings

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var kit: Kit
var main: GameMain
var out := {"runs": []}
var rendered := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	rendered = DisplayServer.get_name() != "headless"
	_run.call_deferred()


func _shot(name: String) -> void:
	if not rendered:
		return
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(Paths.artifacts("integration").path_join("verify/r2/p2_thread_%s.png" % name))


func _try(op: Dictionary, label: String, shots: bool) -> Dictionary:
	var p := main.player
	var c: Vector3 = op["position"]
	var ex: Vector3 = op.get("exit", c)
	var axis := Vector3.ZERO
	if op.has("normal"):
		axis = -(op["normal"] as Vector3)
	if ex.distance_to(c) > 0.2:
		axis = (ex - c).normalized()
	if axis.length() < 0.5:
		return {}
	axis.y = 0.0
	axis = axis.normalized()
	var start := c - axis * 14.0
	var goal := c + axis * 14.0
	goal.y = c.y
	var yaw := atan2(-axis.x, -axis.z)
	p.start_flying(start, yaw, 0.0)
	main.game_loop.teleported(p)
	main.game_loop.set_protection(p, 1e6)
	kit.pilot.set(&"target", goal)
	kit.pilot.set(&"chase", true)
	kit.nav = &"heading"
	kit.set_mode(&"cruise")
	kit.bot.body.head_yaw = 0.0
	kit.bot.body.head_pitch = 0.0
	var stuns := 0
	var was_stunned := false
	var min_lat := INF
	var passed := false
	var shot1 := false
	var shot2 := false
	var t := 0.0
	var depth := maxf(float(op.get("depth", 0.3)), 0.1)
	var entered := false
	while t < 6.0:
		await kit.advance(1.0 / 72.0)
		t += 1.0 / 72.0
		var bp := p.get_body_position()
		var rel := bp - c
		var along := rel.dot(axis)
		var lat := (rel - axis * along).length()
		if absf(along) < 1.0:
			min_lat = minf(min_lat, lat)
		var st := float(p.telemetry()["stun_left"]) > 0.0
		if st and not was_stunned:
			stuns += 1
		was_stunned = st
		if shots and not shot1 and along > -5.0:
			shot1 = true
			await _shot("%s_approach" % label)
		if shots and not shot2 and along > depth * 0.5:
			shot2 = true
			await _shot("%s_inside" % label)
		if along > depth + 0.5 and lat < maxf(float(op.get("width", 1.0)), float(op.get("height", 1.0))):
			entered = true
		if along > 11.0:
			passed = true
			break
	var r := {"name": op["name"], "type": op.get("type", op.get("kind")), "w": op.get("width", op.get("radius")), "h": op.get("height", -1),
		"max_span": op.get("max_span", -1), "entered": entered, "through_11m": passed, "stuns": stuns, "min_lat_at_plane": snappedf(min_lat, 0.01),
		"t": snappedf(t, 0.01), "mode_end": p.mode_name()}
	print("[integration] p2_thread %s %s" % [label, r])
	return r


func _run() -> void:
	kit = Kit.new()
	if not await kit.boot(self, true):
		get_tree().quit()
		return
	main = kit.main
	main.player.camera.fov = 90.0
	await kit.click(&"main", &"play")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 5.0)
	main.ui.onboarding.skip()
	kit.fly_bot(5)
	kit.set_mode(&"climb")
	await kit.advance(2.0)
	var ops: Array = main.world.get_openings()
	var by_type := {}
	for o: Dictionary in ops:
		var ty := String(o.get("type", o.get("kind", "?")))
		if not by_type.has(ty):
			by_type[ty] = []
		by_type[ty].append(o)
	out["types"] = {}
	for k in by_type:
		out["types"][k] = by_type[k].size()
	print("[integration] p2_thread opening types %s" % [out["types"]])
	if not by_type.is_empty():
		print("[integration] p2_thread sample %s" % [by_type[by_type.keys()[0]][0]])
	var n_shots := 0
	for ty in ["window", "belfry", "barn_board", "barn_door", "arch", "hedge_gap"]:
		if not by_type.has(ty):
			continue
		var lst: Array = by_type[ty]
		var k := 0
		for o: Dictionary in lst:
			var span := float(o.get("max_span", 1.0))
			if span < main.player.model.params.span * 1.2:
				continue
			k += 1
			if k > 4:
				break
			var r := await _try(o, "%s_%d" % [ty, k], k == 1 and n_shots < 6)
			if k == 1:
				n_shots += 1
			if not r.is_empty():
				out["runs"].append(r)
	var passed := 0
	for r: Dictionary in out["runs"]:
		if r["entered"] and r["stuns"] == 0:
			passed += 1
	out["summary"] = {"tries": out["runs"].size(), "clean_passes": passed, "errors": kit.log.errors}
	print("[integration] p2_thread summary %s" % [out["summary"]])
	var f := FileAccess.open(Paths.artifacts("integration").path_join("verify/r2/p2_thread.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(out, "  "))
		f.close()
	await kit.teardown()
	get_tree().quit()
