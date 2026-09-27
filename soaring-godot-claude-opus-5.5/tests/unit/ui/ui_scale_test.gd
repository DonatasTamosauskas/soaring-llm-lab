extends TestCase
## U6 - panels keep a constant apparent size (and distance in "player
## metres") across world_scale 0.15 .. 1.3, the pointer still works at every
## scale, and panels follow lazily (never rigidly head-locked): menus the
## head, the HUD where the player's body faces.

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")
const SCALES := [0.15, 0.3, 0.6, 1.0, 1.3]

var k: Kit


func before_each() -> void:
	k = Kit.new()
	k.setup(self, true)
	await k.settle(self, 4)


func after_each() -> void:
	k.teardown()
	await wait_frames(2)


## Angular width/height of a panel quad as seen from the camera, degrees.
func _angular_size(p: UIPanel) -> Vector2:
	var eye := k.cam.global_position
	var s := Vector2(p.panel_size)
	var l := p.pixel_to_world(Vector2(0, s.y * 0.5)) - eye
	var r := p.pixel_to_world(Vector2(s.x, s.y * 0.5)) - eye
	var t := p.pixel_to_world(Vector2(s.x * 0.5, 0)) - eye
	var b := p.pixel_to_world(Vector2(s.x * 0.5, s.y)) - eye
	return Vector2(rad_to_deg(l.angle_to(r)), rad_to_deg(t.angle_to(b)))


func test_constant_apparent_size_across_world_scale() -> void:
	var ref := Vector2.ZERO
	var ref_hud := Vector2.ZERO
	var sizes := {}
	for ws: float in SCALES:
		k.set_world_scale(ws)
		k.ui.menu_panel.snap_to_head()
		await k.settle(self, 3)
		var a := _angular_size(k.ui.menu_panel)
		var dist := k.cam.global_position.distance_to(k.ui.menu_panel.global_position) / ws
		sizes[str(ws)] = [snappedf(a.x, 0.01), snappedf(a.y, 0.01), snappedf(dist, 0.001)]
		if ref == Vector2.ZERO:
			ref = a
		near(a.x, ref.x, ref.x * 0.005, "menu width constant at ws=%.2f" % ws)
		near(a.y, ref.y, ref.y * 0.005, "menu height constant at ws=%.2f" % ws)
		near(dist, UITheme.PANEL_DISTANCE, 0.01, "menu distance = 1.5 m x ws at ws=%.2f" % ws)
		# Glyph angle is carried by the panel scale: check it via real points.
		var cap := UITheme.cap_height_px(UITheme.font(700), UITheme.FS_BODY)
		var c := Vector2(k.ui.menu_panel.panel_size) * 0.5
		var g := rad_to_deg((k.ui.menu_panel.pixel_to_world(c - Vector2(0, cap * 0.5)) - k.cam.global_position).angle_to(
			k.ui.menu_panel.pixel_to_world(c + Vector2(0, cap * 0.5)) - k.cam.global_position))
		gt(g, 1.5, "body glyph >= 1.5 deg (the brief, literal) at ws=%.2f (%.3f)" % [ws, g])
	metric("menu_angular_size_by_scale", sizes)
	# HUD panel too.
	k.gl.start_run()
	for ws: float in SCALES:
		k.set_world_scale(ws)
		k.ui.hud_panel.snap_to_head()
		await k.settle(self, 2)
		var h := _angular_size(k.ui.hud_panel)
		if ref_hud == Vector2.ZERO:
			ref_hud = h
		near(h.x, ref_hud.x, ref_hud.x * 0.005, "HUD width constant at ws=%.2f" % ws)
		# Each HUD band sits at its own elevation at every scale: notices
		# above the horizon, the growth strip low.
		for bi in 2:
			var want := HUD.NOTICE_PITCH if bi == HUD.BAND_NOTICE else HUD.STATUS_PITCH
			near(_band_elevation(k.ui.hud_panel, bi), want, 0.3, "HUD band %d elevation %.0f deg at ws=%.2f" % [bi, want, ws])


