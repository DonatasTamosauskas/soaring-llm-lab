extends TestCase
## UI evidence tool (not in the UI suite: it runs the whole game): are the
## HUD's notices calm in the LIVE game, on the current code of every area?
## For each bot seed (--seeds), through the real chain (scenes/main.tscn via
## the integration kit: BotPoseSource arms -> WingInput -> PlayerBird in the
## valley, GameLoop, the Ecosystem, the UI): Play by the pointer, the
## first-flight lessons each flown with its gesture (the round-7 verifiers'
## schedule, ui_r7x_live), then CHASE_S of hunting with the catch lesson up
## (the pilot flies at GameLoop's target cue, as the competent person does).
## Measured on the notice band, sampled after the UI placed it each frame:
##  - move starts per second of notices shown (the lead's bar: < 0.1/s);
##  - the flight path behind a READABLE notice plate (alpha >= 0.6, i.e. not
##    faded out of the way): the longest unbroken stretch (bar: <= 0.3 s);
##  - fades (see-through onsets), the card readable in view.
##
##   GD_TIMEOUT=1500 tools/gd.sh ui_calm --headless --fixed-fps 72 res://tests/runner.tscn -- \
##       --dir=res://tests/shots --suite=ui_live_calm --seeds=3,8,14 --fresh-settings
##
## Writes artifacts/ui/live_calm.json (per seed and the worst of all).

const Kit := preload("res://tests/unit/integration/game_kit.gd")
const CHASE_S := 60.0
const MOVE_BAR_PER_S := 0.1
const HIDDEN_BAR_S := 0.3

var kit: Kit
var booted := false
var results := {}
var _target: Bird


func before_all() -> void:
	kit = Kit.new()
	booted = await kit.boot(self)
	Events.target_changed.connect(func(b: Variant) -> void: _target = b as Bird)
	print("[ui] real game booted: %s" % booted)


