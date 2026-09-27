extends TestCase
## V7: growth through world_scale. The target follows the bird's span
## (exact wing-to-hand size cue), changes ramp smoothly in log space at
## <= 0.25 ln/s (grow and shrink), hold while paused, drive the camera near
## plane (WorldScaleDriver.NEAR_K x world_scale, >= 1 mm; 0.06 since integration
## round 1, near_plane_test), and nothing ever node-scales the rig:
## every frame of a growth ramp with all VR extras running, the camera,
## controllers, XROrigin3D and every ancestor keep unit scale.

const Env := preload("res://scenes/dev/vr_dev_env.gd")
const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const StubPlayer := preload("res://scenes/dev/vr_stub_player.gd")
const DT := 1.0 / 90.0

var sparrow := 0.03
var pigeon := 0.3
var eagle := 3.0


func make_driver() -> Array:
	var origin := XROrigin3D.new()
	var cam := XRCamera3D.new()
	origin.add_child(cam)
	add_child(origin)
	var d := WorldScaleDriver.new()
	d.auto_step = false
	d.origin = origin
	d.camera = cam
	d.arm_span_override = 1.5
	d.exponent_override = 1.0
	add_child(d)
	return [d, origin, cam]


func cleanup(parts: Array) -> void:
	for p in parts:
		(p as Node).queue_free()
	XRServer.world_scale = 1.0


# -----------------------------------------------------------------------------

func test_target_matches_the_real_span() -> void:
	near(WorldScaleDriver.target_scale(sparrow, 1.5), 0.24 / 1.7, 1e-6, "sparrow: 0.24 m span over 1.7 m of wings")
	near(WorldScaleDriver.target_scale(eagle, 1.5), 2.10 / 1.7, 1e-6, "eagle: 2.1 m")
	near(WorldScaleDriver.target_scale(pigeon, 1.9), 0.66 / 2.1, 1e-6, "a bigger player gets a smaller scale (their arms are longer)")
	near(WorldScaleDriver.target_scale(sparrow, 1.5, 0.8), pow(0.24 / 1.7, 0.8), 1e-6, "exponent option")
	near(WorldScaleDriver.near_for(1.0), 0.06, 1e-9, "near 6 cm at human scale (integration round 1: 3 cm before)")
	near(WorldScaleDriver.near_for(0.15), 0.009, 1e-9, "near scales with the bird")
	near(WorldScaleDriver.near_for(0.01), 0.001, 1e-9, "near never below 1 mm")


func test_growth_ramps_smoothly() -> void:
	var parts := make_driver()
	var d: WorldScaleDriver = parts[0]
	var origin: XROrigin3D = parts[1]
	var cam: XRCamera3D = parts[2]
	d.mass_override = sparrow
	d.snap()
	near(d.world_scale, 0.24 / 1.7, 1e-6, "spawn: snapped, no ramp from 1.0")
	d.mass_override = eagle
	var prev := d.world_scale
	var worst_rate := 0.0
	var t := 0.0
	var reached := -1.0
	var samples: Array = []
	for i in int(12.0 / DT):
		d.step(DT)
		t += DT
		var rate := absf(log(d.world_scale) - log(prev)) / DT
		worst_rate = maxf(worst_rate, rate)
		if d.world_scale < prev - 1e-12:
			fail("ws shrank while growing at t=%.2f" % t)
		if absf(origin.world_scale - d.world_scale) > 1e-6:
			fail("origin.world_scale out of sync at t=%.2f" % t)
		if absf(cam.near - WorldScaleDriver.near_for(d.world_scale)) > 1e-7:
			fail("camera near not following at t=%.2f" % t)
		if reached < 0.0 and absf(d.world_scale - d.target) < 1e-6:
			reached = t
		if i % 45 == 0:
			samples.append([snappedf(t, 0.01), snappedf(d.world_scale, 0.0001)])
		prev = d.world_scale
	# The brief's "smooth" as numbers (not the implementation's constant, so
	# a faster MAX_RATE fails here): <= 0.25 ln/s, so sparrow -> eagle
	# (x8.75) takes at least ln(8.75)/0.25 = 8.68 s.
	lt(worst_rate, 0.25 + 1e-6, "never faster than 0.25 ln/s; monotonic, in sync, near plane followed (no failures above)")
	gt(reached, 8.6, "sparrow -> eagle takes >= 8.6 s (%.2f s)" % reached)
	near(reached, log(8.75) / 0.25, 2.0 * DT, "and arrives at ln(8.75)/0.25 = 8.68 s, not later")
	near(d.world_scale, 2.1 / 1.7, 1e-6, "arrives exactly")
	metric("ramp_samples", samples)
	metric("worst_rate_ln_per_s", worst_rate)
	# Shrinking (losing mass when caught) ramps the same way.
	d.mass_override = pigeon
	prev = d.world_scale
	worst_rate = 0.0
	for i in int(6.0 / DT):
		d.step(DT)
		worst_rate = maxf(worst_rate, absf(log(d.world_scale) - log(prev)) / DT)
		if d.world_scale > prev + 1e-12:
			fail("ws grew while shrinking")
		prev = d.world_scale
	lt(worst_rate, 0.25 + 1e-6, "shrinking also <= 0.25 ln/s")
	near(d.world_scale, 0.66 / 1.7, 1e-6, "arrives at the pigeon scale")
	cleanup(parts)


