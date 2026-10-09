extends TestCase
## Verifier probe (experience lens), V4/V7: situations a player actually
## hits that the area suite does not cover.
##
## - A new run after an eagle run: the player's mass jumps back to sparrow
##   (GameLoop.start_run, Events.run_started / player_spawned). Does the
##   world snap to the new size or visibly inflate 8.75x over ~9 s?
## - The rig attaches before the PlayerBird is registered (dev scenes,
##   spawn order): does the first real size ramp from 1.0?
## - Recenter / respawn are the flight area's only allowed yaw STEPS
##   (PlayerBird sets rig_yaw in one tick). Does the vignette flash?
## - A sustained hard turn then level flight: closes, then fully reopens
##   and the ring hides (no lingering draw call).
## - Extreme world scales (0.05 and 5.0): near plane and wing layout finite.

const Env := preload("res://scenes/dev/vr_dev_env.gd")
const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const StubPlayer := preload("res://scenes/dev/vr_stub_player.gd")
const DT := 1.0 / 72.0


func after_all() -> void:
	XRServer.world_scale = 1.0
	Game.set_state(Game.State.BOOT)
	get_tree().paused = false


func make_driver(parent_origin: XROrigin3D = null) -> Array:
	var origin := parent_origin if parent_origin != null else XROrigin3D.new()
	var cam := XRCamera3D.new()
	origin.add_child(cam)
	if parent_origin == null:
		add_child(origin)
	var d := WorldScaleDriver.new()
	d.auto_step = false
	d.origin = origin
	d.camera = cam
	d.arm_span_override = 1.5
	d.exponent_override = 1.0
	add_child(d)
	return [d, origin, cam]


# -----------------------------------------------------------------------------

## End of an eagle run -> Restart: GameLoop resets the player to START_MASS
## (sparrow) and emits run_started; PlayerBird.respawn emits player_spawned.
func test_new_run_starts_at_the_new_size() -> void:
	await wait_frames(2)
	var p: Bird = StubPlayer.new()
	p.mass = 3.0
	add_child(p)
	var parts := make_driver()
	var d: WorldScaleDriver = parts[0]
	d.snap()
	near(d.world_scale, WorldScaleDriver.target_scale(3.0, 1.5), 1e-6, "eagle size at the end of the run")
	# Restart run.
	p.mass = 0.03
	Events.run_started.emit()
	Events.player_spawned.emit(p)
	var t_settle := -1.0
	var t := 0.0
	for i in int(12.0 / DT):
		d.step(DT)
		t += DT
		if t_settle < 0.0 and absf(log(d.world_scale / d.target)) < 0.01:
			t_settle = t
	metric("new_run_scale_settle_s", t_settle)
	print("[vr-verify] eagle -> new sparrow run: world_scale settles after %.2f s" % t_settle)
	lt(t_settle, 0.5, "a fresh run starts at the right size (settled after %.2f s; the world inflates 8.75x meanwhile)" % t_settle)
	p.queue_free()
	for n in parts:
		(n as Node).queue_free()
	XRServer.world_scale = 1.0


## The extras attach, tick a few times with no player registered yet, then
## the player appears (sparrow): the first size must not ramp from 1.0.
func test_first_size_does_not_ramp_from_one() -> void:
	await wait_frames(2)
	check(Birds.player() == null, "no player registered at the start")
	var parts := make_driver()
	var d: WorldScaleDriver = parts[0]
	for i in 5:
		d.step(DT)   # no Birds.player() yet
	var p: Bird = StubPlayer.new()
	p.mass = 0.03
	add_child(p)
	var t_settle := -1.0
	var t := 0.0
	for i in int(10.0 / DT):
		d.step(DT)
		t += DT
		if t_settle < 0.0 and absf(log(d.world_scale / WorldScaleDriver.target_scale(0.03, 1.5))) < 0.01:
			t_settle = t
	metric("late_player_scale_settle_s", t_settle)
	print("[vr-verify] player registered late: world_scale settles after %.2f s" % t_settle)
	lt(t_settle, 0.5, "late-registered player: size applied at once (settled after %.2f s)" % t_settle)
	p.queue_free()
	for n in parts:
		(n as Node).queue_free()
	XRServer.world_scale = 1.0


