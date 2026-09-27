extends TestCase
## V5: first-person wings. They follow the controllers (hand feathers ride
## the grip pose, the wing plane tilts with the wrist), spread and fold with
## arm extension, draw the wingtip exactly 10 cm (x world_scale) past each
## grip at every world_scale from 0.15 to 1.3, take the species colours,
## hide a wing whose controller lost tracking, and cost one draw call.
## Screenshots: tests/shots/vr_shots.gd (artifacts/vr/wings_*.png) and the
## simulator mirror (tests/sim).

const Env := preload("res://scenes/dev/vr_dev_env.gd")
const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const DT := 1.0 / 90.0

var rig: Dictionary
var extras: VRRigExtras
var wings: FirstPersonWings
var puppet: VRPosePuppet


func before_all() -> void:
	rig = Env.build_rig(self, Vector3(0, 3, 0), MemoryStore.new(), true, false)
	await wait_frames(3)
	extras = rig["extras"]
	wings = extras.wings
	puppet = rig["puppet"]
	# Deterministic stepping: nothing moves unless the test says so.
	puppet.set_process(false)
	extras.calibration.auto_tick = false
	wings.auto_update = false
	extras.world_scale_driver.enabled = false
	# Calibrate on the default player first (the explicit step).
	pose(&"spread")
	extras.calibration.start_manual()
	for i in int(2.0 / DT):
		extras.calibration.tick(DT)
	check(extras.calibration.calibrator.calibrated, "rig calibrated")


func after_all() -> void:
	(rig["player"] as Node).queue_free()
	puppet.queue_free()
	(rig["origin"] as XROrigin3D).world_scale = 1.0


func pose(g: StringName, ws: float = 1.0) -> void:
	(rig["origin"] as XROrigin3D).world_scale = ws
	puppet.look_yaw = 0.0
	puppet.look_pitch = 0.0
	puppet.pose_for(g, 0.0)
	puppet.apply()


## Moves the puppet, feeds the calibration, updates the wings (extension
## fully settled).
func settle() -> void:
	extras.calibration.tick(DT)
	wings.update_wings(1.0)


func origin_space(n: Node3D) -> Transform3D:
	return (rig["origin"] as Node3D).global_transform.affine_inverse() * n.global_transform


func grip_frame(side: int) -> Dictionary:
	var ws := (rig["origin"] as XROrigin3D).world_scale
	var hand := rig["left"] as Node3D if side == 0 else rig["right"] as Node3D
	var t := origin_space(hand)
	var cal := extras.calibration.calibrator
	var o := (t.basis * cal.forearm_axis[side]).normalized()
	var c := t.basis * cal.chord_axis[side]
	c = (c - o * c.dot(o)).normalized()
	var s := -1.0 if side == 0 else 1.0
	# The arm's line (shoulder -> grip), handing over to the forearm near
	# the shoulder, for the folding rules.
	var arm: Vector3 = t.origin / ws - cal.shoulders[side]
	var a := o
	if arm.length() > 1e-4:
		var mixed := o.lerp(arm.normalized(), VRMath.sstep(FirstPersonWings.ARM_DIR_MIN, FirstPersonWings.ARM_DIR_FULL, arm.length()))
		if mixed.length() > 1e-3:
			a = mixed.normalized()
	return {"pos": t.origin, "o": o, "n": (o.cross(c) * s).normalized(), "a": a, "ws": ws}


## The hand frame's outward axis and wing normal the rules give for
## extension e, written out here with slerps (the code rotates by signed
## angles): the controller's frame while spread; as the wing folds it
## swings towards the arm's line (FOLD_ALIGN x (1 - e)² of the way, fading
## out towards opposite directions) and then turns about it towards level
## (wing_normal).
func folded_frame(f: Dictionary, e: float) -> Array:
	var al := aligned(f, e)
	return [al["o"], wing_normal(al, e)]


## The hand frame swung towards the arm's line only (no level turn yet).
func aligned(f: Dictionary, e: float) -> Dictionary:
	var o: Vector3 = f["o"]
	var n: Vector3 = f["n"]
	var a: Vector3 = f["a"]
	var ang := o.angle_to(a)
	var w := FirstPersonWings.FOLD_ALIGN * (1.0 - e) * (1.0 - e) * (1.0 - VRMath.sstep(FirstPersonWings.ALIGN_FADE_FROM, PI, ang))
	if w > 0.0 and ang > 1e-5:
		var q := Quaternion(o, a).slerp(Quaternion.IDENTITY, 1.0 - w)
		o = (q * o).normalized()
		n = (q * n).normalized()
	return {"o": o, "n": n}


## The wing plane's normal the rule gives for extension e: the
## controller's plane while spread, turning about the forearm towards level
## as the wing folds (FirstPersonWings.FOLD_LEVEL x (1 - e)² of the way,
## upper side up), the turn fading out smoothly near a vertical forearm and
## for a palm-up hand. Written out here with a slerp (the code rotates by a
## signed angle about the forearm): two derivations of the same rule.
func wing_normal(f: Dictionary, e: float) -> Vector3:
	var o: Vector3 = f["o"]
	var n: Vector3 = f["n"]
	var level := Vector3.UP - o * o.dot(Vector3.UP)
	var w := FirstPersonWings.FOLD_LEVEL * (1.0 - e) * (1.0 - e)
	w *= VRMath.sstep(FirstPersonWings.LEVEL_FADE_LO, FirstPersonWings.LEVEL_FADE_HI, level.length())
	if w <= 0.0:
		return n
	var ang := n.angle_to(level.normalized())
	w *= 1.0 - VRMath.sstep(FirstPersonWings.TURN_FADE_FROM, PI, ang)
	return n.slerp(level.normalized(), w) if w > 0.0 else n


