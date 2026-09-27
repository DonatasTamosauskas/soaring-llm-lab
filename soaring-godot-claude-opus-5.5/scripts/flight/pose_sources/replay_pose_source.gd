class_name ReplayPoseSource
extends PoseSource
## Replays a PoseRecorder JSON-lines session (FLIGHT_SPEC §3.1), interpolated
## to each tick: regression tests from real Quest sessions.

const EPS := 1e-4
var samples: Array = []   ## [t, head, left, right, valid_bits, grip, trigger, buttons]
var t := 0.0
var loop := false
var _i := 0


func _init(path := "") -> void:
	if not path.is_empty():
		load_file(path)


func load_file(path: String) -> int:
	samples.clear()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.is_empty():
			continue
		var d: Variant = JSON.parse_string(line)
		if d is Dictionary:
			samples.append(PoseRecorder.decode(d))
	return samples.size()


func duration() -> float:
	return float(samples[samples.size() - 1][0]) if not samples.is_empty() else 0.0


## Tick n shows the recording at n * dt: the first tick replays the first
## recorded frame (advancing before the lookup ran one tick ahead and
## dropped it).
func sample(out: PoseFrame, dt: float) -> void:
	var t_now := t
	t += dt
	if samples.is_empty():
		out.head_valid = false
		out.left_valid = false
		out.right_valid = false
		return
	var tt := t_now
	if loop and duration() > 0.0:
		tt = fposmod(t_now, duration())
	# Recorded times are snapped to 1e-5 s: a sample within EPS of the tick
	# is that tick's frame (else a validity change lands one tick late).
	while _i + 1 < samples.size() and float(samples[_i + 1][0]) <= tt + EPS:
		_i += 1
	if _i > 0 and float(samples[_i][0]) > tt + EPS:
		_i = 0
	var a: Array = samples[_i]
	var b: Array = samples[mini(_i + 1, samples.size() - 1)]
	var span := float(b[0]) - float(a[0])
	var k := clampf((tt - float(a[0])) / span, 0.0, 1.0) if span > 1e-6 else 0.0
	out.t = tt
	out.head = (a[1] as Transform3D).interpolate_with(b[1], k)
	out.left = (a[2] as Transform3D).interpolate_with(b[2], k)
	out.right = (a[3] as Transform3D).interpolate_with(b[3], k)
	var bits: int = a[4]
	out.head_valid = bits & 1 != 0
	out.left_valid = bits & 2 != 0
	out.right_valid = bits & 4 != 0
	out.grip = a[5]
	out.trigger = a[6]
	out.buttons = a[7]
	out.discontinuity = false
	# The recorded pose interval (an engine frame hitch) holds on the
	# recorded ticks; between them it is unknown.
	out.pose_dt = float(a[8]) if a.size() > 8 and k < 1e-6 else -1.0


func drives_nodes() -> bool:
	return true


func reset() -> void:
	t = 0.0
	_i = 0
