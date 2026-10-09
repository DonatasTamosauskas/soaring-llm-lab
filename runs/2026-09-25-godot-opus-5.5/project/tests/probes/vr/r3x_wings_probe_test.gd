extends TestCase
## VERIFIER PROBE (vr, round 3, experience lens). Not part of the area suite:
##   tools/gd.sh vr_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/vr --suite=r3x_wings
## Questions:
##  1. Continuity. Fix round 2 made a folding wing turn "towards level,
##     upper side up" but only when the turn is < ~100° and the forearm is
##     not near vertical (FirstPersonWings._place_wing: level.length() > 0.2
##     and level.dot(n_h) > -0.2). A gate on a continuous input with a
##     0.8-of-the-way slerp behind it is a step: does a folded wing POP when
##     a relaxed wrist rolls 1°, or a relaxed elbow straightens 1°? The
##     player sees their own wings all the time, and a feather fan flipping
##     80° between two frames is exactly the kind of glitch VR makes obvious.
##  2. Degenerate poses (hands together, crossed, straight down/up, hand at
##     the shoulder, a 5 m tracking glitch, world_scale 0.05 / 5): every
##     feather transform finite and near the body.

const Env := preload("res://scenes/dev/vr_dev_env.gd")
const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const DT := 1.0 / 90.0
const DEG := PI / 180.0


class Ext:
	extends RefCounted
	var ext_l := 0.0
	var ext_r := 0.0
	var stroke_period := 1.0


var rig: Dictionary
var extras: VRRigExtras
var wings: FirstPersonWings
var puppet: VRPosePuppet
var ext := Ext.new()


func before_all() -> void:
	rig = Env.build_rig(self, Vector3(0, 3, 0), MemoryStore.new(), true, false)
	await wait_frames(3)
	extras = rig["extras"]
	wings = extras.wings
	puppet = rig["puppet"]
	puppet.set_process(false)
	extras.calibration.auto_tick = false
	wings.auto_update = false
	extras.world_scale_driver.enabled = false
	extras.vignette.set_process(false)
	extras.vignette.set_physics_process(false)
	puppet.human.set_arms(-5.0 * DEG)
	puppet.apply()
	for i in int(2.0 / DT):
		extras.calibration.tick(DT)
	check(extras.calibration.calibrator.calibrated, "(setup) calibrated")
	(rig["player"] as Object).set("wing_state_obj", ext)


func after_all() -> void:
	(rig["player"] as Node).queue_free()
	puppet.queue_free()


func layout(e: float) -> Array[Transform3D]:
	puppet.apply()
	extras.calibration.tick(DT)
	ext.ext_l = e
	ext.ext_r = e
	wings.update_wings(0.0)
	var out: Array[Transform3D] = []
	for k in FirstPersonWings.PER_WING * 2:
		out.append(wings.feather_transform(k))
	return out


## Worst change between two layouts: feather-plane normal (deg) and root (m).
func delta(a: Array[Transform3D], b: Array[Transform3D]) -> Vector2:
	var worst_ang := 0.0
	var worst_pos := 0.0
	for k in a.size():
		var na := a[k].basis.y
		var nb := b[k].basis.y
		if na.length() < 1e-4 or nb.length() < 1e-4:
			continue
		worst_ang = maxf(worst_ang, rad_to_deg(na.normalized().angle_to(nb.normalized())))
		worst_pos = maxf(worst_pos, a[k].origin.distance_to(b[k].origin))
	return Vector2(worst_ang, worst_pos)


## Sweeps one pose parameter in 1° steps and reports the worst jump.
func sweep_param(tag: String, e: float, setter: Callable, lo: float, hi: float) -> Dictionary:
	var prev: Array[Transform3D] = []
	var worst := Vector2.ZERO
	var at := lo
	var v := lo
	while v <= hi + 1e-6:
		setter.call(v * DEG)
		var cur := layout(e)
		if not prev.is_empty():
			var d := delta(prev, cur)
			if d.x > worst.x:
				at = v
			worst = Vector2(maxf(worst.x, d.x), maxf(worst.y, d.y))
		prev = cur
		v += 1.0
	var r := {"worst_normal_jump_deg_per_1deg": snappedf(worst.x, 0.01), "at_deg": at, "worst_root_jump_m": snappedf(worst.y, 0.0001)}
	print("[vr-verify] ", tag, " ", r)
	return r


