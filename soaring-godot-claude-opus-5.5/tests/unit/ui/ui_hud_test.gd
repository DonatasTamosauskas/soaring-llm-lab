extends TestCase
## U4 - HUD cue maths (target behind/left/right/above/below), fades by
## distance and threat, flicker-free filtering, 3D cue placement, growth bar.

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")
const EPS := 0.02


func _polar(target: Vector3, cam := Transform3D.IDENTITY) -> Dictionary:
	return HudMath.view_polar(cam, target)


func test_view_polar_cardinal_directions() -> void:
	var ahead := _polar(Vector3(0, 0, -10))
	near(ahead["off_axis"], 0.0, EPS, "ahead: on axis")
	var right := _polar(Vector3(10, 0, 0))
	near(right["off_axis"], PI / 2, EPS, "right: 90 deg off axis")
	near(right["angle"], 0.0, EPS, "right: cue points right (0)")
	var left := _polar(Vector3(-10, 0, 0))
	near(absf(left["angle"]), PI, EPS, "left: cue points left (PI)")
	var up := _polar(Vector3(0, 10, -1))
	near(up["angle"], PI / 2, EPS, "above: cue points up")
	var down := _polar(Vector3(0, -10, -1))
	near(down["angle"], -PI / 2, EPS, "below: cue points down")
	var ul := _polar(Vector3(-5, 5, -5))
	near(ul["angle"], 3.0 * PI / 4.0, EPS, "up-left: 135 deg")


func test_view_polar_behind() -> void:
	var b := _polar(Vector3(0.0, 0.0, 10.0))
	near(b["off_axis"], PI, EPS, "dead behind: 180 deg off axis")
	check(b["behind"], "flagged behind")
	check(b["ambiguous"], "dead behind has no preferred side")
	var bl := _polar(Vector3(-3, 0, 10))
	near(absf(bl["angle"]), PI, EPS, "behind-left: turn left")
	var br := _polar(Vector3(3, 0, 10))
	near(br["angle"], 0.0, EPS, "behind-right: turn right")
	# Behind and well above: still a left/right cue (the view can't pitch).
	var bu := _polar(Vector3(-3, 6, 10))
	lt(absf(sin(bu["angle"])), 0.6, "behind-above-left mostly horizontal (angle %.2f)" % bu["angle"])
	lt(cos(bu["angle"]), 0.0, "behind-above-left still points left")


func test_view_polar_follows_head_rotation() -> void:
	# Head turned 90 deg left: a target straight ahead of the world (-Z) is
	# now on the head's right.
	var cam := Transform3D(Basis(Vector3.UP, deg_to_rad(90.0)), Vector3(0, 1.6, 0))
	var p := HudMath.view_polar(cam, Vector3(0, 1.6, -20))
	near(p["off_axis"], PI / 2, EPS, "90 deg off axis after turning away")
	near(p["angle"], 0.0, EPS, "cue says turn right")
	# Head rolled 20 deg clockwise (right ear down): a level target on the
	# right now sits up-right in the view, and the cue must say so.
	var tilt := Transform3D(Basis(Vector3.FORWARD, deg_to_rad(20.0)), Vector3.ZERO)
	var q := HudMath.view_polar(tilt, Vector3(10, 0, 0))
	near(q["angle"], deg_to_rad(20.0), EPS, "cue compensates head roll")


func test_target_alpha_fades_with_distance() -> void:
	var cruise := 9.0
	near(HudMath.target_alpha(5.0, cruise), 1.0, 1e-4, "close (<2 s away): full")
	near(HudMath.target_alpha(200.0, cruise), 0.0, 1e-4, "far (>9 s away): gone")
	var prev := 2.0
	for d in range(0, 120, 5):
		var a := HudMath.target_alpha(float(d), cruise)
		check(a <= prev + 1e-6, "monotonic fade at %d m" % d)
		prev = a
	# Scale-free: same seconds-away means the same cue for a wren and an eagle.
	var wren: float = SizeRules.performance(SizeRules.SPECIES[1]["mass"])["cruise"]
	var eagle: float = SizeRules.performance(SizeRules.SPECIES[9]["mass"])["cruise"]
	near(HudMath.target_alpha(wren * 5.0, wren), HudMath.target_alpha(eagle * 5.0, eagle), 1e-5, "same time-to-reach, same alpha")
	lt(HudMath.target_alpha(40.0, wren), HudMath.target_alpha(40.0, eagle), "40 m is 'far' for a wren, near for an eagle")


func test_threat_alpha() -> void:
	near(HudMath.threat_alpha(0.05), 0.0, 1e-5, "negligible threat shows nothing")
	near(HudMath.threat_alpha(0.9), 1.0, 1e-5, "imminent threat full")
	var prev := -1.0
	for i in 21:
		var a := HudMath.threat_alpha(i / 20.0)
		check(a >= prev, "monotonic in level")
		prev = a


func test_filter_no_flicker_at_cone_edge() -> void:
	var dt := 1.0 / 72.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	# A naive cue (visible when off-axis > 18 deg) against ours, for a target
	# hovering at the edge of the central cone with +-2.5 deg tracking noise.
	for start_deg: float in [30.0, 0.0]:
		var f := IndicatorFilter.new()
		for i in 72:
			f.update(dt, {"off_axis": deg_to_rad(start_deg), "angle": 0.3, "ambiguous": false}, 0.8)
		var t0 := f.toggles
		var naive_toggles := 0
		var naive_prev := start_deg > 18.0
		var max_step := 0.0
		var a_lo := 1.0
		var a_hi := 0.0
		for i in 72 * 6:
			var off_deg := 18.0 + rng.randf_range(-2.5, 2.5)
			var naive := off_deg > 18.0
			if naive != naive_prev:
				naive_toggles += 1
			naive_prev = naive
			var before := f.alpha
			f.update(dt, {"off_axis": deg_to_rad(off_deg), "angle": 0.3, "ambiguous": false}, 0.8)
			max_step = maxf(max_step, absf(f.alpha - before))
			a_lo = minf(a_lo, f.alpha)
			a_hi = maxf(a_hi, f.alpha)
		var toggles := f.toggles - t0
		metric("naive_toggles_from_%d" % int(start_deg), naive_toggles)
		metric("toggles_from_%d" % int(start_deg), toggles)
		gt(float(naive_toggles), 100.0, "a naive threshold would blink (%d toggles in 6 s)" % naive_toggles)
		eq(toggles, 0, "ours holds its state at the cone edge (from %d deg)" % int(start_deg))
		lt(a_hi - a_lo, 0.01, "alpha steady (from %d deg)" % int(start_deg))
		# A literal comfort number, not the filter's own constant: no cue
		# ever changes opacity faster than a full fade in 0.25 s.
		lt(max_step, dt / 0.25 + 1e-6, "alpha never changes faster than 1 per 0.25 s")


func test_filter_noisy_level_is_smooth() -> void:
	var f := IndicatorFilter.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var dt := 1.0 / 90.0
	var reversals := 0
	var last_sign := 0
	var prev := 0.0
	var lo := 1.0
	var hi := 0.0
	# A threat level jittering +-0.3 every frame around 0.6 (the game loop
	# recomputes it per physics tick).
	for i in 90 * 5:
		var strength := clampf(0.6 + rng.randf_range(-0.3, 0.3), 0.0, 1.0)
		f.update(dt, {"off_axis": deg_to_rad(60.0), "angle": 1.0, "ambiguous": false}, strength)
		if i > 90:
			lo = minf(lo, f.alpha)
			hi = maxf(hi, f.alpha)
			var d := f.alpha - prev
			var sgn := int(signf(d)) if absf(d) > 0.002 else 0
			if sgn != 0 and last_sign != 0 and sgn != last_sign:
				reversals += 1
			if sgn != 0:
				last_sign = sgn
		prev = f.alpha
	metric("reversals_4s", reversals)
	metric("steady_peak_to_peak", hi - lo)
	# What the dead band buys: a steady cue, not a slow wobble.
	lt(float(reversals), 2.0, "no shimmer: at most one direction change in 4 s (%d)" % reversals)
	lt(hi - lo, 0.01, "steady alpha varies < 0.01 while the input varies 0.6 (%.4f)" % (hi - lo))
	gt(lo, 0.3, "and the cue stays clearly visible")


func test_filter_fade_in_takes_a_quarter_second() -> void:
	# A cue appearing must ease in (a pop in the periphery grabs the eye).
	for dt: float in [1.0 / 72.0, 1.0 / 90.0]:
		var f := IndicatorFilter.new()
		var t := 0.0
		var max_step := 0.0
		while f.alpha < 0.8 * 0.95 and t < 3.0:
			var a0 := f.alpha
			f.update(dt, {"off_axis": 1.0, "angle": 0.0, "ambiguous": false}, 0.8)
			max_step = maxf(max_step, f.alpha - a0)
			t += dt
		metric("fade_in_s_at_%d_hz" % int(round(1.0 / dt)), snappedf(t, 0.001))
		between(t, 0.2, 0.8, "fade-in to 95%% takes %.2f s at %d Hz" % [t, int(round(1.0 / dt))])
		# A literal comfort number: never faster than a full fade in 0.25 s,
		# even in the first frames of a fade-in (where easing alone is fastest).
		lt(max_step, dt / 0.25 + 1e-6, "fade-in never steps faster than 1 per 0.25 s (%.4f per frame at %d Hz)" % [max_step, int(round(1.0 / dt))])


func test_filter_new_target_does_not_sweep() -> void:
	var f := IndicatorFilter.new()
	var dt := 1.0 / 72.0
	for i in 60:
		f.update(dt, {"off_axis": 1.0, "angle": 0.0, "ambiguous": false}, 0.8)
	gt(f.alpha, 0.7, "cue fully shown")
	# Target lost: fades out.
	for i in 60:
		f.update(dt, {}, 0.0)
	lt(f.alpha, IndicatorFilter.MIN_VISIBLE_ALPHA, "cue gone without a target")
	# New target on the far side: snaps (invisible), then fades in there.
	f.update(dt, {"off_axis": 1.0, "angle": PI * 0.9, "ambiguous": false}, 0.8)
	near(f.angle, PI * 0.9, 1e-4, "invisible cue snaps to the new direction")
	# While visible, direction changes are eased, not jumped.
	for i in 60:
		f.update(dt, {"off_axis": 1.0, "angle": PI * 0.9, "ambiguous": false}, 0.8)
	var a0 := f.angle
	f.update(dt, {"off_axis": 1.0, "angle": -PI * 0.5, "ambiguous": false}, 0.8)
	var jump := absf(wrapf(f.angle - a0, -PI, PI))
	lt(jump, deg_to_rad(40.0), "visible cue eases toward a new direction (jump %.1f deg)" % rad_to_deg(jump))
	gt(jump, 0.0, "but does move")


func test_indicators_3d_placement_and_fade() -> void:
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 2)
	_synthetic(k)
	var bird := Bird.new()
	bird.mass = 0.01
	add_child(bird)
	# Prey 8 m to the left of the head, level.
	var head := k.cam.global_transform
	bird.global_position = head.origin + head.basis * Vector3(-8, 0, 0)
	Events.target_changed.emit(bird)
	_advance(k, 0.6)
	var cue := k.ui.indicators.cue_mesh(&"target")
	check(cue.visible, "target cue drawn when prey is off to the left")
	var local := head.affine_inverse() * cue.global_position
	lt(local.x, 0.0, "cue sits on the left of the view")
	near(local.length(), HudIndicators.RING_RADIUS * k.rig.world_scale, 0.01, "cue on the ring (1 m x world_scale)")
	near(rad_to_deg(acos(-local.z / local.length())), 24.0, 0.5, "cue 24 deg out from the view centre")
	var tip := (head.basis.inverse() * cue.global_transform.basis.y).normalized()
	lt(tip.x, -0.9, "chevron tip points left")
	var a_close := (cue.material_override as StandardMaterial3D).albedo_color.a
	# Move the prey straight ahead: cue disappears (you can see it).
	bird.global_position = head.origin + head.basis * Vector3(0, 0, -8)
	_advance(k, 0.6)
	check(not cue.visible, "no cue while the prey is in the centre of view")
	# Far away to the left: faint or gone.
	bird.global_position = head.origin + head.basis * Vector3(-400, 0, 0)
	_advance(k, 0.6)
	var a_far := (cue.material_override as StandardMaterial3D).albedo_color.a if cue.visible else 0.0
	lt(a_far, a_close * 0.2, "distant prey fades the cue (%.2f vs %.2f)" % [a_far, a_close])
	# Threat behind-right at high level: coral cue on the right.
	var hawk := Bird.new()
	hawk.mass = 2.0
	add_child(hawk)
	hawk.global_position = head.origin + head.basis * Vector3(4, 0, 10)
	Events.threat_changed.emit(0.9, hawk)
	_advance(k, 0.6)
	var tcue := k.ui.indicators.cue_mesh(&"threat")
	check(tcue.visible, "threat cue shown")
	gt((head.affine_inverse() * tcue.global_position).x, 0.0, "threat behind-right -> cue on the right")
	Events.threat_changed.emit(0.0, null)
	_advance(k, 0.6)
	check(not tcue.visible, "threat cue gone when the threat is")
	# Paused: cues hidden with the HUD.
	Events.target_changed.emit(null)
	bird.queue_free()
	hawk.queue_free()
	k.teardown()
	await wait_frames(2)


func test_growth_progress_log_scale() -> void:
	var s := SizeRules.SPECIES
	near(HudMath.growth_progress(s[2]["mass"]), 0.0, 1e-3, "at a species' mass: 0")
	near(HudMath.growth_progress(sqrt(s[2]["mass"] * s[3]["mass"])), 0.5, 1e-3, "geometric midpoint: 0.5")
	near(HudMath.growth_progress(s[3]["mass"] * 0.998), 1.0, 0.01, "just below the next species: ~1")
	near(HudMath.growth_progress(s[9]["mass"] * 2.0), 1.0, 1e-6, "apex: full")


func test_hud_growth_updates_only_on_visible_change() -> void:
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 4)
	k.player.mass = 0.03
	await k.settle(self, 3)
	eq(k.ui.hud.tier_text(), "Sparrow", "tier name from mass")
	var r0 := k.ui.hud_panel.render_requests
	# Tiny growth (below one bar step) must not re-render the panel.
	k.player.mass = 0.03 * 1.001
	await k.settle(self, 5)
	eq(k.ui.hud_panel.render_requests, r0, "sub-step growth does not re-render")
	k.player.mass = 0.04
	await k.settle(self, 3)
	gt(k.ui.hud_panel.render_requests, r0, "visible growth re-renders")
	near(k.ui.hud.growth_value(), HudMath.growth_progress(0.04), 0.011, "bar shows log progress")
	k.player.mass = SizeRules.SPECIES[3]["mass"]
	await k.settle(self, 3)
	eq(k.ui.hud.tier_text(), "Swallow", "tier name follows")
	k.teardown()
	await wait_frames(2)


# --- birds behind you: one steady "turn this way" cue --------------------------

## Drive a real IndicatorFilter with HudMath.view_polar from an eye at the
## origin looking down -Z while the bird follows pos_fn(t); count side flips,
## total cue travel and frames where the cue points up or down.
func _run_filter(seconds: float, pos_fn: Callable, strength: float, f: IndicatorFilter = null) -> Dictionary:
	if f == null:
		f = IndicatorFilter.new()
	var dt := 1.0 / 90.0
	var flips := 0
	var last_side := 0
	var travel := 0.0
	var prev := NAN
	var drawn := 0
	var vertical := 0
	var n := int(seconds / dt)
	for i in n:
		f.update(dt, HudMath.view_polar(Transform3D.IDENTITY, pos_fn.call(i * dt)), strength)
		if not f.is_drawn():
			prev = NAN
			continue
		drawn += 1
		var c := cos(f.angle)
		var side := 1 if c > 0.3 else (-1 if c < -0.3 else 0)
		if side != 0:
			if last_side != 0 and side != last_side:
				flips += 1
			last_side = side
		if absf(sin(f.angle)) > 0.9:
			vertical += 1
		if not is_nan(prev):
			travel += absf(wrapf(f.angle - prev, -PI, PI))
		prev = f.angle
	return {"side_flips": flips, "travel_deg": snappedf(rad_to_deg(travel), 0.1), "drawn_frac": snappedf(drawn / float(n), 0.01),
		"frames_up_or_down": vertical, "cuts": f.cuts, "final_angle_deg": snappedf(rad_to_deg(f.angle), 0.1)}


func test_threat_on_your_tail_holds_one_side() -> void:
	# A hawk 10 m dead behind, wobbling +-0.4 m (+-2.3 deg) at 1.2 Hz: the
	# classic chase. The cue must pick a side and hold it.
	var r := _run_filter(6.0, func(t: float) -> Vector3: return Vector3(0.4 * sin(TAU * 1.2 * t), 0.0, 10.0), 0.9)
	metric("tail_level", r)
	gt(r["drawn_frac"], 0.9, "threat cue shown for a hawk on your tail")
	eq(r["side_flips"], 0, "cue never flips left/right with a 2 deg wobble")
	lt(r["travel_deg"], 5.0, "cue stays still (%.1f deg travelled in 6 s)" % r["travel_deg"])
	eq(r["frames_up_or_down"], 0, "never swings under or over the view")


func test_threat_on_your_tail_slightly_above_holds_one_side() -> void:
	# The same chase, the hawk 1 m above (a stoop from behind).
	var r := _run_filter(6.0, func(t: float) -> Vector3: return Vector3(0.4 * sin(TAU * 1.2 * t), 1.0, 10.0), 0.9)
	metric("tail_above", r)
	eq(r["side_flips"], 0, "cue never flips left/right")
	lt(r["travel_deg"], 5.0, "cue stays still (%.1f deg)" % r["travel_deg"])
	# ... and still hints "above": tilted up, but mostly a turn cue.
	var tilt := absf(wrapf(deg_to_rad(r["final_angle_deg"]), -PI, PI))
	tilt = minf(tilt, PI - tilt)
	between(rad_to_deg(tilt), 0.5, 20.0, "tilted slightly up (%.1f deg)" % rad_to_deg(tilt))


func test_behind_left_stays_left() -> void:
	var r := _run_filter(6.0, func(t: float) -> Vector3: return Vector3(-3.0 + 0.4 * sin(TAU * 1.2 * t), 0.0, 10.0), 0.9)
	eq(r["side_flips"], 0, "behind-left stays left")
	lt(cos(deg_to_rad(r["final_angle_deg"])), -0.9, "and points left")


func test_bird_crossing_behind_changes_side_once_by_a_cut() -> void:
	# A bird sweeps from behind-right to behind-left over 4 s: the cue keeps
	# saying "right" until the bird is clearly on the left, then jumps there
	# once (hidden, moved, faded back in), never sweeping under the view.
	var r := _run_filter(4.0, func(t: float) -> Vector3:
		var a := lerpf(deg_to_rad(40.0), deg_to_rad(-40.0), t / 4.0)
		return Vector3(sin(a) * 10.0, 0.0, cos(a) * 10.0), 0.9)
	metric("crossing_behind", r)
	eq(r["side_flips"], 1, "exactly one change of side")
	eq(r["cuts"], 1, "made by a cut")
	eq(r["frames_up_or_down"], 0, "never pointing up or down on the way")
	lt(cos(deg_to_rad(r["final_angle_deg"])), -0.9, "ends pointing left")
	# The switch waits for the hysteresis band: with a wobble at 10 deg the
	# other side of dead behind, still no flip.
	var r2 := _run_filter(6.0, func(t: float) -> Vector3:
		var a := deg_to_rad(-10.0 + 3.0 * sin(TAU * 1.2 * t))
		return Vector3(sin(a) * 10.0, 0.0, cos(a) * 10.0), 0.9)
	eq(r2["side_flips"], 0, "10 deg past dead behind is inside the hysteresis band")


