extends TestCase
## VERIFIER PROBES (vr, round 1 of the independent re-verification,
## experience & requirements lens). Not the builder's tests; they try to
## break the area's claims as a player and a game director would:
##   tools/gd.sh vr_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/vr --suite=r1x_experience
## 1. Bodies beyond the brief's box (spans 1.3 / 2.1 / 2.2 m, wrist habits
##    of +-35 deg, three noise seeds): does the capture still fire and do
##    the gestures read like the reference player's?
## 2. The headset is handed to a second person (Quest Pro shared at home or
##    at a demo): after "headset off / on", does the new wearer's natural
##    still spread while perched give them their own calibration, or do
##    they fly the first wearer's wrist neutral and span?
## 3. Ten minutes of ordinary play (flap bursts, glides, turning, head
##    bobbing, looking down at the hands, one short crouch) through the real
##    VRCalibration service: the calibration must not drift, nothing
##    non-finite, and Settings (a file write per set_value on Quest) is not
##    written during ordinary play.

const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const DT := 1.0 / 72.0

var _rng := RandomNumberGenerator.new()

const GESTURES := {
	"spread": [0.0, 0.0, 0.0, 0.0, 0.0],
	"glide": [-45.0, 0.0, 0.0, 0.0, 40.0],
	"twist_up_20": [-5.0, 0.0, 20.0, 20.0, 10.0],
	"twist_down_20": [-5.0, 0.0, -20.0, -20.0, 10.0],
	"aileron_20": [-5.0, 0.0, 20.0, -20.0, 10.0],
	"arm_raise_40": [40.0, 0.0, 0.0, 0.0, 0.0],
	"half_fold": [-20.0, 0.0, 0.0, 0.0, 105.0],
	"arms_down": [-85.0, 0.0, 0.0, 0.0, 0.0],
}


func before_all() -> void:
	XRServer.world_scale = 1.0


func before_each() -> void:
	_rng.seed = 777
	get_tree().paused = false
	Game.set_state(Game.State.BOOT)


func after_all() -> void:
	get_tree().paused = false
	Game.set_state(Game.State.BOOT)
	VR.focused = false
	VR.user_present = true
	VR.session_state = "none"


func feed(cal: WingCalibrator, h: VRHumanPose, seconds: float, noise_mm: float = 0.5) -> void:
	for i in int(round(seconds / DT)):
		var hd := h.head_transform()
		var l := h.hand_transform(0)
		var r := h.hand_transform(1)
		if noise_mm > 0.0:
			var k := noise_mm * 0.001
			hd.origin += Vector3(_rng.randfn(0, k), _rng.randfn(0, k), _rng.randfn(0, k))
			l.origin += Vector3(_rng.randfn(0, k), _rng.randfn(0, k), _rng.randfn(0, k))
			r.origin += Vector3(_rng.randfn(0, k), _rng.randfn(0, k), _rng.randfn(0, k))
		cal.measure(hd, l, r, 7, DT)


func pose(h: VRHumanPose, g: Array) -> void:
	h.dihedral = [deg_to_rad(g[0]), deg_to_rad(g[0])]
	h.sweep = [deg_to_rad(g[1]), deg_to_rad(g[1])]
	h.twist = [deg_to_rad(g[2]), deg_to_rad(g[3])]
	h.elbow = [deg_to_rad(g[4]), deg_to_rad(g[4])]


func readings(cal: WingCalibrator, h: VRHumanPose) -> Dictionary:
	var out := {}
	for g in GESTURES:
		pose(h, GESTURES[g])
		feed(cal, h, 0.15, 0.0)
		out[g] = [cal.extension[0], cal.extension[1], rad_to_deg(cal.twist[0]), rad_to_deg(cal.twist[1]), cal.pitch_command()]
	return out


func player(span: float, off: Array) -> VRHumanPose:
	var h := VRHumanPose.for_span(span)
	h.twist_offset = [deg_to_rad(off[0]), deg_to_rad(off[1])]
	return h


func calibrated_for(h: VRHumanPose) -> WingCalibrator:
	var cal := WingCalibrator.new()
	cal.auto_capture_allowed = true
	cal.refine_allowed = true
	h.spread_pose()
	feed(cal, h, 2.0)
	return cal


func diff(a: Dictionary, b: Dictionary) -> Dictionary:
	var e := 0.0
	var t := 0.0
	var p := 0.0
	for g in GESTURES:
		var x: Array = a[g]
		var y: Array = b[g]
		e = maxf(e, maxf(absf(x[0] - y[0]), absf(x[1] - y[1])))
		if g != "arms_down":
			t = maxf(t, maxf(absf(x[2] - y[2]), absf(x[3] - y[3])))
			p = maxf(p, absf(x[4] - y[4]))
	return {"ext": e, "twist_deg": t, "pitch": p}


