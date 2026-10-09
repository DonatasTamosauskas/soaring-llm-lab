extends Node3D
## VR area screenshots (desktop renderer; the XR viewport reads back black on
## macOS, and what matters here is what the eye camera sees).
##
##   tools/gd.sh vr --rendering-method forward_plus --resolution 1280x960 res://tests/shots/vr_shots.tscn -- [--only=<prefix>]
##
## Writes artifacts/vr/*.png: first-person wing views per gesture, wrist
## twist, world_scale 0.15 vs 1.3, an outside view of the wings, a species
## contact sheet, the vignette at rest vs in a hard turn, and the manual
## calibration prompt. Each shot prints the numbers it shows.

const Env := preload("res://scenes/dev/vr_dev_env.gd")
const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")

var rig: Dictionary
var extras: VRRigExtras
var puppet: VRPosePuppet
var cam: XRCamera3D
var ext_cam: Camera3D
var player: Bird
var _only := ""
var _turn_rate := 0.0


func _ready() -> void:
	_only = Paths.arg("only", "")
	Env.build_environment(self)
	rig = Env.build_rig(self, Vector3(0, 2.5, 0), MemoryStore.new(), true, false)
	extras = rig["extras"]
	puppet = rig["puppet"]
	cam = rig["camera"]
	player = rig["player"]
	cam.fov = 90.0
	cam.current = true
	ext_cam = Camera3D.new()
	ext_cam.fov = 50.0
	add_child(ext_cam)
	_run.call_deferred()


func _physics_process(dt: float) -> void:
	(rig["player"] as Node3D).rotate_y(_turn_rate * dt)


func _want(name: String) -> bool:
	return _only.is_empty() or name.begins_with(_only)


func _settle(frames: int = 20) -> void:
	for i in frames:
		await get_tree().process_frame


func _shot(name: String) -> Image:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := Paths.artifacts("vr").path_join(name + ".png")
	img.save_png(path)
	print("[vr] shot %s -> %s" % [name, path])
	return img


func _pose(gesture: StringName, yaw_deg: float = 0.0, pitch_deg: float = 0.0) -> void:
	puppet.gesture = gesture
	puppet.look_yaw = deg_to_rad(yaw_deg)
	puppet.look_pitch = deg_to_rad(pitch_deg)
	puppet.t = 0.0
	puppet.speed = 0.0 if gesture != &"flap" else 1.0


func _set_ws(ws: float) -> void:
	# Fix the scale directly (the driver would ramp from the species). The
	# puppet re-seats the head and hands at the new scale on its next frame.
	extras.world_scale_driver.enabled = false
	(rig["origin"] as XROrigin3D).world_scale = ws
	cam.near = WorldScaleDriver.near_for(ws)


func _set_species(id: StringName) -> void:
	var i := SizeRules.species_index(id)
	player.mass = float(SizeRules.SPECIES[i]["mass"])
	player.species = id


func _outside(ws: float, from_dir: Vector3 = Vector3(0, 0.25, -1.0), dist: float = 2.4) -> void:
	var head := cam.global_position
	var fwd := -(rig["player"] as Node3D).global_basis.z
	var right := (rig["player"] as Node3D).global_basis.x
	var d := (fwd * -from_dir.z + Vector3.UP * from_dir.y + right * from_dir.x).normalized()
	ext_cam.near = 0.01 * ws
	ext_cam.global_position = head + d * dist * ws
	ext_cam.look_at(head - Vector3.UP * 0.2 * ws, Vector3.UP if absf(d.y) < 0.95 else fwd)
	ext_cam.current = true