func test_cue_is_continuous_at_the_eye_plane() -> void:
	# A bird passing your wingtip (in front -> behind) or overhead must not
	# make the cue jump: the behind formula meets the in-front projection.
	for pos: Array in [[Vector3(5, 1, -0.01), Vector3(5, 1, 0.01)], [Vector3(-5, -2, -0.01), Vector3(-5, -2, 0.01)],
			[Vector3(0.3, 8, -0.01), Vector3(0.3, 8, 0.01)]]:
		var a := HudMath.view_polar(Transform3D.IDENTITY, pos[0])
		var b := HudMath.view_polar(Transform3D.IDENTITY, pos[1])
		check(not a["behind"] and b["behind"], "straddles the eye plane")
		lt(absf(wrapf(a["angle"] - b["angle"], -PI, PI)), deg_to_rad(1.0), "no jump crossing the eye plane at %s" % pos[0])


func test_direct_target_swap_cuts_instead_of_sweeping() -> void:
	# GameLoop switches target straight from A (left) to B (right) with no
	# null in between. The cue must not sweep across the top or bottom.
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 2)
	_synthetic(k)
	var a := Bird.new()
	a.mass = 0.01
	add_child(a)
	var b := Bird.new()
	b.mass = 0.01
	add_child(b)
	var head := k.cam.global_transform
	a.global_position = head.origin + head.basis * Vector3(-8, 0, -1)
	b.global_position = head.origin + head.basis * Vector3(8, 0, -1)
	Events.target_changed.emit(a)
	_advance(k, 0.6)
	var cue := k.ui.indicators.cue_mesh(&"target")
	check(cue.visible, "cue shown for A on the left")
	Events.target_changed.emit(b)
	var ring := HudIndicators.RING_RADIUS * sin(HudIndicators.ECCENTRICITY)
	var vertical := 0
	var old_side := 0
	var shown := 0
	for i in 45:
		_advance_frames(k, 1)
		if not cue.visible:
			continue
		shown += 1
		var local := head.affine_inverse() * cue.global_position
		if absf(local.y) > ring * 0.6:
			vertical += 1
		if local.x < 0.0:
			old_side += 1
	metric("swap", {"visible_frames": shown, "frames_near_top_or_bottom": vertical, "frames_on_old_side": old_side})
	eq(vertical, 0, "no sweep over the top or bottom on a direct swap")
	eq(old_side, 0, "the cue leaves A's side at once")
	gt(float(shown), 20.0, "and is back, on B's side, within half a second")
	# A new bird in the same direction (a flock mate) just slides the cue.
	var c := Bird.new()
	c.mass = 0.01
	add_child(c)
	c.global_position = head.origin + head.basis * Vector3(8, 1.5, -1)
	var cuts := k.ui.indicators.target_filter.cuts
	Events.target_changed.emit(c)
	_advance_frames(k, 3)
	eq(k.ui.indicators.target_filter.cuts, cuts, "same-direction retarget: no cut")
	check(cue.visible, "cue stays up")
	# A new bird on the same side but in a clearly different direction
	# (up-left -> down-left) is a cut too, not a slide along the ring.
	var up := Bird.new()
	up.mass = 0.01
	add_child(up)
	up.global_position = head.origin + head.basis * Vector3(6, 6, -1)
	Events.target_changed.emit(up)
	_advance(k, 0.5)
	var down := Bird.new()
	down.mass = 0.01
	add_child(down)
	down.global_position = head.origin + head.basis * Vector3(6, -6, -1)
	var cuts0 := k.ui.indicators.target_filter.cuts
	Events.target_changed.emit(down)
	_advance_frames(k, 2)
	eq(k.ui.indicators.target_filter.cuts, cuts0 + 1, "up-right -> down-right retarget is a cut")
	var local2 := head.affine_inverse() * cue.global_position
	check(not cue.visible or local2.y < 0.0, "never shown sliding through the middle of the right side")
	up.queue_free()
	down.queue_free()
	Events.target_changed.emit(null)
	for n: Node in [a, b, c]:
		n.queue_free()
	k.teardown()
	await wait_frames(2)


func test_approaching_target_fade_is_monotonic() -> void:
	# Prey 90 deg left, approaching from 120 m to 3 m at 9 m/s (sparrow
	# cruise): the cue only ever gets stronger (no pulsing, no pops).
	var f := IndicatorFilter.new()
	var dt := 1.0 / 90.0
	var reversals := 0
	var prev := 0.0
	var max_jump := 0.0
	for i in int(13.0 / dt):
		var d := maxf(3.0, 120.0 - 9.0 * i * dt)
		f.update(dt, HudMath.view_polar(Transform3D.IDENTITY, Vector3(-d, 0.0, 0.0)), HudMath.target_alpha(d, 9.0) * HudIndicators.TARGET_MAX_ALPHA)
		if f.alpha < prev - 0.002:
			reversals += 1
		max_jump = maxf(max_jump, absf(f.alpha - prev))
		prev = f.alpha
	metric("approach", {"reversals": reversals, "max_alpha_step": snappedf(max_jump, 0.0001)})
	eq(reversals, 0, "alpha never drops while the prey only gets closer")
	lt(max_jump, 0.06, "no visible alpha pops (max %.3f per frame)" % max_jump)
	gt(f.alpha, 0.8, "close prey: cue at full strength")


# --- birds high above and behind you ------------------------------------------

func test_bird_high_above_and_behind_does_not_blink() -> void:
	# The side latch is measured on the true angle from the view's vertical
	# mid-plane: near the zenith a few degrees of real movement are a few
	# degrees, not a swing from one side to the other.
	var p := HudMath.view_polar(Transform3D.IDENTITY, Vector3(1.0, 15.0, 3.0))
	near(rad_to_deg(p["lateral"]), rad_to_deg(asin(1.0 / Vector3(1.0, 15.0, 3.0).length())), 1e-3,
		"lateral = true angle from the mid-plane (3.7 deg here, not the 18 deg of a horizontal-plane angle)")
	var f := IndicatorFilter.new()
	var dt := 1.0 / 90.0
	var side_changes := 0
	var last_side := 0
	for i in int(6.0 / dt):
		f.update(dt, HudMath.view_polar(Transform3D.IDENTITY, Vector3(1.2 * sin(TAU * 0.8 * i * dt), 15.0, 3.0)), 0.9)
		if last_side != 0 and f.side != last_side:
			side_changes += 1
		last_side = f.side
	eq(side_changes, 0, "the latched side never changes for a 4.5 deg drift overhead (%d changes)" % side_changes)
	var r := _run_filter(6.0, func(t: float) -> Vector3: return Vector3(1.2 * sin(TAU * 0.8 * t), 15.0, 3.0), 0.9)
	metric("hawk_above_behind", r)
	eq(r["cuts"], 0, "a hawk 15 m up and 3 m behind drifting +-1.2 m never blinks the cue (%d cuts)" % r["cuts"])
	var circ := _run_filter(12.0, func(t: float) -> Vector3:
		var a := TAU * t / 6.0
		return Vector3(3.0 * cos(a), 15.0, 3.0 * sin(a)), 0.9)
	metric("hawk_circling_overhead", circ)
	lt(circ["cuts"], 2, "a hawk circling overhead (2 laps) at most cuts once (%d)" % circ["cuts"])
	# Every geometry above/behind, a +-4 deg true wobble: never a cut.
	var bad := {}
	for up: float in [0.0, 5.0, 10.0, 15.0, 20.0, 40.0]:
		for behind: float in [0.5, 2.0, 3.0, 5.0, 8.0, 12.0]:
			var base := Vector3(0.0, up, behind)
			var amp: float = base.length() * tan(deg_to_rad(4.0))
			var rr := _run_filter(6.0, func(t: float) -> Vector3: return base + Vector3(amp * sin(TAU * 0.8 * t), 0.0, 0.0), 0.9)
			if rr["cuts"] > 0:
				bad["up%d_behind%.1f" % [int(up), behind]] = rr["cuts"]
	metric("wobble_4deg_cuts", bad)
	eq(bad.size(), 0, "a +-4 deg wobble anywhere behind you never cuts the cue (%s)" % str(bad))


func test_side_change_near_the_zenith_slides_instead_of_blinking() -> void:
	# A bird overhead-behind that really does cross to the other side: both
	# sides' cues point almost straight up, so the change is a slide.
	var r := _run_filter(4.0, func(t: float) -> Vector3:
		return Vector3(lerpf(6.0, -6.0, t / 4.0), 15.0, 2.0), 0.9)
	metric("zenith_crossing", r)
	eq(r["cuts"], 0, "crossing overhead: no blink")
	lt(cos(deg_to_rad(r["final_angle_deg"])), 0.0, "ends pointing up-left")
	# Level behind you the two sides are 180 deg apart: still a cut.
	var lvl := _run_filter(4.0, func(t: float) -> Vector3:
		var a := lerpf(deg_to_rad(40.0), deg_to_rad(-40.0), t / 4.0)
		return Vector3(sin(a) * 10.0, 0.0, cos(a) * 10.0), 0.9)
	eq(lvl["cuts"], 1, "crossing dead behind at eye level: one cut")


# --- the HUD never sits where a hunting bird looks ------------------------------

## Is the gaze ray (camera-local direction) covered by a visible HUD plate?
func _plate_under(k: Kit, dir_local: Vector3) -> bool:
	var cam := k.cam.global_transform
	var hit := k.ui.hud_panel.intersect_ray(cam.origin, (cam.basis * dir_local).normalized())
	if hit.is_empty():
		return false
	for bi in 2:
		for plate: Control in k.ui.hud.band_plates(bi):
			if plate.get_global_rect().has_point(hit["pixel"]):
				return true
	return false


## Fraction of the central cone (radius deg) covered by plates.
func _cone_cover(k: Kit, radius: int) -> float:
	var n := 0
	var hit := 0
	for ax in range(-radius, radius + 1):
		for ay in range(-radius, radius + 1):
			if ax * ax + ay * ay > radius * radius:
				continue
			n += 1
			var d := (Basis(Vector3.UP, deg_to_rad(ax)) * Basis(Vector3.RIGHT, deg_to_rad(ay))) * Vector3.FORWARD
			if _plate_under(k, d):
				hit += 1
	return hit / float(n)


## Sweep head pitch from +10 down to -50: where does a plate cover the gaze?
func _gaze_sweep(k: Kit) -> Dictionary:
	var covered: Array = []
	var cone := {}
	for i in 25:
		var pitch := 10.0 - 2.5 * i
		k.set_head(Vector3(0, Kit.EYE, 0), 0.0, pitch)
		await wait_frames(2)
		if _plate_under(k, Vector3.FORWARD):
			covered.append(pitch)
		cone[pitch] = snappedf(_cone_cover(k, 5), 0.01)
	k.set_head(Vector3(0, Kit.EYE, 0), 0.0, 0.0)
	return {"centre_covered": covered, "cone5_cover": cone}


func test_hud_keeps_out_of_the_hunting_gaze() -> void:
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.gl.start_run()
	await k.settle(self, 4)
	# First flight: lesson card + strip. Then the permanent HUD alone.
	check(k.ui.hud.lesson_visible(), "lesson card up")
	var with_lesson := await _gaze_sweep(k)
	k.ui.onboarding.skip()
	await k.settle(self, 3)
	var strip_only := await _gaze_sweep(k)
	# And the tier-up celebration.
	Events.player_tier_changed.emit(2, 3)
	await k.settle(self, 2)
	var with_toast := await _gaze_sweep(k)
	metric("gaze", {"with_lesson": with_lesson, "strip_only": strip_only, "with_toast": with_toast})
	for sweep: Dictionary in [with_lesson, strip_only, with_toast]:
		for p: float in sweep["cone5_cover"]:
			# The whole band a hunting bird looks through: level (and a
			# little up) to 30 deg down, the 10 deg cone round the gaze.
			if p <= 2.5 and p >= -30.0:
				eq(sweep["cone5_cover"][p], 0.0, "no plate within 5 deg of the gaze at pitch %.1f" % p)
	# The strip is still there for a deliberate glance down.
	check(-40.0 in strip_only["centre_covered"], "looking 40 deg down reads the growth strip")
	for p: float in strip_only["centre_covered"]:
		check(p <= -35.0, "the strip covers the gaze only below -35 deg (at %.1f)" % p)
	# Held gaze on prey 26 deg below for 2 s: never covered.
	k.set_head(Vector3(0, Kit.EYE, 0), 0.0, -26.0)
	var covered := 0
	for i in 120:
		await wait_frames(1)
		if _plate_under(k, Vector3.FORWARD):
			covered += 1
	eq(covered, 0, "a held dive gaze at -26 deg is never covered")
	k.teardown()
	await wait_frames(2)


# --- the notices: a calm home beside the centre line ---------------------------

## Rays within `radius_deg` of a world direction (from the eye) that land on
## a notice plate as drawn right now (0 = at least that much sky round it).
## Uses the analytic ray-band intersection (UIPanel.intersect_ray), not the
## direction maths the HUD places the notices with.
func _notice_hits(k: Kit, dir: Vector3, radius_deg: float) -> int:
	var eye := k.cam.global_position
	var d := dir.normalized()
	var side := d.cross(Vector3.UP)
	side = (side if side.length() > 1e-3 else Vector3.RIGHT).normalized()
	var up := side.cross(d).normalized()
	var rays: Array[Vector3] = [d]
	if radius_deg > 0.0:
		for ring: float in [radius_deg * 0.5, radius_deg]:
			for i in 24:
				var a := TAU * i / 24.0
				rays.append((d + (side * cos(a) + up * sin(a)) * tan(deg_to_rad(ring))).normalized())
	var plates := k.ui.hud.band_plates(HUD.BAND_NOTICE)
	var n := 0
	for r in rays:
		var hit := k.ui.hud_panel.intersect_ray(eye, r)
		if hit.is_empty():
			continue
		for p: Control in plates:
			if p.get_global_rect().has_point(hit["pixel"]):
				n += 1
				break
	return n


## Lowest elevation (deg, from the eye) of the notice band's bottom edge
## across its whole width, where it is placed now.
func _notice_band_lowest_deg(k: Kit) -> float:
	var eye := k.cam.global_position
	var low := 90.0
	for i in 45:
		var px := Vector2(float(UITheme.HUD_SIZE.x) * i / 44.0, HUD.NOTICE_ROWS.y)
		low = minf(low, rad_to_deg(asin((k.ui.hud_panel.pixel_to_world(px) - eye).normalized().y)))
	return low


## Lowest elevation (deg, from the eye) of the notice plates as drawn.
func _notice_lowest_deg(k: Kit) -> float:
	var eye := k.cam.global_position
	var low := 90.0
	for p: Control in k.ui.hud.band_plates(HUD.BAND_NOTICE):
		var r := p.get_global_rect()
		for i in 9:
			var w := k.ui.hud_panel.pixel_to_world(Vector2(lerpf(r.position.x, r.end.x, i / 8.0), r.end.y)) - eye
			low = minf(low, rad_to_deg(asin(w.normalized().y)))
	return low


## World direction at a yaw (+ left) and elevation, degrees.
static func _dir(yaw_deg: float, elev_deg: float) -> Vector3:
	return Basis(Vector3.UP, deg_to_rad(yaw_deg)) * Basis(Vector3.RIGHT, deg_to_rad(elev_deg)) * Vector3.FORWARD


## Azimuth (deg, + = right of the HUD's centre line) and elevation of a
## notice-band texture pixel as drawn.
func _pixel_az_el(k: Kit, px: Vector2) -> Vector2:
	var l := k.ui.hud_panel.level_direction(k.ui.hud_panel.pixel_to_world(px) - k.cam.global_position)
	return Vector2(rad_to_deg(atan2(l.x, -l.z)), rad_to_deg(asin(clampf(l.y, -1.0, 1.0))))


## What the player sees of the notices: band opacity x the toast's own fade.
func _notice_opacity(k: Kit) -> float:
	var p := k.ui.hud_panel
	if not p.is_band_visible(HUD.BAND_NOTICE) or k.ui.hud.band_plates(HUD.BAND_NOTICE).is_empty():
		return 0.0
	var a := p.band_alpha(HUD.BAND_NOTICE)
	var toast := k.ui.hud.get_node_or_null("TierUp") as Control
	if toast and toast.visible:
		a *= toast.modulate.a
	return a


## Is `dir` (world, from the eye) behind a notice plate the player can read?
func _hidden(k: Kit, dir: Vector3) -> bool:
	return _notice_opacity(k) >= HUD.READABLE_ALPHA and _notice_hits(k, dir, 0.0) > 0


## Synthetic time: these tests drive every clock the HUD has (cues, making
## way, the celebration) with fixed frames, so a 40 s flight takes
## milliseconds. UIRoot's, the HUD's and the cues' own per-frame processing
## are off; layout still needs real frames (awaited after events).
const SDT := 1.0 / 72.0
## Long enough clear for the notices to forget earlier crossings.
const ENTRY_CLEAR_S := HUD.ENTRY_WINDOW_S + 0.5


func _synthetic(k: Kit) -> void:
	k.ui.set_process(false)
	k.ui.hud.set_process(false)
	k.ui.indicators.set_process(false)


## `seconds` (or `frames`) of synthetic frames (see _synthetic).
func _advance(k: Kit, seconds: float) -> void:
	for i in int(round(seconds / SDT)):
		_frame(k)


func _advance_frames(k: Kit, frames: int) -> void:
	for i in frames:
		_frame(k)


## One synthetic frame of flight: the HUD panel following the flight
## direction, the cues, the HUD making way for what matters now
## (UIRoot.hud_protected_directions), the celebration's clock.
func _frame(k: Kit, dt: float = SDT) -> void:
	k.ui.hud_panel.follow(dt)
	k.ui.indicators.step(dt)
	k.ui.hud.make_way(k.ui.hud_protected_directions(), dt)
	k.ui.hud.advance(dt)


## A tier-up now (its plate laid out in a real frame, then synthetic time).
func _tier_up(k: Kit, from_tier: int) -> void:
	k.player.mass = float(SizeRules.SPECIES[from_tier + 1]["mass"]) * 1.02
	Events.player_tier_changed.emit(from_tier, from_tier + 1)
	k.ui.hud.set_process(false)
	await wait_frames(1)


## [gamma_deg, speed] at time t of a [t, gamma, speed] series.
static func _sample(s: Array, t: float) -> Vector2:
	if s.is_empty():
		return Vector2(0.0, 8.0)
	t = fmod(t, float(s[s.size() - 1][0]))
	for i in range(1, s.size()):
		if float(s[i][0]) >= t:
			var a: Array = s[i - 1]
			var b: Array = s[i]
			var u := clampf((t - float(a[0])) / maxf(float(b[0]) - float(a[0]), 1e-4), 0.0, 1.0)
			return Vector2(lerpf(float(a[1]), float(b[1]), u), lerpf(float(a[2]), float(b[2]), u))
	return Vector2(float(s[0][1]), float(s[0][2]))


## The flight area's own B1 bot course (artifacts/ui/tools/b1_flightpath.py).
static func _b1(species: String) -> Array:
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://tests/unit/ui/ui_b1_flightpath.json"))
	return ((d as Dictionary)["series"] as Dictionary).get(species, []) if d is Dictionary else []


## The flight a tutorial asks for ("Flap to climb", then "Glide"), flown on
## the real FlightModel (sparrow, wrists neutral) by
## tests/shots/ui_flight_record.gd: bursts of `strokes` strokes at 1 Hz,
## then `glide_s` of gliding. [t, gamma_deg, speed] at 20 Hz, replayed from
## ui_flight_runs.json so this suite never calls flight's internals.
static func _tutorial_series(strokes: int, glide_s: float, seconds: float) -> Array:
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://tests/unit/ui/ui_flight_runs.json"))
	var all: Array = ((d as Dictionary)["tutorial"] as Dictionary).get("%d+%d" % [strokes, int(glide_s)], []) if d is Dictionary else []
	var out: Array = []
	for r: Array in all:
		if float(r[0]) < seconds:
			out.append(r)
	return out