## A new body is not growth: after an eagle run the next run starts at
## sparrow size at once (GameLoop resets the mass, then run_started;
## PlayerBird.respawn emits player_spawned), not after 8.7 s of the world
## inflating. Growth within a run still ramps.
func test_new_run_and_respawn_snap() -> void:
	var p: Bird = StubPlayer.new()
	p.mass = eagle
	add_child(p)
	var parts := make_driver()
	var d: WorldScaleDriver = parts[0]
	d.mass_override = -1.0
	d.step(DT)
	near(d.world_scale, 2.1 / 1.7, 1e-6, "first size: eagle, no ramp")
	p.mass = sparrow
	Events.run_started.emit()
	d.step(DT)
	near(d.world_scale, 0.24 / 1.7, 1e-6, "new run: sparrow at once")
	near((parts[1] as XROrigin3D).world_scale, 0.24 / 1.7, 1e-6, "origin follows")
	near((parts[2] as Camera3D).near, WorldScaleDriver.NEAR_K * 0.24 / 1.7, 1e-7, "near plane follows")
	# Growth in play ramps.
	p.mass = pigeon
	d.step(DT)
	lt(d.world_scale, 0.24 / 1.7 * exp(0.25 * DT) + 1e-9, "growth in play still ramps")
	# Caught -> respawned as a pigeon (the size the run continues with).
	p.mass = pigeon
	Events.player_spawned.emit(p)
	near(d.world_scale, 0.66 / 1.7, 1e-6, "respawn: new size at once")
	remove_child(p)
	p.free()
	cleanup(parts)


## The rig can exist before the PlayerBird (spawn order, dev scenes): with
## no player the scale is left alone, and the first real size is applied
## at once, never ramped from 1.0.
func test_first_size_is_not_ramped_from_one() -> void:
	var parts := make_driver()
	var d: WorldScaleDriver = parts[0]
	d.mass_override = -1.0
	check(Birds.player() == null, "no player yet")
	for i in 10:
		d.step(DT)
	eq((parts[1] as XROrigin3D).world_scale, 1.0, "no player: scale untouched")
	near((parts[2] as Camera3D).near, WorldScaleDriver.NEAR_K, 1e-7, "near plane still matches the scale")
	var p: Bird = StubPlayer.new()
	p.mass = sparrow
	add_child(p)
	d.step(DT)
	near(d.world_scale, 0.24 / 1.7, 1e-6, "first player size applied in one tick")
	remove_child(p)
	p.free()
	cleanup(parts)


## GameLoop may set the new run's mass AFTER emitting run_started (and a
## respawn's after player_spawned): the first physics tick after the signal
## snaps again instead of ramping from the old body's scale.
func test_mass_set_after_the_signal_still_snaps() -> void:
	var p: Bird = StubPlayer.new()
	p.mass = eagle
	add_child(p)
	var parts := make_driver()
	var d: WorldScaleDriver = parts[0]
	d.mass_override = -1.0
	d.auto_step = true
	d.set_physics_process(false)
	d._physics_process(DT)
	near(d.world_scale, 2.1 / 1.7, 1e-6, "(setup) an eagle")
	Events.run_started.emit()
	p.mass = sparrow
	d._physics_process(DT)
	near(d.world_scale, 0.24 / 1.7, 1e-6, "mass reset after run_started: sparrow on the next tick, no 8.7 s shrink")
	p.mass = pigeon
	Events.player_spawned.emit(p)
	p.mass = eagle
	d._physics_process(DT)
	near(d.world_scale, 2.1 / 1.7, 1e-6, "mass set after player_spawned: snapped on the next tick")
	p.mass = pigeon
	d._physics_process(DT)
	lt(d.world_scale, 2.1 / 1.7, "then growth ramps again")
	gt(d.world_scale, 2.1 / 1.7 * exp(-0.25 * DT) - 1e-9, "at <= 0.25 ln/s")
	remove_child(p)
	p.free()
	cleanup(parts)


## Records origin.world_scale from a default-priority physics node, as
## PlayerBird's tick reads it to offset the rig.
class ScaleReader:
	extends Node
	var origin: XROrigin3D
	var seen: Array[float] = []

	func _physics_process(_dt: float) -> void:
		seen.append(origin.world_scale)


