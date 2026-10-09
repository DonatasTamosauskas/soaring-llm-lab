extends TestCase
## Verifier probe (round 2 of this pass, engineering lens) for the ui area.
## Not part of the area's suite; run with:
##   tools/gd.sh ui_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/ui --suite=ui_v2eng
##
## 1. The real rig hierarchy: flight's PlayerBird is the XROrigin3D's parent
##    and yaws with every flown turn (player_bird.gd _apply_rig:
##    global_transform = Basis(UP, rig_yaw)), while Bird.velocity is in world
##    space. Every suite test keeps the mock rig at the identity, so
##    UIRoot.flight_yaw()'s world -> rig conversion is never exercised. Here
##    the rig is parented to a yawing "body" (70 deg, then a 60 deg/s flown
##    turn) and the HUD strip must stay on the flight path in WORLD terms.
## 2. Settings > Replay tutorial in the same session, after the lessons have
##    run to their end (all timed out), brings the lessons back on the next
##    flight (Onboarding.reset must clear the per-session `_ran` latch).

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")
const SDT := 1.0 / 72.0

var k: Kit
var body: Node3D


func before_each() -> void:
	k = Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)


func after_each() -> void:
	k.teardown()
	if is_instance_valid(body):
		body.queue_free()
	await wait_frames(2)


## World heading (deg, + = left, 0 = -Z) of a world direction.
static func _heading(d: Vector3) -> float:
	return rad_to_deg(atan2(-d.x, -d.z))


func _strip_heading() -> float:
	var strip: Control = k.ui.hud.band_plates(HUD.BAND_STATUS)[0]
	return _heading(k.ui.hud_panel.control_to_world(strip) - k.cam.global_position)


func _set_flight(yaw_deg: float) -> void:
	var b := Basis(Vector3.UP, deg_to_rad(yaw_deg))
	body.global_basis = b
	k.player.global_basis = b
	k.player.velocity = b * Vector3(0, 0, -8)


func test_hud_on_the_flight_path_when_the_rig_yaws_with_the_bird() -> void:
	# PlayerBird -> XROrigin3D: put the kit's rig under a yawing body.
	body = Node3D.new()
	body.name = "BodyLikePlayerBird"
	add_child(body)
	k.rig.get_parent().remove_child(k.rig)
	body.add_child(k.rig)
	k.ui.attach_rig(k.rig, k.cam)
	_set_flight(70.0)
	k.set_head(Vector3(0, Kit.EYE, 0), 0.0)
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 4)
	k.ui.set_process(false)
	k.ui.hud.set_process(false)
	k.ui.hud_panel.set_process(false)
	var vel_h := _heading(k.player.velocity)
	var err0 := absf(wrapf(_strip_heading() - vel_h, -180.0, 180.0))
	metric("rig_yawed_70_strip_err_deg", snappedf(err0, 0.01))
	print("[ui] v2eng rig yawed 70: flight_yaw(rig) %.2f deg, strip heading %.2f, velocity heading %.2f" % [
		rad_to_deg(k.ui.flight_yaw()), _strip_heading(), vel_h])
	lt(err0, 1.0, "rig yawed 70 deg with the bird: the strip sits on the flight path (%.2f deg off)" % err0)
	near(rad_to_deg(k.ui.flight_yaw()), 0.0, 0.5, "in rig space the flight direction is straight ahead")
	# A flown turn: the body (and so the rig), the bird and its velocity yaw
	# together at 60 deg/s for 1.5 s; the head looks along the rig's -Z.
	var worst := 0.0
	var yaw0 := k.ui.hud_panel.panel_yaw()
	var drift := 0.0
	var t := 0.0
	while t < 1.5:
		t += SDT
		_set_flight(70.0 + 60.0 * t)
		k.ui.hud_panel.follow(SDT)
		worst = maxf(worst, absf(wrapf(_strip_heading() - _heading(k.player.velocity), -180.0, 180.0)))
		drift = maxf(drift, absf(rad_to_deg(k.ui.hud_panel.panel_yaw() - yaw0)))
	metric("flown_turn", {"worst_strip_err_deg": snappedf(worst, 0.01), "rig_space_drift_deg": snappedf(drift, 0.01)})
	lt(worst, 1.0, "during a flown 90 deg turn the strip stays on the flight path (worst %.2f deg)" % worst)
	lt(drift, 0.5, "and holds still in rig space (%.2f deg)" % drift)


## Smallest angle (deg) between a world direction from the eye and the
## lesson card's plate (sampled on its edges and interior).
func _gap_to_card(dir: Vector3) -> float:
	var hp := k.ui.hud_panel
	var r: Rect2 = k.ui.hud.band_plates(HUD.BAND_NOTICE)[0].get_global_rect()
	var eye := k.cam.global_position
	var best := INF
	for ix in 21:
		for iy in 7:
			var px := r.position + Vector2(r.size.x * ix / 20.0, r.size.y * iy / 6.0)
			best = minf(best, rad_to_deg(dir.angle_to(hp.pixel_to_world(px) - eye)))
	return best


