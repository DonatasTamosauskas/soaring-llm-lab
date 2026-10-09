class_name PoseRecorder
extends RefCounted
## JSON-lines recording of pose frames (FLIGHT_SPEC §3.1, R5), one line per
## tick:
##   {"t", "h":[px,py,pz,qx,qy,qz,qw], "l":[...], "r":[...], "v":bits, "g":[gl,gr], "tr":[tl,tr], "b":int, "pd":s}
## "pd" (fix round 5, only when the source knew it): the pose interval
## (PoseFrame.pose_dt), so a replay reproduces an engine frame hitch.
## PlayerBird records when Settings "record_poses" is true or the game runs
## with --record-poses[=<path>]; files go to user://pose_rec/<stamp>.jsonl
## and replay through ReplayPoseSource (tick-aligned: pinned by WI-29).
## "t" is the recorder's own clock (0 at the first frame, + dt per tick), so
## every source records on the same timeline whatever it puts in frame.t.

var path := ""
var _f: FileAccess = null
var lines := 0
var _t := 0.0


func start(p_path := "") -> bool:
	path = p_path
	if path.is_empty():
		DirAccess.make_dir_recursive_absolute("user://pose_rec")
		path = "user://pose_rec/%s.jsonl" % Time.get_datetime_string_from_system().replace(":", "-")
	_f = FileAccess.open(path, FileAccess.WRITE)
	lines = 0
	_t = 0.0
	return _f != null


## Record this tick's frame; dt is the tick length (the next frame's time).
func record(frame: PoseFrame, dt: float) -> void:
	if _f == null:
		return
	var d := encode(frame)
	d["t"] = snappedf(_t, 1e-5)
	_f.store_line(JSON.stringify(d))
	lines += 1
	_t += dt


func stop() -> void:
	if _f != null:
		_f.flush()
		_f = null


static func _tr(t: Transform3D) -> Array:
	var q := t.basis.get_rotation_quaternion()
	return [snappedf(t.origin.x, 1e-5), snappedf(t.origin.y, 1e-5), snappedf(t.origin.z, 1e-5),
		snappedf(q.x, 1e-6), snappedf(q.y, 1e-6), snappedf(q.z, 1e-6), snappedf(q.w, 1e-6)]


static func encode(fr: PoseFrame) -> Dictionary:
	var v := (1 if fr.head_valid else 0) | (2 if fr.left_valid else 0) | (4 if fr.right_valid else 0)
	var d := {"t": snappedf(fr.t, 1e-5), "h": _tr(fr.head), "l": _tr(fr.left), "r": _tr(fr.right), "v": v,
		"g": [fr.grip.x, fr.grip.y], "tr": [fr.trigger.x, fr.trigger.y], "b": fr.buttons}
	if fr.pose_dt >= 0.0:
		d["pd"] = snappedf(fr.pose_dt, 1e-6)
	return d


static func _untr(a: Variant) -> Transform3D:
	if not (a is Array) or a.size() != 7:
		return Transform3D.IDENTITY
	var q := Quaternion(float(a[3]), float(a[4]), float(a[5]), float(a[6])).normalized()
	return Transform3D(Basis(q), Vector3(float(a[0]), float(a[1]), float(a[2])))


## -> [t, head, left, right, valid_bits, grip, trigger, buttons, pose_dt]
static func decode(d: Dictionary) -> Array:
	var g: Array = d.get("g", [0, 0])
	var tr: Array = d.get("tr", [0, 0])
	return [float(d.get("t", 0.0)), _untr(d.get("h")), _untr(d.get("l")), _untr(d.get("r")), int(d.get("v", 7)),
		Vector2(float(g[0]), float(g[1])), Vector2(float(tr[0]), float(tr[1])), int(d.get("b", 0)), float(d.get("pd", -1.0))]