## [min, max] azimuth (deg, + = right) from the eye of the glyphs of
## `labels` (their text, not their boxes), relative to the horizontal
## direction `ref` (world): where the words are in the player's view.
func _glyph_span(k: Kit, labels: Array[Label], ref: Vector3) -> Vector2:
	var ref_az := atan2(ref.x, -ref.z)
	var mn := INF
	var mx := -INF
	for lbl: Label in labels:
		if lbl == null or not lbl.is_visible_in_tree() or lbl.text == "":
			continue
		var f := lbl.get_theme_font(&"font")
		var fs := lbl.get_theme_font_size(&"font_size")
		var w := f.get_string_size(lbl.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var r := lbl.get_global_rect()
		var x0 := r.position.x
		if lbl.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT:
			x0 = r.end.x - w
		elif lbl.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER:
			x0 = r.get_center().x - w * 0.5
		for x: float in [x0, x0 + w]:
			var d := k.ui.hud_panel.pixel_to_world(Vector2(x, r.get_center().y)) - k.cam.global_position
			var a := rad_to_deg(wrapf(atan2(d.x, -d.z) - ref_az, -PI, PI))
			mn = minf(mn, a)
			mx = maxf(mx, a)
	return Vector2(mn, mx)


## Largest angle (deg) between the gaze (the camera's forward) and the
## text of `labels` (each line's two ends and middle, at mid-height): every
## word within 45 deg is in a Quest Pro's readable view (it shows about +-50
## deg; the lens blurs past ~45).
func _glyph_eccentricity(k: Kit, labels: Array[Label]) -> float:
	var g := -k.cam.global_basis.z
	var worst := 0.0
	for lbl: Label in labels:
		if lbl == null or not lbl.is_visible_in_tree() or lbl.text == "":
			continue
		var f := lbl.get_theme_font(&"font")
		var w := f.get_string_size(lbl.text, HORIZONTAL_ALIGNMENT_LEFT, -1, lbl.get_theme_font_size(&"font_size")).x
		var r := lbl.get_global_rect()
		var x0 := r.position.x
		if lbl.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT:
			x0 = r.end.x - w
		elif lbl.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER:
			x0 = r.get_center().x - w * 0.5
		for x: float in [x0, x0 + w * 0.5, x0 + w]:
			var d := k.ui.hud_panel.pixel_to_world(Vector2(x, r.get_center().y)) - k.cam.global_position
			worst = maxf(worst, rad_to_deg(g.angle_to(d)))
	return worst


## A notice the player can read where they look: opaque enough (>= 0.6) and
## every word of it within 45 deg of the gaze.
func _in_view_readable(k: Kit, labels: Array[Label]) -> bool:
	return _notice_opacity(k) >= HUD.READABLE_ALPHA and _glyph_eccentricity(k, labels) <= 45.0


## Replay `seconds` of a flight-path series with notices up, in synthetic
## time; the head looks along the flight path. From `turn_at` the flight
## direction turns `turn_deg` to the right at 60 deg/s, head included (the
## player turns their body: the bird follows the torso). Tier-ups at
## `tierups` (s).
func _replay(k: Kit, s: Array, seconds: float, tierups: Array = [], turn_deg := 0.0, turn_at := INF) -> Dictionary:
	var hud := k.ui.hud
	var panel := k.ui.hud_panel
	var moves0 := hud.move_count
	var pending := tierups.duplicate()
	var tier := 2
	var toasts: Array = []
	var cur := {}
	var t := 0.0
	var shown_s := 0.0
	var readable_s := 0.0
	var in_view_n := 0
	var in_view_hit := 0
	var frame_i := 0
	var hidden_s := 0.0
	var hidden_run := 0.0
	var hidden_longest := 0.0
	var travel := 0.0
	var fades := 0
	var was_faded := false
	var gam := Vector2(INF, -INF)
	var text := Vector2(INF, -INF)
	var strip_off := 0.0
	var prev_off := panel.band_offset(HUD.BAND_NOTICE)
	while t < seconds:
		if not pending.is_empty() and t >= float(pending[0]):
			pending.pop_front()
			if not cur.is_empty():
				toasts.append(cur)
			await _tier_up(k, tier)
			tier = 2 if tier >= 6 else tier + 1
			cur = {"at": snappedf(t, 0.01), "n": 0, "readable": 0, "in_view": 0, "hidden": 0}
		var g := _sample(s, t)
		gam = Vector2(minf(gam.x, g.x), maxf(gam.y, g.x))
		var a := deg_to_rad(g.x)
		var yaw := -deg_to_rad(clampf((t - turn_at) * 60.0, 0.0, turn_deg)) if t >= turn_at else 0.0
		k.player.velocity = Basis(Vector3.UP, yaw) * Vector3(0.0, sin(a), -cos(a)) * g.y
		# The player turns their torso (body steer): the bird faces the new
		# way, flies it, and the head at rest turns with the torso.
		k.player.global_basis = Basis(Vector3.UP, yaw)
		k.player.tel["body_yaw"] = yaw
		k.set_head(Vector3(0, Kit.EYE, 0), rad_to_deg(yaw))
		_frame(k)
		t += SDT
		var shown := _notice_opacity(k) > 0.0
		var hid := _hidden(k, k.player.velocity)
		var labels := hud.toast_labels() if hud.toast_active() else hud.lesson_labels()
		# Where the words are only changes when the HUD or the notices move:
		# measured every third frame (and counted for three).
		frame_i += 1
		var look := frame_i % 3 == 0
		var faded := shown and _notice_opacity(k) < HUD.READABLE_ALPHA
		if faded and not was_faded:
			fades += 1
		was_faded = faded
		if shown:
			shown_s += SDT
			if _notice_opacity(k) >= HUD.READABLE_ALPHA:
				readable_s += SDT
			if look:
				in_view_n += 1
				if _in_view_readable(k, labels):
					in_view_hit += 1
				# Where the card's text is beside the flight path (not while a
				# body turn is sweeping the path across the HUD: that is a fade).
				if not hud.toast_active() and (t < turn_at or t > turn_at + turn_deg / 60.0 + 2.0):
					var sp := _glyph_span(k, labels, Vector3(k.player.velocity.x, 0.0, k.player.velocity.z))
					text = Vector2(minf(text.x, sp.x), maxf(text.y, sp.y))
		if look:
			var sd := k.ui.hud_panel.control_to_world(hud.band_plates(HUD.BAND_STATUS)[0]) - k.cam.global_position
			strip_off = maxf(strip_off, absf(rad_to_deg(wrapf(atan2(sd.x, -sd.z) - atan2(k.player.velocity.x, -k.player.velocity.z), -PI, PI))))
		hidden_run = hidden_run + SDT if hid else 0.0
		hidden_longest = maxf(hidden_longest, hidden_run)
		if hid:
			hidden_s += SDT
		var off := panel.band_offset(HUD.BAND_NOTICE)
		travel += off.distance_to(prev_off)
		prev_off = off
		if not cur.is_empty() and hud.toast_active():
			cur["n"] = int(cur["n"]) + 1
			if _notice_opacity(k) >= HUD.READABLE_ALPHA:
				cur["readable"] = int(cur["readable"]) + 1
			if look and _in_view_readable(k, labels):
				cur["in_view"] = int(cur["in_view"]) + 3
			if hid:
				cur["hidden"] = int(cur["hidden"]) + 1
	if not cur.is_empty():
		toasts.append(cur)
	for tt: Dictionary in toasts:
		tt["readable_frac"] = snappedf(float(tt["readable"]) / maxf(float(tt["n"]), 1.0), 0.01)
		tt["in_view_s"] = snappedf(float(tt["in_view"]) * SDT, 0.01)
	var moves := hud.move_count - moves0
	return {"seconds": snappedf(seconds, 0.1), "gamma_deg": [snappedf(gam.x, 0.1), snappedf(gam.y, 0.1)],
		"moves": moves, "moves_per_s": snappedf(moves / seconds, 0.001), "travel_deg": snappedf(travel, 0.1),
		"fades": fades,
		"readable_frac": snappedf(readable_s / maxf(shown_s, 1e-3), 0.001),
		"in_view_readable_frac": snappedf(in_view_hit / maxf(float(in_view_n), 1.0), 0.001),
		"card_text_az_deg": [snappedf(text.x, 0.1), snappedf(text.y, 0.1)],
		"strip_off_path_max_deg": snappedf(strip_off, 0.1),
		"path_hidden_s": snappedf(hidden_s, 0.001), "path_hidden_longest_s": snappedf(hidden_longest, 0.001),
		"toasts": toasts}


func test_notices_live_beside_the_centre_line() -> void:
	# Round 3's notices sat on the centre line and stepped aside from the
	# flight path, which every flap cycle sweeps up and down that line: under
	# real flight they moved a third of the time. Their home is beside it,
	# above the horizon, and the whole line is clear of them. Round 6: the
	# text pulled in (the round-6 verifier: round 5's words reached 41 deg
	# from a level gaze along the centre line, 4 deg inside the 45 deg a
	# Quest Pro shows sharply): every word of every lesson within 35 deg.
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.gl.start_run()
	await k.settle(self, 4)
	_synthetic(k)
	k.player.velocity = Vector3(0, 0, -9)
	_frame(k)
	check(k.ui.hud.lesson_visible(), "a lesson card is up")
	var rows := {}
	for which: String in ["lesson card", "tier-up"]:
		if which == "tier-up":
			k.ui.onboarding.skip()
			await _tier_up(k, 2)
			for i in 25:
				_frame(k)
		eq(k.ui.hud_panel.band_offset(HUD.BAND_NOTICE), Vector2.ZERO, "%s: at home" % which)
		var plates := k.ui.hud.band_plates(HUD.BAND_NOTICE)
		check(not plates.is_empty(), "%s: a plate is up" % which)
		var inner := 999.0
		var outer := -999.0
		for p: Control in plates:
			var r := p.get_global_rect()
			for y: float in [r.position.y, r.get_center().y, r.end.y]:
				inner = minf(inner, _pixel_az_el(k, Vector2(r.position.x, y)).x)
				outer = maxf(outer, _pixel_az_el(k, Vector2(r.end.x, y)).x)
		# The whole centre line, from a 60 deg dive to an 85 deg zoom (the
		# tutorial's flapping on the real FlightModel reaches ~80 deg), keeps
		# 8 deg of sky to the notices: a flight path on it, or crabbing up to
		# 6.5 deg towards them, is never behind them nor within their 1.5 deg
		# fade margin.
		var worst := 0
		for el in range(-60, 86):
			worst += _notice_hits(k, _dir(0.0, float(el)), 8.0)
		# Prey jinking +-8 deg round the centre line right at the notices'
		# height (the round-4 verifier's fluttering moth, 7..17 deg up) never
		# comes within the 1.5 deg fade margin: the card does not blink for
		# it.
		var jink := 0
		for az in range(-8, 9):
			for el in range(5, 21):
				jink += _notice_hits(k, _dir(float(az), float(el)), 1.5)
		eq(jink, 0, "%s: prey jinking +-8 deg round the centre line at +5..+20 deg keeps 1.5 deg clear of every plate" % which)
		rows[which] = {"inner_edge_deg_right": snappedf(inner, 0.01), "outer_edge_deg_right": snappedf(outer, 0.01),
			"lowest_deg": snappedf(_notice_lowest_deg(k), 0.01)}
		eq(worst, 0, "%s: the centre line from -60 to +85 deg keeps 8 deg of sky to every plate" % which)
		between(inner, 9.5, 10.5, "%s: inner edge %.2f deg right of the centre line" % [which, inner])
		lt(outer, 44.0, "%s: outer edge %.2f deg right (inside a Quest Pro's view)" % [which, outer])
		gt(_notice_lowest_deg(k), 6.5, "%s: above the hunting gaze (lowest %.2f deg)" % [which, _notice_lowest_deg(k)])
		if which == "tier-up":
			k.set_head(Vector3(0, Kit.EYE, 0), 0.0)
			var te := _glyph_eccentricity(k, k.ui.hud.toast_labels())
			rows["tier-up words from a level gaze along the centre line"] = snappedf(te, 0.01)
			lt(te, 41.5, "the celebration's words within 41.5 deg of a level gaze along the centre line (%.2f)" % te)
	# Text on the inner side of the card, the illustration outside it.
	k.ui.hud.cancel_toast()
	k.ui.onboarding.reset()
	k.ui.onboarding.start()
	await k.settle(self, 2)
	var title := _find_label(k.ui.hud, k.ui.hud.lesson_title())
	var art := k.ui.hud.find_children("*", "GestureCard", true, false)[0] as Control
	lt(title.get_global_rect().position.x, art.get_global_rect().position.x, "home: text nearer the centre line than the art")
	# Every lesson's words, with a level gaze along the centre line: within
	# 35 deg (10 deg inside the 45 deg bound), and the nearest 10.5 deg out.
	k.set_head(Vector3(0, Kit.EYE, 0), 0.0)
	var words := {}
	var far := 0.0
	var near_min := INF
	_synthetic(k)
	for place: Vector2 in [Vector2.ZERO, HUD.NOTICE_MIRROR]:
		for i in Onboarding.LESSONS.size():
			k.ui.hud.show_lesson(i, Onboarding.LESSONS.size(), Onboarding.LESSONS[i])
			k.ui.hud_panel.set_band_offset(HUD.BAND_NOTICE, place)
			k.ui.hud.set_notice_side(1 if place == Vector2.ZERO else -1)
			await k.settle(self, 1)
			var e := _glyph_eccentricity(k, k.ui.hud.lesson_labels())
			var sp := _glyph_span(k, k.ui.hud.lesson_labels(), Vector3.FORWARD)
			# Distance from the centre line: + = away from it on either side.
			var side := 1.0 if place == Vector2.ZERO else -1.0
			var near_d := minf(sp.x * side, sp.y * side)
			var far_d := maxf(sp.x * side, sp.y * side)
			words["%s %s" % ["home" if side > 0 else "mirror", String(Onboarding.LESSONS[i]["id"])]] = [snappedf(near_d, 0.01), snappedf(far_d, 0.01), snappedf(e, 0.01)]
			far = maxf(far, e)
			near_min = minf(near_min, near_d)
	k.ui.hud_panel.set_band_offset(HUD.BAND_NOTICE, Vector2.ZERO)
	k.ui.hud.set_notice_side(1)
	await k.settle(self, 1)
	rows["lesson words: [nearest, farthest from the centre line, farthest from a level gaze] deg"] = words
	lt(far, 35.0, "every lesson's words, at home and at the mirror placement, within 35 deg of a level gaze along the centre line (worst %.2f)" % far)
	gt(near_min, 10.5, "and at least 10.5 deg from it (%.2f)" % near_min)
	# The cue ring: prey or a threat above you points up, and those chevrons
	# (ring angles 60-120) are never on a plate; the card crosses the 24 deg
	# ring on its upper-right arc only, where a cue sits on it (it draws on
	# top, and the notices fade and move if it stays: see the cue tests).
	var cam := k.cam.global_transform
	var covered: Array[int] = []
	for i in 180:
		var d := (cam.basis * HudMath.ring_point(deg_to_rad(i * 2.0), HudIndicators.ECCENTRICITY, 1.0)).normalized()
		if _notice_hits(k, d, 0.0) > 0:
			covered.append(i * 2)
	rows["ring_24_covered_angles"] = str(covered)
	metric("notice_home", rows)
	lt(float(covered.size() * 2), 40.0, "at most 40 of 360 deg of the cue ring under the card (%d)" % (covered.size() * 2))
	for a in covered:
		check(a < 60 or a > 120, "no ring angle pointing up (60-120) under the card (%d)" % a)
	k.teardown()
	await wait_frames(2)


func _find_label(root: Node, text: String) -> Label:
	for l in root.find_children("*", "Label", true, false):
		if (l as Label).text == text:
			return l
	return null


func test_notices_stay_calm_under_real_flight() -> void:
	# The lead's bar, under the flight the game really has: the tutorial's
	# own flap-and-glide on the real FlightModel (recorded), and the flight
	# area's B1 course for a sparrow, a pigeon and an eagle, with the lesson
	# card up the whole time and the head looking along the flight path: no
	# move, the flight path never behind the card, the card readable *in
	# view* (every word within 45 deg of the gaze) the whole time. Then the
	# same with a 30 deg body turn to the right at 5 s (towards the card):
	# the HUD's centre line follows where the body faces, so the card stays
	# beside the new path (it may fade while the turn sweeps the path past
	# it, never move, never hide the path for more than a blink).
	var profiles := {
		"tutorial flap2+glide2 (FlightModel)": _tutorial_series(2, 2.0, 30.0),
		"tutorial flap3+glide3 (FlightModel)": _tutorial_series(3, 3.0, 36.0),
		"B1 sparrow": _b1("sparrow"),
		"B1 pigeon": _b1("pigeon"),
		"B1 eagle": _b1("eagle"),
	}
	var results := {}
	var bad: Array = []
	for key: String in profiles:
		var s: Array = profiles[key]
		if not check(s.size() > 100, "profile %s loaded" % key):
			continue
		var secs := float(s[s.size() - 1][0])
		for turn: float in [0.0, 30.0]:
			var k := Kit.new()
			k.setup(self, true)
			await k.settle(self, 3)
			k.gl.start_run()
			await k.settle(self, 4)
			_synthetic(k)
			check(k.ui.hud.lesson_visible(), "lesson card up (%s)" % key)
			var label := "%s%s" % [key, "" if turn == 0.0 else ", body turn 30 deg right at 5 s"]
			var r := await _replay(k, s, secs, [], turn, 5.0)
			r.erase("toasts")
			results[label] = r
			var text: Array = r["card_text_az_deg"]
			if int(r["moves"]) > 0 or float(r["path_hidden_longest_s"]) > 0.06:
				bad.append("%s: %s" % [label, str(r)])
			# (10.8 at rest; after a torso turn the HUD settles within 0.5 deg.)
			if float(text[0]) < 10.0 or float(text[1]) > 33.0:
				bad.append("%s: card text at %s deg from the flight path (want 10..33)" % [label, str(text)])
			if float(r["strip_off_path_max_deg"]) > (5.0 if turn == 0.0 else 30.0):
				bad.append("%s: growth strip %.1f deg off the flight path" % [label, r["strip_off_path_max_deg"]])
			if turn == 0.0:
				# Beside the flight path: never crossed, never faded, always read.
				if int(r["fades"]) > 0 or float(r["path_hidden_s"]) > 0.0 or float(r["in_view_readable_frac"]) < 0.999:
					bad.append("%s: %s" % [label, str(r)])
			elif float(r["in_view_readable_frac"]) < 0.9:
				bad.append("%s: in view and readable only %.0f %%" % [label, float(r["in_view_readable_frac"]) * 100.0])
			k.teardown()
			await wait_frames(2)
	metric("lesson_card_real_flight", results)
	eq(bad, [], "calm under real flight: no move, the path never hidden, the card beside the path and read in view")
	# Tier-ups mid-course (B1 sparrow: flapping climbs, zooms and dives).
	var k2 := Kit.new()
	k2.setup(self, true)
	await k2.settle(self, 3)
	k2.ui.onboarding.skip()
	k2.gl.start_run()
	await k2.settle(self, 4)
	_synthetic(k2)
	var rt := await _replay(k2, _b1("sparrow"), 24.0, [1.0, 6.0, 11.0, 16.0, 21.0])
	metric("tierups_b1_sparrow", rt)
	eq(int(rt["moves"]), 0, "no celebration moved")
	for tt: Dictionary in rt["toasts"]:
		gt(float(tt["in_view_s"]), 2.5, "the celebration at %.1f s is read in view for > 2.5 s (%s)" % [tt["at"], str(tt)])
		eq(int(tt["hidden"]), 0, "and never hides the flight path (%s)" % str(tt))
	k2.teardown()
	await wait_frames(2)


## The real game's flight as the view saw it (tests/shots/ui_game_record.gd
## flew scenes/main.tscn: the world's breeze, flight's PlayerBird and
## WingInput, the integration bot's arms, the ecosystem, GameLoop): rows
## [t, rig yaw deg, velocity xyz, forward xyz, body_yaw deg, head yaw deg,
## head pitch deg, world_scale, lesson, target id, target xyz from the eye,
## threat id, threat xyz from the eye, threat level], all in the world
## except the torso and the head (the rig's frame).
static func _game_flight(name_: String) -> Array:
	return Kit.game_flight(name_)


## Replay a recorded game flight through core contracts only: the rig hangs
## under a node yawed as PlayerBird yawed the real rig; the mock player has
## the recorded velocity and forward (world) and torso yaw (its telemetry's
## body_yaw); world_scale as recorded; stand-in birds (plain Bird nodes)
## where GameLoop's target and threat were, named on Events.target_changed
## and threat_changed as GameLoop named them (a new bird, or the level
## moving 0.02), so the cues and everything the notices make way for are
## the real game's. `room_deg` turns the player in their
## room (the tracking space): torso and head `room_deg` further left, the
## rig as much the other way, so the flight in the world is the same. The
## head rests along the torso (as the bot's did), plus `head_fn(t)` ([yaw,
## pitch] deg) if given. Tier-ups at `tierups` (s).
## Measured, in synthetic 72 Hz frames (the recording is 36 Hz; linear in
## between, angles the short way round):
##  - the HUD's centre line against where the body faces: largest gap, time
##    past 45 deg, its fastest swing and total travel in the rig;
##  - the lesson card: readable (opacity >= 0.6) and in view (every word
##    within 45 deg of the gaze), fades, moves, the real flight path behind
##    the readable card (longest run);
##  - for comparison only: in view of a gaze along the flight path;
##  - each celebration: seconds read in view.
func _replay_game(k: Kit, rows: Array, room_deg := 0.0, tierups: Array = [], head_fn := Callable()) -> Dictionary:
	var hud := k.ui.hud
	var panel := k.ui.hud_panel
	var n := rows.size()
	var t_end := float(rows[n - 1][0])
	var t := float(rows[0][0])
	var pending := tierups.duplicate()
	var tier := 2
	var toasts: Array = []
	var cur := {}
	var st := {"frames": 0, "shown": 0, "readable": 0, "in_view": 0, "path_n": 0, "path_in_view": 0,
		"hidden_run": 0.0, "hidden_longest": 0.0, "hidden_s": 0.0, "fades": 0, "err_max": 0.0, "over45": 0.0,
		"rate_max": 0.0, "travel": 0.0, "ecc_max": 0.0, "crab_max": 0.0}
	var was_faded := false
	var moves0 := hud.move_count
	var prev_yaw := rad_to_deg(panel.panel_yaw())
	var frame_i := 0
	var fade_log: Array = []
	var replay := {}
	while t < t_end:
		var fr := k.apply_game_row(rows, t, room_deg, replay, head_fn.call(t) if head_fn.is_valid() else Vector2.ZERO)
		var v: Vector3 = fr["velocity"]
		var torso: float = fr["torso_deg"]
		if not pending.is_empty() and t >= float(pending[0]):
			pending.pop_front()
			if not cur.is_empty():
				toasts.append(cur)
			await _tier_up(k, tier)
			tier = 2 if tier >= 6 else tier + 1
			cur = {"at": snappedf(t, 0.01), "in_view_s": 0.0}
		_frame(k)
		t += SDT
		frame_i += 1
		st["frames"] = int(st["frames"]) + 1
		# The HUD against where the body faces (in the rig).
		var y := rad_to_deg(panel.panel_yaw())
		var err := absf(wrapf(y - torso, -180.0, 180.0))
		st["err_max"] = maxf(float(st["err_max"]), err)
		if err > 45.0:
			st["over45"] = float(st["over45"]) + SDT
		var dy := absf(wrapf(y - prev_yaw, -180.0, 180.0))
		st["travel"] = float(st["travel"]) + dy
		st["rate_max"] = maxf(float(st["rate_max"]), dy / SDT)
		prev_yaw = y
		var op := _notice_opacity(k)
		var faded := op > 0.0 and op < HUD.READABLE_ALPHA
		# A fade is the notices making way (the band turning see-through),
		# not a celebration's own pop-in or fade-out.
		var made_way := op > 0.0 and panel.band_alpha(HUD.BAND_NOTICE) < HUD.READABLE_ALPHA
		var moving := v.length() > 1.5 * k.rig.world_scale
		if made_way:
			st["made_way_s"] = float(st.get("made_way_s", 0.0)) + SDT
		if made_way and not was_faded:
			st["fades"] = int(st["fades"]) + 1
			# Where the flight path was (az + = right of the torso, el) and
			# which side the card was on: what made it fade.
			var vr0 := k.rig.global_basis.inverse() * v
			fade_log.append([snappedf(t, 0.01), snappedf(-wrapf(rad_to_deg(atan2(-vr0.x, -vr0.z)) - torso, -180.0, 180.0), 0.1),
				snappedf(rad_to_deg(asin(clampf(v.normalized().y, -1.0, 1.0))), 0.1), hud.notice_side, hud.toast_active(), _fade_causes(k)])
		was_faded = made_way
		var hid := moving and _hidden(k, v)
		st["hidden_run"] = float(st["hidden_run"]) + SDT if hid else 0.0
		st["hidden_longest"] = maxf(float(st["hidden_longest"]), float(st["hidden_run"]))
		if hid:
			st["hidden_s"] = float(st["hidden_s"]) + SDT
		if moving:
			var vr := k.rig.global_basis.inverse() * v
			st["crab_max"] = maxf(float(st["crab_max"]), absf(wrapf(rad_to_deg(atan2(-vr.x, -vr.z)) - torso, -180.0, 180.0)))
		var toasting := hud.toast_active()
		var labels := hud.toast_labels() if toasting else hud.lesson_labels()
		if op > 0.0 and frame_i % 2 == 0:
			var e := _glyph_eccentricity(k, labels)
			if not toasting:
				st["shown"] = int(st["shown"]) + 2
				if not faded:
					st["readable"] = int(st["readable"]) + 2
					if e > float(st["ecc_max"]):
						st["ecc_at"] = [snappedf(t, 0.01), hud.notice_side, snappedf(panel.band_offset(HUD.BAND_NOTICE).x, 0.1), hud.lesson_title()]
					st["ecc_max"] = maxf(float(st["ecc_max"]), e)
					if e <= 45.0:
						st["in_view"] = int(st["in_view"]) + 2
				if moving:
					st["path_n"] = int(st["path_n"]) + 2
					var g := k.cam.global_basis
					k.cam.global_basis = Basis.looking_at(v.normalized(), Vector3.UP)
					if not faded and _glyph_eccentricity(k, labels) <= 45.0:
						st["path_in_view"] = int(st["path_in_view"]) + 2
					k.cam.global_basis = g
			elif not cur.is_empty() and not faded and e <= 45.0:
				cur["in_view_s"] = float(cur["in_view_s"]) + 2.0 * SDT
	if not cur.is_empty():
		toasts.append(cur)
	for tt: Dictionary in toasts:
		tt["in_view_s"] = snappedf(float(tt["in_view_s"]), 0.01)
	k.end_game_replay(replay)
	var shown := maxf(float(st["shown"]), 1.0)
	return {"seconds": snappedf(t_end, 0.1), "room_deg": room_deg,
		"hud_off_body_max_deg": snappedf(float(st["err_max"]), 0.01), "hud_off_body_over_45_s": snappedf(float(st["over45"]), 0.01),
		"hud_swing_max_deg_s": snappedf(float(st["rate_max"]), 0.1), "hud_travel_deg": snappedf(float(st["travel"]), 0.1),
		"card_shown_s": snappedf(float(st["shown"]) * SDT, 0.01),
		"card_readable_frac": snappedf(float(st["readable"]) / shown, 0.001),
		"card_in_view_readable_frac": snappedf(float(st["in_view"]) / shown, 0.001),
		"card_words_max_from_gaze_deg": snappedf(float(st["ecc_max"]), 0.1), "card_words_max_at [t, side, offset, title]": st.get("ecc_at", []),
		"fades": st["fades"], "fades_per_min": snappedf(float(st["fades"]) / (t_end / 60.0), 0.1),
		"fade_mean_s": snappedf(float(st.get("made_way_s", 0.0)) / maxf(float(st["fades"]), 1.0), 0.001),
		"moves": hud.move_count - moves0,
		"path_hidden_s": snappedf(float(st["hidden_s"]), 0.001), "path_hidden_longest_s": snappedf(float(st["hidden_longest"]), 0.001),
		"path_off_body_max_deg": snappedf(float(st["crab_max"]), 0.1),
		"compare_in_view_of_a_gaze_along_the_path_frac": snappedf(float(st["path_in_view"]) / maxf(float(st["path_n"]), 1.0), 0.001),
		"fade_log [t, path az right of torso, path el, card side, celebration]": fade_log, "toasts": toasts}


## What is on (or within the fade margin of) a notice plate now: the flight
## path, the target, a real threat, their cue chevrons.
func _fade_causes(k: Kit) -> String:
	var eye := k.cam.global_position
	var out: Array[String] = []
	if k.player.velocity.length() > 1.5 * k.rig.world_scale and _notice_hits(k, k.player.velocity, HUD.FADE_MARGIN_DEG) > 0:
		out.append("path")
	for which: StringName in [&"target", &"threat"]:
		var bird: Bird = k.ui.indicators.get(which)
		if is_instance_valid(bird) and _notice_hits(k, bird.get_body_position() - eye, HUD.FADE_MARGIN_DEG) > 0:
			out.append(String(which))
		var cue := k.ui.indicators.cue_mesh(which)
		if cue and cue.visible and _notice_hits(k, cue.global_position - eye, HUD.FADE_MARGIN_DEG) > 0:
			out.append("%s cue" % which)
	return ",".join(out)


func test_notices_under_the_real_games_flight() -> void:
	# The round-6 verifier's major: in the real game the round-5 HUD followed
	# the flight path's heading, and the path is not where the player faces:
	# the breeze crabs a slow sparrow's path 15-50 deg off, a zoom over the
	# top reverses it (and the bird's facing) while the view turns round at
	# its comfort rate. The HUD swung 157 deg round the player; the lesson
	# card was in view of a resting gaze 39 % of the tutorial. Here the real
	# game's own flight (recorded: the tutorial as the verifier flew it, then
	# turns, a dive, a zoom and a chase), the rig yawing under a PlayerBird-
	# like parent (the world -> rig maths the round-6 engineering verifier
	# found untested), the head at rest along the torso; and the same with
	# the player standing 60 deg left in their room (the torso is not the
	# rig's forward). The HUD stays where the body faces and never swings;
	# the card is read in view >= 90 % of the time (the verifier's bar) and
	# makes way for the real flight path (fades, rarely moves, never hides
	# it for more than a blink).
	var results := {}
	var bad: Array = []
	for flight: String in ["tutorial", "manoeuvres"]:
		var rows := _game_flight(flight)
		if not check(rows.size() > 500, "recorded flight %s loaded (%d rows)" % [flight, rows.size()]):
			continue
		for room: float in [0.0, 60.0]:
			var k := Kit.new()
			k.setup(self, true)
			await k.settle(self, 3)
			k.parent_rig_like_player_bird()
			k.ui.onboarding.reset()
			var r0: Array = rows[0]
			k.set_rig_heading(float(r0[1]) - room)
			k.player.tel["body_yaw"] = deg_to_rad(float(r0[8]) + room)
			k.set_world_scale(float(r0[11]))
			k.set_head(Vector3(0, Kit.EYE, 0), float(r0[9]) + room)
			k.gl.start_run()
			await k.settle(self, 4)
			_synthetic(k)
			check(k.ui.hud.lesson_visible(), "%s: a lesson card is up" % flight)
			var r := await _replay_game(k, rows, room, [8.0, 30.0] if flight == "manoeuvres" else [])
			var key := "%s, room %+.0f deg" % [flight, room]
			results[key] = r
			if float(r["hud_off_body_max_deg"]) > 1.0 or float(r["hud_travel_deg"]) > 1.0:
				bad.append("%s: the HUD left where the body faces (%.2f deg off, %.1f deg of travel)" % [key, r["hud_off_body_max_deg"], r["hud_travel_deg"]])
			# Read in view: the tutorial as the verifier flew it >= 95 % (its
			# bar: 90); 54 s of hard manoeuvring with one timed-out card up
			# the whole time, where the crab keeps the path near the card's
			# column and every crossing is a fade by design, >= 85 % (see
			# docs/areas/UI.md: nearer, the words pass 35 deg; further out,
			# prey jinking +-8 deg round the centre line fades the card).
			var bar := 0.95 if flight == "tutorial" else 0.85
			if float(r["card_in_view_readable_frac"]) < bar:
				bad.append("%s: card read in view of a resting gaze %.1f %% (want >= %.0f)" % [key, float(r["card_in_view_readable_frac"]) * 100.0, bar * 100.0])
			if float(r["card_words_max_from_gaze_deg"]) > 35.5:
				bad.append("%s: a readable card's words %.1f deg from the resting gaze (want <= 35)" % [key, r["card_words_max_from_gaze_deg"]])
			# Moves: none in the tutorial (the verifier's bar: at most one);
			# in the manoeuvres the crab changes sides with every turn, and a
			# card crossed 3 times in 8 s goes to the other side: at most one
			# move per 15 s. The path is never behind the readable card for
			# more than a blink (the fade takes 0.056 s to pass 0.6).
			var moves_max := 1 if flight == "tutorial" else int(float(r["seconds"]) / 15.0)
			if int(r["moves"]) > moves_max or float(r["path_hidden_longest_s"]) > 0.06:
				bad.append("%s: %d moves (want <= %d), path hidden up to %.3f s" % [key, r["moves"], moves_max, r["path_hidden_longest_s"]])
			# Fades: the card making way for the real flight path (it is
			# never hidden). The tutorial as the verifier flew it: under 3
			# (its bar). 54 s of hard manoeuvring in the breeze (turns both
			# ways, a dive, a zoom, a chase, two celebrations) sweeps the
			# path past the card's inner edge more often: at most one fade
			# every 4 s on average, and the card still read >= 90 % (above).
			if flight == "tutorial" and int(r["fades"]) >= 3:
				bad.append("%s: %d fades (want < 3)" % [key, r["fades"]])
			if float(r["fades_per_min"]) > 15.0:
				bad.append("%s: %.1f fades a minute (want <= 15)" % [key, r["fades_per_min"]])
			for tt: Dictionary in r["toasts"]:
				if float(tt["in_view_s"]) < 2.5:
					bad.append("%s: the celebration at %.1f s read in view %.2f s" % [key, tt["at"], tt["in_view_s"]])
			k.teardown()
			await wait_frames(2)
	metric("real_game_flight", results)
	print("[ui] real game flight: %s" % JSON.stringify(results))
	eq(bad, [], "under the real game's flight the HUD stays where the body faces and the card in view")


## Enter PLAYING the way `how` says, with the head turned away from the
## flight path (-Z) when the HUD appears; returns the head's yaw then (deg,
## + = right) or NAN if play did not start.
##   "start":   head at `amount` deg, then the run starts;
##   "resume":  fly, pause, point at Resume with the head turned `amount`
##              of the way to it (1 = all the way), pull;
##   "play":    on the main menu, point at Play likewise, pull;
##   "respawn": caught, then back in the air with the head at `amount` deg.
func _enter_playing(k: Kit, how: String, amount: float) -> float:
	var head := amount
	match how:
		"start":
			k.set_head(Vector3(0, Kit.EYE, 0), -head)
			k.gl.start_run()
			await k.settle(self, 4)
		"resume", "play":
			var btn: Button
			if how == "resume":
				k.gl.start_run()
				await k.settle(self, 4)
				Events.menu_requested.emit()
				await k.settle(self, 6)
				btn = k.ui.get_screen(&"pause").get_button(&"resume")
			else:
				btn = k.ui.get_screen(&"main").get_button(&"play")
			var d := k.ui.menu_panel.control_to_world(btn) - k.cam.global_position
			head = rad_to_deg(atan2(d.x, -d.z)) * amount
			k.set_head(Vector3(0, Kit.EYE, 0), -head)
			k.aim_at_control(k.right, btn)
			await k.click(self, k.right)
			await k.settle(self, 2)
		"respawn":
			k.gl.start_run()
			await k.settle(self, 4)
			k.gl.fake_caught(null)
			await k.settle(self, 3)
			k.set_head(Vector3(0, Kit.EYE, 0), -head)
			Game.set_state(Game.State.PLAYING)
			await k.settle(self, 3)
	return head if Game.state == Game.State.PLAYING else NAN


func test_the_hud_centre_line_is_where_the_body_faces_whatever_the_head_did() -> void:
	# Round 4 put the notices beside the HUD's centre line on the premise
	# that it was where the player flies; it was the head's yaw when the HUD
	# appeared (the round-5 verifier: after a Resume with the head on the
	# button, the tutorial's own flight crossed the card, faded it twice and
	# sent it to 37-65 deg left). The centre line is where the torso faces
	# (round 5 used the flight path's heading, which the real game's wind
	# and loops swing round: test_notices_under_the_real_games_flight).
	# Whatever the head did as the HUD appeared, looking along the flight
	# path (here where the torso faces) during the tutorial's flap-and-glide:
	# the card's text 10-33 deg beside it, the strip under it, no fade, no
	# move, the path never behind the card, the card read in view the whole
	# time (three whole flap-and-glide cycles: the path sweeps -46..+77 deg).
	var s := _tutorial_series(2, 2.0, 12.0)
	var results := {}
	var bad: Array = []
	for c: Array in [["start", 0.0], ["start", 30.0], ["start", -30.0], ["start", 15.0], ["start", -15.0],
			["resume", 1.0], ["resume", 0.6], ["play", 1.0], ["respawn", -40.0], ["respawn", 35.0]]:
		var k := Kit.new()
		k.setup(self, true)
		await k.settle(self, 3)
		k.ui.onboarding.reset()
		k.player.velocity = Vector3(0, 0, -8)
		var head: float = await _enter_playing(k, c[0], c[1])
		var key := "%s %+.1f" % [c[0], c[1]]
		if not check(is_finite(head), "%s: playing" % key):
			k.teardown()
			await wait_frames(2)
			continue
		check(k.ui.hud.lesson_visible(), "%s: a lesson card is up" % key)
		_synthetic(k)
		var r := await _replay(k, s, 12.0)
		r.erase("toasts")
		r["head_at_show_deg"] = snappedf(head, 0.1)
		results[key] = r
		var text: Array = r["card_text_az_deg"]
		if float(text[0]) < 10.0 or float(text[1]) > 33.0:
			bad.append("%s (head %.1f deg): card text at %s deg from the flight path" % [key, head, str(text)])
		if float(r["strip_off_path_max_deg"]) > 1.0:
			bad.append("%s: growth strip %.1f deg off the flight path" % [key, r["strip_off_path_max_deg"]])
		if int(r["fades"]) > 0 or int(r["moves"]) > 0 or float(r["path_hidden_s"]) > 0.0:
			bad.append("%s: %d fades, %d moves, path hidden %.2f s" % [key, r["fades"], r["moves"], r["path_hidden_s"]])
		if float(r["in_view_readable_frac"]) < 0.999:
			bad.append("%s: read in view %.1f %% of the time" % [key, float(r["in_view_readable_frac"]) * 100.0])
		k.teardown()
		await wait_frames(2)
	metric("hud_centre_line_vs_head_at_show", results)
	eq(bad, [], "the notices sit beside the flight path whatever the head did when the HUD appeared")


## Watch a celebration to its end with the head at `head_fn(t)` ([yaw deg,
## + = right; pitch deg]): seconds it was readable in view (opacity >= 0.6,
## every word within 45 deg of the gaze), frames it hid the flight path,
## where its plate went.
func _watch_toast_in_view(k: Kit, head_fn: Callable, limit := 12.0) -> Dictionary:
	var hud := k.ui.hud
	var seen := 0.0
	var hid := 0
	var t := 0.0
	var inner := INF
	var off0 := k.ui.hud_panel.band_offset(HUD.BAND_NOTICE)
	var moved := false
	var ecc := INF
	var home := off0 == Vector2.ZERO
	while hud.toast_active() and t < limit:
		var h: Vector2 = head_fn.call(t)
		k.set_head(Vector3(0, Kit.EYE, 0), -h.x, h.y)
		_frame(k)
		t += SDT
		if not hud.toast_active():
			break
		if _in_view_readable(k, hud.toast_labels()):
			seen += SDT
		ecc = minf(ecc, _glyph_eccentricity(k, hud.toast_labels()))
		if _hidden(k, k.player.velocity):
			hid += 1
		if k.ui.hud_panel.band_offset(HUD.BAND_NOTICE) != off0:
			moved = true
		var pr := hud.band_plates(HUD.BAND_NOTICE)[0].get_global_rect()
		for x: float in [pr.position.x, pr.end.x]:
			var d := k.ui.hud_panel.pixel_to_world(Vector2(x, pr.get_center().y)) - k.cam.global_position
			inner = minf(inner, absf(rad_to_deg(atan2(d.x, -d.z))))
	return {"seen_in_view_s": snappedf(seen, 0.01), "lasted_s": snappedf(t, 0.01), "path_hidden_frames": hid,
		"text_eccentricity_deg": snappedf(ecc, 0.1), "home": home,
		"plate_nearest_path_deg": snappedf(inner, 0.1), "moved": moved, "held_s": snappedf(hud.toast_held(), 0.01)}


func test_celebrations_appear_where_the_player_looks() -> void:
	# A tier-up comes right after a catch, and the player may be looking at
	# the next bird. Round 4 put every celebration at the notices' home right
	# of the flight path; the round-5 verifier looked 25 deg left and saw 0 s
	# of it (40 deg left: 0 s). A celebration now appears as near the gaze as
	# it can while staying beside the centre line (never nearer it than home)
	# and clear of the flight path, and stays put there. Head level at every yaw from 150 deg right to 150
	# left, glancing 5 deg down along the path, down-left at prey, up-right:
	# read in view > 2.5 s of its 3.2 s, never over the flight path, no move.
	# (Looking further down along the path, where no place above the hunting
	# gaze is in view, it waits: test_a_celebration_waits_...)
	var results := {}
	var bad: Array = []
	for g: Vector2 in [Vector2(0, 0), Vector2(-2.5, 0), Vector2(-25, 0), Vector2(-40, 0), Vector2(30, 0), Vector2(40, 0), Vector2(-60, 0),
			Vector2(60, 0), Vector2(-90, 0), Vector2(90, 0), Vector2(150, 0), Vector2(-150, 0), Vector2(0, -5), Vector2(-40, -15), Vector2(20, 25)]:
		var k := Kit.new()
		k.setup(self, true)
		await k.settle(self, 3)
		k.ui.onboarding.skip()
		k.player.velocity = Vector3(0, 0, -8)
		k.gl.start_run()
		await k.settle(self, 4)
		_synthetic(k)
		k.set_head(Vector3(0, Kit.EYE, 0), -g.x, g.y)
		_advance_frames(k, 10)
		await _tier_up(k, 2)
		var r := _watch_toast_in_view(k, func(_t: float) -> Vector2: return g)
		var key := "gaze %+.0f, %+.0f" % [g.x, g.y]
		results[key] = r
		if float(r["seen_in_view_s"]) < 2.5:
			bad.append("%s: read in view %.2f s of %.2f s" % [key, r["seen_in_view_s"], r["lasted_s"]])
		if int(r["path_hidden_frames"]) > 0 or bool(r["moved"]):
			bad.append("%s: %s" % [key, str(r)])
		if float(r["plate_nearest_path_deg"]) < 9.2:
			bad.append("%s: plate %.1f deg from the centre line (home: 9.7)" % [key, r["plate_nearest_path_deg"]])
		# Looking (nearly) along the flight path both sides are as near:
		# it goes home, where the lesson card lives, not by a hair's choice.
		if absf(g.x) <= 2.5 and g.y == 0.0 and not bool(r["home"]):
			bad.append("%s: placed on the mirror side, not at home" % key)
		k.teardown()
		await wait_frames(2)
	metric("celebration_in_view_by_gaze", results)
	eq(bad, [], "a celebration is read in view > 2.5 s wherever the player looks, beside the centre line, and stays put")


func test_the_card_comes_back_where_it_rests_after_a_celebration() -> void:
	# A celebration placed where the player looked may sit far out (60 deg
	# right, or on the other side, 60 deg left). When it ends, the lesson
	# card must not show there, not even for a frame, nor with its words
	# laid out for the side it left: it comes back at home (or the mirror),
	# laid out for that side.
	for gaze: float in [-60.0, 60.0]:
		var k := Kit.new()
		k.setup(self, true)
		await k.settle(self, 3)
		k.gl.start_run()
		await k.settle(self, 4)
		_synthetic(k)
		k.player.velocity = Vector3(0, 0, -8)
		_advance_frames(k, 5)
		check(k.ui.hud.lesson_visible(), "a lesson card is up")
		k.set_head(Vector3(0, Kit.EYE, 0), gaze)
		_advance_frames(k, 5)
		await _tier_up(k, 2)
		_advance_frames(k, 3)
		var toast_off := k.ui.hud_panel.band_offset(HUD.BAND_NOTICE)
		check(absf(toast_off.x) > 15.0 and signf(toast_off.x) == signf(gaze), "gaze %+.0f: the celebration went out where the player looks (%s)" % [gaze, toast_off])
		var t := 0.0
		while k.ui.hud.toast_active() and t < 12.0:
			k.ui.hud_panel.follow(SDT)
			k.ui.hud.make_way(k.ui.hud_protected_directions(), SDT)
			k.ui.hud.advance(SDT)
			t += SDT
		check(not k.ui.hud.toast_active(), "it ended")
		# The frame it ended in: the card is up again but not shown yet.
		var alpha_end := k.ui.hud_panel.band_alpha(HUD.BAND_NOTICE)
		eq(alpha_end, 0.0, "gaze %+.0f: the frame the celebration ends, the card is not shown at its place (alpha %.2f)" % [gaze, alpha_end])
		_frame(k)
		var off := k.ui.hud_panel.band_offset(HUD.BAND_NOTICE)
		check(off == Vector2.ZERO or off == HUD.NOTICE_MIRROR, "gaze %+.0f: next frame the card is at a place it rests (%s)" % [gaze, off])
		gt(k.ui.hud_panel.band_alpha(HUD.BAND_NOTICE), 0.1, "and shown")
		k.set_head(Vector3(0, Kit.EYE, 0), 0.0)
		var e := _glyph_eccentricity(k, k.ui.hud.lesson_labels())
		lt(e, 35.0, "gaze %+.0f: its words laid out for that side, within 35 deg of a level gaze ahead (%.2f)" % [gaze, e])
		k.teardown()
		await wait_frames(2)


func test_a_celebration_waits_while_the_player_looks_away() -> void:
	# Placed where the player looked, it stays put; if they look away (a bird
	# behind), its clock holds while it is out of view, so it is still there
	# to read when they look back, and it cannot hang on: at most 3 s of
	# waiting in all (literal).
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.ui.onboarding.skip()
	k.player.velocity = Vector3(0, 0, -8)
	k.gl.start_run()
	await k.settle(self, 4)
	_synthetic(k)
	_advance_frames(k, 10)
	await _tier_up(k, 2)
	# 0.5 s looking ahead, 2 s looking 100 deg left, then ahead again.
	var r := _watch_toast_in_view(k, func(t: float) -> Vector2: return Vector2(-100.0, 0.0) if t >= 0.5 and t < 2.5 else Vector2.ZERO)
	metric("look_away_2s", r)
	between(float(r["held_s"]), 1.9, 2.1, "its clock held while it was out of view (%.2f s)" % r["held_s"])
	between(float(r["lasted_s"]), HUD.TOAST_TIME + 1.9, HUD.TOAST_TIME + 2.1, "so it lasted about 3.2 + 2 s (%.2f)" % r["lasted_s"])
	gt(float(r["seen_in_view_s"]), 2.4, "and was read in view for > 2.4 s all told (%.2f)" % r["seen_in_view_s"])
	check(not bool(r["moved"]), "it stayed where it appeared")
	# Looking down at prey 25 deg below the flight path when it comes (the
	# notices stay above the horizon, out of the hunting gaze: the plate is
	# 43 deg above that gaze): it waits there until the player looks up.
	await _tier_up(k, 3)
	var r3 := _watch_toast_in_view(k, func(t: float) -> Vector2: return Vector2(0.0, -25.0) if t < 2.0 else Vector2.ZERO)
	metric("look_down_2s", r3)
	between(float(r3["held_s"]), 1.6, 2.1, "looking down at prey it waited (%.2f s)" % r3["held_s"])
	gt(float(r3["seen_in_view_s"]), 2.5, "and was read in view once the player looked up (%.2f s)" % r3["seen_in_view_s"])
	# Never looking back: it still ends, after at most 3 s of waiting.
	await _tier_up(k, 4)
	var r2 := _watch_toast_in_view(k, func(t: float) -> Vector2: return Vector2(-100.0, 0.0) if t >= 0.3 else Vector2.ZERO)
	metric("look_away_for_good", r2)
	between(float(r2["lasted_s"]), HUD.TOAST_TIME + 2.9, HUD.TOAST_TIME + 3.1, "a celebration never looked at again ends after 3 s of waiting (%.2f s)" % r2["lasted_s"])
	k.teardown()
	await wait_frames(2)


func test_a_new_celebration_over_one_out_of_view_goes_where_the_player_looks() -> void:
	# Two tier-ups close together while the player turns away: the first
	# waits out of view (its clock held); the second must not take its place
	# out of view (a swap in place is only for one being read), it appears
	# where the player now looks.
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.ui.onboarding.skip()
	k.player.velocity = Vector3(0, 0, -8)
	k.gl.start_run()
	await k.settle(self, 4)
	_synthetic(k)
	_advance_frames(k, 10)
	await _tier_up(k, 2)
	_advance(k, 0.5)
	var first := k.ui.hud_panel.band_offset(HUD.BAND_NOTICE)
	k.set_head(Vector3(0, Kit.EYE, 0), 90.0)
	_advance(k, 0.6)
	check(k.ui.hud.toast_active() and k.ui.hud.toast_view_angle() > HUD.TOAST_VIEW_DEG, "the first is out of view, waiting")
	await _tier_up(k, 3)
	var second := k.ui.hud_panel.band_offset(HUD.BAND_NOTICE)
	var r := _watch_toast_in_view(k, func(_t: float) -> Vector2: return Vector2(-90.0, 0.0))
	metric("second_over_out_of_view_first", {"first_offset": str(first), "second_offset": str(second), "second": r})
	gt(second.x, first.x + 60.0, "the second went left, where the player looks (%s -> %s)" % [first, second])
	gt(float(r["seen_in_view_s"]), 2.5, "and is read in view (%.2f s)" % r["seen_in_view_s"])
	k.teardown()
	await wait_frames(2)


## World direction (from the eye) of notice-band texture pixel `px` where
## the band is now, also beyond the texture's edges (its analytic surface).
func _notice_px_dir(k: Kit, px: Vector2) -> Vector3:
	var p := k.ui.hud_panel
	var d := p.band_frame_direction(HUD.BAND_NOTICE, px)
	var level := p.band_placement(HUD.BAND_NOTICE, p.band_offset(HUD.BAND_NOTICE)) * d
	return p.global_transform.basis.orthonormalized() * (Basis(Vector3.RIGHT, deg_to_rad(-p.pitch_deg)) * level)


func test_the_fade_and_reading_margins_are_literal() -> void:
	# The notices make way for anything that matters within 1.5 deg of a
	# plate (a flight path grazing its edge is not hidden by its antialiased
	# rim), not 2.2 deg out; the head pointing within 6 deg of a plate is
	# reading it (the cue ring then may cross it without a fade), not 8 deg
	# off. Literal numbers: the round-6 engineering verifier set either
	# margin to 0 (mutants V40, V41) and the suite passed.
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.gl.start_run()
	await k.settle(self, 4)
	_synthetic(k)
	k.player.velocity = Vector3.ZERO
	_advance_frames(k, 5)
	check(k.ui.hud.lesson_visible(), "a lesson card is up")
	eq(k.ui.hud_panel.band_offset(HUD.BAND_NOTICE), Vector2.ZERO, "at home")
	var r: Rect2 = k.ui.hud.band_plates(HUD.BAND_NOTICE)[0].get_global_rect()
	var px_deg := UITheme.HUD_DISTANCE * UITheme.PX_PER_M * PI / 180.0
	var rows := {}
	for c: Array in [[1.0, true], [2.2, false]]:
		for edge: String in ["inner", "bottom"]:
			var px := Vector2(r.position.x - float(c[0]) * px_deg, r.get_center().y) if edge == "inner" \
				else Vector2(r.get_center().x, r.end.y + float(c[0]) * px_deg)
			var dirs: Array[Vector3] = [_notice_px_dir(k, px)]
			k.ui.hud.make_way(dirs, SDT)
			var faded: bool = k.ui.hud.see_through[HUD.BAND_NOTICE]
			rows["%s edge, %.1f deg out" % [edge, c[0]]] = faded
			eq(faded, c[1], "a bird %.1f deg beyond the card's %s edge: %s" % [c[0], edge, "make way" if c[1] else "no fade"])
			# (Clear long enough for the crossing to end: FADE_CLEAR_S.)
			var none: Array[Vector3] = []
			_hold_dirs(k, none, HUD.FADE_CLEAR_S + 2.0 * SDT)
	# Hysteresis (fix round 7): once faded for a bird 1.0 deg out, it stays
	# faded while the bird is within 1.5 + FADE_HYST_DEG (2.2 deg out), and
	# ends FADE_CLEAR_S after it is beyond that (2.7 deg out).
	var at := func(deg: float) -> Array[Vector3]:
		return [_notice_px_dir(k, Vector2(r.position.x - deg * px_deg, r.get_center().y))]
	_hold_dirs(k, at.call(1.0), SDT)
	check(k.ui.hud.see_through[HUD.BAND_NOTICE], "hysteresis: faded for a bird 1.0 deg out")
	_hold_dirs(k, at.call(2.2), 0.5)
	check(k.ui.hud.see_through[HUD.BAND_NOTICE], "it stays faded while the bird is 2.2 deg out (inside 1.5 + %.1f)" % HUD.FADE_HYST_DEG)
	# (Literal: the crossing lasts 0.12 s after the bird is clear.)
	_hold_dirs(k, at.call(2.7), 6.0 * SDT)
	check(k.ui.hud.see_through[HUD.BAND_NOTICE], "2.7 deg out for 0.083 s: the crossing goes on (it ends 0.12 s after)")
	_hold_dirs(k, at.call(2.7), 5.0 * SDT)
	check(not k.ui.hud.see_through[HUD.BAND_NOTICE], "and by 0.153 s it has ended")
	eq(k.ui.hud.crossings_lately(), 3, "one crossing each (the two literal ones and this one)")
	for c: Array in [[4.0, true], [8.0, false]]:
		var d := _notice_px_dir(k, Vector2(r.position.x - float(c[0]) * px_deg, r.get_center().y))
		var reading := k.ui.hud.looks_at_notices(d)
		rows["head %.0f deg off the card" % c[0]] = reading
		eq(reading, c[1], "the head %.0f deg off the card's edge %s reading it" % [c[0], "is" if c[1] else "is not"])
	metric("margins", rows)
	eq(k.ui.hud.move_count, 0, "single brushes never move the card")
	k.teardown()
	await wait_frames(2)


## Drive make_way with explicit directions for `seconds` (synthetic time),
## calling `watch(t)` after each frame.
func _hold_dirs(k: Kit, dirs: Array[Vector3], seconds: float, watch: Callable = Callable()) -> void:
	var t := 0.0
	while t < seconds - 1e-6:
		k.ui.hud.make_way(dirs, SDT)
		k.ui.hud.advance(SDT)
		t += SDT
		if watch.is_valid():
			watch.call(t)


func test_a_crossing_at_a_lesson_change_counts_once() -> void:
	# UIRoot also calls make_way with no time passing when a lesson starts
	# (to place a new card at once). A crossing that began in that very call
	# was counted twice (its timer had not run yet): two crossings at lesson
	# changes moved the card as if there had been four (found in round 6,
	# watching the real game's UI while recording it).
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.gl.start_run()
	await k.settle(self, 4)
	_synthetic(k)
	var hud := k.ui.hud
	var clear: Array[Vector3] = [_dir(0.0, 14.0)]
	var on_home: Array[Vector3] = [_dir(-30.0, 14.0)]
	_hold_dirs(k, clear, 1.0)
	for i in 2:
		hud.make_way(on_home, 0.0)
		_hold_dirs(k, on_home, 0.3)
		_hold_dirs(k, clear, 1.0)
	eq(hud.crossings_lately(), 2, "two crossings, each starting at a lesson change, count twice (not four times)")
	_hold_dirs(k, on_home, 0.3)
	_hold_dirs(k, clear, 1.5)
	eq(hud.crossings_lately(), 3, "a third counts once")
	eq(hud.move_count, 0, "and crossings, however many, never move the card (fix round 7: only what stays 1 s does)")
	k.teardown()
	await wait_frames(2)


## The round-7 verifier's case: the flight path sits on the card's fade
## margin for 0.4 s, jittering a few tenths of a degree frame to frame (a
## flapping bird's velocity does), then leaves. That is one crossing: one
## fade, no move (round 6 counted it two or three times, and three moved
## the card). Something jittering on the margin for longer than
## MOVE_AFTER_S stays, and moves the card once.
func test_a_jittery_crossing_of_the_margin_is_one_fade() -> void:
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.gl.start_run()
	await k.settle(self, 4)
	_synthetic(k)
	var hud := k.ui.hud
	check(hud.lesson_visible(), "a lesson card is up")
	var el := HUD.NOTICE_PITCH
	# The card's fade margin on its inner side, at the band's middle height
	# (+ yaw = left in _dir: scan rightwards from the centre line).
	var az_b := NAN
	for i in 400:
		if _notice_hits(k, _dir(-i * 0.05, el), HUD.FADE_MARGIN_DEG) > 0:
			az_b = -i * 0.05
			break
	check(is_finite(az_b), "found the card's fade margin (%.2f deg right)" % -az_b)
	var away: Array[Vector3] = [_dir(5.0, -10.0)]
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var rows := {}
	for amp: float in [0.0, 0.1, 0.3, 0.6]:
		_hold_dirs(k, away, ENTRY_CLEAR_S)
		var m0 := hud.move_count
		var fades := 0
		var was := false
		var n0 := hud.crossings_lately()
		for i in int(0.4 / SDT):
			# 1 deg into the margin and back out over 0.4 s, jitter on top.
			var base := az_b + 0.5 - 1.0 * sin(PI * i * SDT / 0.4)
			var d: Array[Vector3] = [_dir(base + rng.randf_range(-amp, amp), el + rng.randf_range(-amp, amp))]
			hud.make_way(d, SDT)
			hud.advance(SDT)
			var st: bool = hud.see_through[HUD.BAND_NOTICE]
			if st and not was:
				fades += 1
			was = st
		_hold_dirs(k, away, 3.0)
		rows["+-%.1f deg" % amp] = {"fades": fades, "crossings": hud.crossings_lately() - n0, "moves": hud.move_count - m0}
		eq(fades, 1, "+-%.1f deg of jitter: one fade" % amp)
		eq(hud.crossings_lately() - n0, 1, "+-%.1f deg of jitter: one crossing" % amp)
		eq(hud.move_count - m0, 0, "+-%.1f deg of jitter: no move" % amp)
	# Leaving the margin altogether for two frames (a cue's cut, a stroke's
	# swing) and coming back is still one crossing: a gap shorter than the
	# fade-out is no gap.
	var on_margin: Array[Vector3] = [_dir(az_b - 0.5, el)]
	var seen := {"n": 0, "was": false}
	var watch := func(_t: float) -> void:
		var st: bool = hud.see_through[HUD.BAND_NOTICE]
		if st and not seen["was"]:
			seen["n"] = int(seen["n"]) + 1
		seen["was"] = st
	_hold_dirs(k, away, ENTRY_CLEAR_S)
	var m2 := hud.move_count
	var n2 := hud.crossings_lately()
	_hold_dirs(k, on_margin, 0.3, watch)
	_hold_dirs(k, away, 2.0 * SDT, watch)
	_hold_dirs(k, on_margin, 0.3, watch)
	_hold_dirs(k, away, 1.0, watch)
	rows["0.3 s, out 2 frames, 0.3 s"] = {"fades": seen["n"], "crossings": hud.crossings_lately() - n2, "moves": hud.move_count - m2}
	eq([int(seen["n"]), hud.crossings_lately() - n2, hud.move_count - m2], [1, 1, 0], "out of the margin for 2 frames and back: one crossing, one fade, no move")
	# "Staying" counts only the time something is on the plates: 0.5 s, a
	# 0.1 s gap (inside the crossing), 0.45 s is 0.95 s: no move yet; 0.1 s
	# more is 1.05 s: the move.
	_hold_dirs(k, away, ENTRY_CLEAR_S)
	var m3 := hud.move_count
	_hold_dirs(k, on_margin, 0.5)
	_hold_dirs(k, away, 0.1)
	_hold_dirs(k, on_margin, 0.45)
	eq(hud.move_count - m3, 0, "0.5 + 0.45 s on the plates (a 0.1 s gap between): not yet staying")
	_hold_dirs(k, on_margin, 0.1)
	eq(hud.move_count - m3, 1, "1.05 s on them: it stays, one move")
	# Back home for the last case.
	_hold_dirs(k, away, HUD.MOVE_GAP_S + HUD.MOVE_S + 0.5)
	k.ui.hud_panel.set_band_offset(HUD.BAND_NOTICE, Vector2.ZERO)
	hud.call(&"_rest_at", Vector2.ZERO)
	_hold_dirs(k, away, ENTRY_CLEAR_S)
	# Staying on the margin (jittering +-0.6 deg) for 1.6 s: it stays.
	var m1 := hud.move_count
	var fades2 := 0
	var was2 := false
	for i in int(1.6 / SDT):
		var d: Array[Vector3] = [_dir(az_b - 0.5 + rng.randf_range(-0.6, 0.6), el + rng.randf_range(-0.6, 0.6))]
		hud.make_way(d, SDT)
		hud.advance(SDT)
		var st: bool = hud.see_through[HUD.BAND_NOTICE]
		if st and not was2:
			fades2 += 1
		was2 = st
	rows["staying 1.6 s, +-0.6 deg"] = {"fades": fades2, "moves": hud.move_count - m1}
	metric("jittery_margin", rows)
	eq(fades2, 1, "jittering on the margin for 1.6 s: one fade")
	eq(hud.move_count - m1, 1, "and, as it stays, one move")
	k.teardown()
	await wait_frames(2)


func test_notices_fade_for_a_crossing_and_move_only_when_something_stays() -> void:
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.gl.start_run()
	await k.settle(self, 4)
	_synthetic(k)
	var hud := k.ui.hud
	var panel := k.ui.hud_panel
	check(hud.lesson_visible(), "a lesson card is up")
	var clear: Array[Vector3] = [_dir(0.0, 14.0)]
	var on_home: Array[Vector3] = [_dir(-30.0, 14.0)]
	var on_mirror: Array[Vector3] = [_dir(30.0, 14.0)]
	_hold_dirs(k, clear, 0.5)
	near(panel.band_alpha(HUD.BAND_NOTICE), 1.0, 1e-4, "clear: fully shown")
	# 1. Something crossing the card (a bird flying by, a glance of the
	# path): the card turns see-through at once and does not move.
	var crossings := {}
	for d: float in [0.2, 0.5, 0.95]:
		var st := {"to_see_through_s": -1.0, "hidden_s": 0.0}
		_hold_dirs(k, on_home, d, func(t: float) -> void:
			if st["to_see_through_s"] < 0.0 and panel.band_alpha(HUD.BAND_NOTICE) < 0.2:
				st["to_see_through_s"] = t
			if panel.band_alpha(HUD.BAND_NOTICE) >= HUD.READABLE_ALPHA and _notice_hits(k, on_home[0], 0.0) > 0:
				st["hidden_s"] = float(st["hidden_s"]) + SDT)
		var back := {"s": -1.0}
		_hold_dirs(k, clear, 5.0, func(t: float) -> void:
			if back["s"] < 0.0 and panel.band_alpha(HUD.BAND_NOTICE) > 0.99:
				back["s"] = t)
		crossings["%.1f s" % d] = {"to_see_through_s": snappedf(st["to_see_through_s"], 0.001), "hidden_s": snappedf(st["hidden_s"], 0.001), "back_s": snappedf(back["s"], 0.001)}
		between(float(st["to_see_through_s"]), 0.0, 0.13, "a %.1f s crossing: below 20 %% within 0.13 s (%.3f)" % [d, st["to_see_through_s"]])
		lt(float(st["hidden_s"]), 0.08, "it hides what crosses for < 0.08 s (%.3f)" % st["hidden_s"])
		# (Fix round 7: the crossing ends FADE_CLEAR_S after it has gone - a
		# gap shorter than the fade-out is no gap - and the fade-in is that
		# much quicker: back as soon as before.)
		between(float(back["s"]), 0.2, 0.5, "and is back gently, within 0.5 s (%.3f)" % back["s"])
		eq(hud.move_count, 0, "a %.1f s crossing moves nothing" % d)
		eq(panel.band_offset(HUD.BAND_NOTICE), Vector2.ZERO, "still at home")
	metric("crossings", crossings)
	# Crossings that keep coming back (0.3 s in every 2 s here, as a path
	# drifted into the card's column sweeps through with each flap cycle):
	# a fade each time, never a move (fix round 7, the lead's rule: move only
	# what stays; round 4 moved the card at the third crossing in 8 s, and
	# live that moved it for one jittery crossing).
	_hold_dirs(k, clear, ENTRY_CLEAR_S)
	var rep := {"fades": 0, "hidden_s": 0.0, "was": false}
	for c in 10:
		_hold_dirs(k, on_home, 0.3, func(_t: float) -> void:
			var st: bool = hud.see_through[HUD.BAND_NOTICE]
			if st and not rep["was"]:
				rep["fades"] = int(rep["fades"]) + 1
			rep["was"] = st
			if panel.band_alpha(HUD.BAND_NOTICE) >= HUD.READABLE_ALPHA and _notice_hits(k, on_home[0], 0.0) > 0:
				rep["hidden_s"] = float(rep["hidden_s"]) + SDT)
		_hold_dirs(k, clear, 1.7, func(_t: float) -> void: rep["was"] = hud.see_through[HUD.BAND_NOTICE])
	rep.erase("was")
	metric("repeated_crossings", rep)
	eq(hud.move_count, 0, "10 crossings of 0.3 s every 2 s: no move")
	eq(int(rep["fades"]), 10, "one fade each")
	lt(float(rep["hidden_s"]), 0.08 * 10, "each hides what crosses for < 0.08 s (%.3f s in all)" % rep["hidden_s"])
	_hold_dirs(k, clear, 6.0)
	hud.move_count = 0
	# Back home for the next checks (a new set of notices appears there).
	hud.hide_lesson()
	_hold_dirs(k, clear, 0.1)
	k.ui.onboarding.reset()
	k.ui.onboarding.start()
	await k.settle(self, 2)
	_hold_dirs(k, clear, 5.0)
	eq(panel.band_offset(HUD.BAND_NOTICE), Vector2.ZERO, "a new lesson card appears at home")
	# 2. Something that stays: after 1 s the card moves, once, slowly, to
	# the other side of the flight path, and is read there again.
	hud.peak_move_speed = 0.0
	var mv := {"start": -1.0, "end": -1.0, "min_y": 0.0, "max_y": 0.0, "read_again": -1.0, "flipped_opaque": 0, "flipped_at_off": INF}
	_hold_dirs(k, on_home, 3.0, func(t: float) -> void:
		var off := panel.band_offset(HUD.BAND_NOTICE)
		mv["min_y"] = minf(mv["min_y"], off.y)
		mv["max_y"] = maxf(mv["max_y"], off.y)
		# The text must not jump to the other end of the card until the band
		# has crossed the centre line (see-through by then).
		if hud.move_count > 0 and hud.notice_side < 0:
			if not is_finite(float(mv["flipped_at_off"])):
				mv["flipped_at_off"] = off.x
			if panel.band_alpha(HUD.BAND_NOTICE) >= HUD.READABLE_ALPHA and mv["end"] < 0.0:
				mv["flipped_opaque"] = int(mv["flipped_opaque"]) + 1
		if mv["start"] < 0.0 and hud.move_count == 1:
			mv["start"] = t
		if mv["end"] < 0.0 and off == HUD.NOTICE_MIRROR:
			mv["end"] = t
		if mv["end"] >= 0.0 and mv["read_again"] < 0.0 and panel.band_alpha(HUD.BAND_NOTICE) > 0.99:
			mv["read_again"] = t)
	mv["peak_deg_s"] = snappedf(hud.peak_move_speed, 0.1)
	metric("staying", mv)
	eq(hud.move_count, 1, "one move")
	eq(int(mv["flipped_opaque"]), 0, "the text never changed sides while the card was readable")
	gt(float(mv["flipped_at_off"]), -HUD.NOTICE_YAW - 1.0, "it changed sides as the band crossed the centre line (offset %.1f deg)" % mv["flipped_at_off"])
	between(float(mv["start"]), 1.0, 1.1, "it starts once the thing has stayed 1 s (%.3f)" % mv["start"])
	between(float(mv["end"]) - float(mv["start"]), 0.8, 1.2, "and eases over about 0.9 s (%.3f)" % (float(mv["end"]) - float(mv["start"])))
	lt(hud.peak_move_speed, 110.5, "at no more than 110 deg/s (%.1f)" % hud.peak_move_speed)
	eq([mv["min_y"], mv["max_y"]], [0.0, 0.0], "sideways only: never lower (or higher) than home")
	eq(panel.band_offset(HUD.BAND_NOTICE), HUD.NOTICE_MIRROR, "now left of the centre line")
	eq(_notice_hits(k, on_home[0], 3.0), 0, "3 deg of sky round what stayed")
	between(float(mv["read_again"]) - float(mv["end"]), 0.2, 0.5, "readable again 0.2-0.5 s after arriving")
	await k.settle(self, 2)
	var title := _find_label(hud, hud.lesson_title())
	var art := hud.find_children("*", "GestureCard", true, false)[0] as Control
	gt(title.get_global_rect().position.x, art.get_global_rect().position.x, "left of the path the text is on the inner (right) side")
	# 3. Something stays on the new place at once: no second move before 4 s
	# since the first began (literal), then home again (clear by then).
	var second := {"t": -1.0}
	var t_first := float(mv["start"])
	var elapsed_before := 3.0 - t_first
	_hold_dirs(k, on_mirror, 6.0, func(t: float) -> void:
		if second["t"] < 0.0 and hud.move_count == 2:
			second["t"] = t + elapsed_before)
	metric("second_move_after_first_s", snappedf(second["t"], 0.01))
	gt(float(second["t"]), 3.99, "at most one move every 4 s (second after %.2f s)" % second["t"])
	lt(float(second["t"]), 4.3, "and it does go once allowed")
	eq(panel.band_offset(HUD.BAND_NOTICE), Vector2.ZERO, "home again")
	# 4. Both sides taken: no move at all, the card stays see-through.
	var both: Array[Vector3] = [on_home[0], on_mirror[0]]
	var n0 := hud.move_count
	_hold_dirs(k, both, 6.0)
	eq(hud.move_count, n0, "nowhere clear: it does not move")
	check(hud.dodge_stuck, "stuck")
	lt(panel.band_alpha(HUD.BAND_NOTICE), 0.2, "and stays see-through (literal 20 %%)")
	_hold_dirs(k, clear, 1.0)
	near(panel.band_alpha(HUD.BAND_NOTICE), 1.0, 1e-4, "clear again: fully shown")
	# 5. A harmless hawk (threat level below 0.1) behind the card is not worth
	# fading it for; a real one (0.1 and up) is.
	var hawk := Bird.new()
	hawk.mass = 1.6
	add_child(hawk)
	hawk.global_position = k.cam.global_position + _dir(-30.0 if panel.band_offset(HUD.BAND_NOTICE) == Vector2.ZERO else 30.0, 14.0) * 25.0
	k.player.velocity = Vector3(0, 0, -9)
	Events.threat_changed.emit(0.09, hawk)
	for i in 30:
		_frame(k)
	near(panel.band_alpha(HUD.BAND_NOTICE), 1.0, 1e-4, "a harmless hawk (0.09) behind the card: it stays")
	Events.threat_changed.emit(0.1, hawk)
	for i in 10:
		_frame(k)
	lt(panel.band_alpha(HUD.BAND_NOTICE), 0.2, "a real one (0.1): see-through within 0.14 s")
	Events.threat_changed.emit(0.0, null)
	hawk.queue_free()
	k.teardown()
	await wait_frames(2)


func test_a_new_notice_appears_where_it_is_clear() -> void:
	# Placing a notice that nobody has seen yet costs no motion: with prey
	# behind the home card, a celebration appears left of the flight path,
	# fully shown, in the very frame of the event (before anything draws).
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 4)
	_synthetic(k)
	k.player.velocity = Vector3(0, 0, -9)
	var prey := Bird.new()
	prey.mass = 0.012
	add_child(prey)
	prey.global_position = k.cam.global_position + _dir(-27.0, 15.0) * 14.0
	Events.target_changed.emit(prey)
	for i in 40:
		_frame(k)
	check(k.ui.indicators.cue_mesh(&"target").visible, "the prey's cue is up too (it points at the card)")
	k.player.mass = float(SizeRules.SPECIES[3]["mass"]) * 1.02
	Events.player_tier_changed.emit(2, 3)
	eq(k.ui.hud_panel.band_offset(HUD.BAND_NOTICE), HUD.NOTICE_MIRROR, "placed left of the centre line at once")
	near(k.ui.hud_panel.band_alpha(HUD.BAND_NOTICE), 1.0, 1e-4, "fully shown")
	eq(k.ui.hud.move_count, 0, "that was no move")
	k.ui.hud.set_process(false)
	await wait_frames(1)
	var hid := 0
	for i in 200:
		_frame(k)
		if _hidden(k, prey.global_position - k.cam.global_position):
			hid += 1
	eq(hid, 0, "the prey is never behind the celebration")
	eq(k.ui.hud.move_count, 0, "and nothing moves")
	# Left of the path the plate hugs the band's other (inner) edge. The
	# notices are judged on where it really is in the very frame it appears
	# (before its container has laid it out again for that side): the rect
	# they use then is the one the layout gives it a frame later.
	for i in 300:
		_frame(k)
	check(not k.ui.hud.toast_active(), "the first celebration is over")
	k.player.mass = float(SizeRules.SPECIES[4]["mass"]) * 1.02
	Events.player_tier_changed.emit(3, 4)
	eq(k.ui.hud_panel.band_offset(HUD.BAND_NOTICE), HUD.NOTICE_MIRROR, "the second one left of the path too")
	var judged: Rect2 = k.ui.hud.notice_rects()[0]
	await wait_frames(2)
	var laid_out := k.ui.hud.band_plates(HUD.BAND_NOTICE)[0].get_global_rect()
	metric("placement_frame_rect", {"judged": str(judged), "laid_out": str(laid_out)})
	lt(absf(judged.get_center().x - laid_out.get_center().x), 2.0, "judged where it is laid out (%s vs %s)" % [judged, laid_out])
	gt(judged.get_center().x, float(UITheme.HUD_SIZE.x) * 0.5, "left of the path the plate is on the texture's right (inner) half")
	Events.target_changed.emit(null)
	prey.queue_free()
	k.teardown()
	await wait_frames(2)