# -----------------------------------------------------------------------------

func test_hand_feathers_ride_the_grip_pose() -> void:
	var worst_pos := 0.0
	var worst_ang := 0.0
	var worst_spread := 0.0
	for g in [&"spread", &"glide", &"bank_left", &"bank_right", &"twist_up", &"twist_down", &"flap", &"tuck"]:
		for phase in [0.0, 0.35, 0.7]:
			pose(g)
			if g == &"flap":
				puppet.pose_for(g, phase)
				puppet.apply()
			settle()
			for side in 2:
				var f := grip_frame(side)
				var k := side * FirstPersonWings.PER_WING
				var t := wings.feather_transform(k)
				var p0: Array = FirstPersonWings.PRIMARIES[0]
				var ff := folded_frame(f, wings.extension_shown[side])
				var want: Vector3 = f["pos"] + (ff[0] as Vector3) * float(p0[0]) * float(f["ws"])
				worst_pos = maxf(worst_pos, t.origin.distance_to(want))
				worst_ang = maxf(worst_ang, rad_to_deg(t.basis.y.normalized().angle_to(ff[1])))
				if wings.extension_shown[side] > 0.97:
					worst_spread = maxf(worst_spread, rad_to_deg(t.basis.y.normalized().angle_to(f["n"])))
	lt(worst_pos, 0.001, "leading primary rooted on the grip's line (worst %.4f m)" % worst_pos)
	lt(worst_ang, 1.0, "primary plane = the controller's wing plane, swung to the arm and turned towards level only as it folds (worst %.2f°)" % worst_ang)
	lt(worst_spread, 1.0, "a spread wing is exactly in the controller's plane (worst %.2f°)" % worst_spread)
	metric("worst_root_err_m", worst_pos)
	metric("worst_normal_err_deg", worst_ang)


## The arm feathers (secondaries, greater and lesser coverts) are rooted
## along the arm: feather j at its table fraction of the way from the
## shoulder to the grip, then offset only across the arm (towards the
## trailing edge and along the wing's normal, by its table offsets, x
## world_scale). Fix round 5: this round's mutant F05 (every arm feather
## rooted at the shoulder) passed every other test.
func test_arm_feathers_lie_along_the_arm() -> void:
	var worst := 0.0
	var worst_along := 0.0
	var n_hand := FirstPersonWings.PRIMARIES.size() + FirstPersonWings.HAND_COVERTS.size()
	var arm_rows: Array = FirstPersonWings.SECONDARIES + FirstPersonWings.GREATER_COVERTS + FirstPersonWings.LESSER_COVERTS
	var cal := extras.calibration.calibrator
	for ws: float in [1.0, 0.15]:
		for g in [&"spread", &"glide", &"flap", &"bank_left"]:
			pose(g, ws)
			settle()
			for side in 2:
				var sh: Vector3 = cal.shoulders[side]
				var hand: Vector3 = cal.hands[side].origin
				var arm := hand - sh
				if arm.length() < FirstPersonWings.ARM_DIR_FULL:
					continue
				for j in range(n_hand, FirstPersonWings.PER_WING):
					var row: Array = arm_rows[j - n_hand]
					var root := wings.feather_transform(side * FirstPersonWings.PER_WING + j).origin
					var on_line := (sh + arm * float(row[0])) * ws
					var off := root - on_line
					# Offsets across the arm only: trailing edge (row[6]) and
					# the normal (row[5]), orthonormal to each other.
					var want := Vector2(float(row[6]), float(row[5])).length() * ws
					worst = maxf(worst, absf(off.length() - want))
					worst_along = maxf(worst_along, absf(off.dot(arm.normalized())))
	lt(worst, 1e-4, "each arm feather sits its fraction along shoulder -> grip, offset only by its table offsets (worst %.5f m)" % worst)
	lt(worst_along, 1e-4, "and none is shifted along the arm (worst %.5f m)" % worst_along)
	pose(&"spread")
	settle()


