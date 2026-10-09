extends Node3D
## The flight lab (FLIGHT_SPEC §13, §14.4): the real player rig on the
## FlightCourse with rings, the window wall, poles and wires, perches and a
## thermal column, flown by desktop keys, the bot, a headset or the
## simulator, with an on-screen telemetry overlay.
##
##   tools/gd.sh flight --rendering-method forward_plus res://scenes/dev/flight_dev.tscn \
##       -- [--pose=desktop|bot|novice|xr|hybrid|script:course] [--species=sparrow]
##          [--quit_after=<s>] [--view=chase|eye|side] [--labshot=5,15] [--probe_axes]
##          [--simdrive]
##   tools/xr.sh 40 res://scenes/dev/flight_dev.tscn -- --pose=script:course --labshot=5,15,25
##   tests/shots/flight_sim_run.sh   (SIM-05: --pose=xr --simdrive, the simulator's
##                                    own controllers moved by its keybindings)
##
## --labshot captures the head view (flight's own mirror, artifacts/flight/
## xr_<prefix>_<s>s.png). --probe_axes (XR) prints SIM-01 / SIM-04: the aim
## vs grip convention of the controllers, the world_scale split between
## node origins and raw tracker poses, and WingInput's wrist twist against
## the twist computed straight from the raw tracker basis.
##
## Poses: desktop (keys, mouse, pad), bot (the autopilot moving virtual
## arms), novice (the bot with human noise), xr (headset controllers),
## hybrid / script:course (XR head, the bot's arms: the simulator's fixed
## controllers cannot fly). Default: xr when a runtime is active, else desktop.
##
## Keys: C camera (chase / eye / side), Tab overlay, R restart at the course
## start, B toggle bot, PgUp/PgDn next/previous species (growth through the
## mass setter), T thermal on/off, right mouse: capture the mouse for look,
## Esc release the mouse / quit. Flight keys: see DesktopPoseSource.

const PLAYER := preload("res://scenes/player/player.tscn")
const LabWorld := preload("res://scenes/dev/flight_dev_world.gd")
const LabBird := preload("res://scenes/dev/flight_dev_bird.gd")
const LabMirror := preload("res://scenes/dev/flight_dev_mirror.gd")
const LabWings := preload("res://scenes/dev/flight_dev_wings.gd")
const LabSimDrive := preload("res://scenes/dev/flight_dev_simdrive.gd")
const SPECIES: Array[StringName] = [&"sparrow", &"swallow", &"starling", &"pigeon", &"crow", &"gull", &"hawk", &"eagle"]

var world: World
var course: FlightCourse
var player: PlayerBird
var pilot: FlightAutopilot
var bot: BotPoseSource
var bird_visual: Node3D
var fp_wings: MeshInstance3D
var chase: Camera3D
var overlay: Label
var overlay_panel: PanelContainer
## Defaults (user args override them; a shots script sets them before
## adding the lab to the tree).
@export var pose_kind := ""
@export var species := &"sparrow"
@export var view := ""
var _t := 0.0
var _quit_after := -1.0
var _overlay_t := 0.0
var _print_t := 0.0
var _chase_pos := Vector3.ZERO
var _chase_init := false
var _probe := false
var _grow_at := -1.0
var _grow_to := &""
var _cam_err_max := 0.0
var _cam_err_at := -1.0
var _cam_err_s := 0.0
var _xrdiag := false
var _probe_done := {}
var _modes_seen: PackedStringArray = []
var _max_bank := 0.0
var _simdrive := false


func _ready() -> void:
	var args := Paths.user_args()
	species = StringName(args.get("species", String(species)))
	if not SPECIES.has(species):
		species = &"sparrow"
	var vr_active: bool = has_node(^"/root/VR") and bool(get_node(^"/root/VR").get("active"))
	if pose_kind.is_empty():
		pose_kind = "xr" if vr_active else "desktop"
	pose_kind = args.get("pose", pose_kind)
	if view.is_empty():
		view = "eye" if vr_active else "chase"
	view = args.get("view", view)
	_quit_after = float(args.get("quit_after", "-1"))
	_probe = args.has("probe_axes")
	# SIM-03: growth mid-flight through the mass setter (--grow_at=<s> --grow_to=<species>).
	_grow_at = float(args.get("grow_at", "-1"))
	_grow_to = StringName(args.get("grow_to", "pigeon"))
	_simdrive = args.has("simdrive")
	_xrdiag = args.has("xrdiag")
	_build_world()
	_build_player()
	_build_cameras()
	_build_overlay()
	var mirror := LabMirror.new()
	mirror.name = "LabMirror"
	mirror.source = player.camera
	add_child(mirror)
	if _simdrive:
		var sd := LabSimDrive.new()
		sd.name = "LabSimDrive"
		sd.player = player
		sd.mirror = mirror
		add_child(sd)
	_restart()
	print("[flight] lab: species %s, pose %s, view %s, xr %s" % [species, pose_kind, view, vr_active])