func test_the_strip_fades_for_what_it_covers() -> void:
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 4)
	_synthetic(k)
	var hud := k.ui.hud
	var panel := k.ui.hud_panel
	var head := k.cam.global_transform
	k.player.velocity = Vector3(0, 0, -9)
	for i in 20:
		_frame(k)
	near(panel.band_alpha(HUD.BAND_STATUS), 1.0, 1e-4, "level flight: the strip fully shown")
	# A dive puts the flight path behind the strip: it turns see-through (it
	# is always there; a fade uses nothing up).
	k.player.velocity = Vector3(0, -8.0, -9.0)
	for i in 18:
		_frame(k)
	check(hud.see_through[HUD.BAND_STATUS], "diving: flight path behind the strip")
	# Literal: 20 % opacity at most, whatever the constant says.
	lt(panel.band_alpha(HUD.BAND_STATUS), 0.2, "the strip fades below 20 %% within 0.25 s (%.2f)" % panel.band_alpha(HUD.BAND_STATUS))
	k.player.velocity = Vector3(0, 0, -9)
	for i in 3:
		_frame(k)
	lt(panel.band_alpha(HUD.BAND_STATUS), 0.5, "fading back is gentle, not a pop")
	for i in 72:
		_frame(k)
	near(panel.band_alpha(HUD.BAND_STATUS), 1.0, 1e-4, "strip back")
	# Prey behind the strip in level flight: the strip makes way.
	var prey := Bird.new()
	prey.mass = 0.01
	add_child(prey)
	prey.global_position = head.origin + head.basis * (Basis(Vector3.RIGHT, deg_to_rad(-40.0)) * Vector3(0, 0, -12))
	Events.target_changed.emit(prey)
	for i in 18:
		_frame(k)
	lt(panel.band_alpha(HUD.BAND_STATUS), 0.2, "prey behind the strip: it fades below 20 %%")
	# ... and just outside its edge: the strip keeps a 2.5 deg margin round
	# itself (prey 1.5 deg below its bottom edge still counts; 5 deg does not).
	var strip := hud.band_plates(HUD.BAND_STATUS)[0].get_global_rect()
	var edge := panel.pixel_to_world(Vector2(strip.get_center().x, strip.end.y)) - head.origin
	var edge_el := rad_to_deg(asin(edge.normalized().y))
	var edge_yaw := rad_to_deg(atan2(-edge.x, -edge.z))
	prey.global_position = head.origin + _dir(edge_yaw, edge_el - 1.5) * 12.0
	for i in 18:
		_frame(k)
	lt(panel.band_alpha(HUD.BAND_STATUS), 0.2, "prey 1.5 deg below the strip's edge: it makes way")
	prey.global_position = head.origin + _dir(edge_yaw, edge_el - 5.0) * 12.0
	for i in 44:
		_frame(k)
	near(panel.band_alpha(HUD.BAND_STATUS), 1.0, 1e-4, "prey 5 deg below it: the strip stays")
	Events.target_changed.emit(null)
	prey.queue_free()
	k.teardown()
	await wait_frames(2)