## The driver runs before PlayerBird in each physics frame, so the rig
## offset PlayerBird computes that tick already uses the new scale (the
## camera stays on the body during a ramp). The reader sits BEFORE the
## driver in the tree, so only the physics priority can order them.
func test_scale_is_applied_before_the_player_tick() -> void:
	var origin := XROrigin3D.new()
	add_child(origin)
	var reader := ScaleReader.new()
	reader.origin = origin
	add_child(reader)
	var d := WorldScaleDriver.new()
	d.origin = origin
	d.arm_span_override = 1.5
	d.exponent_override = 1.0
	d.mass_override = sparrow
	add_child(d)
	await wait_physics(2)
	d.mass_override = eagle
	var mismatches := 0
	var frames := 0
	for i in 20:
		await get_tree().physics_frame
		frames += 1
		# XRServer keeps world_scale as a 32-bit float; one ramp tick moves it
		# by ~4e-3 relative, so 1e-6 separates "this frame" from "last frame".
		if reader.seen.is_empty() or absf(reader.seen.back() / d.world_scale - 1.0) > 1e-6:
			mismatches += 1
	gt(d.world_scale, 0.24 / 1.7 * exp(0.2 * frames / Engine.physics_ticks_per_second), "(setup) the scale was ramping")
	eq(mismatches, 0, "in every physics frame the player-priority node saw that frame's world_scale")
	reader.queue_free()
	d.queue_free()
	origin.queue_free()
	await wait_frames(1)
	XRServer.world_scale = 1.0


## world_scale_exponent is the player's setting, read through the settings
## source production uses (clamped to 0.5..1).
func test_exponent_is_read_from_settings() -> void:
	var parts := make_driver()
	var d: WorldScaleDriver = parts[0]
	var store := MemoryStore.new()
	d.store = store
	d.exponent_override = -1.0
	d.mass_override = sparrow
	store.set_value("world_scale_exponent", 0.8)
	d.snap()
	near(d.world_scale, pow(0.24 / 1.7, 0.8), 1e-6, "Settings exponent 0.8")
	store.set_value("world_scale_exponent", 0.2)
	d.snap()
	near(d.world_scale, pow(0.24 / 1.7, 0.5), 1e-6, "clamped to 0.5")
	store.set_value("world_scale_exponent", 1.0)
	d.snap()
	near(d.world_scale, 0.24 / 1.7, 1e-6, "1.0: the true size")
	cleanup(parts)


## Corrupt inputs never reach the rig (fix round 3, a verifier's probe: a
## NaN world_scale_exponent made world_scale and the near plane NaN for
## every mass): a non-finite exponent reads as 1.0, a non-finite mass or
## span as no player / the default span, and world_scale and the near
## plane stay finite and positive through snaps and ramps.
func test_corrupt_settings_never_reach_the_rig() -> void:
	var parts := make_driver()
	var d: WorldScaleDriver = parts[0]
	var origin: XROrigin3D = parts[1]
	var cam: Camera3D = parts[2]
	var store := MemoryStore.new()
	d.store = store
	d.exponent_override = -1.0
	d.mass_override = sparrow
	for bad in [NAN, INF, -INF]:
		store.set_value("world_scale_exponent", bad)
		eq(d.exponent(), 1.0, "exponent %s reads as 1.0" % str(bad))
		d.snap()
		near(d.world_scale, 0.24 / 1.7, 1e-6, "exponent %s: the true size" % str(bad))
		d.mass_override = eagle
		for i in 30:
			d.step(DT)
		check(is_finite(origin.world_scale) and origin.world_scale > 0.0, "exponent %s: world_scale finite while ramping (%f)" % [str(bad), origin.world_scale])
		check(is_finite(cam.near) and cam.near > 0.0, "exponent %s: near plane finite (%f)" % [str(bad), cam.near])
		d.mass_override = sparrow
	store.set_value("world_scale_exponent", 1.0)
	for bad in [NAN, INF]:
		for t in [WorldScaleDriver.target_scale(bad, 1.5), WorldScaleDriver.target_scale(sparrow, bad), WorldScaleDriver.target_scale(sparrow, 1.5, bad)]:
			between(t, WorldScaleDriver.SCALE_MIN, WorldScaleDriver.SCALE_MAX, "target_scale with a %s input stays a sane scale (%f)" % [str(bad), t])
	# A corrupt calibration dict keeps the default span (and so a sane scale).
	var cal := WingCalibrator.new()
	cal.from_dict({"arm_span": NAN, "shoulder_drop": INF, "calibrated": true})
	near(cal.arm_span, 1.5, 1e-6, "NaN arm_span in the saved dict: default kept")
	near(cal.shoulder_drop, 0.24, 1e-6, "INF shoulder_drop: default kept")
	cleanup(parts)


