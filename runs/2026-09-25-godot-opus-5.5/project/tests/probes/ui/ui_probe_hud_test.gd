extends TestCase
## Verifier probes (round 1) for U4: cue stability in adversarial but common
## geometry the builder's tests do not cover. Written by the independent
## verifier; does not modify any UI source.
##   - a predator sitting on your tail (dead behind) with small lateral wobble
##   - the same, slightly above
##   - a direct target swap (GameLoop emits target_changed(B) without a null)
##   - an approaching target: fade must be monotonic

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")
const DT := 1.0 / 90.0


## Drive a real IndicatorFilter with HudMath.view_polar from an eye at the
## origin looking down -Z; the bird follows pos_fn(t). Returns stability stats.
func _run_filter(seconds: float, pos_fn: Callable, strength: float) -> Dictionary:
	var f := IndicatorFilter.new()
	var cam := Transform3D.IDENTITY
	var n := int(seconds / DT)
	var flips := 0
	var last_side := 0
	var travel := 0.0
	var prev := NAN
	var max_step := 0.0
	var drawn := 0
	var top_bottom := 0
	for i in n:
		var t := i * DT
		var p: Vector3 = pos_fn.call(t)
		f.update(DT, HudMath.view_polar(cam, p), strength)
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
			top_bottom += 1
		if not is_nan(prev):
			var d := absf(wrapf(f.angle - prev, -PI, PI))
			travel += d
			max_step = maxf(max_step, d)
		prev = f.angle
	return {"side_flips": flips, "travel_deg": snappedf(rad_to_deg(travel), 0.1),
		"max_step_deg": snappedf(rad_to_deg(max_step), 0.1), "drawn_frac": snappedf(drawn / float(n), 0.01),
		"frames_pointing_up_or_down": top_bottom}


func test_threat_on_your_tail_with_lateral_wobble() -> void:
	# Hawk 10 m directly behind, wobbling +-0.4 m sideways (about +-2.3 deg)
	# at 1.2 Hz: the classic chase. A cue that says "turn left/turn right"
	# must pick a side and hold it, not swing around the ring.
	var r := _run_filter(6.0, func(t: float) -> Vector3:
		return Vector3(0.4 * sin(TAU * 1.2 * t), 0.0, 10.0), 0.9)
	metric("tail_level", r)
	gt(r["drawn_frac"], 0.9, "threat cue shown for a hawk on your tail")
	lt(r["side_flips"], 3, "cue does not flip left/right with a 2 deg wobble (%d flips in 6 s)" % r["side_flips"])
	lt(r["travel_deg"], 360.0, "cue does not sweep around the ring (%.0f deg travelled in 6 s)" % r["travel_deg"])


func test_threat_on_your_tail_slightly_above() -> void:
	# Same chase, predator 1 m above (a stoop from behind).
	var r := _run_filter(6.0, func(t: float) -> Vector3:
		return Vector3(0.4 * sin(TAU * 1.2 * t), 1.0, 10.0), 0.9)
	metric("tail_above", r)
	lt(r["side_flips"], 3, "cue does not flip left/right (%d flips in 6 s)" % r["side_flips"])
	lt(r["travel_deg"], 360.0, "cue does not sweep over the top (%.0f deg travelled)" % r["travel_deg"])


func test_behind_left_is_stable_control() -> void:
	# Control case: clearly behind-left with the same wobble must be rock steady.
	var r := _run_filter(6.0, func(t: float) -> Vector3:
		return Vector3(-3.0 + 0.4 * sin(TAU * 1.2 * t), 0.0, 10.0), 0.9)
	metric("behind_left", r)
	eq(r["side_flips"], 0, "behind-left stays left")


func test_direct_target_swap_does_not_sweep() -> void:
	# GameLoop's ThreatWatch switches target straight from A to B (no null in
	# between). Builder claims "swapping targets causes no sweep"; its test
	# only covers A -> null -> B.
	var k := Kit.new()
	k.setup(self, true)
	await k.settle(self, 3)
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 2)
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
	await wait_seconds(0.6)
	var cue := k.ui.indicators.cue_mesh(&"target")
	check(cue.visible, "cue shown for A on the left")
	Events.target_changed.emit(b)
	var through_top_bottom := 0
	var wrong_side_frames := 0
	var frames := 0
	for i in 45:
		await wait_frames(1)
		if not cue.visible:
			continue
		frames += 1
		var local := head.affine_inverse() * cue.global_position
		var ring := HudIndicators.RING_RADIUS * sin(HudIndicators.ECCENTRICITY)
		if absf(local.y) > ring * 0.6:
			through_top_bottom += 1
		if local.x < 0.0:
			wrong_side_frames += 1
	metric("swap", {"visible_frames": frames, "frames_near_top_or_bottom": through_top_bottom, "frames_still_on_left": wrong_side_frames})
	eq(through_top_bottom, 0, "cue does not sweep over the top/bottom on a direct swap (%d frames)" % through_top_bottom)
	lt(wrong_side_frames, 3, "cue is on the new target's side almost at once (%d frames on the old side)" % wrong_side_frames)
	Events.target_changed.emit(null)
	a.queue_free()
	b.queue_free()
	k.teardown()
	await wait_frames(2)


func test_approaching_target_fade_is_monotonic() -> void:
	# Prey 90 deg left, approaching from 120 m to 3 m at 9 m/s (sparrow
	# cruise): the cue should only ever get stronger (no pulsing).
	var f := IndicatorFilter.new()
	var cam := Transform3D.IDENTITY
	var reversals := 0
	var prev := 0.0
	var rising := true
	var max_jump := 0.0
	var n := int(13.0 / DT)
	for i in n:
		var d := maxf(3.0, 120.0 - 9.0 * i * DT)
		var polar := HudMath.view_polar(cam, Vector3(-d, 0.0, 0.0))
		f.update(DT, polar, HudMath.target_alpha(d, 9.0) * HudIndicators.TARGET_MAX_ALPHA)
		if f.alpha < prev - 0.002:
			reversals += 1
		max_jump = maxf(max_jump, absf(f.alpha - prev))
		prev = f.alpha
	metric("approach", {"reversals": reversals, "max_alpha_step_per_frame": snappedf(max_jump, 0.0001), "final_alpha": snappedf(f.alpha, 0.01)})
	eq(reversals, 0, "alpha never drops while the prey only gets closer")
	lt(max_jump, 0.06, "no visible alpha pops (max %.3f per frame)" % max_jump)
	gt(f.alpha, 0.8, "close prey: cue at full strength")