## Watch one celebration to its end in synthetic time: readable fraction
## (opacity >= 0.6), frames in which something in `protect` is behind a
## readable notice, and the lowest the notices went.
func _watch_celebration(k: Kit, protect: Array[Vector3]) -> Dictionary:
	var n := 0
	var readable := 0
	var covered := 0
	var low := 90.0
	var t := 0.0
	while k.ui.hud.toast_active() and t < HUD.TOAST_TIME + 3.5:
		_frame(k)
		t += SDT
		n += 1
		if _notice_opacity(k) >= HUD.READABLE_ALPHA:
			readable += 1
		for d in protect:
			if _hidden(k, d):
				covered += 1
				break
		if k.ui.hud.toast_active():
			low = minf(low, _notice_lowest_deg(k))
	return {"readable_frac": snappedf(readable / float(maxi(n, 1)), 0.01), "covered_frames": covered,
		"lowest_deg": snappedf(low, 0.01), "life_s": snappedf(t, 0.01), "offset": str(k.ui.hud_panel.band_offset(HUD.BAND_NOTICE))}


func test_celebrations_readable_and_clear_in_climbs_and_chases() -> void:
	# Round 3 measured the celebrations in climbs and with prey above; they
	# must stay as readable as in level flight and never hide the flight
	# path or the target. Beside the flight path, climbs and dives do not
	# touch them; prey right where the card would be sends it left.
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 4)
	_synthetic(k)
	var eye := k.cam.global_position
	var cruise := SizeRules.cruise_speed(0.055)
	var cases := [
		["level", 0.0, Vector3.ZERO],
		["climb 8", 8.0, Vector3.ZERO],
		["climb 14", 14.0, Vector3.ZERO],
		["climb 24", 24.0, Vector3.ZERO],
		["zoom 50", 50.0, Vector3.ZERO],
		["dive 30", -30.0, Vector3.ZERO],
		["level, prey 12 deg up ahead", 0.0, Vector3(1.0, 3.2, -15.0)],
		["climb 10, prey 20 deg up ahead-left", 10.0, Vector3(-4.0, 5.3, -14.0)],
		["level, prey 15 deg up, 27 deg right (on the home card)", 0.0, Vector3(6.5, 3.8, -13.0)],
	]
	var results := {}
	var bad: Array = []
	# The lowest the notice band reaches at home (its bottom edge across its
	# whole width; a sideways placement keeps the same elevations): no plate
	# may ever sit lower than that.
	var home_low := _notice_band_lowest_deg(k)
	var tier := 2
	for c: Array in cases:
		var a := deg_to_rad(float(c[1]))
		k.player.velocity = Vector3(0.0, sin(a), -cos(a)) * cruise
		var protect: Array[Vector3] = [k.player.velocity.normalized()]
		var prey: Bird = null
		if c[2] != Vector3.ZERO:
			prey = Bird.new()
			prey.mass = 0.012
			add_child(prey)
			prey.global_position = eye + (c[2] as Vector3)
			Events.target_changed.emit(prey)
			protect.append((c[2] as Vector3).normalized())
		for i in 36:
			_frame(k)
		await _tier_up(k, tier)
		var r := await _watch_celebration(k, protect)
		results[c[0]] = r
		# Level flight reads ~0.84 (pop-in and fade-out take the rest).
		if float(r["readable_frac"]) < 0.75:
			bad.append("%s: readable %d%%" % [c[0], int(float(r["readable_frac"]) * 100.0)])
		if int(r["covered_frames"]) > 0:
			bad.append("%s: the path or target behind the readable toast in %d frames" % [c[0], r["covered_frames"]])
		if float(r["lowest_deg"]) < home_low - 0.01:
			bad.append("%s: notices dipped to %.2f deg (home %.2f)" % [c[0], r["lowest_deg"], home_low])
		tier = 2 if tier >= 6 else tier + 1
		Events.target_changed.emit(null)
		if prey:
			prey.queue_free()
		for i in 10:
			_frame(k)
	eq(k.ui.hud.move_count, 0, "not one celebration had to move")
	# The apex "2 of 5!" celebration with the next big bird ahead and above.
	k.player.mass = 3.1
	k.player.velocity = Vector3(0, 0, -1) * SizeRules.cruise_speed(3.1)
	var gull := Bird.new()
	gull.mass = 0.85
	add_child(gull)
	gull.global_position = eye + Vector3(-2.0, 6.0, -30.0)
	Events.target_changed.emit(gull)
	for i in 30:
		_frame(k)
	k.gl.stats["apex"]["reached"] = true
	k.gl.fake_apex_catch()
	k.ui.hud.set_process(false)
	await wait_frames(1)
	var apex_protect: Array[Vector3] = [Vector3(-2.0, 6.0, -30.0).normalized(), Vector3(0, 0, -1)]
	var ra := await _watch_celebration(k, apex_protect)
	results["apex toast, gull 11 deg up ahead"] = ra
	if float(ra["readable_frac"]) < 0.75 or int(ra["covered_frames"]) > 0:
		bad.append("apex toast: %s" % str(ra))
	metric("celebrations", results)
	eq(bad, [], "every celebration readable >= 75 %% of its time, never over the flight path or target, never lower than home")
	Events.target_changed.emit(null)
	gull.queue_free()
	# The lesson card while doing "Flap to climb": steady climbs.
	k.ui.onboarding.reset()
	k.player.mass = 0.03
	k.ui.onboarding.start()
	await k.settle(self, 3)
	check(k.ui.hud.lesson_visible(), "a lesson card is up")
	var lesson := {}
	for deg: float in [6.0, 12.0, 18.0, 40.0]:
		var a2 := deg_to_rad(deg)
		k.player.velocity = Vector3(0.0, sin(a2), -cos(a2)) * SizeRules.cruise_speed(0.03)
		var n := 0
		var shown := 0
		var cov := 0
		for i in 108:
			_frame(k)
			n += 1
			if k.ui.hud_panel.band_alpha(HUD.BAND_NOTICE) >= 0.95:
				shown += 1
			if _notice_hits(k, k.player.velocity, 2.0) > 0:
				cov += 1
		lesson["climb %d" % int(deg)] = {"shown_frac": snappedf(shown / float(n), 0.01), "path_within_2deg_frames": cov}
		eq(shown, n, "the lesson card stays fully shown in a %d deg climb" % int(deg))
		eq(cov, 0, "and keeps 2 deg clear of the flight path")
	metric("lesson_card_in_climbs", lesson)
	k.teardown()
	await wait_frames(2)