## Fix round 5 (the engineering verifier's surviving mutant E38: the wings
## laid out before the calibrator sampled the controllers, a frame behind
## the hands). In the game's own frame order (the XR nodes move at the
## start of the frame, VRCalibration samples them at process priority 50,
## the wings lay out at 100) a wing shows THIS frame's wrist: a 30° roll
## made at the start of a frame is on the feathers when it ends, and
## nothing of it is left for the next frame.
func test_wings_follow_the_controllers_in_the_same_frame() -> void:
	pose(&"spread")
	extras.calibration.auto_tick = true
	wings.auto_update = true
	await wait_frames(40)
	var left := rig["left"] as Node3D
	var cal := extras.calibration.calibrator
	var t0 := wings.feather_transform(0)
	var ax := (left.transform.basis * cal.forearm_axis[0]).normalized()
	# (We are at the start of a frame: the nodes' _process has not run.)
	left.transform = Transform3D(Basis(ax, deg_to_rad(30.0)) * left.transform.basis, left.transform.origin)
	await wait_frames(1)
	var t1 := wings.feather_transform(0)
	await wait_frames(1)
	var t2 := wings.feather_transform(0)
	var turned := rad_to_deg(t0.basis.y.normalized().angle_to(t1.basis.y.normalized()))
	var left_over := rad_to_deg(t1.basis.y.normalized().angle_to(t2.basis.y.normalized()))
	metric("same_frame", {"turned_deg": turned, "left_for_next_frame_deg": left_over})
	near(turned, 30.0, 1.0, "the wing's plane rolled with the wrist in the same frame (%.2f°)" % turned)
	lt(left_over, 0.05, "and nothing was left for the next frame (%.3f°)" % left_over)
	lt(t1.origin.distance_to(t2.origin), 1e-5, "the feather's root did not move on either")
	extras.calibration.auto_tick = false
	wings.auto_update = false
	pose(&"spread")
	settle()


func test_wrist_twist_tilts_the_wing() -> void:
	pose(&"spread")
	settle()
	var n0 := wings.feather_transform(FirstPersonWings.PER_WING).basis.y.normalized()
	var tip0 := wings.wingtip(1)
	puppet.human.twist = [0.0, deg_to_rad(30.0)]
	puppet.apply()
	settle()
	var n30 := wings.feather_transform(FirstPersonWings.PER_WING).basis.y.normalized()
	near(rad_to_deg(n0.angle_to(n30)), 30.0, 1.0, "a 30° wrist roll tilts the hand feathers 30°")
	# Leading edge up tilts the upper-surface normal back (+Z) by the roll.
	near(n30.dot(Vector3.BACK), sin(deg_to_rad(30.0)), 0.02, "LE up 30°: the wing normal leans back by 30°")
	near(wings.wingtip(1).distance_to(tip0), 0.0, 0.03, "the tip stays at the hand")


func test_wingtip_and_span_across_world_scales() -> void:
	var rows: Array = []
	for ws in [0.15, 0.3, 0.6, 1.0, 1.3]:
		pose(&"spread", ws)
		settle()
		var fr := grip_frame(1)
		var fl := grip_frame(0)
		var tip_r := wings.wingtip(1)
		var tip_l := wings.wingtip(0)
		var over := (tip_r - (fr["pos"] as Vector3)).dot(fr["o"])
		near(over, FirstPersonWings.TIP_OVERHANG * ws, 0.002 * ws, "ws %.2f: tip 10 cm x ws past the grip" % ws)
		var grips := ((fr["pos"] as Vector3) - (fl["pos"] as Vector3)).length()
		var span := (tip_r - tip_l).length()
		near(span / ws, grips / ws + 0.20, 0.02, "ws %.2f: drawn span = (grip span + 0.20) x ws" % ws)
		# Feather sizes scale with ws (never node scale).
		near(wings.feather_transform(FirstPersonWings.PER_WING).basis.x.length(), float(FirstPersonWings.PRIMARIES[0][4]) * ws, 1e-5, "ws %.2f: feather length x ws" % ws)
		eq(wings.scale, Vector3.ONE, "the wings node itself is never scaled")
		rows.append([ws, snappedf(span, 0.0001), snappedf(over, 0.0001)])
	metric("ws_span_overhang", rows)
	pose(&"spread", 1.0)


func test_spread_and_fold_with_extension() -> void:
	var stub: Object = rig["player"]
	var ws_obj := RefCounted.new()
	var fan: Array[float] = []
	for e in [0.0, 0.25, 0.5, 0.75, 1.0]:
		stub.set("wing_state_obj", _WS.new(e, e))
		pose(&"spread")
		settle()
		var k := FirstPersonWings.PER_WING
		var d0 := wings.feather_transform(k).basis.x.normalized()
		var d6 := wings.feather_transform(k + 6).basis.x.normalized()
		fan.append(rad_to_deg(d0.angle_to(d6)))
		near(wings.extension_shown[1], e, 1e-3, "the wing shows the flight extension %.2f" % e)
	near(fan[4], 72.0, 1.0, "spread: primaries fan over 72°")
	# Folded, the primaries stay staggered over 20° so the tips of a closed
	# wing read as layered feathers (fix round 2; they were stacked in 12°).
	near(fan[0], 20.0, 1.0, "folded: primaries closed to a 20° stagger")
	for i in range(1, fan.size()):
		gt(fan[i], fan[i - 1], "fan opens monotonically with extension")
	# Folded: every primary lies back along the forearm.
	stub.set("wing_state_obj", _WS.new(0.0, 0.0))
	settle()
	var o: Vector3 = grip_frame(1)["o"]
	var worst := 0.0
	for j in FirstPersonWings.PRIMARIES.size():
		var d := wings.feather_transform(FirstPersonWings.PER_WING + j).basis.x.normalized()
		worst = maxf(worst, rad_to_deg(d.angle_to(-o)))
	lt(worst, 25.0, "folded primaries point back along the forearm (within the 20° stagger + the leading one's 4°)")
	stub.set("wing_state_obj", null)
	metric("fan_deg_by_extension", fan)