func test_folded_wing_never_pops() -> void:
	var h := puppet.human
	var rows := {}
	# Relaxed hands (the simulator's "held"), wrist rolling through palms-in.
	for e in [0.0, 0.3]:
		h.set_arms(-68.0 * DEG, 8.0 * DEG, 0.0, 95.0 * DEG)
		rows["held: wrist roll, ext %.1f" % e] = sweep_param("held: wrist roll, ext %.1f" % e, e,
			func(x: float) -> void: h.twist = [x, x], -120.0, 120.0)
		# Arms hanging down, the elbow flexing from straight to 120°.
		h.set_arms(-85.0 * DEG, 0.0, 0.0, 0.0)
		rows["hanging: elbow flex, ext %.1f" % e] = sweep_param("hanging: elbow flex, ext %.1f" % e, e,
			func(x: float) -> void: h.elbow = [x, x], 0.0, 120.0)
		# Arms lowering from level to straight down, elbows soft.
		h.set_arms(0.0, 0.0, 0.0, 30.0 * DEG)
		rows["lowering: dihedral, ext %.1f" % e] = sweep_param("lowering: dihedral, ext %.1f" % e, e,
			func(x: float) -> void: h.dihedral = [x, x], -90.0, 10.0)
	metric("fold_continuity", rows)
	for tag in rows:
		# 1° of wrist/elbow/shoulder motion: a feather may turn a few degrees
		# (the fold rule amplifies), never flip.
		lt(float(rows[tag]["worst_normal_jump_deg_per_1deg"]), 10.0, "%s: no pop (worst %.1f° for a 1° step at %s°)" % [tag,
			rows[tag]["worst_normal_jump_deg_per_1deg"], str(rows[tag]["at_deg"])])


func test_extension_sweep_is_smooth() -> void:
	var h := puppet.human
	var rows := {}
	for g in ["held", "spread", "glide"]:
		match g:
			"held":
				h.set_arms(-68.0 * DEG, 8.0 * DEG, 0.0, 95.0 * DEG)
			"spread":
				h.set_arms(-5.0 * DEG)
			"glide":
				h.set_arms(-28.0 * DEG, 0.0, 0.0, 22.0 * DEG)
		var prev: Array[Transform3D] = []
		var worst := Vector2.ZERO
		for i in 101:
			var cur := layout(i / 100.0)
			if not prev.is_empty():
				var d := delta(prev, cur)
				worst = Vector2(maxf(worst.x, d.x), maxf(worst.y, d.y))
			prev = cur
		rows[g] = {"worst_normal_jump_deg_per_0.01": snappedf(worst.x, 0.01), "worst_root_jump_m": snappedf(worst.y, 0.0001)}
		print("[vr-verify] extension sweep ", g, " ", rows[g])
		lt(worst.x, 5.0, "%s: extension 0 -> 1 in 0.01 steps turns no feather plane > 5° per step" % g)
	metric("extension_continuity", rows)


func all_finite(ts: Array[Transform3D]) -> bool:
	for t in ts:
		for v in [t.origin, t.basis.x, t.basis.y, t.basis.z]:
			if not (is_finite(v.x) and is_finite(v.y) and is_finite(v.z)):
				return false
	return true


