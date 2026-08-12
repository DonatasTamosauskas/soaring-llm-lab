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
## Snap-turn style comfort: cap how fast the view can yaw, rad/s. 0 = uncapped.
var max_view_yaw_rate: float = 0.0

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