func test_when_nothing_clears_the_notices_fade_and_the_celebration_waits() -> void:
	# The last resort: things that matter on both sides of the flight path.
	# The notices fade, and a celebration's clock holds while it cannot be
	# read, so it is not used up unseen, but for at most 3 s (literal) so it
	# cannot hang on.
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 4)
	_synthetic(k)
	var hud := k.ui.hud
	var panel := k.ui.hud_panel
	var crowd: Array[Vector3] = []
	for yaw in range(-55, 56, 5):
		for el in range(4, 26, 3):
			crowd.append(_dir(float(yaw), float(el)))
	var none: Array[Vector3] = []
	await _tier_up(k, 2)
	_hold_dirs(k, crowd, 2.0)
	check(hud.dodge_stuck, "no placement clears the crowd")
	lt(panel.band_alpha(HUD.BAND_NOTICE), 0.2, "so the notices fade (below 20 %%)")
	check(hud.toast_active(), "the celebration is still waiting after 2 s")
	gt(hud.toast_held(), 1.5, "its clock held while it could not be read (%.2f s)" % hud.toast_held())
	# The sky clears: the band comes back and the celebration plays out.
	var readable := {"s": 0.0}
	_hold_dirs(k, none, 6.0, func(_t: float) -> void:
		if _notice_opacity(k) >= HUD.READABLE_ALPHA:
			readable["s"] = float(readable["s"]) + SDT)
	check(not hud.dodge_stuck, "cleared")
	check(not hud.toast_active(), "and it ended")
	gt(float(readable["s"]), 2.0, "after being read for over 2 s (%.2f s)" % readable["s"])
	# In a sky that never clears it still ends: held at most 3 s.
	await _tier_up(k, 3)
	var life := {"s": 0.0}
	_hold_dirs(k, crowd, 9.0, func(t: float) -> void:
		if hud.toast_active():
			life["s"] = t)
	metric("stuck_celebration_life_s", snappedf(life["s"], 0.01))
	between(float(life["s"]), HUD.TOAST_TIME + 2.5, 3.2 + 3.0 + 0.3, "a celebration that is never readable ends after at most 3 s of waiting (%.2f s)" % life["s"])
	k.teardown()
	await wait_frames(2)


