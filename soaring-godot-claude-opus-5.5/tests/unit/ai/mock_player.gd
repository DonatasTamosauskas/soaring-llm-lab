extends Bird
## TEST-ONLY player stand-in: a Bird with is_player() == true that flies a
## scripted path (no FlightModel, no XR), so AI tests do not depend on the
## flight area's in-progress rig. Moves only when step() is called.
##
## Paths: laps of a circle (default), or - `travel = true` - straight legs
## back and forth between line_a and line_b (a player crossing the valley,
## looking where it flies: the hardest case for keeping life around it).
##
## Caught: like GameLoop does for the real player, it is protected for
## `protect_s` seconds (meta npc_ignore, which NPC brains honour) - so a
## hunter that "ate" it goes off to digest and the next one does not simply
## queue up on an immortal bird. protect_s = 0 turns that off.

var path_center := Vector3.ZERO
var path_radius := 60.0
var path_height := 25.0
var speed := 9.0
## Angular position on the circular path.
var angle := 0.0
var travel := false
var line_a := Vector3(-330, 30, 0)
var line_b := Vector3(330, 30, 0)
var _s := 0.0
var _dir := 1.0
var view_dir := Vector3.FORWARD
## The head turned this far (rad, about +Y) from the direction of flight: in
## VR the gaze is free - looking over a shoulder at a threat - and spawns
## must stay out of where the player looks, not where it flies.
var gaze_turn := 0.0
## When false the bird stays put (tests place it by hand).
var moving := true
var caught_by: Bird = null
var times_caught := 0
var protect_s := 5.0
var _protect_left := 0.0


func is_player() -> bool:
	return true


func get_view_direction() -> Vector3:
	return view_dir


func step(dt: float) -> void:
	if _protect_left > 0.0:
		_protect_left -= dt
		if _protect_left <= 0.0:
			set_meta(&"npc_ignore", false)
	if not moving:
		return
	if travel:
		var L := line_a.distance_to(line_b)
		_s += _dir * speed * dt
		if _s > L:
			_s = L
			_dir = -1.0
		elif _s < 0.0:
			_s = 0.0
			_dir = 1.0
		var d := (line_b - line_a).normalized() * _dir
		velocity = d * speed
		view_dir = d.rotated(Vector3.UP, gaze_turn)
		global_transform = Transform3D(Basis.looking_at(d, Vector3.UP), line_a.lerp(line_b, _s / L))
		return
	var w := speed / maxf(path_radius, 1.0)
	angle += w * dt
	var p := path_center + Vector3(cos(angle) * path_radius, path_height, sin(angle) * path_radius)
	var tangent := Vector3(-sin(angle), 0.0, cos(angle))
	velocity = tangent * speed
	view_dir = tangent.rotated(Vector3.UP, gaze_turn)
	global_transform = Transform3D(Basis.looking_at(tangent, Vector3.UP), p)


func on_caught(by: Bird) -> void:
	caught_by = by
	if _protect_left > 0.0:
		return
	times_caught += 1
	if protect_s > 0.0:
		_protect_left = protect_s
		set_meta(&"npc_ignore", true)