func _build_world() -> void:
	course = FlightCourse.new(FlightParams.species_mass(species))
	var w := LabWorld.new()
	w.name = "LabWorld"
	w.course = course
	world = w
	add_child(w)
	course.build(w, true, true)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color8(92, 150, 214)
	sm.sky_horizon_color = Color8(196, 214, 226)
	sm.ground_horizon_color = Color8(170, 186, 160)
	sm.ground_bottom_color = Color8(110, 130, 96)
	sky.sky_material = sm
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.8
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.fog_enabled = true
	e.fog_light_color = Color8(196, 212, 224)
	e.fog_density = 0.0012
	e.fog_sky_affect = 0.0
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, 38.0, 0.0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 250.0
	add_child(sun)


func _build_player() -> void:
	player = PLAYER.instantiate() as PlayerBird
	player.mass = FlightParams.species_mass(species)
	player.default_source = &"none"
	# The lab runs without the VR area's WorldScaleDriver: flight drives it.
	player.drive_world_scale = true
	player.log_interval = 1.0
	add_child(player)
	bird_visual = LabBird.new()
	bird_visual.name = "LabBird"
	bird_visual.player = player
	add_child(bird_visual)
	fp_wings = LabWings.new()
	fp_wings.name = "LabWings"
	fp_wings.player = player
	add_child(fp_wings)
	_set_pose(pose_kind)


func _set_pose(kind: String) -> void:
	pose_kind = kind
	pilot = null
	bot = null
	match kind:
		"bot", "novice", "hybrid", "script:course":
			pilot = FlightAutopilot.new(player.model.params, course)
			var pl := player
			bot = BotPoseSource.new(pilot, func() -> Dictionary:
				return {"pos": pl.model.position, "vel": pl.model.velocity, "airspeed": pl.model.airspeed()}, 21)
			bot.calibration = player.wing_input.calibration
			bot.set_novice(kind == "novice")
			if kind == "hybrid" or kind == "script:course":
				var xr := XRPoseSource.new(player.origin, player.camera, player.left_hand, player.right_hand)
				player.set_pose_source(HybridPoseSource.new(xr, bot))
			else:
				player.set_pose_source(bot)
		"xr":
			var xs := XRPoseSource.new(player.origin, player.camera, player.left_hand, player.right_hand)
			xs.frame_timing = true
			player.set_pose_source(xs)
		_:
			pose_kind = "desktop"
			player.set_pose_source(DesktopPoseSource.new())


func _restart() -> void:
	course.setup(FlightParams.species_mass(species))
	if pilot != null:
		_set_pose(pose_kind)
	# SIM-05 flies straight and high for a minute, clear of the course.
	var at := course.start.origin + (Vector3.UP * 130.0 if _simdrive else Vector3.ZERO)
	player.start_flying(at, 0.0, 0.0)
	_chase_init = false


func _build_cameras() -> void:
	chase = Camera3D.new()
	chase.name = "ChaseCamera"
	chase.fov = 70.0
	chase.near = 0.01
	chase.far = 3000.0
	add_child(chase)
	_apply_view()


func _apply_view() -> void:
	var vr_active: bool = has_node(^"/root/VR") and bool(get_node(^"/root/VR").get("active"))
	if vr_active:
		# The headset shows the XR camera; the chase camera would be unused.
		bird_visual.visible = false
		fp_wings.visible = true
		return
	if view == "eye":
		player.camera.current = true
		bird_visual.visible = false
		fp_wings.visible = true
	else:
		chase.current = true
		bird_visual.visible = true
		fp_wings.visible = false
	# The overlay names the view: refresh it now (screenshots freeze time,
	# and the 0.1 s refresh would still show the previous view).
	if overlay != null and overlay_panel != null and overlay_panel.visible:
		overlay.text = _overlay_text()