# -----------------------------------------------------------------------------

## 1. Beyond the brief's box: spans 1.3 (a 10-12 year old, Meta's minimum
## age for Quest accounts), 2.1 and 2.2 m, wrist habits of +-35 deg, three
## noise seeds. The brief's own tolerances (0.03 extension, 1 deg twist,
## 0.02 pitch) are the bar; these are outside the brief, so a miss is a
## known-limit note, not a V3 failure.
func test_bodies_beyond_the_brief() -> void:
	var ref := readings(calibrated_for(player(1.6, [0.0, 0.0])), player(1.6, [0.0, 0.0]))
	var rows := {}
	var worst := {"ext": 0.0, "twist_deg": 0.0, "pitch": 0.0}
	var not_captured: Array = []
	for span in [1.3, 2.1, 2.2]:
		for off in [[-35.0, -35.0], [35.0, 35.0], [35.0, -35.0]]:
			for seed in [11, 22, 33]:
				_rng.seed = seed
				var h := player(span, off)
				var cal := calibrated_for(h)
				var tag := "span %.1f habit %s seed %d" % [span, str(off), seed]
				if not cal.calibrated:
					not_captured.append(tag)
					continue
				var d := diff(readings(cal, h), ref)
				rows[tag] = {"ext": snappedf(d["ext"], 0.001), "twist_deg": snappedf(d["twist_deg"], 0.01),
					"pitch": snappedf(d["pitch"], 0.001), "span_measured": snappedf(cal.arm_span, 0.001)}
				for k in worst:
					worst[k] = maxf(worst[k], d[k])
	metric("rows", rows)
	metric("worst", worst)
	metric("not_captured", not_captured)
	print("[vr_verify] beyond the brief: worst %s, not captured %s" % [str(worst), str(not_captured)])
	eq(not_captured.size(), 0, "every body beyond the brief's box is captured by a natural spread")
	lt(worst["ext"], 0.03, "extension agrees with the reference player within 0.03")
	lt(worst["twist_deg"], 1.0, "wrist twist agrees within 1 deg")
	lt(worst["pitch"], 0.02, "pitch command agrees within 0.02")


# -----------------------------------------------------------------------------

func make_service(store: Object) -> Dictionary:
	var origin := XROrigin3D.new()
	var cam := XRCamera3D.new()
	var l := XRController3D.new()
	var r := XRController3D.new()
	origin.add_child(cam)
	origin.add_child(l)
	origin.add_child(r)
	add_child(origin)
	var node := VRCalibration.new()
	node.store = store
	node.auto_tick = false
	node.show_prompt = false
	node.force_valid = true
	# The bird is perched / spawning: a still spread is a deliberate one.
	node.force_auto_allowed = true
	add_child(node)
	node.origin = origin
	node.camera = cam
	node.hands = [l, r]
	return {"origin": origin, "camera": cam, "hands": [l, r], "node": node, "store": store}


func run(rig: Dictionary, h: VRHumanPose, seconds: float, per_tick: Callable = Callable()) -> void:
	for i in int(round(seconds / DT)):
		if per_tick.is_valid():
			per_tick.call(i)
		var k := 0.0005
		var hd := h.head_transform()
		(rig["camera"] as Node3D).transform = Transform3D(hd.basis, hd.origin + Vector3(_rng.randfn(0, k), _rng.randfn(0, k), _rng.randfn(0, k)))
		for s in 2:
			var x := h.hand_transform(s)
			x.origin += Vector3(_rng.randfn(0, k), _rng.randfn(0, k), _rng.randfn(0, k))
			(rig["hands"][s] as Node3D).transform = x
		(rig["node"] as VRCalibration).tick(DT)


func free_service(rig: Dictionary) -> void:
	(rig["node"] as Node).queue_free()
	(rig["origin"] as Node).queue_free()


## What a wearer flies with: flat wrists in a spread glide (twist, pitch
## command) and the half fold's extension.
func wearer_readings(cal: WingCalibrator, rig: Dictionary, h: VRHumanPose) -> Dictionary:
	h.set_arms(deg_to_rad(-5.0), 0.0, 0.0, deg_to_rad(10.0))
	run(rig, h, 0.4)
	var flat := {"twist_l": rad_to_deg(cal.twist[0]), "twist_r": rad_to_deg(cal.twist[1]), "pitch": cal.pitch_command()}
	h.set_arms(deg_to_rad(-20.0), 0.0, 0.0, deg_to_rad(105.0))
	run(rig, h, 0.4)
	flat["half_fold"] = 0.5 * (cal.extension[0] + cal.extension[1])
	h.set_arms(deg_to_rad(-80.0))
	run(rig, h, 0.3)
	return flat