func test_own_extension_without_flight() -> void:
	(rig["player"] as Object).set("wing_state_obj", null)
	pose(&"spread")
	settle()
	near(wings.extension_shown[0], 1.0, 0.01, "spread arms: open wings")
	pose(&"tuck")
	settle()
	lt(wings.extension_shown[0], 0.05, "tucked arms: folded wings")


## Fix round 4 (a verifier's look-at-your-hands shots: a folded wing read
## as 2-3 rounded plates per hand): folded, the covert plates narrow to
## COVERT_FOLD_WIDTH and lengthen by COVERT_FOLD_LENGTH, so they overlap in
## rows longer than wide like a perched bird's coverts; smoothly with the
## fold (quadratic), and not at all on a spread wing (its shape and wingtip
## are unchanged). Flight and secondary feathers keep their size.
func test_folded_coverts_become_feathers() -> void:
	var stub: Object = rig["player"]
	var k0 := FirstPersonWings.PER_WING
	var rows := {}
	var prev_ratio := -1.0
	for e in [1.0, 0.75, 0.5, 0.25, 0.0]:
		stub.set("wing_state_obj", _WS.new(e, e))
		pose(&"spread")
		settle()
		var worst_ratio := 10.0
		var bad_other := 0.0
		for j in FirstPersonWings.PER_WING:
			var b := wings.feather_transform(k0 + j).basis
			var kind := FirstPersonWings.feather_kind(j)
			var f2: float = (1.0 - e) * (1.0 - e)
			var want_len: float = float(wings._t_len[j])
			var want_wid: float = float(wings._t_wid[j])
			if kind.y == FirstPersonWings.Shape.PLATE:
				want_len *= 1.0 + (FirstPersonWings.COVERT_FOLD_LENGTH - 1.0) * f2
				want_wid *= 1.0 + (FirstPersonWings.COVERT_FOLD_WIDTH - 1.0) * f2
				worst_ratio = minf(worst_ratio, b.x.length() / b.y.length())
			near(b.x.length(), want_len, 1e-5, "e %.2f feather %d: length" % [e, j])
			near(b.y.length(), want_wid, 1e-5, "e %.2f feather %d: width" % [e, j])
		rows["e %.2f" % e] = snappedf(worst_ratio, 0.01)
		check(worst_ratio > prev_ratio, "the plates grow more feather-like as the wing folds (length/width %.2f)" % worst_ratio)
		# Fix round 5: the shader tapers the folded plates' roots (the wrist
		# end seen from the eyes) and outlines their ends by the same law,
		# per wing: fold_lr = ((1 - e_left)^2, (1 - e_right)^2), 0 spread.
		# Read untyped first (fix round 6, engineering verifier): a uniform
		# never set reads null, and a typed assignment then aborted the test
		# with a SCRIPT ERROR the runner still counted as a pass.
		var flv: Variant = wings.material_override.get_shader_parameter("fold_lr")
		if check(flv is Vector2, "e %.2f: the shader's fold_lr uniform is set (%s)" % [e, str(flv)]):
			var fl: Vector2 = flv
			near(fl.x, (1.0 - e) * (1.0 - e), 1e-6, "e %.2f: the shader's fold for the left wing" % e)
			near(fl.y, (1.0 - e) * (1.0 - e), 1e-6, "e %.2f: and for the right wing" % e)
		prev_ratio = worst_ratio
	gt(prev_ratio, 1.4, "folded, every covert is clearly longer than wide (worst length/width %.2f; spread 0.57)" % prev_ratio)
	# Each wing its own: left folded, right spread.
	stub.set("wing_state_obj", _WS.new(0.0, 1.0))
	pose(&"spread")
	settle()
	var f2: Variant = wings.material_override.get_shader_parameter("fold_lr")
	check(f2 is Vector2 and (f2 as Vector2).is_equal_approx(Vector2(1.0, 0.0)), "left folded, right spread: fold_lr %s" % str(f2))
	# The shader reads the left wing as instances 0..PER_WING-1.
	check(FirstPersonWings.SHADER_CODE.contains("INSTANCE_ID < %d" % FirstPersonWings.PER_WING), "the shader splits the wings at PER_WING")
	stub.set("wing_state_obj", null)
	metric("covert_length_over_width", rows)


## WingState look-alike (flight's ext_l / ext_r) for the smoothing test.
class FakeWings:
	extends RefCounted
	var ext_l := 0.6
	var ext_r := 0.6


## The drawn extension is lightly smoothed (τ 0.06 s) so tracker jitter in
## flight's extension never makes the fan shimmer, while a real fold still
## shows within ~0.2 s (mutant R21 removed the smoothing and survived).
## A ±0.05 frame-to-frame jitter moves the drawn wing by at most 0.2 of it
## per frame; a 0.6 -> 0.1 fold reaches 95 % within 0.2 s.
func test_extension_is_smoothed_against_jitter() -> void:
	var fw := FakeWings.new()
	(rig["player"] as Object).set("wing_state_obj", fw)
	pose(&"spread")
	extras.calibration.tick(DT)
	for i in 30:
		wings.update_wings(DT)
	var worst := 0.0
	var prev := wings.extension_shown[0]
	for i in 90:
		fw.ext_l = 0.6 + (0.05 if i % 2 == 0 else -0.05)
		wings.update_wings(DT)
		worst = maxf(worst, absf(wings.extension_shown[0] - prev))
		prev = wings.extension_shown[0]
	lt(worst, 0.2 * 0.10, "jitter of 0.10 frame to frame moves the drawn wing by %.4f per frame" % worst)
	near(wings.extension_shown[0], 0.6, 0.02, "it shows the mean")
	fw.ext_l = 0.1
	var t95 := -1.0
	for i in 60:
		wings.update_wings(DT)
		if t95 < 0.0 and wings.extension_shown[0] <= 0.1 + 0.05 * 0.5:
			t95 = (i + 1) * DT
	between(t95, 0.05, 0.2, "a real fold shows within 0.2 s (95 %% after %.3f s)" % t95)
	metric("extension_smoothing", {"jitter_step_per_frame": worst, "fold_95_s": t95})
	(rig["player"] as Object).set("wing_state_obj", null)


