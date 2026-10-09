extends Node3D
## VR area dev scene: a stand-in player rig with the VR extras (calibration,
## first-person wings, comfort vignette, world-scale growth) over a small
## practice field. Works on the desktop (a puppet body moves the "controllers")
## and in the Meta XR Simulator (real head and controllers; add
## -- --puppet to have scripted arms on the real head).
##
##   tools/gd.sh vr --rendering-method forward_plus res://scenes/dev/vr_dev.tscn
##   tools/xr.sh 30 res://scenes/dev/vr_dev.tscn -- --xrdiag --xrshot=8,16 --xrshot_dir=vr --xrshot_prefix=dev
##   tools/xr.sh 25 "--rendering-method forward_plus res://scenes/dev/vr_dev.tscn" -- --puppet --gesture=spread_high --torso_yaw=66 --xrshot=10,18 --xrshot_dir=vr --xrshot_prefix=dev_sim
## --torso_yaw=<deg> (with --puppet in the simulator) turns the scripted
## body under the real head, as a player looking over a shoulder along a
## spread wing (the simulator's head cannot be turned without persisted
## settings); in a forward view spread arms are outside the frame.
## --demo (fix round 6: round 5's two simulator shots were one still pose,
## byte-identical) plays a timeline, one phase per screenshot:
##   0-8 s spread wing (a sparrow)   8-12 s flapping (11.1 s: the top of
##   an upstroke)   12-16 s wrists rolled back (leading edge up), now a
##   gull (another palette, the world shrinking around the bigger bird)
##   16-22 s a fast hard turn (the comfort vignette)
##   tools/xr.sh 24 "--rendering-method forward_plus res://scenes/dev/vr_dev.tscn" -- --puppet --demo --torso_yaw=66 --xrdiag --xrshot=7,11.1,15,20 --xrshot_dir=vr --xrshot_prefix=dev_sim
##
## Desktop keys: 1-9,0 gestures (spread, glide, tuck, flap, bank L, bank R,
## wrists up, wrists down, superman, cycle), arrows: fly (up), stop (down),
## turn (left/right, shows the vignette), PgUp/PgDn: grow/shrink a species,
## C: recalibrate, V: vignette setting 0 / 0.6 / 1, mouse: look, Esc: menu.

const Env := preload("res://scenes/dev/vr_dev_env.gd")

var rig: Dictionary
var extras: VRRigExtras
var puppet: VRPosePuppet
var _label: Label
var _speed := 0.0
var _turn := 0.0
var _species := 2
var _vig_settings := [0.6, 1.0, 0.0]
var _vig_i := 0
var _log_t := 0.0
var _frames := 0
var _automated := false
## --demo timeline: [start s, gesture, forward speed m/s, turn °/s, species
## index or -1 to keep].
const DEMO := [
	[0.0, &"spread_high", 0.0, 0.0, 2],
	[8.0, &"flap", 0.0, 0.0, -1],
	[12.0, &"twist_up", 0.0, 0.0, 7],
	[16.0, &"spread_high", 9.0, -120.0, -1],
]
var _demo := false
var _demo_t := 0.0
var _demo_i := -1


func _ready() -> void:
	var args := Paths.user_args()
	_automated = args.has("autoquit")
	Env.build_environment(self)
	# Automated runs never write the shared settings file.
	rig = Env.build_rig(self, Vector3(0, 2.0, 0), null, true, not _automated)
	extras = rig["extras"]
	puppet = rig["puppet"]
	puppet.gesture = StringName(args.get("gesture", "cycle"))
	puppet.drive_head = not VR.active
	if VR.active and not args.has("puppet"):
		puppet.queue_free()
		puppet = null
	elif args.has("torso_yaw"):
		puppet.torso_yaw_offset = deg_to_rad(float(args["torso_yaw"]))
	_demo = args.has("demo") and puppet != null
	var mirror := XRMirror.new()
	mirror.name = "XRMirror"
	mirror.source = rig["camera"]
	add_child(mirror)
	if not VR.active:
		(rig["camera"] as Camera3D).current = true
		_label = Label.new()
		_label.position = Vector2(12, 10)
		_label.add_theme_font_size_override("font_size", 15)
		_label.add_theme_color_override("font_outline_color", Color.BLACK)
		_label.add_theme_constant_override("outline_size", 4)
		var layer := CanvasLayer.new()
		layer.add_child(_label)
		add_child(layer)
	print("[vr] dev scene ready; vr=%s puppet=%s" % [str(VR.active), str(puppet != null)])


