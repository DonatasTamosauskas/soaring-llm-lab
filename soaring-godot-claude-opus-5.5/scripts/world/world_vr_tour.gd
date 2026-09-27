class_name WorldVrTour
extends Node
## Simulator evidence for the world area: moves the XR rig through a few
## vantage points (translation + yaw only, growth via world_scale, never node
## scale) so XRMirror screenshots show the valley through the headset, and
## logs frame rate and render stats every second.
##
##   tools/xr.sh 88 res://scenes/dev/world_vr.tscn -- --xrshot=5,13,21,29,37,45,53,61,69,77 --xrshot_prefix=world_vr --xrshot_dir=world

@export var origin: XROrigin3D
@export var camera: XRCamera3D
@export var stop_seconds := 8.0

var _world: World
var _t := 0.0
var _stop := -1
var _log_t := 0.0
## [name, origin position (feet), look-at target, world_scale]
var _stops: Array = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _build_stops() -> void:
	var w := _world
	var spawn := w.get_player_spawn()
	_stops.append(["spawn_roof_sparrow", spawn.origin, spawn.origin - spawn.basis.z * 30.0 + Vector3(0, -3, 0), 0.15])
	for p in w.get_perches():
		if p.kind == Perch.Kind.WIRE and p.district == &"powerline":
			_stops.append(["wire_sparrow", p.position, p.position + Vector3(40, -2, -8), 0.15])
			break
	# A nest box on its trunk at sparrow scale (the batten, the hole).
	var sw := w as SoaringWorld
	for o in sw.get_openings() if sw else []:
		if String(o["name"]) == "nest_box_4":
			var bp: Vector3 = o["position"]
			var bn: Vector3 = o["normal"]
			var side := Vector3.UP.cross(bn).normalized()
			_stops.append(["nest_box_sparrow", bp + bn * 1.1 + side * 0.5 - Vector3.UP * 0.2, bp, 0.15])
			break
	# Inside the old wood at sparrow scale, 3 m up, looking into the glade.
	var fc := WorldLayout.FOREST + Vector2(25, 25)
	var glade: Vector2 = WorldLayout.THERMALS[7]["pos"]
	_stops.append(["old_wood_sparrow", Vector3(fc.x, w.ground_height(fc.x, fc.y) + 3.0, fc.y), Vector3(glade.x, w.ground_height(glade.x, glade.y) + 6.0, glade.y), 0.2])
	# Skimming the canopy from the wood's south-west rim (the round-2
	# verifiers' heaviest view), crow scale.
	var rim := WorldLayout.FOREST + Vector2(-15, -73)
	_stops.append(["old_wood_canopy_crow", Vector3(rim.x, w.ground_height(rim.x, rim.y) + 16.0, rim.y),
		Vector3(WorldLayout.FOREST.x + 30, 14.0, WorldLayout.FOREST.y + 40), 0.6])
	_stops.append(["village_street", Vector3(-205, 5.0, 31), Vector3(-60, 5, 29), 1.0])
	# The swallow colony from 25 m (how the bed sits in the cliff) and from
	# 6 m, at swallow scale.
	for o in (w as SoaringWorld).get_openings() if w is SoaringWorld else []:
		if o["type"] == "cliff_hole" and String(o["name"]) == "cliff_hole_12":
			var p: Vector3 = o["position"]
			var n: Vector3 = o["normal"]
			_stops.append(["cliff_colony_25m", p + n * 25.0 + Vector3(0, -3.0, 6.0), p, 0.4])
			_stops.append(["cliff_colony_swallow", p + n * 6.0 - Vector3.UP * 1.0, p, 0.25])
			break
	# An eagle's shelf up the west cliff, at eagle scale, from the air.
	var shelf: Perch = null
	for p in w.get_perches():
		if p.kind == Perch.Kind.LEDGE and p.district == &"cliff" and p.max_span >= 2.0 and \
				(shelf == null or p.position.distance_to(Vector3(-454, 45, 48.5)) < shelf.position.distance_to(Vector3(-454, 45, 48.5))):
			shelf = p
	if shelf:
		var lat := Vector3.UP.cross(shelf.facing).normalized()
		_stops.append(["cliff_shelf_eagle", shelf.position + shelf.facing * 7.0 + lat * 3.0 - Vector3.UP * 1.5, shelf.position, 1.3])
	_stops.append(["over_valley", Vector3(-150, 120, 260), Vector3(150, 20, -100), 1.0])


func _process(delta: float) -> void:
	if _world == null:
		_world = World.find(get_tree())
		if _world == null or not _world.is_generated:
			return
		_build_stops()
	_t += delta
	var want := int(_t / stop_seconds)
	if want != _stop and want < _stops.size():
		_stop = want
		_go(_stops[_stop])
	_log_t += delta
	if _log_t >= 1.0:
		_log_t = 0.0
		var vp := get_viewport()
		print("[world] xr t=%.0f stop=%s fps=%d draws=%d prims=%d" % [_t, _stops[clampi(_stop, 0, _stops.size() - 1)][0] if not _stops.is_empty() else "-",
			Engine.get_frames_per_second(),
			vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME) + vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME),
			vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME) + vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)])


func _go(stop: Array) -> void:
	var pos: Vector3 = stop[1]
	var target: Vector3 = stop[2]
	var ws: float = stop[3]
	origin.world_scale = ws
	# Keep the near plane proportional to the bird's size (ARCHITECTURE 7.5).
	camera.near = maxf(0.005, 0.05 * ws)
	var flat := Vector3(target.x - pos.x, 0, target.z - pos.z)
	origin.global_transform = Transform3D(Basis.looking_at(flat.normalized(), Vector3.UP), pos)
	print("[world] xr stop %s at %s world_scale %.2f" % [stop[0], pos, ws])