func test_small_body_turns_keep_the_flight_path_clear_of_the_card() -> void:
	# UIRoot.HUD_HEADING_LEASH_DEG's own comment: "the notices' inner edge is
	# 10 deg out, so the flight path keeps >= 6 deg to them in steady flight".
	# The suite pins a 3 deg wobble (nothing moves) and a 30 deg turn
	# (followed); nothing between. Here: body turns (flight direction and
	# facing) of 3.9 .. 20 deg to the right, towards the card, each held 2 s;
	# the level flight path must keep >= 6 deg from the card's plate.
	k.player.velocity = Vector3(0, 0, -8)
	k.gl.start_run()
	await k.settle(self, 4)
	check(k.ui.hud.lesson_visible(), "a lesson card is up")
	k.ui.set_process(false)
	k.ui.hud.set_process(false)
	k.ui.hud_panel.set_process(false)
	var rows := {}
	var worst := INF
	for turn: float in [3.9, 6.0, 8.0, 9.0, 12.0, 20.0]:
		k.ui.hud_panel.snap_to_head()
		k.player.global_basis = Basis.IDENTITY
		k.player.velocity = Vector3(0, 0, -8)
		k.ui.hud_panel.snap_to_head()
		var b := Basis(Vector3.UP, deg_to_rad(-turn))
		k.player.global_basis = b
		k.player.velocity = b * Vector3(0, 0, -8)
		for i in 144:
			k.ui.hud_panel.follow(SDT)
			k.ui.hud.make_way(k.ui.hud_protected_directions(), SDT)
		var gap := _gap_to_card(k.player.velocity.normalized())
		rows["%.1f" % turn] = {"gap_deg": snappedf(gap, 0.01), "centre_line_off_path_deg": snappedf(rad_to_deg(absf(k.ui.hud_panel.anchor_error())), 0.01),
			"moves": k.ui.hud.move_count, "card_alpha": snappedf(k.ui.hud_panel.band_alpha(HUD.BAND_NOTICE), 0.01)}
		worst = minf(worst, gap)
	metric("body_turn_gap_to_card", rows)
	print("[ui] v2eng body turns: %s" % str(rows))
	gt(worst, 6.0, "after any body turn the level flight path keeps >= 6 deg from the card (worst %.2f)" % worst)


func test_hud_reappears_on_a_changed_flight_direction_at_once() -> void:
	# "Placed on the flight direction at once whenever it appears (Play,
	# Resume, respawn)". The suite only varies the HEAD at show time; here
	# the flight direction itself changes while the HUD is hidden (a respawn
	# on a perch facing another way): caught, the bird respawns facing 90
	# deg left, play resumes.
	k.ui.onboarding.skip()
	k.player.velocity = Vector3(0, 0, -8)
	k.gl.start_run()
	await k.settle(self, 4)
	k.gl.fake_caught(null)
	await k.settle(self, 3)
	var b := Basis(Vector3.UP, deg_to_rad(90.0))
	k.player.global_basis = b
	k.player.velocity = Vector3.ZERO
	k.set_head(Vector3(0, Kit.EYE, 0), 90.0)
	Game.set_state(Game.State.PLAYING)
	await wait_frames(1)
	var err := absf(rad_to_deg(k.ui.hud_panel.anchor_error()))
	metric("respawn_facing_90_first_frame_err_deg", snappedf(err, 0.01))
	lt(err, 1.0, "respawned facing 90 deg left: the HUD is on the new flight direction in its first frame (%.2f deg off)" % err)


func test_hud_holds_still_for_small_wobbles_after_a_turn_too() -> void:
	# The leash must work after a follow as well as before one: the suite
	# pins "a 3 deg wobble moves nothing" only before the 30 deg turn (the
	# menu has its "glance after the recentre" check; the HUD does not).
	k.ui.onboarding.skip()
	k.player.velocity = Vector3(0, 0, -8)
	k.gl.start_run()
	await k.settle(self, 4)
	var p := k.ui.hud_panel
	p.set_process(false)
	var b := Basis(Vector3.UP, deg_to_rad(-30.0))
	k.player.global_basis = b
	k.player.velocity = b * Vector3(0, 0, -8)
	for i in 216:
		p.follow(SDT)
	var yaw0 := p.panel_yaw()
	var worst := 0.0
	for w: float in [3.0, -3.0, 2.0, -2.0]:
		var bw := Basis(Vector3.UP, deg_to_rad(-30.0 + w))
		k.player.global_basis = bw
		k.player.velocity = bw * Vector3(0, 0, -8)
		for i in 72:
			p.follow(SDT)
			worst = maxf(worst, absf(rad_to_deg(p.panel_yaw() - yaw0)))
	metric("wobble_after_turn_moved_deg", snappedf(worst, 0.01))
	lt(worst, 0.05, "after a 30 deg turn, 2-3 deg wobbles of the flight direction move nothing (%.2f deg)" % worst)
	p.set_process(true)


func test_replay_tutorial_in_the_same_session_brings_the_lessons_back() -> void:
	k.gl.start_run()
	await k.settle(self, 4)
	var ob := k.ui.onboarding
	check(ob.active, "the tutorial starts on the first flight")
	# An idle player: every lesson times out (45 s each) and the tutorial ends.
	ob.auto_step = false
	var idle := {"airspeed": 8.0, "wing_extension": 0.0, "flapping": 0.0}
	var t := 0.0
	while ob.active and t < 600.0:
		ob.step(0.1, idle)
		t += 0.1
	check(not ob.active, "the lessons ran to their end (%.0f s)" % t)
	ob.auto_step = true
	# Settings > Replay tutorial, then back to flying.
	Events.menu_requested.emit()
	await k.settle(self, 4)
	k.ui._on_action(&"replay_tutorial", &"settings")
	await wait_seconds(0.3)
	Events.menu_requested.emit()
	await k.settle(self, 4)
	eq(Game.state, Game.State.PLAYING, "resumed")
	check(ob.active, "Replay tutorial: the lessons are back on this flight")
	check(k.ui.hud.lesson_visible(), "and the lesson card is up")
	# Also through Quit to menu and Play again.
	if not ob.active:
		k.gl.quit_run()
		Game.set_state(Game.State.MENU)
		await k.settle(self, 3)
		k.gl.start_run()
		await k.settle(self, 4)
		check(ob.active, "or at least on the next run")
