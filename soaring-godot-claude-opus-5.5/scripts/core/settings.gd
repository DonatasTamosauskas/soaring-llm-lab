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