func after_all() -> void:
	var f := FileAccess.open(Paths.artifacts("ui").path_join("live_calm.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(results, "  "))
	print("[ui] live calm: %s" % JSON.stringify(results.get("worst", {})))
	if kit:
		await kit.teardown()
	await wait_frames(5)


class Watch:
	var clock := 0.0
	var shown_s := 0.0
	var card_frames := 0
	var readable_in_view := 0
	var fades := 0
	var moves: Array = []
	var hidden_run := 0.0
	var hidden_max := 0.0
	var hidden_total := 0.0
	var _st := false
	var _moves_seen := -1
	var phase := "lessons"


class _Late:
	extends Node
	var fn: Callable

	func _init(f: Callable) -> void:
		fn = f
		process_priority = 100000
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _process(_d: float) -> void:
		fn.call()


## Largest angle (deg) from the camera's gaze to the card's words.
func _ecc() -> float:
	var ui := kit.main.ui
	var cam := kit.main.player.camera
	var g := -cam.global_basis.z
	var worst := 0.0
	for lbl: Label in ui.hud.lesson_labels():
		if lbl == null or not lbl.is_visible_in_tree() or lbl.text == "":
			continue
		var r := lbl.get_global_rect()
		for x: float in [r.position.x, r.get_center().x, r.end.x]:
			var d := ui.hud_panel.pixel_to_world(Vector2(x, r.get_center().y)) - cam.global_position
			worst = maxf(worst, rad_to_deg(g.angle_to(d)))
	return worst


## Is the flight path (the velocity, from the eye) behind a notice plate?
func _path_behind_plate() -> bool:
	var ui := kit.main.ui
	var p := kit.main.player
	if p.velocity.length() < 1.5 * p.origin.world_scale:
		return false
	var px := ui.hud_panel.direction_pixel(HUD.BAND_NOTICE, p.velocity.normalized())
	if not px.is_finite():
		return false
	for r: Rect2 in ui.hud.notice_rects():
		if r.has_point(px):
			return true
	return false


func _watch(w: Watch) -> void:
	var ui := kit.main.ui
	if Game.state != Game.State.PLAYING or not ui.hud_panel.shown:
		return
	var dt := 1.0 / 72.0
	w.clock += dt
	var hud := ui.hud
	if hud.band_plates(HUD.BAND_NOTICE).is_empty():
		w._st = false
		w.hidden_run = 0.0
		return
	w.shown_s += dt
	if w._moves_seen < 0:
		w._moves_seen = hud.move_count
	if hud.move_count != w._moves_seen:
		w.moves.append([snappedf(w.clock, 0.01), w.phase, ",".join(ui.notice_causes())])
	w._moves_seen = hud.move_count
	var st: bool = hud.see_through[HUD.BAND_NOTICE]
	if st and not w._st:
		w.fades += 1
	w._st = st
	var a := ui.hud_panel.band_alpha(HUD.BAND_NOTICE)
	if a >= HUD.READABLE_ALPHA and _path_behind_plate():
		w.hidden_run += dt
		w.hidden_total += dt
		w.hidden_max = maxf(w.hidden_max, w.hidden_run)
	else:
		w.hidden_run = 0.0
	if hud.lesson_visible() and not hud.toast_active():
		w.card_frames += 1
		if a >= HUD.READABLE_ALPHA and _ecc() <= 45.0:
			w.readable_in_view += 1


func _fly(seed_value: int) -> Dictionary:
	var ui := kit.main.ui
	if Game.state != Game.State.MENU:
		ui.bridge.quit_to_menu()
		await kit.frames(3)
	ui.onboarding.reset()
	await kit.frames(2)
	var clicked := await kit.click(&"main", &"play")
	if not await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0):
		return {"error": "Play did not start a run", "clicked": clicked}
	var w := Watch.new()
	var sampler := _Late.new(func() -> void: _watch(w))
	add_child(sampler)
	kit.fly_bot(seed_value)
	var ob := ui.onboarding
	var gesture := {&"spread": &"cruise", &"flap": &"flap", &"glide": &"glide", &"speed": &"speed",
		&"turn": &"turn", &"dive": &"dive", &"catch": &"cruise"}
	var t := 0.0
	while t < 100.0 and ob.active and ob.current().get("id") != &"catch" and Game.state == Game.State.PLAYING:
		var id: StringName = ob.current().get("id", &"")
		var agl: float = kit.pilot.get(&"last_agl")
		var mode: StringName = gesture.get(id, &"cruise")
		if ob.celebrating > 0.0 or (mode in [&"glide", &"speed", &"dive"] and agl < 22.0):
			mode = &"climb"
		kit.set_mode(mode)
		await kit.advance(0.25)
		t += 0.25
	# The hunt, the catch lesson up until a catch: fly at the target cue.
	w.phase = "hunt"
	kit.set_mode(&"cruise")
	var h := 0.0
	var lesson_end := -1.0
	while h < CHASE_S:
		if is_instance_valid(_target) and _target.alive and _target.is_inside_tree():
			kit.chase(_target.get_body_position())
		elif bool(kit.pilot.get(&"chase")):
			kit.cruise()
		await kit.advance(0.1)
		h += 0.1
		if lesson_end < 0.0 and not ob.active:
			lesson_end = h
	kit.cruise()
	sampler.queue_free()
	return {"seed": seed_value, "lessons_s": t, "hunt_s": h, "catch_lesson_over_after_s": snappedf(lesson_end, 0.1),
		"notices_shown_s": snappedf(w.shown_s, 0.01), "moves": w.moves,
		"move_starts_per_s": snappedf(w.moves.size() / maxf(w.shown_s, 0.01), 0.001),
		"fades": w.fades, "path_hidden_longest_s": snappedf(w.hidden_max, 0.001),
		"path_hidden_total_s": snappedf(w.hidden_total, 0.001),
		"card_readable_in_view_frac": snappedf(float(w.readable_in_view) / maxi(w.card_frames, 1), 0.001),
		"player_caught": kit.count("player_caught"), "state_at_end": Game.State.keys()[Game.state]}


func test_notices_are_calm_in_the_live_game() -> void:
	check(booted, "the real game booted")
	if not booted:
		return
	var worst := {"move_starts_per_s": 0.0, "path_hidden_longest_s": 0.0, "moves": 0, "min_readable_in_view": 1.0}
	for v: String in Paths.arg("seeds", "3,8,14").split(","):
		var sd := int(v)
		var r := await _fly(sd)
		results["seed_%d" % sd] = r
		print("[ui] live calm, seed %d: %s" % [sd, JSON.stringify(r)])
		if r.has("error"):
			check(false, "seed %d: %s" % [sd, r["error"]])
			continue
		worst["move_starts_per_s"] = maxf(worst["move_starts_per_s"], r["move_starts_per_s"])
		worst["path_hidden_longest_s"] = maxf(worst["path_hidden_longest_s"], r["path_hidden_longest_s"])
		worst["moves"] = maxi(worst["moves"], (r["moves"] as Array).size())
		worst["min_readable_in_view"] = minf(worst["min_readable_in_view"], r["card_readable_in_view_frac"])
		lt(float(r["move_starts_per_s"]), MOVE_BAR_PER_S, "seed %d: notice move starts per second shown (bar < %.1f)" % [sd, MOVE_BAR_PER_S])
		lt(float(r["path_hidden_longest_s"]), HIDDEN_BAR_S + 1e-6, "seed %d: longest flight path behind a readable plate (bar <= %.1f s)" % [sd, HIDDEN_BAR_S])
	results["worst"] = worst