func test_back_to_back_celebrations_do_not_blink() -> void:
	# Two apex catches 0.6 s apart (an eagle taking two birds from a flock):
	# the second celebration replaces the first in place. Round 3 restarted
	# its pop-in from nothing: the notice fell to 3 % and popped back.
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.ui.onboarding.skip()
	k.player.mass = 3.1
	k.gl.start_run()
	await k.settle(self, 4)
	_synthetic(k)
	k.player.velocity = Vector3(0, 0, -1) * SizeRules.cruise_speed(3.1)
	k.gl.stats["apex"]["reached"] = true
	k.gl.fake_apex_catch()
	k.ui.hud.set_process(false)
	await wait_frames(1)
	var first := k.ui.hud.toast_text()
	var lo := {"after_full": 1.0, "full": false}
	for i in int(0.6 / SDT):
		_frame(k)
		if _notice_opacity(k) >= 0.99:
			lo["full"] = true
	k.gl.fake_apex_catch()
	k.ui.hud.set_process(false)
	var second := k.ui.hud.toast_text()
	check(second != first, "a new celebration (%s -> %s)" % [first, second])
	lo["after_full"] = minf(lo["after_full"], _notice_opacity(k))
	await wait_frames(1)
	var n := 0
	var r := 0
	while k.ui.hud.toast_active() and n < 400:
		_frame(k)
		n += 1
		if n < int(0.6 / SDT):
			lo["after_full"] = minf(lo["after_full"], _notice_opacity(k))
		if _notice_opacity(k) >= HUD.READABLE_ALPHA:
			r += 1
	metric("back_to_back", {"min_opacity_after_swap": snappedf(lo["after_full"], 0.001), "second_readable_frac": snappedf(r / float(maxi(n, 1)), 0.01)})
	check(lo["full"], "the first was fully shown")
	gt(float(lo["after_full"]), 0.95, "the swap keeps it shown (min %.3f; round 3: 0.03)" % lo["after_full"])
	gt(r / float(maxi(n, 1)), 0.8, "the second is read for its whole time")
	# A tier-up followed by an apex toast mid-fade-out: it comes back up
	# from where it was, never from nothing.
	k.player.mass = 1.3
	await _tier_up(k, 7)
	for i in int(2.9 / SDT):
		_frame(k)
	var fading := _notice_opacity(k)
	k.player.mass = 3.1
	k.gl.fake_apex_catch()
	k.ui.hud.set_process(false)
	var m := _notice_opacity(k)
	for i in 20:
		_frame(k)
		m = minf(m, _notice_opacity(k))
	gt(m, fading - 0.01, "an apex toast during a fade-out rises from %.2f, not 0 (min %.2f)" % [fading, m])
	k.teardown()
	await wait_frames(2)


# --- prey and threat cues stay apart --------------------------------------------

## Angle (deg) between the two cue meshes as the eye sees them; -1 unless
## both are drawn.
func _cue_sep(k: Kit) -> float:
	var t := k.ui.indicators.cue_mesh(&"target")
	var h := k.ui.indicators.cue_mesh(&"threat")
	if not (t.visible and h.visible):
		return -1.0
	var eye := k.cam.global_position
	return rad_to_deg((t.global_position - eye).angle_to(h.global_position - eye))


## Ring angle and eccentricity (deg) of a cue mesh in the camera's view.
func _cue_polar(k: Kit, which: StringName) -> Vector2:
	var l := k.cam.global_transform.affine_inverse() * k.ui.indicators.cue_mesh(which).global_position
	return Vector2(rad_to_deg(atan2(l.y, l.x)), rad_to_deg(acos(-l.z / l.length())))


func test_prey_and_threat_cues_never_draw_on_top_of_each_other() -> void:
	# The commonest chase: prey off to one side, a hawk closing from behind
	# on that side. Its turn cue then points the same way as the prey's; on
	# one ring they drew on top of each other (0.0-0.9 deg apart, round 3).
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 4)
	_synthetic(k)
	var head := k.cam.global_transform
	var cases := [
		["prey 90 left, hawk behind-left", Vector3(-8, 0, 0), Vector3(-2, 0.5, 9)],
		["prey 60 left, hawk behind-left", Vector3(-7, 0, -4), Vector3(-3, 1, 8)],
		["prey 90 right, hawk behind-right", Vector3(8, 0, 0), Vector3(2, 0, 9)],
		["prey 45 right and up, hawk right", Vector3(6, 3, -6), Vector3(9, 3, 1)],
		["prey left and below, hawk dead astern", Vector3(-6, -3, -2), Vector3(0.4, 0.5, 10)],
		["prey up, hawk above-behind", Vector3(0.5, 8, -3), Vector3(0.3, 12, 4)],
		["prey down-right, hawk below-behind-right", Vector3(4, -6, -3), Vector3(3, -5, 6)],
		["control: prey right, hawk behind-left", Vector3(8, 0, 0), Vector3(-2, 0.5, 9)],
	]
	var seps := {}
	var bad: Array = []
	for c: Array in cases:
		var prey := Bird.new()
		prey.mass = 0.01
		add_child(prey)
		prey.global_position = head * (c[1] as Vector3)
		var hawk := Bird.new()
		hawk.mass = 2.0
		add_child(hawk)
		hawk.global_position = head * (c[2] as Vector3)
		Events.target_changed.emit(prey)
		Events.threat_changed.emit(0.9, hawk)
		var min_sep := 999.0
		var worst_dir := 0.0
		var max_ecc := 0.0
		var both := 0
		for _i in int(0.6 / SDT):
			_frame(k)
			var s := _cue_sep(k)
			if s < 0.0:
				continue
			both += 1
			min_sep = minf(min_sep, s)
			# Each still points exactly its own way along its own ring.
			for w: StringName in [&"target", &"threat"]:
				var f := k.ui.indicators.target_filter if w == &"target" else k.ui.indicators.threat_filter
				worst_dir = maxf(worst_dir, absf(wrapf(_cue_polar(k, w).x - rad_to_deg(f.angle), -180.0, 180.0)))
			max_ecc = maxf(max_ecc, _cue_polar(k, &"threat").y)
		seps[c[0]] = {"min_sep_deg": snappedf(min_sep, 0.1), "frames_both": both, "threat_ecc_max": snappedf(max_ecc, 0.1)}
		if both < 20:
			bad.append("%s: both cues drawn in only %d frames" % [c[0], both])
		if min_sep < 5.0:
			bad.append("%s: %.1f deg apart" % [c[0], min_sep])
		if worst_dir > 0.5:
			bad.append("%s: a cue drawn %.1f deg off its own direction" % [c[0], worst_dir])
		if max_ecc > 33.5:
			bad.append("%s: threat cue %.1f deg out" % [c[0], max_ecc])
		Events.target_changed.emit(null)
		Events.threat_changed.emit(0.0, null)
		prey.queue_free()
		hawk.queue_free()
		_advance_frames(k, 25)
	metric("cue_separation", seps)
	eq(bad, [], "prey and threat cues >= 5 deg apart, each pointing its own way, threat within 33.5 deg")
	# The pure rule: out by the full step when both point the same way,
	# nothing past the span, smooth and symmetric in between.
	near(rad_to_deg(HudIndicators.separation(1.0, 1.0)), 9.0, 1e-4, "same direction: threat 9 deg further out")
	near(HudIndicators.separation(0.2, 0.2 + HudIndicators.SEPARATE_SPAN), 0.0, 1e-6, "none at the span")
	near(HudIndicators.separation(3.1, -3.1), HudIndicators.separation(0.0, TAU - 6.2), 1e-6, "wraps round PI")
	var prev := HudIndicators.separation(0.0, 0.0)
	for i in range(1, 40):
		var v := HudIndicators.separation(0.0, deg_to_rad(i * 0.6))
		check(v <= prev + 1e-9, "monotonic with the angle between them")
		prev = v
	# The threat already showing, the prey cue appears right beside it: the
	# two are apart by the time the prey cue is visible enough to matter.
	var hawk2 := Bird.new()
	hawk2.mass = 2.0
	add_child(hawk2)
	hawk2.global_position = head * Vector3(-2, 0.5, 9)
	Events.threat_changed.emit(0.9, hawk2)
	_advance(k, 0.6)
	var prey2 := Bird.new()
	prey2.mass = 0.01
	add_child(prey2)
	prey2.global_position = head * Vector3(-8, 0, 0)
	Events.target_changed.emit(prey2)
	var late_min := 999.0
	var counted := 0
	for _i in int(0.8 / SDT):
		_frame(k)
		var s2 := _cue_sep(k)
		if s2 >= 0.0 and k.ui.indicators.target_filter.alpha >= 0.2:
			counted += 1
			late_min = minf(late_min, s2)
	metric("prey_cue_appearing_beside_threat", {"min_sep_deg": snappedf(late_min, 0.1), "frames": counted})
	gt(float(counted), 20.0, "the prey cue did appear beside the threat cue (%d frames)" % counted)
	gt(late_min, 5.0, "a prey cue appearing beside a threat cue is apart once visible (%.1f deg)" % late_min)
	Events.target_changed.emit(null)
	Events.threat_changed.emit(0.0, null)
	prey2.queue_free()
	hawk2.queue_free()
	k.teardown()
	await wait_frames(2)


func test_cues_keep_their_angle_and_size_at_every_world_scale() -> void:
	# A wren and an eagle see the same cue: 24 deg out, the same visual size.
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 3)
	_synthetic(k)
	var bird := Bird.new()
	bird.mass = 0.01
	add_child(bird)
	var ref := -1.0
	var rows := {}
	for ws: float in [1.0, 0.15, 1.3]:
		k.set_world_scale(ws)
		await k.settle(self, 2)
		var head := k.cam.global_transform
		bird.global_position = head.origin + head.basis * Vector3(-4.0 * ws, 0, 0)
		Events.target_changed.emit(null)
		_advance_frames(k, 2)
		Events.target_changed.emit(bird)
		_advance(k, 0.6)
		var cue := k.ui.indicators.cue_mesh(&"target")
		if not check(cue.visible, "cue drawn at ws=%.2f" % ws):
			continue
		var local := head.affine_inverse() * cue.global_position
		var ecc := rad_to_deg(acos(-local.z / local.length()))
		var size_deg := rad_to_deg(2.0 * atan(cue.global_transform.basis.x.length() * 0.5 / local.length()))
		rows[str(ws)] = [snappedf(ecc, 0.01), snappedf(size_deg, 0.001)]
		near(ecc, 24.0, 0.5, "cue 24 deg out at ws=%.2f" % ws)
		if ref < 0.0:
			ref = size_deg
		near(size_deg, ref, ref * 0.01, "cue visual size constant at ws=%.2f (%.3f vs %.3f deg)" % [ws, size_deg, ref])
	metric("cue_by_world_scale", rows)
	Events.target_changed.emit(null)
	k.set_world_scale(1.0)
	bird.queue_free()
	k.teardown()
	await wait_frames(2)


func test_cue_goes_when_the_target_is_caught() -> void:
	# The target was eaten by someone else (alive = false, still in the
	# tree until GameLoop names the next one): no cue to a dead bird.
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 3)
	_synthetic(k)
	var bird := Bird.new()
	bird.mass = 0.01
	add_child(bird)
	var head := k.cam.global_transform
	bird.global_position = head.origin + head.basis * Vector3(-6, 0, 0)
	Events.target_changed.emit(bird)
	_advance(k, 0.5)
	var cue := k.ui.indicators.cue_mesh(&"target")
	check(cue.visible, "cue up for a live target")
	var a0 := k.ui.indicators.target_filter.alpha
	bird.alive = false
	_advance(k, 0.25)
	lt(k.ui.indicators.target_filter.alpha, a0 * 0.5, "fading at once when the bird is caught")
	_advance(k, 0.55)
	check(not cue.visible, "gone within 0.8 s (a fade, not a pop)")
	Events.target_changed.emit(null)
	bird.queue_free()
	k.teardown()
	await wait_frames(2)


# --- cues are never under the HUD ------------------------------------------------

## Is the centre of a cue chevron (as drawn now) behind a notice plate the
## player can read (round 4's probe: opacity >= 0.6)?
func _cue_under_notice(k: Kit, which: StringName) -> bool:
	var cue := k.ui.indicators.cue_mesh(which)
	if not cue.visible or k.ui.hud_panel.band_alpha(HUD.BAND_NOTICE) < HUD.READABLE_ALPHA:
		return false
	return _notice_hits(k, cue.global_position - k.cam.global_position, 0.0) > 0


