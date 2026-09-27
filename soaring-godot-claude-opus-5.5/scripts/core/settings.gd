extends Node
## Player preferences, persisted to user://settings.cfg (autoload "Settings").
##
## Areas add keys to DEFAULTS as they need them; read with Settings.get_value,
## write with Settings.set_value (emits Events.settings_changed).

const PATH := "user://settings.cfg"

const DEFAULTS := {
	"comfort_vignette": 0.6,     # 0 off .. 1 strong tunnel vision when turning fast
	"turn_comfort": 0.75,         # turn speed cap: 0.25 Gentle 90, 0.5 Calm 120, 0.75 Brisk 180, 1 Full 240 deg/s
	"snap_turn": false,           # reserved: flight turns are always smooth
	"master_volume": 0.8,
	"music_volume": 0.5,
	"haptics": 1.0,               # 0 off .. 1 full
	"handedness": "right",        # which hand the menu pointer prefers
	"seated": false,              # seated play: lowers the flap-detection floor
	"arm_span": 1.6,              # calibrated fingertip-to-fingertip reach, m
	"wing_calibration": {},       # VR's persisted WingCalibration fields
	"vr_refresh_rate": 0.0,       # 0 = auto (72 Hz); 90 once profiled on device
	"vr_foveation_level": 3,      # fixed foveated rendering level 0..3
	"vr_foveation_dynamic": true, # let the runtime lower foveation when GPU allows
	"world_scale_exponent": 1.0,  # growth: world_scale = (span / arm)^exponent
	"record_poses": false,        # dev: record controller poses for replay
	# Developer menu (playtest #1), bars 0..1 mapped in PlayerBird._apply_settings:
	"dev_turn_deadzone": 0.5,     # 0..20 deg with no turn around neutral
	"dev_turn_sensitivity": 0.5,  # full turn at 70 (0) .. 25 (1) deg of tilt
	"dev_turn_curve": 0.5,        # curve exponent 1 (linear) .. 3
	"dev_flap_power": 0.55,       # flap force/climb x0.5 .. x2.5 (x1.6)
	"dev_speed": 0.625,           # glide efficiency and dive limit x0.8 .. x1.6 (x1.3)
	"dev_roll_rate": 0.5,         # roll rate x0.6 .. x2.0 (x1.3)
	"dev_stretch_bonus": 0.6,     # extra flap force with arms fully stretched (+60%)
	"dev_arm_turn": true,         # turn by lowering one hand
	"dev_tilt_turn": true,        # turn by opposite wrist tilts
	"dev_tilt_invert": true,      # playtest #1: tilt turned the wrong way
	"dev_relaxed_glide": true,    # full wings with elbows relaxed (not a T-pose)
}

var _values := {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_values = DEFAULTS.duplicate()
	if OS.get_cmdline_user_args().has("--fresh-settings"):
		return
	var cfg := ConfigFile.new()
	if cfg.load(PATH) == OK:
		for k in cfg.get_section_keys("settings") if cfg.has_section("settings") else []:
			_values[k] = cfg.get_value("settings", k)


func get_value(key: String, fallback: Variant = null) -> Variant:
	return _values.get(key, DEFAULTS.get(key, fallback))


func set_value(key: String, value: Variant) -> void:
	_values[key] = value
	Events.settings_changed.emit(key, value)
	save()


func save() -> void:
	var cfg := ConfigFile.new()
	for k in _values:
		cfg.set_value("settings", k, _values[k])
	cfg.save(PATH)