func test_species_tint() -> void:
	var p := rig["player"] as Bird
	var cols: Array = []
	for s in SizeRules.SPECIES:
		p.mass = float(s["mass"])
		p.species = s["id"]
		wings.update_wings(DT)
		eq(wings.species_shown, s["id"], "wings follow the player's species (%s)" % s["id"])
		near(wings.species_blend(), DT / 0.8, 1e-4, "tier change cross-fades (starts at 0)")
		cols.append(_look(s["id"]))
		for i in int(1.0 / DT):
			wings.update_wings(DT)
		eq(wings.species_blend(), 1.0, "fade complete within 1 s")
	# The species cue is "my wings look like that bird's": the player's
	# colours are the NPC palette of the same species (the birds contract:
	# BirdModels.wing_palette, ARCHITECTURE "birds" additions).
	var npc_ok := FirstPersonWings._npc_wing_palette(&"sparrow")
	if npc_ok.is_empty():
		print("[vr] BirdModels unavailable: palette checked against the fallback copy only")
	else:
		var worst_npc := 0.0
		for sp in SizeRules.SPECIES:
			var npc := FirstPersonWings._npc_wing_palette(sp["id"])
			var mine := FirstPersonWings.wing_colors(sp["id"])
			for k in FirstPersonWings.PALETTE_KEYS:
				worst_npc = maxf(worst_npc, _cdist(mine[k], npc[k]))
		lt(worst_npc, 0.01, "every colour is the NPC wing palette of the same species (worst %.4f)" % worst_npc)
		metric("worst_npc_palette_dist", worst_npc)
	# (Whether the fallback copy FirstPersonWings.PALETTE still equals the
	# birds area's current data is a drift report, not a contract: it lives
	# in the on-demand suite tests/sim/birds_palette, fix round 4.)
	# Neighbouring tiers (the eat-or-flee decisions) look different: some
	# visible colour (coverts, flight feathers, primaries, or a worn accent)
	# differs by >= 0.1.
	var worst_adj := 10.0
	var closest := ""
	for i in range(1, cols.size()):
		var d := 0.0
		for g in 4:
			d = maxf(d, _cdist(cols[i][g], cols[i - 1][g]))
		if d < worst_adj:
			worst_adj = d
			closest = "%s/%s" % [SizeRules.SPECIES[i - 1]["id"], SizeRules.SPECIES[i]["id"]]
	gt(worst_adj, 0.1, "neighbouring tiers' wings differ (closest %s %.3f)" % [closest, worst_adj])
	metric("closest_neighbour_tiers", [closest, snappedf(worst_adj, 0.001)])
	p.mass = 0.03
	p.species = &"sparrow"
	for i in int(1.0 / DT):
		wings.update_wings(DT)


## Relaxed hands hold the controllers palms-in: a folded wing then lies
## upper side up along the forearm (visible from the eyes above), not
## edge-on in the hand's vertical plane.
func test_folded_wing_lies_upper_side_up() -> void:
	(rig["player"] as Object).set("wing_state_obj", _WS.new(0.0, 0.0))
	pose(&"held")
	settle()
	var worst_up := 1.0
	for side in 2:
		var f := grip_frame(side)
		lt(absf((f["n"] as Vector3).dot(Vector3.UP)), 0.5, "(setup) side %d: the controller's plane is within 30° of vertical" % side)
		for j in FirstPersonWings.PRIMARIES.size():
			var n := wings.feather_transform(side * FirstPersonWings.PER_WING + j).basis.y.normalized()
			worst_up = minf(worst_up, n.dot(Vector3.UP))
	gt(worst_up, 0.75, "folded primaries face up (worst cos %.2f to vertical)" % worst_up)
	(rig["player"] as Object).set("wing_state_obj", null)


