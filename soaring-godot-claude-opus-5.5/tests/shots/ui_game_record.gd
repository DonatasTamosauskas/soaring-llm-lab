extends Node
## Records how the REAL game's flight moves the view, for the UI suites to
## replay: tests/unit/ui/ui_game_flights.json (in the real tree).
##
## Why: the HUD's notices must stay in view of a player at rest and clear of
## the flight path. The round-5 suites replayed flights as [t, flight-path
## angle, speed] with the path's azimuth locked to the rig's forward, and so
## never saw what the round-6 verifier measured in the real game: a slow
## sparrow's path crabbing 15-50 deg off where it faces in the valley's
## breeze, a loop over the top reversing its heading while the view turns
## round at its comfort rate, the rig yawing with every flown turn.
##
## The UI suites may depend only on core contracts, stubs and the area's
## own mocks (ARCHITECTURE hard rules), so the game is flown here, once, and
## the suites replay the recording through the mock player (as they do for
## ui_flight_runs.json and flight's B1 course). Rerun after a change to
## flight, the world's wind or the integration bot:
##
##   tools/gd.sh ui_rec --headless --fixed-fps 72 res://tests/shots/ui_game_record.tscn
##
## It boots scenes/main.tscn through the integration area's test kit (the
## whole game: world, flight's PlayerBird and WingInput, the integration
## bot's arm motion, GameLoop), clicks Play with the laser pointer, and flies:
##  - "tutorial": the first-flight lessons, each flown with its gesture (the
##    round-6 verifier's schedule: spread, flap, glide, speed, turn, dive,
##    then cruising with the catch lesson up), 15 s past the last one;
##  - "manoeuvres": straight on from there: an orbit cruise, hard banked
##    turns both ways, a dive and a zoom climb, a chase of staged prey.
## Every other physics tick (36 Hz), in WORLD space as the game has them:
##   [t s, rig yaw deg (the XROrigin3D's heading: PlayerBird yaws it with
##    flown turns), velocity x y z m/s (Bird.velocity), forward x y z
##    (Bird.get_forward(): the beak, with body pitch), body_yaw deg
##    (telemetry: the torso in the rig's frame), head yaw deg and pitch deg
##    (the camera in the rig's frame), world_scale, lesson index (-1 none),
##    target id, its position from the eye x y z (world, m), threat id, its
##    position from the eye x y z, threat level]
## The target and the threat are what GameLoop last named on
## Events.target_changed / threat_changed (id -1: none; ids number the
## birds in the order they were first named), so a replay can put a stand-in
## bird where each was and name it the same way: the cues and the notices
## then meet the real sky too.

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var kit: Kit
var rows: Array = []
var flight := ""
var _clock := 0.0
var _n := 0
## GameLoop's last target and threat (and its level), and ids for birds.
var _target: Bird
var _threat: Bird
var _threat_level := 0.0
var _ids := {}


func _ready() -> void:
	var ok := await _record()
	get_tree().quit(0 if ok else 1)