func _build_overlay() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	overlay_panel = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.06, 0.08, 0.62)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	sb.corner_radius_top_left = 6
	sb.corner_radius_top_right = 6
	sb.corner_radius_bottom_left = 6
	sb.corner_radius_bottom_right = 6
	overlay_panel.add_theme_stylebox_override("panel", sb)
	overlay_panel.position = Vector2(12, 12)
	layer.add_child(overlay_panel)
	overlay = Label.new()
	overlay.add_theme_font_size_override("font_size", 13)
	overlay.add_theme_color_override("font_color", Color(0.95, 0.96, 0.93))
	overlay_panel.add_child(overlay)


func _process(delta: float) -> void:
	_t += delta
	if _quit_after > 0.0 and _t >= _quit_after:
		print("[flight] lab quit after %.1f s" % _t)
		_quit_after = -1.0
		get_tree().quit()
	_update_chase(delta)
	_overlay_t -= delta
	if _overlay_t <= 0.0 and overlay_panel.visible:
		_overlay_t = 0.1
		overlay.text = _overlay_text()
	var md: String = player.telemetry()["mode"]
	if _modes_seen.is_empty() or _modes_seen[_modes_seen.size() - 1] != md:
		_modes_seen.append(md)
		print("[flight] lab modes: %s" % " -> ".join(_modes_seen))
	_max_bank = maxf(_max_bank, absf(rad_to_deg(player.model.phi)))
	if _grow_at > 0.0 and _t >= _grow_at:
		_grow_at = -1.0
		species = _grow_to
		player.mass = FlightParams.species_mass(_grow_to)
		if pilot != null:
			pilot.set_params(player.model.params)
		print("[flight] lab growth -> %s (%.3f kg)" % [_grow_to, player.mass])
	# Only while the runtime tracks the head: before the session shows a
	# frame (and on tracking loss) the XR camera node is not driven, and
	# nothing is displayed from it (fix round 5; the rig itself is checked on
	# every tick by the unit suite's comfort monitor).
	if player.mode == PlayerBird.Mode.FLYING and player.frame.head_valid:
		# The camera is the body: eye = model position + heave offset.
		var want := player.model.position + player.view_offset()
		# In XR the XR server writes the camera at render time (a later head
		# sample than the physics tick); the check holds for a still head.
		# A head re-localization (the runtime's first poses at session start)
		# shows here for the 0.25 s WingInput's tracker gate holds the jump
		# before the body follows the view: reported per second, with the
		# time of the worst, so a startup transient is not read as a lasting
		# error (round 3 verifier: "cam_err_max 1040 mm from the first frame").
		var e := player.camera.global_position.distance_to(want)
		_cam_err_s = maxf(_cam_err_s, e)
		if e > _cam_err_max:
			_cam_err_max = e
			_cam_err_at = _t
		if _xrdiag and _t < 1.5:
			print("[flight] lab xrdiag t=%.3f head(tracking) %s gate-held head %s cam-body %.1f mm ws %.3f pose_dt %.4f" % [_t,
				(player.camera.position / maxf(player.origin.world_scale, 1e-4)).snapped(Vector3.ONE * 0.001),
				player.wing_input.head.origin.snapped(Vector3.ONE * 0.001), e * 1000.0, player.origin.world_scale, player.frame.pose_dt])
	elif _xrdiag and _t < 1.5:
		print("[flight] lab xrdiag t=%.3f head not tracked yet (mode %s)" % [_t, player.mode_name()])
	_print_t -= delta
	if _print_t <= 0.0:
		_print_t = 1.0
		var cam_b := player.camera.global_basis
		# The rig never pitches or rolls: the camera's tilt is the head's own.
		var head_tilt := rad_to_deg(asin(clampf(cam_b.x.normalized().y, -1.0, 1.0)))
		var origin_tilt := rad_to_deg(acos(clampf(player.origin.global_basis.y.normalized().dot(Vector3.UP), -1.0, 1.0)))
		print("[flight] lab t=%.0f fps=%d bank=%.0f max_bank=%.0f origin_tilt=%.3f cam_roll=%.2f phase=%s ws=%.3f tick=%.2fms cam_err=%.1fmm (this second; worst %.1fmm at t=%.2f)" % [
			_t, Engine.get_frames_per_second(), rad_to_deg(player.model.phi), _max_bank, origin_tilt, head_tilt,
			pilot.phase_name() if pilot != null else "-", player.origin.world_scale, player.tick_us / 1000.0, _cam_err_s * 1000.0,
			_cam_err_max * 1000.0, _cam_err_at])
		_cam_err_s = 0.0
	if _probe:
		for at in [3.0, 8.0]:
			if _t >= at and not _probe_done.has(at):
				_probe_done[at] = true
				_probe_axes()