func test_cues_draw_over_the_hud_and_never_sit_under_a_readable_plate() -> void:
	# Round 4: the chevrons (render priority 8) drew under the HUD panel (9)
	# and its 95 % opaque plates, and the notices protected the birds, not
	# the cues pointing at them: a prey cue vanished under the lesson card in
	# every 12 deg climb. Now the cues draw last, and the notices never sit
	# on one: every case of the verifier's probe, prey and hawks.
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.gl.start_run()
	await k.settle(self, 4)
	_synthetic(k)
	check(k.ui.hud.lesson_visible(), "a lesson card is up (first flight)")
	var hud_prio := k.ui.hud_panel.get_material().render_priority
	for which: StringName in [&"target", &"threat"]:
		var m := k.ui.indicators.cue_mesh(which).material_override as BaseMaterial3D
		gt(m.render_priority, hud_prio, "%s chevrons draw after (over) the HUD panel (%d > %d)" % [which, m.render_priority, hud_prio])
		check(m.no_depth_test, "%s chevrons ignore depth like the panel" % which)
	var layer := -1
	for c in k.ui.indicators.get_children():
		if c is CanvasLayer:
			layer = (c as CanvasLayer).layer
	gt(layer, k.ui.hud_panel.desktop_layer, "desktop: the cue layer (%d) is above the HUD's (%d)" % [layer, k.ui.hud_panel.desktop_layer])
	lt(layer, k.ui.menu_panel.desktop_layer, "and below the menus'")
	var cruise := SizeRules.cruise_speed(0.03)
	var rows := {}
	var bad := 0
	var prey := Bird.new()
	prey.mass = 0.01
	add_child(prey)
	for climb: float in [0.0, 8.0, 12.0, 16.0]:
		var a := deg_to_rad(climb)
		k.player.velocity = Vector3(0.0, sin(a), -cos(a)) * cruise
		for spec: Vector2 in [Vector2(0.0, 32.0), Vector2(10.0, 36.0), Vector2(-12.0, 34.0), Vector2(0.0, 40.0)]:
			prey.global_position = k.cam.global_position + _dir(spec.x, spec.y) * 12.0
			Events.target_changed.emit(prey)
			for i in int(0.8 / SDT):
				_frame(k)
			var n := 0
			var hid := 0
			for i in 20:
				_frame(k)
				if k.ui.indicators.cue_mesh(&"target").visible:
					n += 1
					if _cue_under_notice(k, &"target"):
						hid += 1
			rows["climb %d, prey yaw %d el %d" % [int(climb), int(spec.x), int(spec.y)]] = [n, hid]
			check(n > 0, "prey cue drawn (climb %d, %s)" % [int(climb), spec])
			bad += 1 if hid > 0 else 0
			Events.target_changed.emit(null)
			for i in 22:
				_frame(k)
	prey.queue_free()
	var hawk := Bird.new()
	hawk.mass = 1.3
	add_child(hawk)
	for climb: float in [0.0, 10.0, 14.0]:
		var a := deg_to_rad(climb)
		k.player.velocity = Vector3(0.0, sin(a), -cos(a)) * cruise
		for spec: Vector3 in [Vector3(0.0, 8.0, 12.0), Vector3(2.0, 10.0, 6.0), Vector3(-1.5, 12.0, 9.0)]:
			hawk.global_position = k.cam.global_position + spec
			Events.threat_changed.emit(0.8, hawk)
			for i in int(0.8 / SDT):
				_frame(k)
			var n := 0
			var hid := 0
			for i in 20:
				_frame(k)
				if k.ui.indicators.cue_mesh(&"threat").visible:
					n += 1
					if _cue_under_notice(k, &"threat"):
						hid += 1
			rows["climb %d, hawk at %s" % [int(climb), spec]] = [n, hid]
			check(n > 0, "threat cue drawn (climb %d, %s)" % [int(climb), spec])
			bad += 1 if hid > 0 else 0
			Events.threat_changed.emit(0.0, null)
			for i in 22:
				_frame(k)
	metric("cue_under_readable_notice_frames", rows)
	eq(bad, 0, "no cue under a readable notice plate in any of the probe's 21 cases")
	# The one case that does put a cue on the card (a hawk above-behind-right
	# points up-right; above, the card moved away from it each time): a new
	# card at home is see-through at once and, as the cue stays, it goes to
	# the other side of the flight path and is read there.
	k.player.velocity = Vector3(0, 0, -cruise)
	k.ui.onboarding.reset()
	k.ui.hud.hide_lesson()
	_advance(k, HUD.MOVE_GAP_S)
	k.ui.onboarding.start()
	await k.settle(self, 2)
	eq(k.ui.hud_panel.band_offset(HUD.BAND_NOTICE), Vector2.ZERO, "a new card at home")
	var moves0 := k.ui.hud.move_count
	hawk.global_position = k.cam.global_position + Vector3(2.0, 10.0, 6.0)
	Events.threat_changed.emit(0.8, hawk)
	var first_under := -1.0
	var see_through := -1.0
	var t := 0.0
	while t < 3.0:
		_frame(k)
		t += SDT
		var cue := k.ui.indicators.cue_mesh(&"threat")
		if first_under < 0.0 and cue.visible and _notice_hits(k, cue.global_position - k.cam.global_position, 1.0) > 0:
			first_under = t
		if first_under >= 0.0 and see_through < 0.0 and k.ui.hud_panel.band_alpha(HUD.BAND_NOTICE) < 0.2:
			see_through = t
	metric("hawk_cue_on_the_card", {"cue_on_card_at_s": snappedf(first_under, 0.001), "see_through_at_s": snappedf(see_through, 0.001), "moves": k.ui.hud.move_count - moves0})
	check(first_under >= 0.0, "the hawk's cue came onto the card")
	between(see_through - first_under, 0.0, 0.14, "see-through within 0.14 s of the cue arriving")
	eq(k.ui.hud_panel.band_offset(HUD.BAND_NOTICE), HUD.NOTICE_MIRROR, "the card went to the other side of the centre line")
	eq(k.ui.hud.move_count - moves0, 1, "once")
	eq(_notice_hits(k, k.ui.indicators.cue_mesh(&"threat").global_position - k.cam.global_position, 2.0), 0, "clear of the cue")
	gt(k.ui.hud_panel.band_alpha(HUD.BAND_NOTICE), 0.99, "and read again")
	Events.threat_changed.emit(0.0, null)
	hawk.queue_free()
	k.teardown()
	await wait_frames(2)


## The round-7 engineering verifier: in the live frame order UIRoot's
## make_way runs before the cues are re-placed, and a flying rig carries
## the eye ~0.1 m a frame, so the chevron meshes' last positions were a few
## degrees off where the chevrons are drawn: the notices faded (and moved)
## for cues that were never on them. The notices now take each cue where it
## is drawn from the eye as it is now (HudIndicators.cue_direction).
func test_the_notices_see_the_cues_where_they_are_drawn_now() -> void:
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.parent_rig_like_player_bird()
	k.gl.start_run()
	await k.settle(self, 4)
	_synthetic(k)
	var prey := Bird.new()
	prey.mass = 0.01
	add_child(prey)
	var hawk := Bird.new()
	hawk.mass = 1.3
	add_child(hawk)
	prey.global_position = k.cam.global_position + _dir(40.0, 25.0) * 12.0
	hawk.global_position = k.cam.global_position + Vector3(2.0, 10.0, 6.0)
	Events.target_changed.emit(prey)
	Events.threat_changed.emit(0.8, hawk)
	for i in 60:
		_frame(k)
	var worst := 0.0
	var stale_worst := 0.0
	var n := 0
	for i in 36:
		# Live order, flying: the rig travels 0.12 m (8.6 m/s at 72 Hz) and
		# the notices make way before the cues are re-placed.
		k.rig_parent.global_position += Vector3(0.0, 0.0, -0.12)
		k.ui.hud_panel.follow(SDT)
		var stale := {}
		for which: StringName in [&"target", &"threat"]:
			stale[which] = (k.ui.indicators.cue_mesh(which).global_position - k.cam.global_position).normalized()
		var dirs := k.ui.hud_protected_directions()
		var labels := k.ui.protected_labels.duplicate()
		k.ui.hud.make_way(dirs, SDT)
		k.ui.indicators.step(SDT)
		k.ui.hud.advance(SDT)
		for which: StringName in [&"target", &"threat"]:
			var j := labels.find("%s cue" % which)
			var cue := k.ui.indicators.cue_mesh(which)
			if j < 0 or not cue.visible:
				continue
			var drawn := (cue.global_position - k.cam.global_position).normalized()
			worst = maxf(worst, rad_to_deg(dirs[j].angle_to(drawn)))
			stale_worst = maxf(stale_worst, rad_to_deg((stale[which] as Vector3).angle_to(drawn)))
			n += 1
	metric("cue_direction_error_deg", {"now": snappedf(worst, 0.001), "mesh_last_position": snappedf(stale_worst, 0.001)})
	gt(n, 60, "both cues drawn and protected (%d)" % n)
	# (What is left is the ring angle's own one-frame lag as the bird's
	# bearing turns: small beside the 1.5 deg fade margin and its 1.0 deg
	# hysteresis. The meshes' last positions were several degrees off.)
	lt(worst, 0.5, "the notices see each cue where it is drawn that frame (worst %.3f deg off)" % worst)
	gt(stale_worst, 2.0, "(the chevron meshes' last positions were %.1f deg off)" % stale_worst)
	Events.target_changed.emit(null)
	Events.threat_changed.emit(0.0, null)
	prey.queue_free()
	hawk.queue_free()
	k.teardown()
	await wait_frames(2)


func test_reading_the_notices_never_fades_them() -> void:
	# The cue ring turns with the head. Turning the head to read the lesson
	# card (15 deg right, 12 deg up) swings the ring over the card's outer
	# end. With a hawk whose chevron lands there, the card must stay put
	# and fully shown while it is read (the chevron draws on top); the first
	# version of this round faded it (the screenshot vr_notice_read showed
	# a ghost card).
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.gl.start_run()
	await k.settle(self, 4)
	_synthetic(k)
	check(k.ui.hud.lesson_visible(), "a lesson card is up")
	k.player.velocity = Vector3(0, 0, -9)
	k.set_head(Vector3(0, Kit.EYE, 0), -15.0, 12.0)
	await k.settle(self, 1)
	# A point of the card 24 deg from where the head points (on the ring),
	# and a hawk far out along that ring angle.
	var cam := k.cam.global_transform
	var plate := k.ui.hud.band_plates(HUD.BAND_NOTICE)[0].get_global_rect()
	var theta := INF
	for i in 60:
		for j in 12:
			var px := plate.position + plate.size * Vector2((i + 0.5) / 60.0, (j + 0.5) / 12.0)
			var l := cam.basis.inverse() * (k.ui.hud_panel.pixel_to_world(px) - cam.origin).normalized()
			if absf(rad_to_deg(acos(clampf(-l.z, -1.0, 1.0))) - 24.0) < 0.3 and not is_finite(theta):
				theta = atan2(l.y, l.x)
	check(is_finite(theta), "the ring crosses the card while reading it")
	var hawk := Bird.new()
	hawk.mass = 1.6
	add_child(hawk)
	var off := deg_to_rad(60.0)
	hawk.global_position = cam.origin + cam.basis * (Vector3(sin(off) * cos(theta), sin(off) * sin(theta), -cos(off)) * 15.0)
	Events.threat_changed.emit(0.75, hawk)
	_advance(k, 0.5)
	var min_a := 1.0
	var cue_on_card := 0
	var n := int(3.0 / SDT)
	for i in n:
		_frame(k)
		min_a = minf(min_a, k.ui.hud_panel.band_alpha(HUD.BAND_NOTICE))
		var cue := k.ui.indicators.cue_mesh(&"threat")
		if cue.visible and _notice_hits(k, cue.global_position - k.cam.global_position, 0.0) > 0:
			cue_on_card += 1
	metric("reading", {"min_alpha": snappedf(min_a, 0.001), "cue_frames_on_card": cue_on_card, "of_frames": n, "moves": k.ui.hud.move_count})
	check(k.ui.hud.looks_at_notices(-k.cam.global_basis.z), "the head points at the notices")
	gt(float(cue_on_card), n * 0.9, "the hawk's chevron is on the card (%d of %d frames)" % [cue_on_card, n])
	gt(min_a, 0.99, "read for 3 s with a cue over it: fully shown throughout (min %.3f)" % min_a)
	eq(k.ui.hud.move_count, 0, "and it does not move")
	# Looking ahead again with a hawk whose cue lies on the card (above-behind-
	# right, the probe's case): a cue in the way, and the card makes way.
	k.set_head(Vector3(0, Kit.EYE, 0), 0.0)
	hawk.global_position = k.cam.global_position + Vector3(2.0, 10.0, 6.0)
	_advance(k, 2.5)
	eq(k.ui.hud.move_count, 1, "looking ahead, a cue on the card sends it to the other side")
	Events.threat_changed.emit(0.0, null)
	hawk.queue_free()
	k.teardown()
	await wait_frames(2)


# --- cue strength where it is drawn -------------------------------------------------

func test_threat_cue_strength_follows_the_threat_level() -> void:
	# HudMath.threat_alpha is pinned as maths; this pins it where the drawn
	# cue uses it: a distant, harmless hawk must not get a full-strength cue.
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 3)
	_synthetic(k)
	var hawk := Bird.new()
	hawk.mass = 1.6
	add_child(hawk)
	hawk.global_position = k.cam.global_transform * Vector3(4, 0, 10)
	var rows := {}
	for level: float in [0.05, 0.3, 0.9]:
		Events.threat_changed.emit(level, hawk)
		for i in 72:
			_frame(k)
		var cue := k.ui.indicators.cue_mesh(&"threat")
		var a := (cue.material_override as StandardMaterial3D).albedo_color.a if cue.visible else 0.0
		rows[str(level)] = snappedf(a, 0.001)
	metric("threat_cue_alpha_by_level", rows)
	lt(float(rows["0.05"]), 0.02, "a threat of 0.05: no cue (%.3f)" % rows["0.05"])
	between(float(rows["0.3"]), 0.18, 0.32, "a threat of 0.3: a faint cue (%.3f)" % rows["0.3"])
	gt(float(rows["0.9"]), 0.85, "a threat of 0.9: a strong cue (%.3f)" % rows["0.9"])
	Events.threat_changed.emit(0.0, null)
	hawk.queue_free()
	k.teardown()
	await wait_frames(2)


func test_target_cue_fade_is_the_same_for_a_sparrow_and_an_eagle() -> void:
	# The target cue fades with seconds of flight to the bird at the
	# player's own cruise speed: the same for a sparrow and an eagle.
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 3)
	_synthetic(k)
	var prey := Bird.new()
	prey.mass = 0.01
	add_child(prey)
	var rows := {}
	for sp: int in [2, 9]:
		var m: float = SizeRules.SPECIES[sp]["mass"] * 1.02
		k.player.mass = m
		var cruise: float = SizeRules.performance(m)["cruise"]
		for secs: float in [5.0]:
			prey.global_position = k.cam.global_transform * Vector3(-secs * cruise, 0, 0)
			Events.target_changed.emit(null)
			for i in 40:
				_frame(k)
			Events.target_changed.emit(prey)
			for i in 90:
				_frame(k)
			var cue := k.ui.indicators.cue_mesh(&"target")
			rows[String(SizeRules.SPECIES[sp]["id"])] = snappedf((cue.material_override as StandardMaterial3D).albedo_color.a if cue.visible else 0.0, 0.001)
	metric("target_cue_alpha_5s_away", rows)
	var sa: float = rows["sparrow"]
	var ea: float = rows["eagle"]
	# 5 s away is halfway through the 2-9 s fade: about half of 0.85.
	between(sa, 0.3, 0.55, "a sparrow 5 s from its prey: a half-strength cue (%.3f)" % sa)
	near(ea, sa, 0.03, "an eagle 5 s from its prey: the same (%.3f vs %.3f)" % [ea, sa])
	Events.target_changed.emit(null)
	prey.queue_free()
	k.teardown()
	await wait_frames(2)


func test_cues_fade_in_afresh_after_a_pause() -> void:
	# While the cues are off (a menu is up) their filters forget: after the
	# pause a cue fades in again where the bird is now, it never pops back
	# at full strength (possibly on a side that is stale by then).
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 3)
	_synthetic(k)
	var prey := Bird.new()
	prey.mass = 0.01
	add_child(prey)
	prey.global_position = k.cam.global_transform * Vector3(-8, 0, 0)
	Events.target_changed.emit(prey)
	for i in 72:
		_frame(k)
	gt(k.ui.indicators.target_filter.alpha, 0.7, "cue fully up")
	Game.set_state(Game.State.PAUSED)
	await k.settle(self, 2)
	near(k.ui.indicators.target_filter.alpha, 0.0, 1e-6, "paused: the cue's filter is reset")
	Game.set_state(Game.State.PLAYING)
	await k.settle(self, 1)
	_synthetic(k)
	_frame(k)
	lt(k.ui.indicators.target_filter.alpha, 0.1, "resumed: it fades in again (%.3f), no pop" % k.ui.indicators.target_filter.alpha)
	Events.target_changed.emit(null)
	prey.queue_free()
	k.teardown()
	await wait_frames(2)


func test_desktop_hud_keeps_off_the_window_edges() -> void:
	# On a monitor the lesson card sat flush with the window's top edge (the
	# round-5 experience verifier: it looked clipped) and the strip with its
	# bottom. Both keep at least 16 screen px of margin, and stay centred.
	var k := Kit.new()
	k.setup(self, false)
	await k.settle(self, 3)
	k.gl.start_run()
	await k.settle(self, 4)
	check(k.ui.hud.lesson_visible(), "a lesson card is up")
	var win := k.ui.get_viewport().get_visible_rect().size
	var card: Control = k.ui.hud.band_plates(HUD.BAND_NOTICE)[0]
	var strip: Control = k.ui.hud.band_plates(HUD.BAND_STATUS)[0]
	var cxf := card.get_global_transform_with_canvas()
	var sxf := strip.get_global_transform_with_canvas()
	var card_top := (cxf * Vector2.ZERO).y
	var strip_bottom := (sxf * strip.size).y
	var card_mid := ((cxf * Vector2.ZERO).x + (cxf * card.size).x) * 0.5
	metric("desktop_margins_px", {"window": str(win), "card_top": snappedf(card_top, 0.1), "strip_bottom_gap": snappedf(win.y - strip_bottom, 0.1)})
	gt(card_top, 16.0, "the lesson card keeps %.1f px (> 16) off the window's top" % card_top)
	gt(win.y - strip_bottom, 16.0, "the strip keeps %.1f px (> 16) off the bottom" % (win.y - strip_bottom))
	near(card_mid, win.x * 0.5, 1.0, "the card is centred")
	k.teardown()
	await wait_frames(2)


func test_desktop_threat_cue_steps_out_too() -> void:
	# On a monitor the cues are drawn round the screen centre: the threat's
	# step out to the outer ring applies there as in VR.
	var k := Kit.new()
	k.setup(self, false)
	await k.settle(self, 3)
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 3)
	var head := k.cam.global_transform
	var prey := Bird.new()
	prey.mass = 0.01
	add_child(prey)
	prey.global_position = head * Vector3(-8, 0, 0)
	var hawk := Bird.new()
	hawk.mass = 2.0
	add_child(hawk)
	hawk.global_position = head * Vector3(-2, 0.5, 9)
	Events.target_changed.emit(prey)
	Events.threat_changed.emit(0.9, hawk)
	await wait_seconds(0.5)
	var tips := k.ui.indicators.desktop_tip_radius()
	metric("desktop_tips", tips)
	check(tips.has(&"target") and tips.has(&"threat"), "both cues drawn on the desktop overlay (%s)" % str(tips))
	near(float(tips.get(&"target", 0.0)), 1.0, 1e-3, "prey cue on the ring")
	gt(float(tips.get(&"threat", 0.0)), 1.3, "the threat cue stepped out (33/24 of the ring: %.3f)" % float(tips.get(&"threat", 0.0)))
	Events.target_changed.emit(null)
	Events.threat_changed.emit(0.0, null)
	prey.queue_free()
	hawk.queue_free()
	k.teardown()
	await wait_frames(2)
