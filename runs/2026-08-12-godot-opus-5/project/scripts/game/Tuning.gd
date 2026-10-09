extends Node

## Live-tunable knobs, kept in one place so flight feel can be adjusted from the
## in-game debug panel (or a launch argument) without touching the model's
## defaults. Autoloaded as `Tuning`.

# --- Comfort -----------------------------------------------------------------

## How much of the bird's bank angle is shown to the eyes. Full 1:1 roll is the
## most thrilling and the most nauseating; a partial roll keeps the horizon
## readable while still selling the turn. 0 disables visual roll entirely.
var visual_roll_fraction: float = 0.35
## Peripheral vignette strength at top speed. 0 disables it.
var comfort_vignette: float = 0.7
## How the view follows the bird's heading: 0 smooth, 1 eased, 2 stepped. See
## [enum ViewComfort.Turning] — rotation, not speed, is what makes people ill,
## and this is the knob that spends visual fidelity to buy the rotation down.
var turning_comfort: float = 0.0
## Ceiling on view yaw rate in eased mode, rad/s. 0 uses
## [constant ViewComfort.EASED_RATE]. Ignored in the other two modes, which have
## no rate to cap.
var max_view_yaw_rate: float = 0.0
## Whether the world quietly turns to face a player who has physically turned
## around in their room. See [method ViewComfort.update_reorientation].
var auto_recentre: float = 1.0

# --- Input -------------------------------------------------------------------

## Minimum downstroke travel, in metres, before a hand movement counts as a
## flap. This is what stops players from cheesing flight by vibrating their
## wrists, and it is the single most important number for making flapping feel
## like an athletic act rather than a button.
var flap_min_travel: float = 0.30
## Minimum downstroke speed, m/s.
var flap_min_speed: float = 0.9
## Scales all wing tilt input. Higher = twitchier.
var tilt_sensitivity: float = 1.0
## Seconds of smoothing applied to controller-derived wing angles.
var input_smoothing: float = 0.07

# --- Debug -------------------------------------------------------------------

var show_debug_hud: bool = false
var free_camera: bool = false


func _ready() -> void:
	_apply_command_line()


func _apply_command_line() -> void:
	for arg: String in OS.get_cmdline_user_args():
		var parts: PackedStringArray = arg.lstrip("-").split("=")
		if parts.size() != 2:
			continue
		var key: String = parts[0]
		var value: String = parts[1]
		if not (key in self):
			continue
		var current: Variant = get(key)
		if current is float:
			set(key, value.to_float())
		elif current is bool:
			set(key, value == "true" or value == "1")
		print("[Tuning] %s = %s" % [key, str(get(key))])