## Elevation (deg, from the camera) of the centre of a panel band.
func _band_elevation(p: UIPanel, bi: int) -> float:
	var r := p.band_rows(bi)
	var to := p.pixel_to_world(Vector2(p.panel_size.x * 0.5, (r.x + r.y) * 0.5)) - k.cam.global_position
	return rad_to_deg(asin(to.normalized().y))


func test_pointer_works_at_every_scale() -> void:
	for ws: float in SCALES:
		k.set_world_scale(ws)
		k.ui.menu_panel.snap_to_head()
		k.ui.pointer.world_scale = ws
		await k.settle(self, 2)
		var how := k.ui.get_screen(&"main").get_button(&"howto")
		k.aim_at_control(k.right, how)
		await k.settle(self, 2)
		eq(k.ui.pointer.hovered(), how, "hover at ws=%.2f" % ws)
		# Reticle keeps its visual angle (~0.9 deg) at every scale.
		var ret := k.ui.pointer.reticle_node()
		var d := k.right.aim.origin.distance_to(ret.global_position)
		var dia := ret.global_transform.basis.x.length()
		near(rad_to_deg(2.0 * atan(dia * 0.5 / d)), UIPointer.RETICLE_DEG, 0.05, "reticle angle at ws=%.2f" % ws)
		# Beam thickness scales with the player.
		near(k.ui.pointer.beam_node(1).global_transform.basis.x.length(), ws, 1e-4, "beam thickness x ws")
		await k.click(self, k.right)
		eq(k.ui.current_screen_id(), &"howto", "click at ws=%.2f" % ws)
		k.ui.pop_screen()
		await k.settle(self, 2)


## Synthetic time for a panel's head-follow: its own per-frame follow is
## off and `seconds` of fixed frames are run here (a 2 s recentre takes
## milliseconds). Returns seconds until |yaw error| < stop_deg, or -1.
const SDT := 1.0 / 72.0


func _follow(p: UIPanel, seconds: float, stop_deg: float = -1.0) -> float:
	p.set_process(false)
	var t := 0.0
	while t < seconds - 1e-6:
		p.follow(SDT)
		t += SDT
		if stop_deg > 0.0 and absf(rad_to_deg(p.yaw_error())) < stop_deg:
			return t
	return -1.0


func test_panel_is_lazily_head_following_not_head_locked() -> void:
	var p := k.ui.menu_panel
	p.snap_to_head()
	await k.settle(self, 2)
	var pos0 := p.global_position
	# Small glance (20 deg): the panel does not move at all.
	k.set_head(Vector3(0, Kit.EYE, 0), 20.0)
	_follow(p, 0.5)
	lt(p.global_position.distance_to(pos0), 0.001, "a 20 deg glance leaves the panel in place")
	# Big turn (90 deg): it follows, but gently.
	k.set_head(Vector3(0, Kit.EYE, 0), 90.0)
	_follow(p, SDT)
	var err0 := absf(rad_to_deg(p.yaw_error()))
	gt(err0, 80.0, "one frame later the panel has barely moved (not head-locked)")
	p.peak_follow_speed = 0.0
	# Ease-out: the last 5 deg are approached slowly (an exponential ease,
	# tau 0.35 s: ~14 deg/s there), never at the cap to a dead stop (the
	# round-5 engineering verifier's mutation S3, an instant follow).
	var ease := {"max_last5": 0.0, "prev": p.panel_yaw()}
	var secs := -1.0
	var tt := 0.0
	p.set_process(false)
	while tt < 3.0:
		p.follow(SDT)
		tt += SDT
		if absf(rad_to_deg(p.yaw_error())) < 5.0:
			ease["max_last5"] = maxf(float(ease["max_last5"]), rad_to_deg(absf(p.panel_yaw() - float(ease["prev"]))) / SDT)
		ease["prev"] = p.panel_yaw()
		if absf(rad_to_deg(p.yaw_error())) < 3.0:
			secs = tt
			break
	# 87 deg at no more than 110 deg/s takes at least ~0.8 s: gentle.
	gt(secs, 0.75, "the recentre is a gentle swing, not a snap (%.2f s)" % secs)
	metric("recentre_seconds", secs)
	metric("recentre_max_deg_s_in_last_5deg", snappedf(ease["max_last5"], 0.1))
	lt(float(ease["max_last5"]), 25.0, "easing out: under 25 deg/s within 5 deg of the head (%.1f)" % ease["max_last5"])
	var max_speed := p.peak_follow_speed
	metric("max_follow_deg_s", max_speed)
	_follow(p, maxf(0.0, 2.0 - secs))
	lt(absf(rad_to_deg(p.yaw_error())), 3.0, "within 2 s the panel is back in front")
	# A literal comfort number, not the node's own setting: a slow, gentle
	# swing (a panel whipping round is what makes people sick).
	lt(max_speed, 110.5, "follow speed capped at 110 deg/s (%.1f)" % max_speed)
	gt(max_speed, 30.0, "but it does actually follow")
	# Once recentred it is lazy again: a 20 deg glance leaves it where it is
	# (a panel that kept tracking after its first recentre would be a
	# smoothed head-lock).
	var settled := p.global_position
	k.set_head(Vector3(0, Kit.EYE, 0), 110.0)
	_follow(p, 0.8)
	lt(p.global_position.distance_to(settled), 0.001, "after recentring, a 20 deg glance leaves the panel in place")
	k.set_head(Vector3(0, Kit.EYE, 0), 90.0)
	_follow(p, 2.0 * SDT)
	# Lean forward 30 cm: the panel eases along instead of jumping.
	var before := p.global_position
	k.set_head(Vector3(0.0, Kit.EYE, -0.3), 90.0)
	_follow(p, SDT)
	lt(p.global_position.distance_to(before), 0.1, "head translation is smoothed")
	p.set_process(true)


