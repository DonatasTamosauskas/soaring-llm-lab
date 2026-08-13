class_name XRDiagnostic
extends Node

## Prints what the headset and controllers are actually reporting, and what the
## wing sensor makes of it.
##
## The headless suites drive [WingInput] with synthetic poses. This closes the
## last gap: proof that real OpenXR poses — from the Meta XR Simulator or a
## headset — arrive in the space and units the sensor expects. A mapping that is
## correct against invented data and wrong against real data would look fine in
## every test and be unflyable in the headset.
##
##   godot -- --xrdiag=1

const SAMPLE_INTERVAL: float = 1.0

var player: BirdPlayer

var _timer: float = 0.0
var _samples: int = 0
var _frames: int = 0
var _frame_clock: float = 0.0
var _left_seen: bool = false
var _right_seen: bool = false
var _grip_seen: bool = false
var _trigger_seen: bool = false
var _span_min: float = INF
var _span_max: float = -INF


func start(player_ref: BirdPlayer) -> void:
	player = player_ref
	print("")
	print("=== XR input diagnostic ===")
	var interface: XRInterface = XRServer.find_interface("OpenXR")
	if interface == null or not interface.is_initialized():
		print("  no OpenXR runtime — nothing to diagnose")
		queue_free()
		return
	print("  runtime      : %s" % interface.get_name())
	print("  play area    : %s" % XRServer.get_reference_frame())
	var sizes: PackedVector2Array = interface.get_render_target_size_array() \
		if interface.has_method("get_render_target_size_array") \
		else PackedVector2Array([interface.get_render_target_size()])
	print("  render target: %s" % str(sizes))
	print("")
	print(
		"  time   L-tracked R-tracked  span(m)  span  bank(deg)  AoA(deg)  stroke"
		+ "  grip  trig  fps"
	)


func _process(delta: float) -> void:
	if player == null or not player.xr_active:
		return
	_frames += 1
	_frame_clock += delta
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = SAMPLE_INTERVAL
	_sample()


func _sample() -> void:
	var left: XRController3D = player.left_hand
	var right: XRController3D = player.right_hand
	var left_tracked: bool = left.get_has_tracking_data()
	var right_tracked: bool = right.get_has_tracking_data()
	_left_seen = _left_seen or left_tracked
	_right_seen = _right_seen or right_tracked

	var separation: float = left.transform.origin.distance_to(right.transform.origin)
	if left_tracked and right_tracked:
		_span_min = minf(_span_min, separation)
		_span_max = maxf(_span_max, separation)

	var fps: float = float(_frames) / maxf(_frame_clock, 0.001)
	_frames = 0
	_frame_clock = 0.0

	# The buttons this game binds, so that "is the grip reaching the game" has an
	# answer other than putting a headset on and hoping. Both are read exactly
	# the way [BirdPlayer] reads them.
	var gripping: bool = player.is_clinging()
	var triggering: bool = player.both_triggers_held()
	_grip_seen = _grip_seen or gripping
	_trigger_seen = _trigger_seen or triggering

	var cmd: FlightCommand = player.command
	print("  %5.1f  %9s %9s  %7.2f  %4.2f  %9.1f  %8.1f  %6.2f  %4s  %4s  %4.0f" % [
		_samples * SAMPLE_INTERVAL,
		"yes" if left_tracked else "NO",
		"yes" if right_tracked else "NO",
		separation, cmd.span, rad_to_deg(cmd.bank), rad_to_deg(cmd.alpha),
		cmd.stroke_speed,
		"HELD" if gripping else "-", "HELD" if triggering else "-", fps
	])
	_samples += 1


func report() -> bool:
	var problems: PackedStringArray = []
	if not _left_seen:
		problems.append("left controller never reported tracking data")
	if not _right_seen:
		problems.append("right controller never reported tracking data")
	if is_finite(_span_max) and _span_max > 3.0:
		problems.append("hand separation reached %.2f m — poses are not in metres" % _span_max)
	if is_finite(_span_min) and _span_min < 0.0:
		problems.append("negative hand separation")

	print("")
	print("  hand separation observed: %.2f .. %.2f m" % [_span_min, _span_max])
	# Not a failure: a diagnostic run where nobody squeezed anything is the
	# normal case. It is here so that a session where somebody [i]did[/i] squeeze
	# and the game did nothing has a line to point at.
	print("  grip seen: %s,  both triggers seen: %s" % [
		str(_grip_seen), str(_trigger_seen)
	])
	if problems.is_empty():
		print("XR INPUT OK")
		return true
	print("XR INPUT PROBLEMS:")
	for p: String in problems:
		print("  - %s" % p)
	return false