func test_paused_holds_the_scale() -> void:
	var parts := make_driver()
	var d: WorldScaleDriver = parts[0]
	d.mass_override = sparrow
	d.snap()
	d.mass_override = eagle
	d.step(DT)
	var held := d.world_scale
	get_tree().paused = true
	for i in 90:
		d.step(DT)
	eq(d.world_scale, held, "paused: no growth (PlayerBird does not re-seat the camera while paused)")
	get_tree().paused = false
	d.step(DT)
	gt(d.world_scale, held, "resumes after unpause")
	cleanup(parts)


## world_scale is VR's (ARCHITECTURE "vr — additive"): a steady scale is
## re-asserted the next tick if something else writes the origin's
## world_scale or the camera's near plane (a stray flight or dev-scene
## write; mutant R02 dropped the re-assert and survived).
func test_a_foreign_write_is_corrected() -> void:
	var parts := make_driver()
	var d: WorldScaleDriver = parts[0]
	var origin: XROrigin3D = parts[1]
	var cam: XRCamera3D = parts[2]
	d.mass_override = sparrow
	d.snap()
	for i in 5:
		d.step(DT)
	var steady := d.world_scale
	origin.world_scale = 1.0
	cam.near = 0.05
	d.step(DT)
	near(origin.world_scale, steady, 1e-6, "a foreign world_scale write is undone within a tick")
	near(cam.near, WorldScaleDriver.near_for(steady), 1e-7, "and the near plane follows")
	cam.near = 0.05
	d.step(DT)
	near(cam.near, WorldScaleDriver.near_for(steady), 1e-7, "a foreign near-plane write alone is undone too")
	cleanup(parts)


func test_calibrated_span_feeds_the_scale() -> void:
	var parts := make_driver()
	var d: WorldScaleDriver = parts[0]
	var cal := VRCalibration.new()
	cal.store = MemoryStore.new()
	cal.auto_tick = false
	add_child(cal)
	cal.calibrator.arm_span = 1.9
	d.calibration = cal
	d.arm_span_override = -1.0
	d.mass_override = pigeon
	d.snap()
	near(d.world_scale, 0.66 / 2.1, 1e-6, "arm span from the calibration")
	cal.queue_free()
	cleanup(parts)


## Scale of a node's local transform (1 = unscaled).
func node_scale_err(n: Node3D) -> float:
	var b := n.transform.basis
	return maxf(absf(b.x.length() - 1.0), maxf(absf(b.y.length() - 1.0), absf(b.z.length() - 1.0)))


func test_nothing_ever_node_scales_the_rig() -> void:
	var rig := Env.build_rig(self, Vector3(0, 5, 0), MemoryStore.new(), true, false)
	var puppet: VRPosePuppet = rig["puppet"]
	puppet.gesture = &"cycle"
	puppet.speed = 4.0
	var p := rig["player"] as Bird
	p.mass = sparrow
	await wait_frames(3)
	var extras: VRRigExtras = rig["extras"]
	extras.vignette.setting_override = 1.0
	var origin: XROrigin3D = rig["origin"]
	var watched: Array[Node3D] = [rig["camera"], rig["left"], rig["right"], origin]
	var n := origin.get_parent()
	while n != null:
		if n is Node3D:
			watched.append(n)
		n = n.get_parent()
	var worst := 0.0
	var worst_near := 0.0
	var frames := 0
	p.mass = eagle
	for i in 150:
		# The flight stand-in yaws and moves the body (translation + yaw only).
		(rig["player"] as Node3D).rotate_y(0.02)
		(rig["player"] as Node3D).position += Vector3(0.05, 0, -0.1)
		await get_tree().physics_frame
		frames += 1
		for w in watched:
			worst = maxf(worst, node_scale_err(w))
		worst_near = maxf(worst_near, absf((rig["camera"] as Camera3D).near - WorldScaleDriver.near_for(origin.world_scale)))
		if not origin.transform.basis.is_equal_approx(Basis.IDENTITY):
			fail("XROrigin3D local basis must stay identity (yaw lives on the player)")
			break
	lt(worst, 1e-5, "camera, controllers, origin and every ancestor: unit scale on all %d frames" % frames)
	lt(worst_near, 1e-6, "near plane followed world_scale every frame")
	gt(origin.world_scale, 0.24 / 1.7 + 0.01, "the rig grew meanwhile (world_scale %.3f)" % origin.world_scale)
	metric("frames_checked", frames)
	(rig["player"] as Node).queue_free()
	puppet.queue_free()
	await wait_frames(1)
	XRServer.world_scale = 1.0