## The folded wing never pops (fix round 3, both verifiers): round 2's
## level turn was switched by a hard gate, so a 1° wrist roll or elbow bend
## across it flipped a folded wing by 50-80° and tracker noise at the gate
## made it flicker. Sweeps the relaxed-hands wrist roll through a full turn,
## the hanging arm's elbow, the arm lowering to vertical and the elbow of a
## hand coming to the shoulder, at extensions 0 and 0.3, in 0.5° steps: no
## feather's plane or direction turns more than 4° per degree of input.
## Then ±0.3° of tracker noise held at the old gates and at the sweep's own
## worst point never turns a feather more than 3° between frames.
func test_folded_wing_turns_continuously() -> void:
	var h := puppet.human
	var stub: Object = rig["player"]
	var rows := {}
	var sweeps := {
		"held: wrist roll": [func() -> void: h.set_arms(deg_to_rad(-68.0), deg_to_rad(8.0), 0.0, deg_to_rad(95.0)),
			func(x: float) -> void: h.twist = [x, x], -180.0, 180.0],
		"hanging: elbow": [func() -> void: h.set_arms(deg_to_rad(-85.0)),
			func(x: float) -> void: h.elbow = [x, x], 0.0, 140.0],
		"lowering: arm to vertical": [func() -> void: h.set_arms(0.0, 0.0, 0.0, deg_to_rad(30.0)),
			func(x: float) -> void: h.dihedral = [x, x], -90.0, 20.0],
		"hand to the shoulder: elbow": [func() -> void: h.set_arms(deg_to_rad(-20.0), deg_to_rad(10.0)),
			func(x: float) -> void: h.elbow = [x, x], 100.0, 178.0],
		"raised arm: wrist roll": [func() -> void: h.set_arms(deg_to_rad(60.0), 0.0, 0.0, deg_to_rad(40.0)),
			func(x: float) -> void: h.twist = [x, x], -180.0, 180.0],
	}
	var worst_all := 0.0
	var worst_at := {}
	for e in [0.0, 0.3]:
		stub.set("wing_state_obj", _WS.new(e, e))
		for tag in sweeps:
			var sw: Array = sweeps[tag]
			(sw[0] as Callable).call()
			var prev: Array[Transform3D] = []
			var worst := 0.0
			var at := 0.0
			var x: float = sw[2]
			while x <= float(sw[3]) + 1e-6:
				(sw[1] as Callable).call(deg_to_rad(x))
				var cur := _layout()
				if not prev.is_empty():
					var d := _max_turn(prev, cur) / 0.5
					if d > worst:
						worst = d
						at = x
				prev = cur
				x += 0.5
			var key := "%s, ext %.1f" % [tag, e]
			rows[key] = {"worst_deg_per_deg": snappedf(worst, 0.01), "at_deg": at}
			worst_at[key] = at
			worst_all = maxf(worst_all, worst)
			lt(worst, 4.0, "%s: a 1° change turns no feather more than 4° (worst %.2f°/° at %.1f°)" % [key, worst, at])
	metric("fold_continuity_deg_per_deg", rows)
	# Tracker noise held still at the round-2 gates (34° of wrist roll on
	# relaxed hands, 11° of elbow on hanging arms) and at the worst point.
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var noise := {}
	stub.set("wing_state_obj", _WS.new(0.0, 0.0))
	for c in [["held: wrist roll", 33.5], ["hanging: elbow", 10.5], ["held: wrist roll", float(worst_at["held: wrist roll, ext 0.0"])],
			["hanging: elbow", float(worst_at["hanging: elbow, ext 0.0"])]]:
		var sw: Array = sweeps[c[0]]
		(sw[0] as Callable).call()
		var prev: Array[Transform3D] = []
		var worst := 0.0
		for i in 90:
			(sw[1] as Callable).call(deg_to_rad(float(c[1]) + rng.randf_range(-0.3, 0.3)))
			var cur := _layout()
			if not prev.is_empty():
				worst = maxf(worst, _max_turn(prev, cur))
			prev = cur
		var key := "%s at %.1f°" % [c[0], c[1]]
		noise[key] = snappedf(worst, 0.01)
		lt(worst, 3.0, "%s with ±0.3° noise: no feather turns > 3° between frames (worst %.2f°)" % [key, worst])
	metric("fold_noise_worst_deg_per_frame", noise)
	stub.set("wing_state_obj", null)
	pose(&"spread")
	settle()


## A palm-up folded hand keeps its own plane: turning a wing that faces
## straight down "towards level" could go either way round, so the level
## turn fades to nothing there (the round-2 guard, now continuous; mutant
## E31 dropped it and survived). The wrist rolls through palm-up; where the
## controller's wing normal is most nearly opposite to level, the folded
## wing is drawn in the hand's own plane.
func test_palm_up_fold_keeps_the_hands_plane() -> void:
	var h := puppet.human
	var stub: Object = rig["player"]
	stub.set("wing_state_obj", _WS.new(0.0, 0.0))
	var most := {}
	for side in 2:
		most[side] = [0.0, 0.0, 0.0]
	for deg in range(130, 231):
		h.set_arms(deg_to_rad(-30.0), 0.0, deg_to_rad(float(deg)), deg_to_rad(30.0))
		puppet.apply()
		settle()
		for side in 2:
			# The frame swung to the arm's line; the level turn then acts on it.
			var f := aligned(grip_frame(side), 0.0)
			var o: Vector3 = f["o"]
			var level := (Vector3.UP - o * o.dot(Vector3.UP)).normalized()
			var ang := rad_to_deg((f["n"] as Vector3).angle_to(level))
			var n := wings.feather_transform(side * FirstPersonWings.PER_WING).basis.y.normalized()
			var off := rad_to_deg(n.angle_to(f["n"]))
			if ang > float(most[side][0]):
				most[side] = [ang, float(deg), off]
	for side in 2:
		gt(float(most[side][0]), 175.0, "(setup) side %d: the roll passes palm-up (hand normal %.1f° from level)" % [side, most[side][0]])
		lt(float(most[side][2]), 1.0, "side %d palm up (%.1f° from level at %d° of roll): the folded wing stays in the hand's plane (%.2f°)" % [side,
			most[side][0], int(most[side][1]), most[side][2]])
	metric("palm_up_most_opposite", most)
	stub.set("wing_state_obj", null)
	pose(&"spread")
	settle()