## 2. A second wearer. Wearer A (1.6 m, no wrist habit) is calibrated by the
## automatic capture and it is persisted. The headset comes off and goes on
## a second person B (1.9 m, a +20 deg leading-edge-up wrist habit on both
## hands, i.e. what B calls "flat"). B is perched and holds the natural
## still spread for 3 s, exactly the pose that calibrated A. The brief:
## "Calibration of reach and neutral wrist angle (automatic, with a manual
## recalibrate)". Good means B's flat wrists read a level wing (|pitch
## command| < 0.1) and B's half fold reads like B's own calibration.
func test_second_wearer_after_the_headset_changes_hands() -> void:
	var store := MemoryStore.new()
	var rig := make_service(store)
	var node: VRCalibration = rig["node"]
	var cal := node.calibrator
	var a := VRHumanPose.for_span(1.6)
	a.spread_pose()
	run(rig, a, 2.0)
	check(cal.calibrated, "(setup) wearer A captured automatically")
	var a_span := cal.arm_span
	# The headset changes hands: presence off, then on (the handlers the
	# runtime's user_presence_changed calls).
	VR._on_user_presence_changed(false)
	run(rig, a, 0.5)
	VR._on_user_presence_changed(true)
	var b := VRHumanPose.for_span(1.9)
	b.twist_offset = [deg_to_rad(20.0), deg_to_rad(20.0)]
	b.spread_pose()
	run(rig, b, 3.0)
	b.set_arms(deg_to_rad(-80.0))
	run(rig, b, 0.5)
	var under_a := wearer_readings(cal, rig, b)
	# B's own calibration, for reference (a fresh service, B's capture).
	var own_rig := make_service(MemoryStore.new())
	var b2 := VRHumanPose.for_span(1.9)
	b2.twist_offset = [deg_to_rad(20.0), deg_to_rad(20.0)]
	b2.spread_pose()
	run(own_rig, b2, 2.0)
	var own := wearer_readings((own_rig["node"] as VRCalibration).calibrator, own_rig, b2)
	metric("wearer_A_span", a_span)
	metric("span_after_B_spread", cal.arm_span)
	metric("B_under_A_calibration", under_a)
	metric("B_own_calibration", own)
	print("[vr_verify] second wearer: span %.3f -> %.3f; B under A's calibration %s; B's own %s" % [a_span, cal.arm_span, str(under_a), str(own)])
	lt(absf(float(under_a["pitch"])), 0.1, "B's flat wrists read a level wing (pitch %.3f; B's own calibration %.3f)" % [under_a["pitch"], own["pitch"]])
	near(float(under_a["half_fold"]), float(own["half_fold"]), 0.05, "B's half fold reads like B's own calibration")
	free_service(rig)
	free_service(own_rig)
	VR.user_present = true
	# The reverse: a smaller second wearer (1.45 m, e.g. a child) after a
	# 1.8 m first wearer. Can they still fully spread their wings?
	var rig2 := make_service(MemoryStore.new())
	var cal2 := (rig2["node"] as VRCalibration).calibrator
	var big := VRHumanPose.for_span(1.8)
	big.spread_pose()
	run(rig2, big, 2.0)
	check(cal2.calibrated, "(setup) the 1.8 m wearer captured")
	VR._on_user_presence_changed(false)
	VR._on_user_presence_changed(true)
	var small := VRHumanPose.for_span(1.45)
	small.spread_pose()
	run(rig2, small, 3.0)
	small.set_arms(0.0)
	run(rig2, small, 0.4)
	var full_spread := 0.5 * (cal2.extension[0] + cal2.extension[1])
	metric("small_B_full_spread_under_big_A", full_spread)
	print("[vr_verify] small second wearer: arms fully spread read extension %.3f (span stays %.3f)" % [full_spread, cal2.arm_span])
	gt(full_spread, 0.95, "a smaller second wearer's full spread reads a fully spread wing (got %.3f)" % full_spread)
	free_service(rig2)
	VR.user_present = true


# -----------------------------------------------------------------------------