func _record() -> bool:
	kit = Kit.new()
	if not await kit.boot(self):
		printerr("[ui] the real game did not boot")
		return false
	var m := kit.main
	var ui := m.ui
	var out := {
		"about": "The real game's flight as the view sees it (world space; see tests/shots/ui_game_record.gd), replayed by ui_hud_test so the UI suites never run other areas' code.",
		"recorded": Time.get_datetime_string_from_system(true),
		"columns": ["t", "rig_yaw_deg", "vx", "vy", "vz", "fx", "fy", "fz", "body_yaw_deg", "head_yaw_deg", "head_pitch_deg", "world_scale", "lesson",
			"target_id", "tx", "ty", "tz", "threat_id", "hx", "hy", "hz", "threat_level"],
		"flights": {},
	}
	Events.target_changed.connect(func(b: Bird) -> void: _target = b)
	Events.threat_changed.connect(func(lv: float, b: Bird) -> void:
		_threat = b
		_threat_level = lv)
	ui.onboarding.reset()
	if not await kit.click(&"main", &"play"):
		printerr("[ui] Play was not hovered")
	if not await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0):
		printerr("[ui] Play did not start a run")
		return false
	var sampler := _Late.new(_sample)
	add_child(sampler)
	kit.fly_bot()
	# 1. The tutorial, each lesson flown with its gesture.
	_begin("tutorial")
	var ob := ui.onboarding
	var gesture := {&"spread": &"cruise", &"flap": &"flap", &"glide": &"glide", &"speed": &"speed",
		&"turn": &"turn", &"dive": &"dive", &"catch": &"cruise"}
	var t := 0.0
	while t < 100.0 and ob.active and ob.current().get("id") != &"catch":
		var id: StringName = ob.current().get("id", &"")
		var agl: float = kit.pilot.get(&"last_agl")
		var mode: StringName = gesture.get(id, &"cruise")
		if ob.celebrating > 0.0 or (mode in [&"glide", &"speed", &"dive"] and agl < 22.0):
			mode = &"climb"
		kit.set_mode(mode)
		await kit.advance(0.25)
		t += 0.25
	kit.set_mode(&"cruise")
	await kit.advance(15.0)
	(out["flights"] as Dictionary)["tutorial"] = rows
	print("[ui] tutorial: %d samples, %.1f s (lessons %.1f s)" % [rows.size(), _clock, t])
	# 2. Manoeuvres, straight on from there.
	_begin("manoeuvres")
	kit.cruise()
	await kit.advance(12.0)
	for turn: float in [1.0, -1.0]:
		kit.pilot.set(&"turn_sign", turn)
		kit.set_mode(&"turn")
		await kit.advance(5.0)
		kit.set_mode(&"cruise")
		await kit.advance(4.0)
	kit.set_mode(&"climb")
	await kit.advance(3.0)
	kit.set_mode(&"dive")
	await kit.advance(2.5)
	kit.set_mode(&"climb")
	await kit.advance(4.0)
	kit.set_mode(&"cruise")
	await kit.advance(4.0)
	if Game.state == Game.State.PLAYING:
		var prey := kit.stage_prey(&"moth", 26.0)
		kit.chase_bird(prey)
		await kit.wait_until(func() -> bool: return not is_instance_valid(prey) or not prey.alive, 8.0)
		kit.cruise()
	await kit.advance(6.0)
	(out["flights"] as Dictionary)["manoeuvres"] = rows
	print("[ui] manoeuvres: %d samples, %.1f s" % [rows.size(), _clock])
	sampler.queue_free()
	out["live_ui"] = live
	print("[ui] the real UI meanwhile: %s" % JSON.stringify(live))
	var root := OS.get_environment("SOARING_ROOT")
	if root.is_empty():
		root = ProjectSettings.globalize_path("res://")
	var path := root.path_join("tests/unit/ui/ui_game_flights.json")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "", false))
	f.close()
	print("[ui] recorded %d flights into %s (errors in the game: %d)" % [(out["flights"] as Dictionary).size(), path, kit.log.errors])
	await kit.teardown()
	return true


func _begin(name_: String) -> void:
	flight = name_
	rows = []
	_clock = 0.0
	_n = 0