## Seconds of synthetic frames for a panel's follow, calling `each(t)`.
func _follow_watch(p: UIPanel, seconds: float, each: Callable) -> void:
	p.set_process(false)
	var t := 0.0
	while t < seconds - 1e-6:
		p.follow(SDT)
		t += SDT
		each.call(t)


## Turn the mock player's torso (its telemetry's body_yaw, the HUD's centre
## line) to `deg` (+ = left, in the rig).
func _torso(deg: float) -> void:
	k.player.tel["body_yaw"] = deg_to_rad(deg)


## Largest HUD motion (deg of centre-line yaw) over `seconds` of synthetic
## frames.
func _hud_motion(p: UIPanel, seconds: float) -> float:
	var y0 := p.panel_yaw()
	var worst := [0.0]
	_follow_watch(p, seconds, func(_t: float) -> void:
		worst[0] = maxf(worst[0], absf(rad_to_deg(wrapf(p.panel_yaw() - y0, -PI, PI)))))
	return worst[0]


func test_hud_follows_where_the_body_faces_not_the_head_nor_the_path() -> void:
	# The HUD's centre line is where the player's torso faces (UIRoot.body_yaw:
	# PlayerBird's telemetry body_yaw): a head at rest looks along it. Not the
	# head (round 4 followed it past a 55 deg dead zone, from wherever it
	# pointed when the HUD appeared), and not the flight path (round 5: wind
	# and loops swung the HUD round the player in the real game).
	k.ui.onboarding.skip()
	k.player.velocity = Vector3(0, 0, -8)
	k.set_head(Vector3(0, Kit.EYE, 0), 25.0)
	k.gl.start_run()
	await k.settle(self, 4)
	var p := k.ui.hud_panel
	near(rad_to_deg(p.anchor_error()), 0.0, 0.01, "shown where the body faces, though the head was 25 deg left")
	near(rad_to_deg(p.panel_yaw()), 0.0, 0.01, "centre line = the torso (-Z)")
	var pos0 := p.global_position
	for head: float in [18.0, -45.0, 70.0, 130.0, -170.0]:
		k.set_head(Vector3(0, Kit.EYE, 0), head)
		_follow(p, 1.5)
		lt(p.global_position.distance_to(pos0), 0.001, "a %.0f deg head turn leaves the HUD where it is" % head)
	k.set_head(Vector3(0, Kit.EYE, 0), 0.0)
	# The flight path and where the bird faces go anywhere; the torso stays:
	# nothing moves. Crabbing 40 deg in the breeze; over the top of a loop
	# (velocity and facing reversed while the view turns round); a perched
	# bird turned 120 deg.
	var cases := [
		["crab 40 deg right", Basis(Vector3.UP, deg_to_rad(-40.0)) * Vector3(0, 0, -5), Basis.IDENTITY],
		["over the top", Vector3(0, 12, 2), Basis(Vector3.UP, PI) * Basis(Vector3.RIGHT, deg_to_rad(-80.0))],
		["perched facing 120 left", Vector3.ZERO, Basis(Vector3.UP, deg_to_rad(120.0))],
	]
	for c: Array in cases:
		k.player.velocity = c[1]
		k.player.global_basis = c[2]
		lt(_hud_motion(p, 1.5), 0.001, "%s: the HUD holds still" % c[0])
	k.player.global_basis = Basis.IDENTITY
	k.player.velocity = Vector3(0, 0, -8)
	# The torso estimate jitters a few degrees while the hands swing: inside
	# the 6 deg dead zone, nothing moves; a 5 deg lean held 3 s neither.
	for w: float in [4.0, -4.0, 3.0, -2.0]:
		_torso(w)
		lt(_hud_motion(p, 0.4), 0.001, "a %+.0f deg torso wobble moves nothing" % w)
	_torso(5.0)
	lt(_hud_motion(p, 3.0), 0.001, "a 5 deg lean held for 3 s moves nothing")
	# 8 deg held: out of the dead zone, followed all the way.
	_torso(8.0)
	_follow(p, 3.0)
	near(rad_to_deg(p.panel_yaw()), 8.0, 0.55, "an 8 deg turn of the torso is followed (the dead zone is under 8 deg)")
	# ...and after that follow the dead zone holds again (a follow that never
	# stopped would track every wobble: the round-6 engineering verifier's
	# mutant V12).
	for w: float in [12.0, 4.0, 11.0, 5.0]:
		_torso(w)
		lt(_hud_motion(p, 0.4), 0.001, "after a follow, a wobble to %+.0f deg moves nothing" % w)
	_torso(8.0)
	_follow(p, 1.0)
	# A 30 deg torso turn to the right (body steer: the player turns to turn):
	# followed calmly, never jumped, all the way, and it settles there.
	_torso(-22.0)
	_follow(p, SDT)
	gt(absf(rad_to_deg(p.anchor_error())), 29.0, "one frame later the HUD has not jumped")
	p.peak_follow_speed = 0.0
	var tr := {"within_1": -1.0, "max_speed_last_5": 0.0, "prev": rad_to_deg(p.panel_yaw())}
	_follow_watch(p, 4.0, func(t: float) -> void:
		var e := absf(rad_to_deg(p.anchor_error()))
		var y := rad_to_deg(p.panel_yaw())
		if e < 5.0:
			tr["max_speed_last_5"] = maxf(float(tr["max_speed_last_5"]), absf(y - float(tr["prev"])) / SDT)
		if tr["within_1"] < 0.0 and e < 1.0:
			tr["within_1"] = t
		tr["prev"] = y)
	metric("hud_follow_30deg_torso_turn", {"within_1deg_s": snappedf(tr["within_1"], 0.01), "peak_deg_s": snappedf(p.peak_follow_speed, 0.1),
		"max_deg_s_in_last_5deg": snappedf(tr["max_speed_last_5"], 0.1), "final_err_deg": snappedf(rad_to_deg(p.anchor_error()), 0.01)})
	between(float(tr["within_1"]), 0.8, 2.5, "where the body now faces within 1 deg after %.2f s (smoothed over seconds)" % tr["within_1"])
	lt(p.peak_follow_speed, 90.5, "at no more than 90 deg/s, gentler than the menu's 110 (%.1f)" % p.peak_follow_speed)
	gt(p.peak_follow_speed, 15.0, "but it does follow (%.1f deg/s)" % p.peak_follow_speed)
	lt(float(tr["max_speed_last_5"]), 30.0, "easing out: under 30 deg/s in the last 5 deg (%.1f)" % tr["max_speed_last_5"])
	lt(absf(rad_to_deg(p.anchor_error())), 0.55, "and it settles on it, not beside it (%.2f deg)" % rad_to_deg(p.anchor_error()))
	for w: float in [-26.0, -18.0, -25.0]:
		_torso(w)
		lt(_hud_motion(p, 0.4), 0.001, "after the turn, a wobble to %+.0f deg moves nothing" % w)
	# A 150 deg turn in the room: round at the cap, never faster.
	p.peak_follow_speed = 0.0
	_torso(128.0)
	_follow(p, 5.0)
	lt(absf(rad_to_deg(p.anchor_error())), 0.55, "turned round in the room: the HUD came round too")
	lt(p.peak_follow_speed, 90.5, "at no more than 90 deg/s (%.1f)" % p.peak_follow_speed)
	p.set_process(true)