func _run() -> void:
	await _settle(30)
	# Calibrate from a clean spread first (the calibration step, as a player
	# does on first launch).
	_pose(&"spread")
	extras.calibration.start_manual()
	var waited := 0.0
	while not extras.calibration.calibrator.calibrated and waited < 6.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	# Let the confirmation card and glow go before the shots.
	while extras.calibration.flow != VRCalibration.Flow.IDLE and waited < 10.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	await get_tree().create_timer(0.3).timeout
	print("[vr] calibrated=%s after %.2f s span=%.3f" % [str(extras.calibration.calibrator.calibrated), waited, extras.calibration.calibrator.arm_span])
	_set_species(&"sparrow")
	_set_ws(1.0)

	if _want("wings_fp"):
		# (The tuck pose holds the hands under the chin, outside a headset's
		# field of view: it is shown from outside, wings_outside_tuck; the
		# folded wings a player sees are wings_fp_held.)
		var views := [["wings_fp_spread_right", &"spread", -84.0, -18.0], ["wings_fp_spread_left", &"spread", 84.0, -18.0],
			["wings_fp_glide_right", &"glide", -70.0, -38.0],
			["wings_fp_superman", &"superman", 0.0, -12.0], ["wings_fp_bank_right_view", &"bank_right", -40.0, -20.0],
			["wings_fp_twist_up", &"twist_up", -80.0, -20.0], ["wings_fp_twist_down", &"twist_down", -80.0, -20.0],
			["wings_fp_held", &"held", 0.0, -30.0], ["wings_fp_held_right", &"held", -35.0, -45.0]]
		for v in views:
			_pose(v[1], v[2], v[3])
			await _settle(12)
			var cal := extras.calibration.calibrator
			print("[vr]   %s: ext %.2f/%.2f twist %+.1f/%+.1f deg" % [v[0], cal.extension[0], cal.extension[1], rad_to_deg(cal.twist[0]), rad_to_deg(cal.twist[1])])
			await _shot(v[0])

	if _want("wings_fp_sim"):
		# The Meta XR Simulator's fixed controllers (±0.29, 1.4, -0.5),
		# pointing forward, under a head at 1.65 m looking ahead: the pose
		# of every real-controller mirror shot (sim_wings_real_controllers),
		# reproduced here to review the folded wing without the simulator.
		puppet.set_process(false)
		var ws := (rig["origin"] as XROrigin3D).world_scale
		cam.transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 1.65, 0.0) * ws)
		(rig["left"] as Node3D).transform = Transform3D(Basis.IDENTITY, Vector3(-0.29, 1.4, -0.5) * ws)
		(rig["right"] as Node3D).transform = Transform3D(Basis.IDENTITY, Vector3(0.29, 1.4, -0.5) * ws)
		await _settle(20)
		var cal := extras.calibration.calibrator
		print("[vr]   sim controllers: ext %.2f/%.2f" % [cal.extension[0], cal.extension[1]])
		await _shot("wings_fp_sim_controllers")
		_outside(1.0, Vector3(0.6, 0.9, 1.0), 1.6)
		await _settle(4)
		await _shot("wings_outside_sim_controllers")
		cam.current = true
		puppet.set_process(true)
		await _settle(4)

	if _want("wings_ws"):
		for ws in [0.15, 1.3]:
			_set_ws(ws)
			_pose(&"spread", -84.0, -18.0)
			await _settle(40)
			var tip := extras.wings.wingtip(1)
			var hand := rig["right"] as Node3D
			# Along the forearm (the leading primary also sits 3° back).
			var o := (hand.basis * extras.calibration.calibrator.forearm_axis[1]).normalized()
			print("[vr]   ws %.2f: wingtip past the grip along the forearm = %.4f m (want %.4f), extension %.3f" % [ws,
				(tip - hand.position).dot(o), FirstPersonWings.TIP_OVERHANG * ws, extras.wings.extension_shown[1]])
			await _shot("wings_ws_%03d" % int(ws * 100))
		_set_ws(1.0)

	if _want("wings_outside"):
		# An outside view (not what the player sees) to review the shape:
		# from behind and above, like a chase camera, and from the front.
		for g in [[&"spread", "spread"], [&"glide", "glide"], [&"tuck", "tuck"], [&"bank_left", "bank_left"], [&"twist_down", "twist_down"]]:
			_pose(g[0])
			await _settle(10)
			_outside(1.0, Vector3(0.0, 0.75, 1.0), 2.0)
			await _settle(4)
			var m := extras.wings.material_override as ShaderMaterial
			print("[vr]   glow %.2f shader glow %s species %s/%s blend %s" % [extras.wings.glow, str(m.get_shader_parameter("glow")),
				str(m.get_shader_parameter("species_a")), str(m.get_shader_parameter("species_b")), str(m.get_shader_parameter("blend"))])
			await _shot("wings_outside_" + g[1])
		_pose(&"spread")
		_outside(1.0, Vector3(0.0, 0.15, -1.0), 2.0)
		await _settle(6)
		await _shot("wings_outside_front")
		cam.current = true

	if _want("wings_species"):
		var tiles: Array[Image] = []
		_pose(&"spread")
		for s in SizeRules.SPECIES:
			_set_species(s["id"])
			# Let the puppet re-seat the head at the current world_scale first.
			await _settle(3)
			_outside(1.0, Vector3(0.0, 0.8, 1.0), 1.55)
			# The tint cross-fades over 0.8 s.
			await get_tree().create_timer(1.0).timeout
			var img := await _shot("_tmp_species")
			img.resize(320, 240, Image.INTERPOLATE_BILINEAR)
			tiles.append(img)
		_sheet(tiles, 5, "wings_species")
		DirAccess.remove_absolute(Paths.artifacts("vr").path_join("_tmp_species.png"))
		_set_species(&"sparrow")
		cam.current = true

	if _want("vignette"):
		extras.vignette.setting_override = 1.0
		_pose(&"glide", 0.0, -8.0)
		(rig["player"] as Node3D).position = Vector3(6.0, 2.5, -10.0)
		_turn_rate = 0.0
		await get_tree().create_timer(1.0).timeout
		print("[vr]   vignette at rest: %.3f" % extras.vignette.strength())
		await _shot("vignette_rest")
		_turn_rate = deg_to_rad(150.0)
		await get_tree().create_timer(0.8).timeout
		_turn_rate = deg_to_rad(150.0)
		print("[vr]   vignette hard turn: strength %.3f yaw %.0f deg/s" % [extras.vignette.strength(), rad_to_deg(extras.vignette.yaw_rate)])
		await _shot("vignette_turn")
		extras.vignette.setting_override = 0.0
		await get_tree().create_timer(0.3).timeout
		print("[vr]   vignette setting 0: %.3f visible %s" % [extras.vignette.strength(), str(extras.vignette.visible)])
		await _shot("vignette_turn_off")
		_turn_rate = 0.0
		extras.vignette.setting_override = -1.0

	if _want("drawcalls"):
		# What the wings and the vignette cost the renderer, measured.
		_pose(&"spread", -84.0, -18.0)
		extras.vignette.setting_override = 1.0
		_turn_rate = deg_to_rad(200.0)
		await get_tree().create_timer(0.6).timeout
		var counts := {}
		for cfg in [["all", true, true], ["no_wings", false, true], ["no_vignette", true, false], ["neither", false, false]]:
			extras.wings.visible = cfg[1]
			extras.vignette.set_process(cfg[2])
			if not cfg[2]:
				extras.vignette.visible = false
			await _settle(4)
			await RenderingServer.frame_post_draw
			counts[cfg[0]] = {"draw_calls": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
				"primitives": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)}
		extras.wings.visible = true
		extras.vignette.set_process(true)
		_turn_rate = 0.0
		extras.vignette.setting_override = -1.0
		var all_calls: int = counts["all"]["draw_calls"] - counts["neither"]["draw_calls"]
		counts["wings_draw_calls"] = counts["all"]["draw_calls"] - counts["no_wings"]["draw_calls"]
		counts["vignette_draw_calls"] = counts["all"]["draw_calls"] - counts["no_vignette"]["draw_calls"]
		counts["vr_total_draw_calls"] = all_calls
		var f := FileAccess.open(Paths.artifacts("vr").path_join("drawcalls.json"), FileAccess.WRITE)
		f.store_string(JSON.stringify(counts, "  "))
		f.close()
		print("[vr]   draw calls: %s (wings %d, vignette %d)" % [str(counts), counts["wings_draw_calls"], counts["vignette_draw_calls"]])

	if _want("calibration"):
		# The calibration step's card (the only way wrist neutral and arm
		# span are captured): the instruction with its cancel hint, the hint
		# a relaxed pose earns after a second, the ring filling during the
		# hold, the confirmation, and a cancel.
		_pose(&"glide", 0.0, 0.0)
		extras.calibration.start_manual()
		await get_tree().create_timer(0.5).timeout
		print("[vr]   calibration step: %s, hint '%s'" % [str(extras.calibration.status()), extras.calibration.hint_text()])
		await _shot("calibration_prompt_card")
		await get_tree().create_timer(1.2).timeout
		print("[vr]   calibration step, arms relaxed: hint '%s'" % extras.calibration.hint_text())
		await _shot("calibration_prompt_hint")
		_pose(&"spread", 0.0, 0.0)
		await get_tree().create_timer(0.85).timeout
		print("[vr]   calibration step, holding: %s" % str(extras.calibration.status()))
		await _shot("calibration_prompt_holding")
		await get_tree().create_timer(0.9).timeout
		print("[vr]   calibration step, done: %s" % str(extras.calibration.status()))
		await _shot("calibration_prompt_done")
		await get_tree().create_timer(VRCalibration.RESULT_SHOW + 0.3).timeout
		_pose(&"glide", 0.0, 0.0)
		extras.calibration.start_manual()
		await get_tree().create_timer(0.4).timeout
		extras.calibration.cancel()
		await get_tree().create_timer(0.3).timeout
		print("[vr]   calibration step, cancelled: %s" % str(extras.calibration.status()))
		await _shot("calibration_prompt_cancelled")
	print("[vr] shots done")
	get_tree().quit()


func _sheet(tiles: Array[Image], cols: int, name: String) -> void:
	if tiles.is_empty():
		return
	var w := tiles[0].get_width()
	var h := tiles[0].get_height()
	var rows := ceili(float(tiles.size()) / cols)
	var sheet := Image.create(w * cols, h * rows, false, tiles[0].get_format())
	for i in tiles.size():
		sheet.blit_rect(tiles[i], Rect2i(0, 0, w, h), Vector2i((i % cols) * w, (i / cols) * h))
	var path := Paths.artifacts("vr").path_join(name + ".png")
	sheet.save_png(path)
	print("[vr] sheet %s -> %s" % [name, path])