func _sample() -> void:
	if Game.state != Game.State.PLAYING or kit == null or kit.main == null:
		return
	_clock += 1.0 / 72.0
	_n += 1
	_watch_ui()
	if _n % 2 != 0:
		return
	var p := kit.main.player
	var rig := p.origin
	var cam := p.camera
	var rf := -rig.global_basis.orthonormalized().z
	var head := cam.transform.basis.orthonormalized()
	var hf := -head.z
	var v := p.velocity
	var fw := p.get_forward()
	var tel: Dictionary = p.telemetry()
	var ob := kit.main.ui.onboarding
	var eye := cam.global_position
	var row := [snappedf(_clock, 0.001), snappedf(rad_to_deg(atan2(-rf.x, -rf.z)), 0.01),
		snappedf(v.x, 0.001), snappedf(v.y, 0.001), snappedf(v.z, 0.001),
		snappedf(fw.x, 0.0001), snappedf(fw.y, 0.0001), snappedf(fw.z, 0.0001),
		snappedf(rad_to_deg(float(tel.get("body_yaw", 0.0))), 0.01),
		snappedf(rad_to_deg(atan2(-hf.x, -hf.z)), 0.01), snappedf(rad_to_deg(asin(clampf(hf.y, -1.0, 1.0))), 0.01),
		snappedf(rig.world_scale, 0.0001), ob.index if ob.active else -1]
	for b: Variant in [_target, _threat]:
		if is_instance_valid(b) and (b as Bird).is_inside_tree():
			var bird := b as Bird
			if not _ids.has(bird.get_instance_id()):
				_ids[bird.get_instance_id()] = _ids.size()
			var rel := bird.get_body_position() - eye
			row.append_array([_ids[bird.get_instance_id()], snappedf(rel.x, 0.001), snappedf(rel.y, 0.001), snappedf(rel.z, 0.001)])
		else:
			row.append_array([-1, 0.0, 0.0, 0.0])
	row.append(snappedf(_threat_level if is_instance_valid(_threat) else 0.0, 0.001))
	rows.append(row)


## The real UI's notices while the game flies (diagnostics, in the JSON's
## "live_ui"): each time the lesson card turns see-through or moves, what
## was on it (within the 1.5 deg fade margin): the flight path, GameLoop's
## target or a real threat, or their cue chevrons.
var live: Dictionary = {}
var _was_see_through := false
var _moves_seen := -1


func _watch_ui() -> void:
	var ui := kit.main.ui
	var hud := ui.hud
	if not hud.lesson_visible():
		_was_see_through = false
		return
	var fl: Dictionary = live.get_or_add(flight, {"fades": [], "moves": [], "frames": 0, "see_through_frames": 0})
	fl["frames"] = int(fl["frames"]) + 1
	var st: bool = hud.see_through[HUD.BAND_NOTICE]
	if st:
		fl["see_through_frames"] = int(fl["see_through_frames"]) + 1
	if _moves_seen < 0:
		_moves_seen = hud.move_count
	var moved := hud.move_count != _moves_seen
	_moves_seen = hud.move_count
	if (st and not _was_see_through) or moved:
		(fl["moves" if moved else "fades"] as Array).append([snappedf(_clock, 0.01), _causes()])
	_was_see_through = st


func _causes() -> String:
	var ui := kit.main.ui
	var p := kit.main.player
	var eye := p.camera.global_position
	var out: Array[String] = []
	var dirs := {}
	if p.velocity.length() > 1.5 * p.origin.world_scale:
		dirs["path"] = p.velocity
	if is_instance_valid(_target):
		dirs["target"] = _target.get_body_position() - eye
	if is_instance_valid(_threat) and UIRoot.is_real_threat(_threat_level):
		dirs["threat"] = _threat.get_body_position() - eye
	for which: StringName in [&"target", &"threat"]:
		var cue := ui.indicators.cue_mesh(which)
		if cue and cue.visible:
			dirs["%s cue" % which] = cue.global_position - eye
	var m := deg_to_rad(HUD.FADE_MARGIN_DEG) * UITheme.HUD_DISTANCE * UITheme.PX_PER_M
	for key: String in dirs:
		var px := ui.hud_panel.direction_pixel(HUD.BAND_NOTICE, (dirs[key] as Vector3).normalized())
		if not px.is_finite():
			continue
		for r: Rect2 in ui.hud.notice_rects():
			if r.grow(m).has_point(px):
				out.append(key)
				break
	return ",".join(out)


## Runs its callable at the end of every process frame (after the game and
## the UI have moved everything for this frame).
class _Late:
	extends Node
	var fn: Callable

	func _init(f: Callable) -> void:
		fn = f
		process_priority = 100000
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _process(_d: float) -> void:
		fn.call()
