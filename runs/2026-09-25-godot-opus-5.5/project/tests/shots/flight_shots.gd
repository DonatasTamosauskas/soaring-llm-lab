extends Node
## Flight lab screenshots (the real rig, the bot flying the course):
##
##   tools/gd.sh flight --rendering-method forward_plus --resolution 1280x720 \
##       res://tests/shots/flight_shots.tscn -- [--species=sparrow] [--speed=3]
##
## Writes artifacts/flight/shot_<species>_<view>.png: the lab overview, the
## chase view through a ring, the banked turn, a flapping climb seen from the
## side, the approach to the window seen from beside the facade, the eye
## (first-person) view just before the window, and the landing on the branch
## perch. Quits itself.

const LAB := preload("res://scenes/dev/flight_dev.tscn")

var lab: Node3D
var _out := ""
var _species := &"sparrow"
var _taken := {}
var _busy := false
var _t := 0.0
var _limit := 90.0
var _perched_at := -1.0


func _ready() -> void:
	var args := Paths.user_args()
	_species = StringName(args.get("species", "sparrow"))
	_out = Paths.artifacts("flight")
	Engine.time_scale = float(args.get("speed", "3"))
	lab = LAB.instantiate()
	lab.set("pose_kind", "bot")
	lab.set("species", _species)
	lab.set("view", "chase")
	add_child(lab)
	# One overview from a fixed camera before the flight starts.
	await get_tree().process_frame
	await get_tree().process_frame
	await _overview()


func _process(delta: float) -> void:
	_t += delta
	if _busy or lab == null:
		return
	if _t > _limit:
		_finish()
		return
	var p: PlayerBird = lab.get("player")
	var pilot: FlightAutopilot = lab.get("pilot")
	var c: FlightCourse = lab.get("course")
	if p == null or pilot == null:
		return
	var pos := p.model.position
	var sp := c.span
	# A flapping climb on leg 1, seen from the side.
	if not _taken.has("side_flap") and _t > 2.0 and p.wing_state().flap_l > 0.3:
		_shot("side_flap", "side")
	# Through the second ring (chase).
	# Ring 3 sits on the cruise line the bot flies (the first two are on
	# the desktop climb profile, below the bot's steeper climb).
	elif not _taken.has("chase_ring") and c.rings.size() > 2 and pos.z < c.rings[2].z + 3.0 * sp + 0.6:
		_shot("chase_ring", "chase")
	# The eye view turned to the right wing (what a player sees looking at
	# it): the lab's first-person wing, feathered.
	elif not _taken.has("eye_wing") and _taken.has("chase_ring") and p.wing_state().flap_l < 0.05:
		_shot("eye_wing", "eye", Vector2(-78.0, -14.0))
	# The banked 180 deg turn.
	elif not _taken.has("chase_turn") and absf(rad_to_deg(p.model.phi)) > 25.0 and pos.z < -c.leg_len + 2.0:
		_shot("chase_turn", "chase")
	# The approach to the window seen from beside the facade.
	elif not _taken.has("window_wall") and pilot.phase_name() == "final_glide" \
			and c.window_center.z - pos.z < 9.0 * sp + 1.0 and pos.x > 0.5 * c.offset:
		_shot_fixed("window_wall")
	# Eye view on the final glide, the window just ahead.
	elif not _taken.has("eye_window") and pilot.phase_name() == "final_glide" \
			and c.window_center.z - pos.z < 0.45 * c.v_c and pos.x > 0.5 * c.offset:
		_shot("eye_window", "eye")
	# The landing: just before the grip, from the side.
	elif not _taken.has("side_perch") and pilot.phase_name() == "final" \
			and (pos - c.perch_grip).length() < 1.4 * sp + 0.1:
		_shot("side_perch", "side")
	elif not _taken.has("perched") and p.mode == PlayerBird.Mode.PERCHED:
		# After the 0.15 s capture ease has settled the bird on the branch.
		if _perched_at < 0.0:
			_perched_at = _t
		elif _t - _perched_at > 0.5 * Engine.time_scale:
			_shot_perched("perched")
	elif _taken.size() >= 9:
		_finish()


func _shot(name: String, view: String, look_deg := Vector2.ZERO) -> void:
	_busy = true
	_taken[name] = true
	var prev := Engine.time_scale
	Engine.time_scale = 0.0          # freeze the flight while the view settles
	lab.set("view", view)
	lab.call("_apply_view")
	lab.set("_chase_init", false)
	lab.call("_update_chase", 0.0)
	var turned: Camera3D = null
	var saved := Transform3D.IDENTITY
	if look_deg != Vector2.ZERO:
		# Turn the eye (time is frozen, so no tick overwrites it) to look at
		# a wing: yaw x degrees (- = right), then pitch y degrees.
		turned = get_viewport().get_camera_3d()
		saved = turned.transform
		turned.rotate_object_local(Vector3.UP, deg_to_rad(look_deg.x))
		turned.rotate_object_local(Vector3.RIGHT, deg_to_rad(look_deg.y))
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := _out.path_join("shot_%s_%s.png" % [_species, name])
	img.save_png(path)
	var cam := get_viewport().get_camera_3d()
	var bird: Node3D = lab.get("bird_visual")
	print("[flight] shot %s (%s view) cam %s bird %s dist %.2f visible %s" % [path, view, cam.name if cam else "none",
		bird.global_position.snapped(Vector3.ONE * 0.01), cam.global_position.distance_to(bird.global_position) if cam else -1.0, bird.visible])
	if turned != null:
		turned.transform = saved
	lab.set("view", "chase")
	lab.call("_apply_view")
	Engine.time_scale = prev
	_busy = false