func _layout() -> Array[Transform3D]:
	puppet.apply()
	extras.calibration.tick(DT)
	wings.update_wings(1.0)
	var out: Array[Transform3D] = []
	for k in FirstPersonWings.PER_WING * 2:
		out.append(wings.feather_transform(k))
	return out


## The most any feather's plane normal or direction turned between two
## layouts (deg).
func _max_turn(a: Array[Transform3D], b: Array[Transform3D]) -> float:
	var worst := 0.0
	for k in a.size():
		for ax in [1, 0]:
			var va: Vector3 = a[k].basis[ax]
			var vb: Vector3 = b[k].basis[ax]
			if va.length() < 1e-4 or vb.length() < 1e-4:
				continue
			worst = maxf(worst, rad_to_deg(va.normalized().angle_to(vb.normalized())))
	return worst


func test_untracked_wing_hides() -> void:
	pose(&"spread")
	settle()
	# The left controller loses tracking (the calibrator's validity is what
	# the rig reports per hand: XRNode3D.get_has_tracking_data in VR).
	var cal := extras.calibration.calibrator
	cal.measure(cal.head, cal.hands[0], cal.hands[1], 1 | 4, DT)
	wings.update_wings(1.0)
	lt(wings.feather_transform(0).basis.x.length(), 1e-3, "left wing collapsed while its controller is lost")
	gt(wings.feather_transform(FirstPersonWings.PER_WING).basis.x.length(), 0.1, "right wing still drawn")
	settle()
	gt(wings.feather_transform(0).basis.x.length(), 0.1, "left wing back")


## What the shader actually gets (fix round 2: the tint test compared
## wing_colors() with the palette it returns, so reversed palette rows or
## primaries drawn in the covert colour passed): the palette texture's row
## for each species (SizeRules order) holds that species' NPC colours, the
## species uniform points at the player's row, every feather instance
## carries its group, and each group samples the palette column its name
## says (primaries the primaries, coverts the coverts, both surfaces).
func test_palette_reaches_the_shader() -> void:
	var mat := wings.material_override as ShaderMaterial
	var img := (mat.get_shader_parameter("palette") as Texture2D).get_image()
	eq(img.get_size(), Vector2i(FirstPersonWings.PALETTE_KEYS.size(), SizeRules.SPECIES.size()), "one row per species, one column per palette key")
	var worst := 0.0
	for sp in SizeRules.SPECIES:
		var id: StringName = sp["id"]
		var row := SizeRules.species_index(id)
		var want := FirstPersonWings.wing_colors(id)
		for c in FirstPersonWings.PALETTE_KEYS.size():
			worst = maxf(worst, _cdist(img.get_pixel(c, row), want[FirstPersonWings.PALETTE_KEYS[c]]))
		near(img.get_pixel(5, row).a, float(FirstPersonWings.ACCENT_AT.get(id, 0)) / 4.0, 0.01, "%s: accent placement in the alpha" % id)
	lt(worst, 0.005, "row species_index(sp) holds that species' wing palette (worst %.4f)" % worst)
	var p := rig["player"] as Bird
	for id in [&"crow", &"sparrow"]:
		p.species = id
		p.mass = SizeRules.SPECIES[SizeRules.species_index(id)]["mass"]
		for i in int(1.0 / DT):
			wings.update_wings(DT)
		eq(int(mat.get_shader_parameter("species_b")), SizeRules.species_index(id), "the shader draws %s's row" % id)
	var top: PackedInt32Array = mat.get_shader_parameter("group_top")
	var under: PackedInt32Array = mat.get_shader_parameter("group_under")
	var keys := FirstPersonWings.PALETTE_KEYS
	var G := FirstPersonWings.Group
	var want_cols := {
		G.PRIMARY: ["upper_primaries", "under_flight"], G.SECONDARY: ["upper_flight", "under_flight"],
		G.GREATER_COVERT: ["upper_coverts", "under_coverts"], G.LESSER_COVERT: ["upper_coverts", "under_coverts"],
		G.PRIMARY_COVERT: ["upper_coverts", "under_coverts"],
	}
	for g in want_cols:
		eq(keys[top[g]], want_cols[g][0], "group %d upper surface samples %s" % [g, want_cols[g][0]])
		eq(keys[under[g]], want_cols[g][1], "group %d underside samples %s" % [g, want_cols[g][1]])
	# The per-instance custom data as given to the renderer (the wings keep
	# a copy: headless rendering keeps none to read back).
	var bad := 0
	for k in FirstPersonWings.PER_WING * 2:
		if int(round(wings.feather_custom(k).r)) != FirstPersonWings.feather_kind(k % FirstPersonWings.PER_WING).x:
			bad += 1
	eq(bad, 0, "every feather instance carries its group")
	eq(FirstPersonWings.feather_kind(0).x, G.PRIMARY, "instance 0 is the leading primary")


