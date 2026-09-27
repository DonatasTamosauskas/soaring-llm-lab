class_name AudioBuses
extends RefCounted
## The mixer layout and the Settings -> bus volume mapping.
##
##   Master   [HardLimiter -1.5 dB]         <- master_volume
##   ├ Music                                 <- music_volume
##   ├ SFX    [LowPass "muffle", off]        <- sfx_volume, ducked on pause
##   │ ├ Wind   [HighPass, LowPass, Panner]    player's wind (flight-driven)
##   │ ├ Body                                  player's wingbeats, stall buffet, updraft hum
##   │ ├ Calls                                 NPC voices (3D)
##   │ └ Danger                                heartbeat + tension drone
##   ├ Ambience [LowPass "muffle", off]      <- ambience_volume, ducked on pause
##   └ UI                                    <- ui_volume, never ducked
##
## The same layout ships as res://default_bus_layout.tres (Godot loads it at
## startup); ensure() rebuilds whatever is missing, so the director also
## works if the file is absent or was edited.

const MASTER := &"Master"
const MUSIC := &"Music"
const SFX := &"SFX"
const WIND := &"Wind"
const BODY := &"Body"
const CALLS := &"Calls"
const DANGER := &"Danger"
const AMBIENCE := &"Ambience"
const UI := &"UI"

## Buses in index order (a bus may only send to one before it).
const LAYOUT: Array[Dictionary] = [
	{"name": MUSIC, "send": MASTER},
	{"name": SFX, "send": MASTER},
	{"name": WIND, "send": SFX},
	{"name": BODY, "send": SFX},
	{"name": CALLS, "send": SFX},
	{"name": DANGER, "send": SFX},
	{"name": AMBIENCE, "send": MASTER},
	{"name": UI, "send": MASTER},
]

## Settings key per bus (master_volume and music_volume exist in core's
## DEFAULTS; the other three are optional keys that default to 1.0).
const SETTING := {MASTER: "master_volume", MUSIC: "music_volume", SFX: "sfx_volume", AMBIENCE: "ambience_volume", UI: "ui_volume"}
const SETTING_DEFAULT := {"master_volume": 0.8, "music_volume": 0.5, "sfx_volume": 1.0, "ambience_volume": 1.0, "ui_volume": 1.0}

## Output ceiling: nothing leaves the mixer above this (AU1: < -1 dBFS).
const CEILING_DB := -1.5
## Low-pass used to muffle gameplay sound while paused.
const MUFFLE_HZ := 900.0


static func index(bus: StringName) -> int:
	return AudioServer.get_bus_index(bus)


## Creates missing buses and effects; idempotent.
static func ensure() -> void:
	for spec in LAYOUT:
		var name: StringName = spec["name"]
		if index(name) < 0:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count - 1, name)
		AudioServer.set_bus_send(index(name), spec["send"])
	if effect(MASTER, "AudioEffectHardLimiter") == null:
		var lim := AudioEffectHardLimiter.new()
		lim.ceiling_db = CEILING_DB
		lim.release = 0.12
		AudioServer.add_bus_effect(index(MASTER), lim)
	if effect(WIND, "AudioEffectHighPassFilter") == null:
		var hp := AudioEffectHighPassFilter.new()
		hp.cutoff_hz = 30.0
		AudioServer.add_bus_effect(index(WIND), hp)
	if effect(WIND, "AudioEffectLowPassFilter") == null:
		var lp := AudioEffectLowPassFilter.new()
		lp.cutoff_hz = 1000.0
		AudioServer.add_bus_effect(index(WIND), lp)
	if effect(WIND, "AudioEffectPanner") == null:
		AudioServer.add_bus_effect(index(WIND), AudioEffectPanner.new())
	for bus in [SFX, AMBIENCE]:
		if effect(bus, "AudioEffectLowPassFilter") == null:
			var m := AudioEffectLowPassFilter.new()
			m.cutoff_hz = MUFFLE_HZ
			AudioServer.add_bus_effect(index(bus), m)
		var mi := effect_index(bus, "AudioEffectLowPassFilter")
		AudioServer.set_bus_effect_enabled(index(bus), mi, false)


## The first effect of class cls on bus, or null.
static func effect(bus: StringName, cls: String) -> AudioEffect:
	var i := effect_index(bus, cls)
	return AudioServer.get_bus_effect(index(bus), i) if i >= 0 else null


static func effect_index(bus: StringName, cls: String) -> int:
	var b := index(bus)
	if b < 0:
		return -1
	for i in AudioServer.get_bus_effect_count(b):
		if AudioServer.get_bus_effect(b, i).is_class(cls):
			return i
	return -1


## Settings value (0..1) -> bus gain in dB. Perceptual taper: amplitude =
## v^2 (40 log10 v), so half the slider is -12 dB, which sounds like "half
## as loud"; a plain linear_to_db(v) would make the lower half of the
## slider nearly useless. 0 mutes.
static func volume_to_db(v: float) -> float:
	if v <= 0.001:
		return -80.0
	return 40.0 * log(minf(v, 1.0)) / log(10.0)


## The slider (0..1) for a bus, read from `store` (anything with
## get_value(key, fallback); the Settings autoload when null). A value that
## is not a finite number (a hand-edited or corrupted settings file) reads
## as the key's shipped default; one out of range is clamped.
static func setting_value(bus: StringName, store: Object = null) -> float:
	var key: String = SETTING.get(bus, "")
	if key.is_empty():
		return 1.0
	var def: float = SETTING_DEFAULT.get(key, 1.0)
	var src: Object = store if store != null else Settings
	return AudioInput.num(src.call(&"get_value", key, def), def, 0.0, 1.0)


## Sets a bus fader (dB; -80 and below mutes). A non-finite value is not
## written: the bus keeps its last good level.
static func set_volume(bus: StringName, db: float) -> void:
	var i := index(bus)
	if i < 0 or not is_finite(db):
		return
	AudioServer.set_bus_volume_db(i, maxf(db, -80.0))
	AudioServer.set_bus_mute(i, db <= -79.9)


static func set_muffle(bus: StringName, on: bool) -> void:
	var i := effect_index(bus, "AudioEffectLowPassFilter")
	if i >= 0:
		AudioServer.set_bus_effect_enabled(index(bus), i, on)