## A fixed camera beside the approach, ahead of the facade: the bird on its
## final glide with the window (and the perch beyond it) in one frame.
func _shot_fixed(name: String) -> void:
	_busy = true
	_taken[name] = true
	var prev := Engine.time_scale
	Engine.time_scale = 0.0
	var c: FlightCourse = lab.get("course")
	var p: PlayerBird = lab.get("player")
	var sp := c.span
	var cam := Camera3D.new()
	cam.fov = 50.0
	cam.near = maxf(0.01, 0.02 * sp)
	cam.far = 3000.0
	lab.add_child(cam)
	var w := c.window_center
	# Behind and to the left of the bird (it flies +Z), looking at the
	# window: the bird large in the foreground, the opening beyond it.
	var b := p.model.position
	cam.global_position = b + Vector3(-2.0 * sp - 0.15, 0.8 * sp + 0.1, -4.0 * sp - 0.3)
	cam.look_at(w.lerp(b, 0.25), Vector3.UP)
	cam.current = true
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var path := _out.path_join("shot_%s_%s.png" % [_species, name])
	get_viewport().get_texture().get_image().save_png(path)
	print("[flight] shot %s (fixed camera, bird %.1f m from the window)" % [path, p.model.position.distance_to(w)])
	cam.queue_free()
	lab.call("_apply_view")
	Engine.time_scale = prev
	_busy = false


## A fixed camera beside and ahead of the perched bird, a little above it:
## the bird on its branch with the wings folded, large in frame.
func _shot_perched(name: String) -> void:
	_busy = true
	_taken[name] = true
	var prev := Engine.time_scale
	Engine.time_scale = 0.0
	var c: FlightCourse = lab.get("course")
	var p: PlayerBird = lab.get("player")
	var sp := c.span
	var cam := Camera3D.new()
	cam.fov = 45.0
	cam.near = maxf(0.005, 0.02 * sp)
	cam.far = 3000.0
	lab.add_child(cam)
	var b := p.model.position
	var fwd := FlightMath.yaw_forward(p.model.heading())
	var rgt := Vector3(-fwd.z, 0.0, fwd.x)
	cam.global_position = b + rgt * 2.0 * sp + fwd * 1.4 * sp + Vector3.UP * 0.7 * sp
	cam.look_at(b + Vector3.DOWN * 0.15 * sp, Vector3.UP)
	cam.current = true
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var path := _out.path_join("shot_%s_%s.png" % [_species, name])
	get_viewport().get_texture().get_image().save_png(path)
	print("[flight] shot %s (fixed camera %.2f m from the perched bird)" % [path, cam.global_position.distance_to(b)])
	cam.queue_free()
	lab.call("_apply_view")
	Engine.time_scale = prev
	_busy = false


func _overview() -> void:
	_busy = true
	_taken["overview"] = true
	var c: FlightCourse = lab.get("course")
	var cam := Camera3D.new()
	cam.fov = 60.0
	cam.far = 4000.0
	lab.add_child(cam)
	# High, behind and to the right of the return leg, looking back up the
	# course: the facade with its window seen at ~40 deg (round 2: a narrow
	# wall seen from far away read as a beige tower with an invisible
	# window), the perch and the poles with wires in front of it, the turn
	# and leg 1 with its ring gates beyond, the thermal column to the left;
	# chevrons on the ground trace the route.
	var L := c.leg_len
	var w := c.window_center
	var look := Vector3(0.35 * c.offset, 5.0, -0.6 * L)
	cam.global_position = Vector3(c.offset + 0.9 * L, 0.5 * L, w.z + 0.75 * L)
	cam.look_at(look, Vector3.UP)
	cam.fov = 50.0
	cam.current = true
	var prev := Engine.time_scale
	Engine.time_scale = 0.0
	var panel: Control = lab.get("overlay_panel")
	panel.visible = false
	# No haze for the overview (the lab's fog is tuned for bird height).
	var env := get_viewport().world_3d.environment
	var fog := env.fog_enabled if env != null else false
	if env != null:
		env.fog_enabled = false
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	if env != null:
		env.fog_enabled = fog
	panel.visible = true
	var path := _out.path_join("shot_%s_overview.png" % _species)
	get_viewport().get_texture().get_image().save_png(path)
	print("[flight] shot %s (overview)" % path)
	cam.queue_free()
	lab.call("_apply_view")
	Engine.time_scale = prev
	_busy = false


func _finish() -> void:
	set_process(false)
	Engine.time_scale = 1.0
	print("[flight] shots done: %s" % str(_taken.keys()))
	get_tree().quit()