func test_degenerate_poses_stay_finite_and_near_the_body() -> void:
	var h := puppet.human
	var origin := rig["origin"] as XROrigin3D
	var rows := {}
	var cases := {
		"hands together at the chest": func() -> void: h.set_arms(-20.0 * DEG, 88.0 * DEG, 0.0, 0.0),
		"arms crossed": func() -> void: h.set_arms(-30.0 * DEG, 120.0 * DEG, 0.0, 40.0 * DEG),
		"straight down": func() -> void: h.set_arms(-90.0 * DEG),
		"straight up": func() -> void: h.set_arms(90.0 * DEG),
		"hand at the shoulder": func() -> void: h.set_arms(0.0, 0.0, 0.0, 178.0 * DEG),
		"palms up": func() -> void: h.set_arms(-5.0 * DEG, 0.0, 180.0 * DEG, 0.0),
	}
	for ws in [0.05, 1.0, 5.0]:
		origin.world_scale = ws
		for name in cases:
			(cases[name] as Callable).call()
			for e in [0.0, 1.0]:
				var ts := layout(e)
				var tag := "%s ws %.2f ext %.0f" % [name, ws, e]
				var fin := all_finite(ts)
				var far := 0.0
				var big := 0.0
				var cal := extras.calibration.calibrator
				for k in ts.size():
					var side := k / FirstPersonWings.PER_WING
					var g: Vector3 = cal.hands[side].origin * ws
					var sh: Vector3 = cal.shoulders[side] * ws
					far = maxf(far, minf(ts[k].origin.distance_to(g), ts[k].origin.distance_to(sh)) / ws)
					big = maxf(big, maxf(ts[k].basis.x.length(), ts[k].basis.z.length()) / ws)
				rows[tag] = {"finite": fin, "farthest_root_from_grip_or_shoulder_m": snappedf(far, 0.001), "largest_axis_m": snappedf(big, 0.001)}
				check(fin, "%s: all feather transforms finite" % tag)
				lt(far, 0.8, "%s: every feather rooted within 0.8 m (x ws) of its grip or shoulder (%.3f)" % [tag, far])
				lt(big, 0.8, "%s: no feather stretched beyond 0.8 m (x ws) (%.3f)" % [tag, big])
	origin.world_scale = 1.0
	# A tracking glitch: the right grip reported 5 m away for one frame.
	h.set_arms(-5.0 * DEG)
	puppet.apply()
	var right := rig["right"] as Node3D
	right.transform = Transform3D(right.transform.basis, right.transform.origin + Vector3(5, 0, 0))
	extras.calibration.tick(DT)
	wings.update_wings(0.0)
	var ts2: Array[Transform3D] = []
	for k in FirstPersonWings.PER_WING * 2:
		ts2.append(wings.feather_transform(k))
	check(all_finite(ts2), "tracking glitch: finite")
	metric("degenerate", rows)


## Tracker-level jitter (+-0.3° of wrist roll, typical controller rotation
## noise plus hand tremor) on a relaxed hand held right at the gate found
## above: does the folded wing flicker between two orientations?
func test_folded_wing_does_not_flicker_under_tracker_noise() -> void:
	var h := puppet.human
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var rows := {}
	for c in [["held wrist", 33.5, "twist"], ["hanging elbow", 10.5, "elbow"]]:
		if c[2] == "twist":
			h.set_arms(-68.0 * DEG, 8.0 * DEG, 0.0, 95.0 * DEG)
		else:
			h.set_arms(-85.0 * DEG, 0.0, 0.0, 0.0)
		var prev: Array[Transform3D] = []
		var flips := 0
		var worst := 0.0
		for i in 90:
			var v := (float(c[1]) + rng.randf_range(-0.3, 0.3)) * DEG
			if c[2] == "twist":
				h.twist = [v, v]
			else:
				h.elbow = [v, v]
			var cur := layout(0.0)
			if not prev.is_empty():
				var d := delta(prev, cur)
				worst = maxf(worst, d.x)
				if d.x > 30.0:
					flips += 1
			prev = cur
		rows[c[0]] = {"frames": 90, "frames_with_a_flip_over_30deg": flips, "worst_deg": snappedf(worst, 0.1)}
		print("[vr-verify] flicker ", c[0], " ", rows[c[0]])
		eq(flips, 0, "%s: a folded wing held still (+-0.3° noise) never flips > 30° between frames" % c[0])
	metric("flicker", rows)