func test_hud_without_a_torso_estimate_uses_where_the_bird_faces() -> void:
	# A player bird whose telemetry has no body_yaw: where it faces stands in
	# (Bird.get_forward(), world -> rig: the rig yaws with the bird, like
	# PlayerBird's), held while it points steeply up or down (over the top
	# of a loop its horizontal part flips). Without a player: the head.
	k.player.tel.erase("body_yaw")
	k.parent_rig_like_player_bird()
	k.set_rig_heading(70.0)
	k.player.global_basis = Basis(Vector3.UP, deg_to_rad(70.0))
	k.player.velocity = k.player.global_basis * Vector3(0, 0, -8)
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 4)
	var p := k.ui.hud_panel
	near(rad_to_deg(k.ui.body_yaw()), 0.0, 0.01, "rig yawed 70 deg with the bird: in the rig it faces straight ahead")
	near(rad_to_deg(p.panel_yaw()), 0.0, 0.01, "and the HUD is there")
	# The rig and the bird turn together (a flown turn): nothing moves in the rig.
	var worst := 0.0
	for i in 108:
		var yaw := 70.0 + 60.0 * i * SDT
		k.set_rig_heading(yaw)
		k.player.global_basis = Basis(Vector3.UP, deg_to_rad(yaw))
		p.follow(SDT)
		worst = maxf(worst, absf(rad_to_deg(p.panel_yaw())))
	lt(worst, 0.01, "a flown 90 deg turn moves nothing in the rig (%.3f deg)" % worst)
	var heading := 70.0 + 60.0 * 107 * SDT
	# The bird turned 40 deg left of the rig (a body turn): followed.
	k.player.global_basis = Basis(Vector3.UP, deg_to_rad(heading + 40.0))
	_follow(p, 3.0)
	near(rad_to_deg(p.panel_yaw()), 40.0, 0.55, "facing 40 deg left of the rig: the HUD followed")
	# Pitched past the vertical (105 deg: over the top, its horizontal part
	# now points behind): held.
	k.player.global_basis = Basis(Vector3.UP, deg_to_rad(heading + 40.0)) * Basis(Vector3.RIGHT, deg_to_rad(105.0))
	near(rad_to_deg(k.ui.body_yaw()), 40.0, 0.01, "over the top (steeper than 60 deg): the last good facing is held")
	lt(_hud_motion(p, 1.5), 0.001, "and the HUD holds still")
	# No player bird (a dev scene): the head, past a 55 deg dead zone.
	k.player.queue_free()
	await k.settle(self, 2)
	check(is_nan(k.ui.body_yaw()), "no player: no torso")
	check(is_nan(k.ui.flight_yaw()), "no player: no flight path")
	p.snap_to_head()
	var pos1 := p.global_position
	k.set_head(Vector3(0, Kit.EYE, 0), 18.0)
	_follow(p, 0.6)
	lt(p.global_position.distance_to(pos1), 0.001, "no player: an 18 deg glance leaves the HUD in place")
	k.set_head(Vector3(0, Kit.EYE, 0), 80.0)
	_follow(p, 2.5)
	lt(absf(rad_to_deg(p.yaw_error())), 3.0, "and an 80 deg turn is followed past the %.0f deg dead zone" % UIRoot.HUD_FOLLOW_DEADZONE_DEG)
	p.set_process(true)