func _unhandled_input(event: InputEvent) -> void:
	if puppet != null and event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		puppet.look_yaw -= event.relative.x * 0.004
		puppet.look_pitch = clampf(puppet.look_pitch - event.relative.y * 0.004, -1.3, 1.3)
	if event is InputEventMouseButton and event.pressed:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var k: Key = event.keycode
	if k >= KEY_0 and k <= KEY_9 and puppet != null:
		var i := 9 if k == KEY_0 else int(k - KEY_1)
		puppet.gesture = VRPosePuppet.GESTURES[clampi(i, 0, VRPosePuppet.GESTURES.size() - 1)]
	match k:
		KEY_UP:
			_speed = 9.0
		KEY_DOWN:
			_speed = 0.0
		KEY_PAGEUP:
			_set_species(_species + 1)
		KEY_PAGEDOWN:
			_set_species(_species - 1)
		KEY_C:
			extras.calibration.start_manual()
		KEY_V:
			_vig_i = (_vig_i + 1) % _vig_settings.size()
			extras.vignette.setting_override = _vig_settings[_vig_i]
		KEY_ESCAPE:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
			Events.menu_requested.emit()


func _set_species(i: int) -> void:
	_species = clampi(i, 0, SizeRules.SPECIES.size() - 1)
	var p := rig["player"] as Bird
	p.mass = float(SizeRules.SPECIES[_species]["mass"])
	p.species = SizeRules.SPECIES[_species]["id"]
	print("[vr] species -> %s" % p.species)


func _physics_process(dt: float) -> void:
	if get_tree().paused:
		return
	# A stand-in for flight: translation and yaw of the player node only.
	var p := rig["player"] as Node3D
	var want := 0.0
	if Input.is_key_pressed(KEY_LEFT):
		want = deg_to_rad(120.0)
	elif Input.is_key_pressed(KEY_RIGHT):
		want = deg_to_rad(-120.0)
	if _demo:
		want = _step_demo(dt)
	_turn = lerpf(_turn, want, VRMath.lp(dt, 0.25))
	p.rotate_y(_turn * dt)
	p.position += -p.global_basis.z * _speed * dt
	if p.position.length() > 70.0:
		p.position = Vector3(0, 2.0, 0)


## Advances the --demo timeline; returns the turn rate it asks for (rad/s).
func _step_demo(dt: float) -> float:
	_demo_t += dt
	var i := 0
	for k in DEMO.size():
		if _demo_t >= float(DEMO[k][0]):
			i = k
	var row: Array = DEMO[i]
	if i != _demo_i:
		_demo_i = i
		puppet.gesture = row[1]
		_speed = float(row[2])
		if int(row[4]) >= 0:
			_set_species(int(row[4]))
		print("[vr] dev demo %.1f s: %s, speed %.0f m/s, turn %.0f°/s" % [_demo_t, row[1], _speed, float(row[3])])
	return deg_to_rad(float(row[3]))


func _process(dt: float) -> void:
	_frames += 1
	_log_t += dt
	var cal := extras.calibration.calibrator
	if _label != null:
		_label.text = "gesture %s   species %s   world_scale %.3f   near %.4f\nextension L %.2f R %.2f   twist L %+.0f° R %+.0f°   calibrated %s  span %.2f m\nvignette %.2f (setting %.1f, yaw %.0f°/s, accel %.1f perceived m/s², proximity %.2f)   %s" % [
			puppet.gesture if puppet else "-", (rig["player"] as Bird).species, extras.world_scale_driver.world_scale,
			(rig["camera"] as Camera3D).near, cal.extension[0], cal.extension[1], rad_to_deg(cal.twist[0]), rad_to_deg(cal.twist[1]),
			str(cal.calibrated), cal.arm_span, extras.vignette.strength(), extras.vignette.setting(),
			rad_to_deg(extras.vignette.yaw_rate), extras.vignette.accel / maxf(extras.world_scale_driver.world_scale, 0.01), extras.vignette.proximity, extras.calibration.prompt_text().replace("\n", " ")]
	if _log_t >= 1.0:
		print("[vr] dev fps=%.0f ws=%.3f ext=%.2f/%.2f vignette=%.2f calibrated=%s" % [_frames / _log_t,
			extras.world_scale_driver.world_scale, cal.extension[0], cal.extension[1], extras.vignette.strength(), str(cal.calibrated)])
		_log_t = 0.0
		_frames = 0