func make_vignette_rig() -> Dictionary:
	var body := Node3D.new()
	var origin := XROrigin3D.new()
	var cam := XRCamera3D.new()
	cam.position = Vector3(0, 1.6, 0)
	var v := ComfortVignette.new()
	v.auto_update = false
	cam.add_child(v)
	origin.add_child(cam)
	body.add_child(origin)
	add_child(body)
	v.origin = origin
	v.setting_override = 0.6
	return {"body": body, "origin": origin, "camera": cam, "vignette": v}


func vstep(rig: Dictionary, vel: Vector3, yaw_rate: float) -> void:
	var body := rig["body"] as Node3D
	body.rotate_y(yaw_rate * DT)
	body.position += vel * DT
	(rig["vignette"] as ComfortVignette).measure(DT)
	(rig["vignette"] as ComfortVignette).update_strength(DT)


## A 120° recenter / respawn yaw step in one tick while gliding straight.
func test_yaw_step_does_not_flash_the_vignette() -> void:
	var rig := make_vignette_rig()
	var v: ComfortVignette = rig["vignette"]
	for i in 30:
		vstep(rig, Vector3(0, 0, -8.0), 0.0)
	var body := rig["body"] as Node3D
	body.rotate_y(deg_to_rad(120.0))
	var peak := 0.0
	for i in int(1.5 / DT):
		(rig["vignette"] as ComfortVignette).measure(DT)
		(rig["vignette"] as ComfortVignette).update_strength(DT)
		body.position += -body.global_basis.z * 8.0 * DT
		peak = maxf(peak, v.strength())
	metric("yaw_step_peak_strength", peak)
	print("[vr-verify] 120° yaw step: vignette peak strength %.3f (inner edge %.1f°)" % [peak, ComfortVignette.clear_radius_deg(peak)])
	lt(peak, 0.1, "a flagged yaw step (recenter/respawn) is not a turn: no vignette flash (peak %.3f)" % peak)
	(rig["body"] as Node).queue_free()


func test_hard_turn_then_level_reopens_and_hides() -> void:
	var rig := make_vignette_rig()
	var v: ComfortVignette = rig["vignette"]
	for i in int(1.5 / DT):
		vstep(rig, Vector3.ZERO, deg_to_rad(180.0))
	near(v.strength(), 0.6, 0.02, "sustained 180°/s turn at the default setting 0.6: strength 0.6")
	check(v.visible, "ring drawn while turning")
	var t_open := -1.0
	var t := 0.0
	for i in int(5.0 / DT):
		vstep(rig, Vector3.ZERO, 0.0)
		t += DT
		if t_open < 0.0 and not v.visible:
			t_open = t
	metric("reopen_hidden_after_s", t_open)
	between(t_open, 0.3, 3.5, "view reopens smoothly and the ring hides (%.2f s)" % t_open)
	eq(v.strength(), 0.0, "fully open")
	(rig["body"] as Node).queue_free()


## The extras at the clamp limits of world_scale: everything finite, near
## plane positive, wings exactly 10 cm x ws past the grip.
func test_extreme_world_scales() -> void:
	var rig := Env.build_rig(self, Vector3(0, 5, 0), MemoryStore.new(), true, false)
	(rig["puppet"] as VRPosePuppet).gesture = &"spread"
	var extras := rig["extras"] as VRRigExtras
	await wait_frames(4)
	var d := extras.world_scale_driver
	for ws in [0.05, 5.0]:
		d.enabled = false
		(rig["origin"] as XROrigin3D).world_scale = ws
		(rig["camera"] as Camera3D).near = WorldScaleDriver.near_for(ws)
		await wait_frames(4)
		var w := extras.wings
		var cal := extras.calibration.calibrator
		var ok := true
		for k in 60:
			var tr := w.feather_transform(k)
			ok = ok and tr.origin.is_finite() and tr.basis.x.is_finite()
		check(ok, "all feather transforms finite at ws %.2f" % ws)
		for side in 2:
			var grip: Vector3 = cal.hands[side].origin * ws
			var tip := w.wingtip(side)
			near(tip.distance_to(grip), 0.10 * ws, 0.02 * ws + 1e-4,
				"wingtip ~10 cm x ws past grip at ws %.2f side %d (%.4f)" % [ws, side, tip.distance_to(grip)])
		gt((rig["camera"] as Camera3D).near, 0.0, "near plane positive at ws %.2f" % ws)
	(rig["player"] as Node).queue_free()
	(rig["puppet"] as Node).queue_free()
	XRServer.world_scale = 1.0