func test_hud_reappears_where_the_body_now_faces() -> void:
	# Hidden while CAUGHT or paused, the HUD comes back on where the torso
	# faces NOW, in its first frame (the round-6 engineering verifier's
	# mutant V10: shown without re-placing, it came back on the old line and
	# swung across the view). The player turned 90 deg left in their room
	# while caught, then 50 deg right while paused.
	k.ui.onboarding.skip()
	k.player.velocity = Vector3(0, 0, -8)
	k.gl.start_run()
	await k.settle(self, 4)
	var p := k.ui.hud_panel
	k.gl.fake_caught(null)
	await k.settle(self, 3)
	check(not p.shown, "hidden while caught")
	_torso(90.0)
	k.set_head(Vector3(0, Kit.EYE, 0), 90.0)
	Game.set_state(Game.State.PLAYING)
	await wait_frames(1)
	var e1 := absf(rad_to_deg(p.anchor_error()))
	metric("respawn_torso_90_first_frame_err_deg", snappedf(e1, 0.01))
	lt(e1, 1.0, "respawned facing 90 deg left in the room: the HUD there in its first frame (%.2f deg off)" % e1)
	Game.set_state(Game.State.PAUSED)
	await k.settle(self, 2)
	_torso(-50.0)
	k.set_head(Vector3(0, Kit.EYE, 0), -50.0)
	Game.set_state(Game.State.PLAYING)
	await wait_frames(1)
	var e2 := absf(rad_to_deg(p.anchor_error()))
	lt(e2, 1.0, "resumed facing 50 deg right: the HUD there in its first frame (%.2f deg off)" % e2)