func test_one_draw_call_and_ui_occluder() -> void:
	check(wings is MultiMeshInstance3D, "one MultiMesh for both wings")
	eq(wings.multimesh.mesh.get_surface_count(), 1, "one surface")
	check(wings.material_override is ShaderMaterial, "one material")
	eq(wings.multimesh.instance_count, FirstPersonWings.PER_WING * 2, "every feather of both wings in it")
	eq(wings.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "no shadow pass")
	var tris: int = FirstPersonWings.FEATHER_TRIS * wings.multimesh.instance_count
	lt(float(tris), 1000.0, "under 1000 triangles (%d)" % tris)
	metric("triangles", tris)
	var code := (wings.material_override as ShaderMaterial).shader.code
	check(code.contains("stencil_mode write, compare_always, 64"), "wings write the UI occluder stencil (64)")
	for c in (rig["origin"] as Node).get_children():
		if c is GeometryInstance3D and c != wings:
			fail("unexpected extra geometry under the rig: %s" % c.name)


class _WS:
	extends RefCounted
	var ext_l := 1.0
	var ext_r := 1.0

	func _init(l: float, r: float) -> void:
		ext_l = l
		ext_r = r


func test_still_pose_costs_nothing() -> void:
	pose(&"glide")
	settle()
	var u := wings.updates
	var s := wings.skipped
	for i in 10:
		extras.calibration.tick(DT)
		wings.update_wings(DT)
	eq(wings.updates, u, "a still pose re-lays no feathers")
	eq(wings.skipped, s + 10, "ten frames skipped")
	puppet.human.twist = [0.0, deg_to_rad(5.0)]
	puppet.apply()
	settle()
	eq(wings.updates, u + 1, "a moved wrist re-lays them")


## Fix round 5 (the layout's cost): the fan (each feather's transform in
## its frame) depends on the extension only and is rebuilt only when that
## changes; the arms moving at a held extension re-lay the wings from the
## cached fan. (Round 4 keyed its cache on a 32-bit copy of the 64-bit
## extension, which never matched: the fan was rebuilt every frame.)
func test_a_held_extension_rebuilds_no_fan() -> void:
	var stub: Object = rig["player"]
	stub.set("wing_state_obj", _WS.new(0.6, 0.6))
	pose(&"glide")
	settle()
	settle()
	eq(wings.extension_shown[0], 0.6, "(setup) the drawn extension arrived at flight's 0.6 exactly")
	var builds := wings.local_builds
	var u := wings.updates
	for i in 10:
		puppet.human.twist = [deg_to_rad(2.0 * (i + 1)), deg_to_rad(-2.0 * (i + 1))]
		puppet.apply()
		extras.calibration.tick(DT)
		wings.update_wings(DT)
	eq(wings.updates, u + 10, "the wrists moved: ten re-layouts")
	eq(wings.local_builds, builds, "at a held extension: no fan rebuilt")
	stub.set("wing_state_obj", _WS.new(0.3, 0.6))
	settle()
	eq(wings.local_builds, builds + 1, "a new extension on one wing rebuilds that wing's fan only")
	stub.set("wing_state_obj", null)
	puppet.human.twist = [0.0, 0.0]
	pose(&"spread")
	settle()


## The skip key covers everything the layout reads: a shoulder move with
## dx + 3 dy + 7 dz = 0, or a change in a basis component the old 3-of-9
## key ignored, must still re-lay the feathers.
func test_relayout_key_is_complete() -> void:
	pose(&"glide")
	settle()
	var cal := extras.calibration.calibrator
	var u := wings.updates
	var s0: Vector3 = cal.shoulders[0]
	cal.shoulders[0] = s0 + Vector3(0.07, 0.0, -0.01)
	wings.update_wings(DT)
	eq(wings.updates, u + 1, "a shoulder move invisible to x + 3y + 7z re-lays the wings")
	cal.shoulders[0] = s0
	wings.update_wings(DT)
	var h: Transform3D = cal.hands[1]
	cal.hands[1] = Transform3D(h.basis * Basis(Vector3.FORWARD, 1e-3), h.origin)
	u = wings.updates
	wings.update_wings(DT)
	eq(wings.updates, u + 1, "a hand-basis change re-lays the wings")
	cal.hands[1] = h
	wings.update_wings(DT)


## What a species' upper wing shows: coverts, flight feathers, primaries,
## and the accent where it is worn (else the flight colour it sits on).
func _look(sp: StringName) -> Array:
	var c := FirstPersonWings.wing_colors(sp)
	var acc: Color = c["accent"] if int(FirstPersonWings.ACCENT_AT.get(sp, 0)) > 0 else c["upper_flight"]
	return [c["upper_coverts"], c["upper_flight"], c["upper_primaries"], acc]


func _cdist(a: Color, b: Color) -> float:
	return Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length()


## Every feather basis is right-handed (the front face, the upper-surface
## palette, stays on top) and, on a level spread wing, its normal points up.
func test_feathers_are_right_handed_and_upper_side_up() -> void:
	pose(&"spread")
	settle()
	var worst_up := 1.0
	var bad := 0
	for k in FirstPersonWings.PER_WING * 2:
		var b := wings.feather_transform(k).basis
		if b.determinant() <= 0.0:
			bad += 1
		worst_up = minf(worst_up, b.y.normalized().dot(Vector3.UP))
	eq(bad, 0, "no mirrored feather (determinant > 0 for all 60)")
	gt(worst_up, 0.8, "level spread: every feather's upper surface faces up (worst cos %.2f)" % worst_up)