## 3. Ten minutes of ordinary play through the real service at 72 Hz:
## bursts of flapping (+-30 deg at 1.1 Hz with the head bobbing 4 cm and the
## wrists pitching), glides with aileron turns and the torso turning,
## looking down at the hands for 6 s, a 20 cm crouch for 3 s once a minute.
## The calibration must not drift, everything stays finite and ordinary
## play writes nothing to Settings (each set_value is a file write on the
## headset).
func test_ten_minutes_of_ordinary_play() -> void:
	var store := MemoryStore.new()
	var rig := make_service(store)
	var node: VRCalibration = rig["node"]
	var cal := node.calibrator
	var h := VRHumanPose.for_span(1.7)
	h.twist_offset = [deg_to_rad(8.0), deg_to_rad(8.0)]
	h.spread_pose()
	run(rig, h, 2.0)
	check(cal.calibrated, "(setup) captured")
	h.set_arms(deg_to_rad(-80.0))
	run(rig, h, 0.5)
	var span0 := cal.arm_span
	var n0: Array[Basis] = [cal.neutral[0], cal.neutral[1]]
	var writes0: int = store.writes
	var eye0 := h.eye_height
	# Now in play (the bird flies): no automatic capture, refinement allowed.
	node.force_auto_allowed = false
	Game.set_state(Game.State.PLAYING)
	var st := {"t": 0.0, "ticks": 0, "nonfinite": 0, "seated": 0}
	var t_start := Time.get_ticks_usec()
	for minute in 10:
		var step := func(_i: int) -> void:
			st["t"] += DT
			st["ticks"] += 1
			var ph := fmod(float(st["t"]), 60.0)
			if ph < 20.0:
				# Flap bursts: 4 beats then 3 s gliding, wrists pitching a little.
				var c := fmod(ph, 6.6)
				if c < 3.6:
					h.set_arms(deg_to_rad(-5.0 + 30.0 * sin(TAU * 1.1 * c)), 0.0, deg_to_rad(-10.0), deg_to_rad(15.0))
					h.eye_height = eye0 - 0.04 * (0.5 + 0.5 * sin(TAU * 1.1 * c))
				else:
					h.set_arms(deg_to_rad(-8.0), 0.0, 0.0, deg_to_rad(10.0))
					h.eye_height = eye0
			elif ph < 40.0:
				# Glides with aileron turns and the torso turning with them.
				h.set_arms(deg_to_rad(-10.0), 0.0, 0.0, deg_to_rad(10.0))
				var ail := deg_to_rad(20.0) * sin(TAU * 0.2 * ph)
				h.twist = [ail, -ail]
				h.torso_yaw = deg_to_rad(30.0) * sin(TAU * 0.05 * ph)
				h.eye_height = eye0
			elif ph < 46.0:
				# Looking down at the hands (natural "look at my wings").
				h.set_arms(deg_to_rad(-35.0), deg_to_rad(55.0), 0.0, deg_to_rad(70.0))
				h.head_pitch = deg_to_rad(-35.0)
			elif ph < 49.0:
				# A 20 cm crouch (ducking, a dive's body language).
				h.head_pitch = 0.0
				h.set_arms(deg_to_rad(-60.0), 0.0, 0.0, deg_to_rad(30.0))
				h.eye_height = eye0 - 0.20
			else:
				h.eye_height = eye0
				h.head_pitch = 0.0
				h.torso_yaw = 0.0
				h.set_arms(deg_to_rad(-6.0), 0.0, 0.0, deg_to_rad(8.0))
			if not (is_finite(cal.extension[0]) and is_finite(cal.extension[1]) and is_finite(cal.twist[0]) and is_finite(cal.pitch_command())):
				st["nonfinite"] += 1
			if cal.is_seated():
				st["seated"] += 1
		run(rig, h, 60.0, step)
	var ticks: int = st["ticks"]
	var nonfinite: int = st["nonfinite"]
	var seated_ticks: int = st["seated"]
	var us_per_tick := float(Time.get_ticks_usec() - t_start) / maxf(ticks, 1)
	var neutral_drift := maxf(VRMath.basis_angle(n0[0], cal.neutral[0]), VRMath.basis_angle(n0[1], cal.neutral[1]))
	metric("span_before_after", [span0, cal.arm_span])
	metric("neutral_drift_deg", rad_to_deg(neutral_drift))
	metric("settings_writes_in_play", store.writes - writes0)
	metric("seated_ticks", seated_ticks)
	metric("us_per_tick_incl_pose_synthesis", us_per_tick)
	print("[vr_verify] 10 min play: span %.3f -> %.3f, neutral drift %.3f deg, writes %d, seated ticks %d, %.1f us/tick" % [span0,
		cal.arm_span, rad_to_deg(neutral_drift), store.writes - writes0, seated_ticks, us_per_tick])
	eq(nonfinite, 0, "every reading finite for 10 minutes")
	near(cal.arm_span, span0, 0.005, "the span does not drift in ordinary play")
	lt(rad_to_deg(neutral_drift), 0.01, "the wrist neutral does not drift")
	eq(seated_ticks, 0, "a standing player is never flagged seated by play (flap bob, a 3 s crouch)")
	eq(store.writes - writes0, 0, "ordinary play writes nothing to Settings")
	Game.set_state(Game.State.BOOT)
	free_service(rig)