func _update_chase(delta: float) -> void:
	if player == null or player.model == null:
		return
	var m := player.model
	var sp := m.params.span
	var fwd := FlightMath.yaw_forward(m.heading())
	var target := m.position
	var want := Vector3.ZERO
	# Distances in spans (plus a little): a sparrow and an eagle fill the
	# same part of the frame, at least ~10 % of its width (fix round 5: 4
	# spans + 0.3 m left a sparrow a sliver of a few pixels in a turn).
	if view == "side":
		var right := Vector3(-fwd.z, 0.0, fwd.x)
		want = target + right * (3.0 * sp + 0.05) + Vector3.UP * (0.5 * sp + 0.02) - fwd * (0.8 * sp)
	else:
		want = target - fwd * (2.8 * sp + 0.05) + Vector3.UP * (0.7 * sp + 0.02)
	if not _chase_init:
		_chase_pos = want
		_chase_init = true
	_chase_pos = _chase_pos.lerp(want, 1.0 - exp(-delta / 0.25))
	chase.global_position = _chase_pos
	if _chase_pos.distance_to(target) > 1e-3:
		chase.look_at(target + fwd * sp, Vector3.UP)


func _overlay_text() -> String:
	var t := player.telemetry()
	var p := player.model.params
	var s := PackedStringArray()
	s.append("FLIGHT LAB   %s  (%.0f g, span %.2f m)   pose: %s   view: %s" % [species, p.mass * 1000.0, p.span, pose_kind, view])
	s.append("mode %-9s  airspeed %5.1f m/s (%.2f V_c)  vz %+5.1f  AGL %6.1f m" % [t["mode"], t["airspeed"], t["speed_ratio"], t["vertical_speed"], t["altitude_agl"]])
	s.append("bank %+5.0f deg  pitch %+5.0f deg  aoa %+5.1f deg  g %4.2f  stall warn %.2f%s" % [rad_to_deg(t["bank"]), rad_to_deg(t["pitch"]),
		rad_to_deg(t["aoa"]), t["g_load"], t["stall_warning"], "  STALL" if t["stalled"] else ""])
	s.append("inputs: pitch %+5.2f  roll %+5.2f  ext %.2f/%.2f  flap %.2f/%.2f  up %.2f/%.2f%s" % [t["pitch_input"], t["roll_input"],
		t["extension_l"], t["extension_r"], t["flap_l"], t["flap_r"], t["up_l"], t["up_r"], "  TUCK" if t["tucked"] else ""])
	s.append("updraft %.1f m/s  endurance %.2f  world scale %.3f  tick %.2f ms  contacts %d" % [t["in_updraft"], t["endurance"],
		t["world_scale"], t["tick_ms"], t["contacts"]])
	if pilot != null:
		s.append("bot: %s, %.0f m along the course" % [pilot.phase_name(), pilot.progress])
	s.append("keys: W/S pitch  A/D roll  Space flap  Q/E one wing  Shift tuck  C camera  B bot  R restart  PgUp/PgDn size  Tab hide")
	return "\n".join(s)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_RIGHT:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if not (event is InputEventKey) or not event.pressed or event.is_echo():
		return
	match (event as InputEventKey).physical_keycode:
		KEY_C:
			view = {"chase": "eye", "eye": "side", "side": "chase"}[view]
			_apply_view()
		KEY_TAB:
			overlay_panel.visible = not overlay_panel.visible
		KEY_R:
			_restart()
		KEY_B:
			_set_pose("desktop" if pilot != null else "bot")
			if pilot != null:
				pilot.progress = 0.0
		KEY_PAGEUP, KEY_PAGEDOWN:
			var i := SPECIES.find(species)
			i = clampi(i + (1 if event.physical_keycode == KEY_PAGEUP else -1), 0, SPECIES.size() - 1)
			species = SPECIES[i]
			# Growth through the mass setter: the model re-derives in the same tick.
			player.mass = FlightParams.species_mass(species)
			if pilot != null:
				pilot.set_params(player.model.params)
		KEY_T:
			var lw := world as LabWorld
			lw.thermal_core = 0.0 if lw.thermal_core > 0.0 else 4.0
		KEY_ESCAPE:
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			else:
				get_tree().quit()