func test_hud_eye_point_follows_a_reseated_head_at_once() -> void:
	# A non-XR run (the integration harness, simulator mirrors): the camera
	# sits at its unscaled menu height when Play shows the HUD, then flight
	# writes the scaled head (the round-6 verifier: 1.62 m -> 0.23 m at a
	# sparrow's world_scale 0.141, the HUD a metre above the eye for a
	# second, lesson words at +80 deg). A head that jumps further than a neck
	# can move in a frame is followed at once; leaning still eases.
	k.set_world_scale(0.141)
	k.cam.transform.origin = Vector3(0, 1.62, 0)
	k.gl.start_run()
	await k.settle(self, 2)
	var p := k.ui.hud_panel
	p.set_process(false)
	k.set_head(Vector3(0, Kit.EYE, 0), 0.0)
	p.follow(SDT)
	var eye := k.cam.global_position
	var strip := p.control_to_world(k.ui.hud.band_plates(HUD.BAND_STATUS)[0]) - eye
	var el := rad_to_deg(asin(strip.normalized().y))
	metric("strip_elevation_after_reseat_deg", snappedf(el, 0.01))
	near(el, HUD.STATUS_PITCH, 0.5, "one frame after the head was re-seated, the strip is at its elevation (%.2f deg)" % el)
	# A real lean (10 cm in a frame is 7 m/s, fast for a neck) still eases.
	var before := p.global_position
	k.set_head(Vector3(0, Kit.EYE, -0.1), 0.0)
	p.follow(SDT)
	var moved := p.global_position.distance_to(before) / k.rig.world_scale
	lt(moved, 0.05, "a 10 cm lean eases (%.3f m in a frame)" % moved)
	p.set_process(true)