# --- SIM-01 / SIM-04: controller axes in the simulator ---------------------------
func _probe_axes() -> void:
	var ws := player.origin.world_scale
	for i in 2:
		var tracker_name := &"left_hand" if i == 0 else &"right_hand"
		var tr := XRServer.get_tracker(tracker_name) as XRPositionalTracker
		if tr == null:
			print("[flight] SIM-01 %s: no tracker" % tracker_name)
			continue
		var aim := tr.get_pose(&"aim")
		var grip := tr.get_pose(&"grip")
		var dflt := tr.get_pose(&"default")
		if aim == null or grip == null:
			print("[flight] SIM-01 %s: missing aim/grip pose" % tracker_name)
			continue
		# Convention (§3.2): grip = aim * Rx(60 deg); default = aim.
		var rel := aim.transform.basis.inverse() * grip.transform.basis
		var want := Basis(Vector3.RIGHT, deg_to_rad(60.0))
		var err := rad_to_deg((want.inverse() * rel).get_rotation_quaternion().get_angle())
		var err_neg := rad_to_deg((Basis(Vector3.RIGHT, deg_to_rad(-60.0)).inverse() * rel).get_rotation_quaternion().get_angle())
		var d_err := -1.0
		if dflt != null:
			d_err = rad_to_deg((aim.transform.basis.inverse() * dflt.transform.basis).get_rotation_quaternion().get_angle())
		# World scale: node origins scale with it, raw tracker poses do not.
		var node: XRController3D = player.left_hand if i == 0 else player.right_hand
		var raw_o := grip.transform.origin
		var ratio := node.transform.origin.length() / maxf(raw_o.length(), 1e-6)
		var eul := rel.get_euler(EULER_ORDER_XYZ)
		print("[flight] SIM-01 %s: grip vs aim*Rx(+60) %.2f deg (vs Rx(-60) %.2f), aim->grip euler XYZ (%.2f, %.2f, %.2f) deg, default vs aim %.2f deg, node/raw origin %.4f, world_scale %.4f, raw grip %s" % [
			tracker_name, err, err_neg, rad_to_deg(eul.x), rad_to_deg(eul.y), rad_to_deg(eul.z), d_err, ratio, ws, raw_o.snapped(Vector3.ONE * 0.001)])
		# SIM-04: WingInput's twist vs the twist straight from the raw grip basis
		# (body frame from WingInput's own body yaw, the calibrated neutral and
		# forearm axis: the node path and world-scale normalisation checked).
		var wi := player.wing_input
		var cal := wi.calibration
		var r_body := Basis(Vector3.UP, wi.state.body_yaw).inverse() * grip.transform.basis
		var q := (cal.neutral(i).transposed() * r_body).get_rotation_quaternion()
		var al := cal.forearm_axis(i)
		var proj := q.x * al.x + q.y * al.y + q.z * al.z
		var k_side := signf((cal.neutral(i) * al).dot(Vector3(1, 0, 0)))
		if k_side == 0.0:
			k_side = -1.0 if i == 0 else 1.0
		var pred := rad_to_deg(k_side * wrapf(2.0 * atan2(proj, q.w), -PI, PI))
		var got := rad_to_deg(wi.twist_raw[i])
		print("[flight] SIM-04 %s: WingInput twist %.2f deg, predicted from the raw grip %.2f deg, diff %.2f deg (filtered state %.2f)" % [
			tracker_name, got, pred, got - pred, rad_to_deg(wi.state.twist_l if i == 0 else wi.state.twist_r)])