func test_recenter_places_open_panels_in_front_at_once() -> void:
	# After VR.recentered the old "in front" is meaningless: an open menu,
	# and the HUD in flight, are re-placed straight ahead in one frame, even
	# inside their dead zones (where they would otherwise stay put).
	var m := k.ui.menu_panel
	m.snap_to_head()
	await k.settle(self, 2)
	k.set_head(Vector3(0, Kit.EYE, 0), 25.0)
	await wait_seconds(0.4)
	gt(absf(rad_to_deg(m.yaw_error())), 20.0, "inside its dead zone the menu stayed")
	VR.recentered.emit()
	await wait_frames(1)
	lt(absf(rad_to_deg(m.yaw_error())), 0.5, "VR.recentered re-places the menu in front at once (%.2f deg)" % rad_to_deg(m.yaw_error()))
	k.set_head(Vector3(0, Kit.EYE, 0), 0.0)
	k.ui.onboarding.skip()
	k.player.velocity = Vector3(0, 0, -8)
	k.gl.start_run()
	await k.settle(self, 4)
	var h := k.ui.hud_panel
	h.snap_to_head()
	await k.settle(self, 2)
	# The HUD follows where the body faces, not the head. A recenter
	# re-seats the tracking space (and with it the torso's yaw in it), and
	# the HUD is re-placed there at once, even inside its dead zone (here
	# the torso moved 4 deg while the panel was not following).
	h.set_process(false)
	k.player.tel["body_yaw"] = deg_to_rad(4.0)
	await k.settle(self, 2)
	gt(absf(rad_to_deg(h.anchor_error())), 3.5, "inside its dead zone the HUD stayed")
	VR.recentered.emit()
	await wait_frames(1)
	lt(absf(rad_to_deg(h.anchor_error())), 0.05, "VR.recentered re-places the HUD where the body faces at once (%.2f deg)" % rad_to_deg(h.anchor_error()))
	h.set_process(true)


func test_panel_travels_with_the_rig() -> void:
	var p := k.ui.menu_panel
	await k.settle(self, 2)
	var rel0 := k.cam.global_transform.affine_inverse() * p.global_position
	# The bird flies 50 m and turns 40 deg in one frame (rig = bird).
	k.rig.global_transform = Transform3D(Basis(Vector3.UP, deg_to_rad(40.0)), Vector3(30, 5, -40))
	await wait_frames(1)
	var rel1 := k.cam.global_transform.affine_inverse() * p.global_position
	lt(rel1.distance_to(rel0), 0.01, "panel stays put relative to the flying rig")
	k.rig.global_transform = Transform3D.IDENTITY


func test_panels_hold_still_while_the_player_grows() -> void:
	# A tier-up grows world_scale continuously (here 0.33 -> 0.66 over 1 s of
	# real frames). The panels' anchors live in tracker metres, so growth
	# alone must not make the HUD or an open menu drift or breathe.
	k.ui.onboarding.skip()
	k.set_world_scale(0.33)
	k.gl.start_run()
	await k.settle(self, 4)
	k.ui.hud_panel.snap_to_head()
	await k.settle(self, 2)
	var p := k.ui.hud_panel
	var s := Vector2(p.panel_size)
	var width := func() -> float:
		var eye := k.cam.global_position
		return rad_to_deg((p.pixel_to_world(Vector2(0, s.y * 0.5)) - eye).angle_to(p.pixel_to_world(Vector2(s.x, s.y * 0.5)) - eye))
	var ref: float = width.call()
	var worst_size := 0.0
	var worst_elev := 0.0
	var frames := 0
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 1000:
		k.set_world_scale(lerpf(0.33, 0.66, (Time.get_ticks_msec() - t0) / 1000.0))
		await wait_frames(1)
		frames += 1
		worst_size = maxf(worst_size, absf(float(width.call()) - ref) / ref)
		worst_elev = maxf(worst_elev, maxf(absf(_band_elevation(p, HUD.BAND_STATUS) - HUD.STATUS_PITCH),
			absf(_band_elevation(p, HUD.BAND_NOTICE) - HUD.NOTICE_PITCH)))
	metric("growth", {"frames": frames, "max_size_err": snappedf(worst_size, 0.0001), "max_elev_err_deg": snappedf(worst_elev, 0.001)})
	gt(float(frames), 30.0, "watched a real-time growth")
	lt(worst_size, 0.002, "HUD apparent size steady within 0.2%% while growing (%.4f)" % worst_size)
	lt(worst_elev, 0.2, "HUD elevation steady within 0.2 deg while growing (%.3f)" % worst_elev)
