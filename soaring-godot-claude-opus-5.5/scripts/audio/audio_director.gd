class_name AudioDirector
extends Node
## The sound of flight and a living sky. Root of
## scenes/audio/audio_director.tscn (group "audio_director",
## PROCESS_MODE_ALWAYS so menus and pause keep their sound).
##
## Listens to Events and polls PlayerBird.telemetry() every frame:
##  * wind (the main speed cue in VR): loudness and brightness rise with
##    airspeed; tucked = brighter and thinner; a periodic buffet when
##    stalled; an updraft hum in rising air (FlightSoundMap has the curves);
##  * wingbeat whooshes on Events.player_flapped, strength-scaled and placed
##    at the flapping hand (3D, so left/right follows the head in VR);
##  * catch crunch + feather puff, caught stinger, tier-up fanfare, bumps;
##  * a danger heartbeat + tension drone scaling with Events.threat_changed
##    (the heart beats faster at a fixed pitch), and the predator's own
##    scream when the threat turns serious;
##  * NPC calls per species in 3D through a pooled voice set (CallVoices);
##  * ambience per zone from World landmarks (AmbienceZones), receding as
##    the bird flies faster so its own wind stays on top;
##  * gentle menu music; pause ducks and muffles gameplay (SFX, Ambience)
##    but keeps music and UI; Settings volumes drive the buses.
##
## Runtime cost is only parameter changes (volume, pitch, bus filters) on
## pre-rendered loops; every buffer is synthesized once (AudioBank).
##
## Public API (docs/ARCHITECTURE.md, contract changes; all optional):
##   play_ui(kind)             UI sounds: click, select, back, open, close, confirm, hover
##                             (each at its own level, UI_LEVEL; pass volume_db to override)
##   await shutdown()          stop everything before get_tree().quit() (clean exit)
##   signal cue(name, info)    every one-shot cue as it plays
##   debug_snapshot()          readable state for HUDs and logs
##   perf_stats()              frame-cost statistics (ms): mean, p25, median, p95, max, trimmed
## Also used by the tests and the dev scene: flight_params(), perf_avg_ms(),
## reset_perf(), bank_ready(), and `settings` (where the volumes are read).
##
## Every number taken from outside (telemetry, the threat level, event
## payloads, positions, Settings volumes) is sanitised at the boundary
## (AudioInput, FlightSoundMap.clean_telemetry), and every smoothed state is
## reset to its target should it ever become non-finite: one glitching
## frame must not silence a layer for the rest of the session.

## Emitted for every one-shot cue (tests, dev HUD): name, details.
signal cue(name: StringName, info: Dictionary)

## Synthesize on a worker thread (the game) or synchronously (tests).
@export var async_build := true
## Where the volume sliders are read from: anything with
## get_value(key, fallback) (the Settings autoload when null). Tests use an
## in-memory store so a run never rewrites user://settings.cfg; set it
## before the director enters the tree. A store should emit
## Events.settings_changed when a value changes, as Settings does.
var settings: Object = null

var bank: AudioBank
var voices: CallVoices
var ambience: AmbienceZones

## Smoothed flight parameters as applied (see FlightSoundMap.compute).
var params := {}
var threat_level := 0.0
var threat_bird: Bird = null
var target_bird: Bird = null
## _process timing (AU5): totals plus the last PERF_WINDOW frame costs (a
## ring), so tests can use robust statistics (on a shared machine the OS
## preempts the thread now and then; a median is the director's cost, a
## spike is not).
const PERF_WINDOW := 1024
var perf_frames := 0
var perf_usec := 0
var perf_samples := PackedInt32Array()
var _perf_i := 0

## A looping layer: its player, current linear gain and the last values
## written to the engine (engine property writes are the per-frame cost, so
## they only happen on a real change).
class Layer:
	extends RefCounted
	var player: AudioStreamPlayer
	var key: StringName
	var gain := 0.0
	var db := -80.0
	var pitch := 1.0
	var paused := false

var _wind_body: Layer
var _wind_edge: Layer
var _flutter: Layer
var _hum: Layer
var _heart: Layer
var _drone: Layer
var _layers: Array[Layer] = []
var _music: AudioStreamPlayer
var _oneshot: AudioStreamPlayer
var _ui: AudioStreamPlayer
var _whoosh: Array[AudioStreamPlayer3D] = []
var _whoosh_i := 0
var _last_variant := -1

var _attached := false
var _rig: XROrigin3D = null
var _rig_check := 0
var _music_applied := -999.0
var _cut := 1000.0
var _hp := 30.0
var _pan := 0.0
## The last listener transform and world scale that made sense (see
## _listener_transform and _world_scale): a glitching frame reuses them.
var _last_listener := Transform3D.IDENTITY
var _last_ws := 1.0
## Current pause/menu duck of SFX and of Ambience, dB. Each ramps on its own
## towards the state's STATE_MIX value, so a change of either one (PLAYING
## -> CAUGHT only moves the ambience) always lands.
var _duck_db := 0.0
var _amb_duck_db := 0.0
var _music_db := -80.0
## Cue duck: while a reward or failure cue plays, the continuous layers
## (wind, buffet, hum, heartbeat, drone) sit this many dB lower (see
## _cue_duck).
var _cue_duck_db := 0.0
var _cue_duck_t := 0.0
## The same duck on the rest of the world (the Calls and Ambience buses):
## at once with the cue, then back up smoothly (TAU_UP) when it ends.
var _world_duck_db := 0.0
var _screech_cool := 0.0
## When each stackable cue last played (Time, s): see CUE_STACK_S.
var _cue_last := {}
## Set once _ready has built everything (a director re-entering the tree
## reconnects instead of rebuilding).
var _built := false
## The last threat named a predator (so its disappearance can be noticed:
## a freed Object compares equal to null).
var _threat_has_bird := false
var _rng := RandomNumberGenerator.new()
var _world_checked := false
var _lp_wind: AudioEffectLowPassFilter
var _hp_wind: AudioEffectHighPassFilter
var _panner: AudioEffectPanner
var _heart_pb: AudioStreamGeneratorPlayback = null
## The lub-dub as stereo frames (from the bank), silence to pad the gaps,
## frames since the current beat began, and the threat level driving it.
var _beat := PackedVector2Array()
var _beat_silence := PackedVector2Array()
var _beat_pos := 0
## Where this beat's dub starts (frames), fixed when the beat begins.
var _beat_dub := 0
var _danger_level := 0.0
## Beats begun (tests measure the tempo on the mix; this counts it).
var beats := 0

## Duck (dB) of SFX/Ambience and music level per game state, keyed by
## Game.State value (BOOT 0, MENU 1, PLAYING 2, PAUSED 3, CAUGHT 4, ENDED 5;
## an autoload's enum cannot appear in a constant expression).
const STATE_MIX := {
	0: {"sfx": -20.0, "amb": -10.0, "music": 0.0, "muffle": false},
	1: {"sfx": -20.0, "amb": -10.0, "music": 0.0, "muffle": false},
	2: {"sfx": 0.0, "amb": 0.0, "music": -80.0, "muffle": false},
	3: {"sfx": -20.0, "amb": -14.0, "music": -3.0, "muffle": true},
	4: {"sfx": 0.0, "amb": -4.0, "music": -80.0, "muffle": false},
	5: {"sfx": -20.0, "amb": -10.0, "music": 0.0, "muffle": false},
}
## One-shot levels (dB on the SFX bus). The mix is a loudness hierarchy:
## reward and failure moments on top, then the dive wind, wingbeats,
## nearby calls, danger, cruise wind and the ambience beds underneath; and
## realistic heavy play must peak under the limiter ceiling by gain staging
## alone (tests/unit/audio/audio_wind_test.gd). The rendered level of every
## cue is listed in artifacts/audio/mix_levels.json.
const LEVEL := {
	# The crunch's needle peaks are softened 3 dB in the clip
	# (SoundDesigns.CRUNCH_SOFTEN_DB), so -9 here is as loud as an
	# unsoftened crunch at -6, with 3 dB more headroom.
	"crunch": -9.0, "puff": -10.0, "caught": -4.0, "fanfare": -6.0,
	"bump_min": -16.0, "bump_max": -5.0, "brush": -12.0, "perch": -18.0,
	"npc_crunch": -11.0,
}
## A cue fired again within CUE_STACK_S of its last play (two prey caught in
## one sweep) plays CUE_STACK_DB lower: both are heard, but the second
## transient does not land on the first at full level. (Round 2 measured
## two full crunches 50 ms apart at -1.2 dBFS before the limiter; since
## round 3 the cue duck takes the rest of the mix down under a catch, so
## heavy play keeps its headroom without this rule too, and it stays for
## the crunch itself: two bites summed at full level are +6 dB of transient.
## test_event_cues pins it on the mix: two catches in one frame measure
## +3.5 dB over one, not +6.)
const CUE_STACK_S := 0.25
const CUE_STACK_DB := -6.0
## UI sound levels (dB on the UI bus), set by measured loudness (A-weighted,
## integrated over 0.1 s) rather than one gain for all: the Kenney files
## span 25 dB to the ear (the confirm chime against the 20 ms hover tick).
## select, open, close, back and confirm land 5-7 dB over the menu music
## at the default settings: clearly there, not a jolt (they follow the
## music: 2 dB lower since round 3). click and hover are 20-90 ms ticks, as
## loud as their peaks allow (-3 dBFS): integrated over 0.1 s they measure
## at or a little over the music, but a tick is heard by its onset.
const UI_LEVEL := {
	&"click": -2.0, &"hover": -2.0, &"back": -4.2, &"open": -12.0,
	&"close": -12.0, &"select": -7.0, &"confirm": -18.0,
}
## Cue ducks: [dB, seconds]. While a reward or failure cue plays, the
## continuous layers (wind, buffet, hum, heartbeat, drone) and the rest of
## the world (NPC calls, ambience, the bell) step back: applied at once,
## released smoothly (_cue_duck). Only the cue itself and the player's own
## wingbeats keep their level. Ducking the world too (round 3) keeps a
## nearby crow or the tolling bell from landing on the crunch at full level
## (heavy play touched -1.3 dBFS before the limiter) and lets the moment read.
## The catch's depth grows with the wind in a fast dive
## (FlightSoundMap.catch_duck_db: -5 dB up to about 2x cruise, -14 dB, its
## limit, in a tucked 2.6x dive), so the crunch stands 9 dB and more clear
## of it.
const CUE_DUCK := {"catch": [-5.0, 0.35], "caught": [-10.0, 2.5], "fanfare": [-6.0, 2.0]}
## Pause/menu duck speed, dB per second.
const DUCK_DB_PER_S := 60.0
## Music fades are linear ramps in amplitude (an exponential fade lingers
## audibly for seconds): full in 2 s, silent 1.5 s after take-off.
const MUSIC_FADE_IN := 2.0
const MUSIC_FADE_OUT := 1.5
## Make-up gain for the menu music. The loop is mastered quiet (-23.9 LUFS
## over its 33.7 s, every 2 s within 1 LU of that, peak -11.9 dBFS), so
## +10 dB puts it at about -28.6 LUFS at the output with the default
## music_volume 0.5 and master_volume 0.8: the loudness of ordinary play
## near the ground (perched in a wood with birds calling, flapping at
## cruise), and a glide at cruise within 8 LU under it. The menu is where
## the player sets the headset volume: music much louder than play (round
## 3: +12 dB, a glide 11.6 LU under it) sends them into the game too quiet.
## With both sliders at full its rare top peaks (0.2% of 10 ms blocks)
## stay under the master limiter.
const MUSIC_GAIN_DB := 10.0
## Loop layer smoothing: fast attack, slower release (no zipper noise, but a
## flap or a dive is heard at once).
const TAU_UP := 0.06
const TAU_DOWN := 0.18
const SILENT := -80.0
const WHOOSH_VOICES := 4
## Threat level at which the predator screams (rising edge, with cooldown).
const SCREECH_LEVEL := 0.6
## The heartbeat is scheduled, not looped: each beat writes the one lub-dub
## clip ("heartbeat", fixed pitch) into an AudioStreamGenerator, then silence
## until the next beat, so the tempo rises with the threat while the heart
## keeps its pitch. (Speeding a loop up with pitch_scale raised it almost an
## octave at contact: a chipmunk heart at the tensest moment.) Per frame
## this is a slice and a push_buffer, native copies, no per-sample
## GDScript. The generator buffer is the tempo latency and the hitch margin.
const HEART_BUFFER_S := 0.15


func _enter_tree() -> void:
	add_to_group(&"audio_director")
	process_mode = Node.PROCESS_MODE_ALWAYS
	if _built:
		# Back in the tree (re-parented): listen again and restore the mix.
		_connect_events(true)
		_apply_state_mix(true)


func _ready() -> void:
	_rng.seed = 12345
	AudioBuses.ensure()
	_lp_wind = AudioBuses.effect(AudioBuses.WIND, "AudioEffectLowPassFilter") as AudioEffectLowPassFilter
	_hp_wind = AudioBuses.effect(AudioBuses.WIND, "AudioEffectHighPassFilter") as AudioEffectHighPassFilter
	_panner = AudioBuses.effect(AudioBuses.WIND, "AudioEffectPanner") as AudioEffectPanner
	bank = AudioBank.acquire(async_build)
	_wind_body = _loop_player("WindBody", AudioBuses.WIND, &"wind_body")
	_wind_edge = _loop_player("WindEdge", AudioBuses.WIND, &"wind_edge")
	_flutter = _loop_player("StallFlutter", AudioBuses.BODY, &"stall_flutter")
	_hum = _loop_player("UpdraftHum", AudioBuses.BODY, &"updraft_hum")
	_heart = _loop_player("Heartbeat", AudioBuses.DANGER, &"heartbeat")
	_drone = _loop_player("Drone", AudioBuses.DANGER, &"drone")
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = SoundDesigns.FX_RATE
	gen.buffer_length = HEART_BUFFER_S
	_heart.player.stream = gen
	_heart.player.play()
	_heart_pb = _heart.player.get_stream_playback() as AudioStreamGeneratorPlayback
	_beat_silence.resize(int(SoundDesigns.FX_RATE * HEART_BUFFER_S) + 256)
	_music = AudioStreamPlayer.new()
	_music.name = "Music"
	_music.bus = AudioBuses.MUSIC
	_music.volume_db = SILENT
	add_child(_music)
	_oneshot = _poly_player("OneShots", AudioBuses.SFX, 16)
	_ui = _poly_player("UI", AudioBuses.UI, 6)
	for i in WHOOSH_VOICES:
		var w := AudioStreamPlayer3D.new()
		w.name = "Whoosh%d" % i
		w.bus = AudioBuses.BODY
		# Placed at the flapping hand: only the direction matters (panning),
		# the wing is always at arm's length.
		w.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
		# ~12 dB between the ears for a wing at arm's length: clearly on
		# its side (a real 1-3 kHz ILD at 90 deg is 10-15 dB) while the far
		# ear still hears it (2.0 isolates it completely, which sounds wrong).
		w.panning_strength = 1.5
		w.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
		# No air absorption at arm's length. Godot's default shelf (-24 dB
		# at 5 kHz, scaled by 1 - gain, volume_db included) took the small
		# flutter's centroid from 3.6 to 2.0 kHz (round 3).
		w.attenuation_filter_db = 0.0
		add_child(w)
		_whoosh.append(w)
	voices = CallVoices.new()
	voices.name = "CallVoices"
	add_child(voices)
	voices.setup(bank)
	ambience = AmbienceZones.new()
	ambience.name = "Ambience"
	add_child(ambience)
	ambience.setup(bank)
	_connect_events(true)
	var gl := get_tree().get_first_node_in_group(&"game_loop")
	if gl:
		if gl.has_signal(&"apex_reached"):
			gl.connect(&"apex_reached", func() -> void: _play_fanfare(0.84))
		if gl.has_signal(&"victory"):
			gl.connect(&"victory", func(_s: Dictionary) -> void: _play_fanfare(1.0))
	_built = true
	_apply_state_mix(true)
	_apply_volumes()


## Events are heard only while in the tree: a director taken out (a scene
## removed before it is freed, a re-parent) has no viewport, listener or
## tree to play into.
func _connect_events(on: bool) -> void:
	var pairs := [
		[Events.player_flapped, _on_flapped], [Events.bird_caught, _on_bird_caught],
		[Events.player_caught, _on_player_caught], [Events.player_tier_changed, _on_tier_changed],
		[Events.player_collided, _on_collided], [Events.player_perched, _on_perched],
		[Events.threat_changed, _on_threat_changed], [Events.target_changed, _on_target_changed],
		[Events.game_state_changed, _on_state_changed], [Events.settings_changed, _on_settings_changed],
	]
	for pair in pairs:
		var sig: Signal = pair[0]
		var fn: Callable = pair[1]
		if on and not sig.is_connected(fn):
			sig.connect(fn)
		elif not on and sig.is_connected(fn):
			sig.disconnect(fn)


func _exit_tree() -> void:
	_connect_events(false)
	# Leave the shared buses as we found them (dev scenes and tests come and go).
	AudioBuses.set_muffle(AudioBuses.SFX, false)
	AudioBuses.set_muffle(AudioBuses.AMBIENCE, false)
	_duck_db = 0.0
	_amb_duck_db = 0.0
	_world_duck_db = 0.0
	_cue_duck_t = 0.0
	_apply_volumes()


## The bank is held for the director's whole life, not its time in the
## tree: a director that is re-parented keeps every clip and carries on.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and bank != null:
		bank = null
		AudioBank.release()


func _loop_player(n: String, bus: StringName, key: StringName) -> Layer:
	var p := AudioStreamPlayer.new()
	p.name = n
	p.bus = bus
	p.volume_db = SILENT
	add_child(p)
	var l := Layer.new()
	l.player = p
	l.key = key
	_layers.append(l)
	return l


func _poly_player(n: String, bus: StringName, voices_n: int) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.name = n
	p.bus = bus
	var poly := AudioStreamPolyphonic.new()
	poly.polyphony = voices_n
	p.stream = poly
	add_child(p)
	return p


func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	delta = AudioInput.num(delta, 0.0, 0.0, 0.1)
	bank.poll()  # saves freshly synthesized clips; returns at once when idle
	_attach_streams()
	_apply_state_mix(false, delta)
	var listener := _listener_transform()
	var player := Birds.player()
	var ws := _world_scale(player)
	_update_flight(delta, player, listener)
	_update_danger(delta)
	_update_world_duck(delta)
	voices.threat = threat_bird if is_instance_valid(threat_bird) else null
	voices.target = target_bird if is_instance_valid(target_bird) else null
	voices.speed_duck_target_db = params.get("calls_duck_db", 0.0) if voices.scheduling else 0.0
	voices.edge_lift_target_db = params.get("threat_lift_db", 0.0) if voices.scheduling else 0.0
	voices.tick(delta, listener.origin, ws)
	if not _world_checked or ambience.world == null:
		var w := World.find(get_tree())
		if w and w.is_generated:
			ambience.set_world(w)
			_world_checked = true
	# The speed duck only while flying: paused or in menus the state mix
	# rules the ambience alone.
	var amb_duck: float = params.get("amb_duck_db", 0.0) if ambience.scheduling else 0.0
	ambience.tick(delta, listener.origin, ws, amb_duck)
	var us := Time.get_ticks_usec() - t0
	perf_frames += 1
	perf_usec += us
	# A ring: no per-frame shift of the whole window.
	if perf_samples.size() < PERF_WINDOW:
		perf_samples.append(us)
	else:
		perf_samples[_perf_i] = us
		_perf_i = (_perf_i + 1) % PERF_WINDOW


func perf_avg_ms() -> float:
	return perf_usec / 1000.0 / maxf(1.0, perf_frames)


func reset_perf() -> void:
	perf_frames = 0
	perf_usec = 0
	perf_samples.clear()
	_perf_i = 0


## Robust frame-cost statistics over the recent window, ms: mean, p25,
## median, p95, max and the mean of the fastest 90% (drops preemption
## spikes).
func perf_stats() -> Dictionary:
	var v := PackedFloat32Array()
	for us in perf_samples:
		v.append(us / 1000.0)
	if v.is_empty():
		return {"mean": 0.0, "p25": 0.0, "median": 0.0, "p95": 0.0, "max": 0.0, "trimmed": 0.0, "frames": 0}
	v.sort()
	var sum := 0.0
	for x in v:
		sum += x
	var keep := maxi(1, int(v.size() * 0.9))
	var tsum := 0.0
	for i in keep:
		tsum += v[i]
	return {"mean": sum / v.size(), "p25": v[v.size() / 4], "median": v[v.size() / 2], "p95": v[int(v.size() * 0.95) - 1] if v.size() >= 20 else v[-1],
		"max": v[-1], "trimmed": tsum / keep, "frames": v.size()}


## Starts each loop the moment its clip exists (the bank may still be
## synthesizing on a worker thread); stops checking once all are attached.
func _attach_streams() -> void:
	if _attached:
		return
	var all := true
	for l in _layers:
		if l.player.stream == null:
			if bank.has(l.key):
				l.player.stream = bank.get_stream(l.key)
				l.player.play(_rng.randf() * l.player.stream.get_length())
				l.paused = false
			else:
				all = false
	if _music.stream == null:
		if bank.has(&"music_menu"):
			_music.stream = bank.get_stream(&"music_menu")
		else:
			all = false
	if _beat.is_empty():
		_beat = bank.frames(&"heartbeat")
		if _beat.is_empty():
			all = false
	_attached = all


## Where the ears are: the audio listener, else the current camera (the
## XRCamera3D in VR), else the player's body. A transform that is not
## finite or is absurdly far (a glitching tracker) is not used: the last
## good one stands in.
func _listener_transform() -> Transform3D:
	var cam := get_viewport().get_camera_3d()
	var lst := get_viewport().get_audio_listener_3d()
	var t := _last_listener
	if lst:
		t = lst.global_transform
	elif cam:
		t = cam.global_transform
	else:
		var p := Birds.player()
		if p:
			var fwd := p.get_forward()
			if fwd.is_finite() and fwd.length_squared() > 1e-6:
				t = Transform3D(Basis.looking_at(fwd), p.get_body_position())
			else:
				t = Transform3D(Basis.IDENTITY, p.get_body_position())
	if AudioInput.transform_ok(t):
		_last_listener = t
	return _last_listener


func _world_scale(player: Bird) -> float:
	# The rig is looked up twice a second, not every frame.
	_rig_check -= 1
	if _rig_check <= 0 or (_rig != null and not is_instance_valid(_rig)):
		_rig_check = 30
		_rig = get_tree().get_first_node_in_group(&"player_rig") as XROrigin3D
	if _rig != null and is_instance_valid(_rig):
		_last_ws = AudioInput.num(_rig.world_scale, _last_ws, 0.01, 100.0)
	elif player and player.has_method("telemetry"):
		_last_ws = AudioInput.num(_telemetry(player).get("world_scale", 1.0), _last_ws, 0.01, 100.0)
	else:
		_last_ws = 1.0
	return _last_ws


static func _telemetry(player: Bird) -> Dictionary:
	if player.has_method("telemetry"):
		var tel: Variant = player.call("telemetry")
		if tel is Dictionary:
			return tel
	# Minimal stand-in so a bare Bird still makes wind.
	return {"airspeed": player.velocity.length(), "perched": player.perched}


# ------------------------------------------------------------- flight ---

func _update_flight(dt: float, player: Bird, listener: Transform3D) -> void:
	var p := {}
	if player != null and player.alive:
		var tel := _telemetry(player)
		var vel := player.velocity
		var rel := 0.0
		var speed := 0.0
		if vel.is_finite():
			speed = vel.length()
			if Vector2(vel.x, vel.z).length() > 0.5:
				var fwd := -listener.basis.z
				rel = wrapf(atan2(-fwd.x, -fwd.z) - atan2(-vel.x, -vel.z), -PI, PI)
		# compute() sanitises every key (a NaN airspeed falls back to the
		# Bird's own velocity, when that is finite).
		p = FlightSoundMap.compute(tel, player.mass, rel, speed)
	else:
		p = {"body_db": SILENT, "edge_db": SILENT, "flutter_db": SILENT, "hum_db": SILENT,
			"body_cutoff": 400.0, "body_highpass": 30.0, "body_pitch": 1.0, "flutter_pitch": 1.0,
			"hum_pitch": 1.0, "pan": 0.0, "x": 0.0, "tuck": 0.0}
	if _cue_duck_t > 0.0:
		_cue_duck_t -= dt
	var duck := _cue_duck_db if _cue_duck_t > 0.0 else 0.0
	_k_up = 1.0 - exp(-dt / TAU_UP)
	_k_down = 1.0 - exp(-dt / TAU_DOWN)
	_set_level(_wind_body, p["body_db"] + duck)
	_set_level(_wind_edge, p["edge_db"] + duck)
	_set_level(_flutter, p["flutter_db"] + duck)
	_set_level(_hum, p["hum_db"] + duck)
	_set_pitch(_wind_body, p["body_pitch"])
	_set_pitch(_wind_edge, p["body_pitch"])
	_set_pitch(_flutter, p["flutter_pitch"])
	_set_pitch(_hum, p["hum_pitch"])
	# Filters move in log-frequency with a short time constant. (Their
	# targets are finite: compute() sanitised the telemetry. Should a state
	# still go non-finite it restarts from its target, never stays stuck.)
	var k := 1.0 - exp(-dt / 0.08)
	var cut_to := float(p["body_cutoff"])
	var hp_to := float(p["body_highpass"])
	_cut = exp(lerpf(log(_cut), log(cut_to), k))
	_hp = exp(lerpf(log(_hp), log(hp_to), k))
	_pan = lerpf(_pan, float(p["pan"]), 1.0 - exp(-dt / 0.3))
	if not is_finite(_cut) or _cut <= 0.0:
		_cut = cut_to
	if not is_finite(_hp) or _hp <= 0.0:
		_hp = hp_to
	if not is_finite(_pan):
		_pan = float(p["pan"])
	if _lp_wind and absf(_lp_wind.cutoff_hz - _cut) > _cut * 0.005:
		_lp_wind.cutoff_hz = _cut
	if _hp_wind and absf(_hp_wind.cutoff_hz - _hp) > _hp * 0.005:
		_hp_wind.cutoff_hz = _hp
	if _panner and absf(_panner.pan - _pan) > 0.005:
		_panner.pan = _pan
	params = p
	params["cutoff_applied"] = _cut
	params["highpass_applied"] = _hp


var _k_up := 0.0
var _k_down := 0.0


## Smooths a loop's level (linear gain, fast attack / slower release) and
## pauses it while silent so it costs no mixing. _k_up/_k_down are this
## frame's smoothing factors.
func _set_level(l: Layer, target_db: float) -> void:
	var cur := l.gain
	var tgt := 0.0 if not is_finite(target_db) or target_db <= SILENT + 0.1 else db_to_linear(minf(target_db, 0.0))
	cur = lerpf(cur, tgt, _k_up if tgt > cur else _k_down)
	# A non-finite gain would never leave that state (lerp from NaN is NaN):
	# restart from the target.
	if not is_finite(cur):
		cur = tgt
	# An exponential release never ends: once a layer headed for silence is
	# 50 dB down, finish it (and pause it, below).
	if tgt <= 0.0 and cur < 0.003:
		cur = 0.0
	l.gain = cur
	if l.player.stream == null:
		return
	var db := linear_to_db(maxf(cur, 1e-5))
	if absf(db - l.db) > 0.01:
		l.db = db
		l.player.volume_db = db
	var quiet := cur <= 0.0 and tgt <= 0.0
	if quiet != l.paused:
		l.paused = quiet
		l.player.stream_paused = quiet


func _set_pitch(l: Layer, pitch: float) -> void:
	if absf(pitch - l.pitch) > 0.0005:
		l.pitch = pitch
		l.player.pitch_scale = pitch


# ------------------------------------------------------------- danger ---

func _update_danger(dt: float) -> void:
	var lvl := threat_level
	# GameLoop re-emits the threat every frame it changes; should the
	# predator leave the world (recycled, removed) before a new level
	# arrives, its heartbeat must not go on for a bird that is not there.
	if _threat_has_bird and not CallVoices._present(threat_bird):
		lvl = 0.0
	_danger_level = lvl
	var duck := _cue_duck_db if _cue_duck_t > 0.0 else 0.0
	_set_level(_heart, FlightSoundMap.heart_db(lvl) + duck)
	# In fast flight with the wings spread the drone rises with the wind's
	# body (FlightSoundMap.danger_makeup_db), so the danger keeps its place
	# over the wind in the 125-250 Hz octaves. Silent stays silent.
	var drone := FlightSoundMap.drone_db(lvl)
	if drone > SILENT:
		drone += float(params.get("danger_makeup_db", 0.0))
	_set_level(_drone, drone + duck)
	_feed_heart()
	_screech_cool = maxf(0.0, _screech_cool - dt)


## Fills the heartbeat generator, one beat period at a time: the lub,
## silence, the dub at FlightSoundMap.heart_dub (closer at speed), silence
## to the end of the period. Sample-exact tempo, fixed pitch.
func _feed_heart() -> void:
	if _heart_pb == null or not _heart.player.playing:
		return
	var n := _heart_pb.get_frames_available()
	var rate := float(SoundDesigns.FX_RATE)
	var period := maxi(1, int(rate / FlightSoundMap.heart_rate(_danger_level)))
	var lub_end := mini(_beat.size(), int(SoundDesigns.HEART_LUB_END * rate))
	var dub_from := mini(_beat.size(), int(SoundDesigns.HEART_DUB_AT * rate))
	var dub_len := _beat.size() - dub_from
	while n > 0:
		# The period may shrink mid-beat (the threat rose): a beat always
		# finishes its dub before the next one starts.
		var beat_end := maxi(period, _beat_dub + dub_len)
		if _beat_pos >= beat_end:
			_beat_pos = 0
		if _beat_pos == 0:
			beats += 1
			_beat_dub = maxi(lub_end, int(FlightSoundMap.heart_dub(_danger_level) * rate))
			beat_end = maxi(period, _beat_dub + dub_len)
		var take := 0
		if _beat_pos < lub_end:
			take = mini(n, lub_end - _beat_pos)
			_heart_pb.push_buffer(_beat.slice(_beat_pos, _beat_pos + take))
		elif _beat_pos < _beat_dub:
			take = mini(mini(n, _beat_dub - _beat_pos), _beat_silence.size())
			_heart_pb.push_buffer(_beat_silence.slice(0, take))
		elif _beat_pos < _beat_dub + dub_len:
			var off := dub_from + _beat_pos - _beat_dub
			take = mini(n, _beat_dub + dub_len - _beat_pos)
			_heart_pb.push_buffer(_beat.slice(off, off + take))
		else:
			take = mini(mini(n, beat_end - _beat_pos), _beat_silence.size())
			_heart_pb.push_buffer(_beat_silence.slice(0, take))
		_beat_pos += take
		n -= take


func _on_threat_changed(level: float, predator: Bird) -> void:
	# A level that is not a number says nothing: the event is dropped and
	# the current danger stands (a glitch must neither silence nor trigger
	# the danger cue). An out-of-range one is clamped.
	if not is_finite(level):
		return
	level = clampf(level, 0.0, 1.0)
	var was := threat_level
	threat_level = level
	threat_bird = predator
	_threat_has_bird = predator != null
	if level >= SCREECH_LEVEL and was < SCREECH_LEVEL and _screech_cool <= 0.0 \
			and predator != null and CallVoices._present(predator) and not predator.is_player():
		# The predator screams from wherever it is (urgent: no reach cut, a
		# floor under its level). The cooldown starts only if it does: a
		# scream that could not sound must not silence the rest of the attack.
		voices.threat = predator
		if voices.request_call(predator, 20.0, true):
			_screech_cool = 5.0
			cue.emit(&"screech", {"species": predator.species})


func _on_target_changed(prey: Bird) -> void:
	target_bird = prey


# ------------------------------------------------------------ one-shots ---

func _play(stream: AudioStream, db: float, pitch: float = 1.0) -> void:
	if stream == null or not _oneshot.playing:
		if stream == null:
			return
		_oneshot.play()
	var pb := _oneshot.get_stream_playback() as AudioStreamPlaybackPolyphonic
	if pb:
		pb.play_stream(stream, 0.0, db, pitch)


func _on_flapped(side: int, strength: float) -> void:
	var player := Birds.player()
	var mass := AudioInput.num(player.mass if player else 0.03, 0.03, 0.001, 100.0)
	# A flap was detected, so it sounds; a strength that is not a number
	# plays as a medium one.
	strength = AudioInput.num(strength, 0.5, 0.0, 1.0)
	side = signi(side)
	var size := FlightSoundMap.whoosh_size(mass)
	var v := _rng.randi() % AudioBank.WHOOSH_VARIANTS
	if v == _last_variant:
		v = (v + 1) % AudioBank.WHOOSH_VARIANTS
	_last_variant = v
	var stream := bank.get_stream(StringName("whoosh_%d_%d" % [size, v]))
	if stream == null:
		return
	var db := FlightSoundMap.whoosh_db(strength)
	var pitch := FlightSoundMap.whoosh_pitch(mass) * _rng.randf_range(0.95, 1.05)
	var sides: Array[int] = [-1, 1]
	if side != 0:
		sides = [side]
	for s in sides:
		var w := _whoosh[_whoosh_i]
		_whoosh_i = (_whoosh_i + 1) % _whoosh.size()
		w.stream = stream
		w.volume_db = db - (3.0 if side == 0 else 0.0)
		w.pitch_scale = pitch
		w.global_position = _wing_position(s)
		w.play()
	cue.emit(&"whoosh", {"side": side, "strength": strength, "size": size, "db": db})


## Where a wing is: the matching controller when the XR rig exists, else
## arm's length to that side of the listener.
func _wing_position(side: int) -> Vector3:
	var rig := get_tree().get_first_node_in_group(&"player_rig") as Node3D
	if rig:
		var hand := rig.get_node_or_null("LeftHand" if side < 0 else "RightHand") as Node3D
		if hand and AudioInput.position_ok(hand.global_position):
			return hand.global_position
	var t := _listener_transform()
	var ws := _world_scale(Birds.player())
	return t.origin + t.basis.x * side * 0.8 * ws - t.basis.y * 0.2 * ws


## 0, or CUE_STACK_DB when `name` already played within CUE_STACK_S.
func _stack_db(name: StringName) -> float:
	var now := Time.get_ticks_usec() / 1e6
	var last: float = _cue_last.get(name, -INF)
	_cue_last[name] = now
	return CUE_STACK_DB if now - last < CUE_STACK_S else 0.0


func _on_bird_caught(predator: Bird, prey: Bird) -> void:
	if predator == null or prey == null:
		return
	var pitch := clampf(pow(0.03 / AudioInput.num(prey.mass, 0.03, 0.001, 100.0), 0.1), 0.8, 1.3)
	var v := _rng.randi() % AudioBank.CRUNCH_VARIANTS
	if predator.is_player():
		var stack := _stack_db(&"catch")
		_play(bank.get_stream(StringName("crunch_%d" % v)), LEVEL["crunch"] + stack, pitch)
		_play(bank.get_stream(StringName("puff_%d" % v)), LEVEL["puff"] + stack, pitch * _rng.randf_range(0.95, 1.05))
		# Deeper in a fast dive: the crunch stands clear of the loudest wind.
		var duck := FlightSoundMap.catch_duck_db(float(params.get("body_db", SILENT)))
		_cue_duck(duck, CUE_DUCK["catch"][1])
		cue.emit(&"catch", {"prey": prey.species, "stack_db": stack, "duck_db": duck})
	elif not prey.is_player() and is_instance_valid(prey):
		# NPC-on-NPC: a quieter 3D crunch where it happened, if in earshot.
		var st := bank.get_stream(StringName("crunch_%d" % v))
		if st:
			voices.play_fx(prey.get_body_position(), st, LEVEL["npc_crunch"], predator.species, pitch)


## Ducks the continuous layers for a cue: at once (the step is masked by the
## cue's own onset, and a smoothed duck would arrive after the transient it
## is meant to make room for), then back up smoothly when it ends. This is
## what lets a catch crunch cut through a tucked dive with the heart racing
## without the mix reaching the limiter.
func _cue_duck(db: float, seconds: float) -> void:
	if _cue_duck_t > 0.0 and _cue_duck_db <= db:
		_cue_duck_t = maxf(_cue_duck_t, seconds)  # a deeper duck is running
		return
	var k := db_to_linear(db - (_cue_duck_db if _cue_duck_t > 0.0 else 0.0))
	_cue_duck_db = db
	_cue_duck_t = seconds
	# The calls and the ambience: at once too.
	_world_duck_db = minf(_world_duck_db, db)
	voices.cue_duck_db = _world_duck_db
	voices.apply_bus_now()
	_apply_volumes()
	for l in _layers:
		if l.gain > 0.0 and l.player.stream != null:
			l.gain *= k
			l.db = linear_to_db(maxf(l.gain, 1e-5))
			l.player.volume_db = l.db


func _on_player_caught(predator: Bird) -> void:
	_play(bank.get_stream(&"caught"), LEVEL["caught"])
	_cue_duck(CUE_DUCK["caught"][0], CUE_DUCK["caught"][1])
	cue.emit(&"caught", {"by": predator.species if predator else &""})


func _on_tier_changed(old_tier: int, new_tier: int) -> void:
	if new_tier > old_tier:
		_play_fanfare(1.0)


func _play_fanfare(pitch: float) -> void:
	_play(bank.get_stream(&"fanfare"), LEVEL["fanfare"], pitch)
	_cue_duck(CUE_DUCK["fanfare"][0], CUE_DUCK["fanfare"][1])
	cue.emit(&"fanfare", {"pitch": pitch})


func _on_collided(impact_speed: float, _normal: Vector3) -> void:
	var player := Birds.player()
	var pitch := clampf(pow(0.03 / AudioInput.num(player.mass if player else 0.03, 0.03, 0.001, 100.0), 0.08), 0.8, 1.2)
	# An impact that is not a number plays as the softest contact (a brush).
	impact_speed = AudioInput.num(impact_speed, 0.0, 0.0, 1000.0)
	if impact_speed <= 0.05:
		_play(bank.get_stream(&"brush"), LEVEL["brush"], pitch)
		cue.emit(&"brush", {})
	else:
		var db: float = LEVEL["bump_min"] + (LEVEL["bump_max"] - LEVEL["bump_min"]) * clampf(impact_speed / 8.0, 0.0, 1.0)
		_play(bank.get_stream(&"bump"), db, pitch)
		cue.emit(&"bump", {"impact": impact_speed, "db": db})


func _on_perched(_pos: Vector3) -> void:
	_play(bank.get_stream(&"brush"), LEVEL["perch"], 1.1)
	cue.emit(&"perch", {})


## UI sounds for the UI area: click, select, back, open, close, confirm,
## hover, each at its UI_LEVEL unless volume_db is given.
func play_ui(kind: StringName, volume_db: float = NAN) -> void:
	var st := bank.get_stream(StringName("ui_" + String(kind))) if bank else null
	if st == null or not is_inside_tree():
		return
	# No level (NAN, the default) or one that is not a finite number: the
	# kind's own level. An explicit one is kept within -80..+6 dB.
	volume_db = AudioInput.num(volume_db, UI_LEVEL.get(kind, -8.0), -80.0, 6.0)
	if not _ui.playing:
		_ui.play()
	var pb := _ui.get_stream_playback() as AudioStreamPlaybackPolyphonic
	if pb:
		pb.play_stream(st, 0.0, volume_db, 1.0)
	cue.emit(&"ui", {"kind": kind, "db": volume_db})


# -------------------------------------------------- state, pause, volume ---

func _on_state_changed(new_state: int, old_state: int) -> void:
	if new_state == Game.State.PAUSED and old_state != Game.State.PAUSED:
		play_ui(&"open")
	elif old_state == Game.State.PAUSED and new_state == Game.State.PLAYING:
		play_ui(&"close")
	var mix: Dictionary = STATE_MIX.get(new_state, STATE_MIX[Game.State.PLAYING])
	AudioBuses.set_muffle(AudioBuses.SFX, mix["muffle"])
	AudioBuses.set_muffle(AudioBuses.AMBIENCE, mix["muffle"])
	var gameplay := new_state == Game.State.PLAYING or new_state == Game.State.CAUGHT
	voices.scheduling = gameplay
	ambience.scheduling = gameplay


func _on_settings_changed(key: String, _value: Variant) -> void:
	if key in AudioBuses.SETTING.values():
		_apply_volumes()


func _apply_state_mix(instant: bool, dt: float = 0.0) -> void:
	var mix: Dictionary = STATE_MIX.get(Game.state, STATE_MIX[Game.State.PLAYING])
	var sfx_to: float = mix["sfx"]
	var amb_to: float = mix["amb"]
	var old := _duck_db
	var old_amb := _amb_duck_db
	if instant:
		_duck_db = sfx_to
		_amb_duck_db = amb_to
		_music_db = mix["music"]
		AudioBuses.set_muffle(AudioBuses.SFX, mix["muffle"])
		AudioBuses.set_muffle(AudioBuses.AMBIENCE, mix["muffle"])
		var gameplay := Game.state == Game.State.PLAYING or Game.state == Game.State.CAUGHT
		voices.scheduling = gameplay
		ambience.scheduling = gameplay
	else:
		# A linear ramp in dB (-20 dB in a third of a second) lands exactly.
		_duck_db = move_toward(_duck_db, sfx_to, DUCK_DB_PER_S * dt)
		_amb_duck_db = move_toward(_amb_duck_db, amb_to, DUCK_DB_PER_S * dt)
		var m_target: float = mix["music"]
		var g := db_to_linear(_music_db) if _music_db > SILENT else 0.0
		var tg := db_to_linear(m_target) if m_target > SILENT else 0.0
		g = move_toward(g, tg, dt / (MUSIC_FADE_IN if tg > g else MUSIC_FADE_OUT))
		_music_db = maxf(SILENT, linear_to_db(maxf(g, 1e-5)))
	if _music.stream:
		if absf(_music_db - _music_applied) > 0.01:
			_music_applied = _music_db
			_music.volume_db = _music_db + MUSIC_GAIN_DB if _music_db > SILENT else SILENT
		var audible := _music_db > -70.0
		if audible and not _music.playing:
			_music.play()
		elif _music.playing and _music.stream_paused == audible:
			_music.stream_paused = not audible
	if instant or old != _duck_db or old_amb != _amb_duck_db:
		_apply_volumes()


## The world's cue duck (Calls and Ambience buses) follows the flight
## layers' one: it drops at once with the cue (_cue_duck) and comes back
## with the layers' attack time once the cue is over. Buses are written
## only while it moves.
func _update_world_duck(dt: float) -> void:
	var want := _cue_duck_db if _cue_duck_t > 0.0 else 0.0
	if not is_finite(_world_duck_db):
		_world_duck_db = want
	var was := _world_duck_db
	if want <= _world_duck_db:
		_world_duck_db = want
	else:
		_world_duck_db = lerpf(_world_duck_db, want, 1.0 - exp(-dt / TAU_UP))
		if absf(_world_duck_db - want) < 0.05:
			_world_duck_db = want
	if _world_duck_db != was:
		voices.cue_duck_db = _world_duck_db
		_apply_volumes()


## Bus volume = Settings slider (perceptual taper) + state duck (+ the cue
## duck on the ambience).
func _apply_volumes() -> void:
	AudioBuses.set_volume(AudioBuses.MASTER, AudioBuses.volume_to_db(AudioBuses.setting_value(AudioBuses.MASTER, settings)))
	AudioBuses.set_volume(AudioBuses.MUSIC, AudioBuses.volume_to_db(AudioBuses.setting_value(AudioBuses.MUSIC, settings)))
	AudioBuses.set_volume(AudioBuses.SFX, AudioBuses.volume_to_db(AudioBuses.setting_value(AudioBuses.SFX, settings)) + _duck_db)
	AudioBuses.set_volume(AudioBuses.AMBIENCE, AudioBuses.volume_to_db(AudioBuses.setting_value(AudioBuses.AMBIENCE, settings)) + _amb_duck_db + _world_duck_db)
	AudioBuses.set_volume(AudioBuses.UI, AudioBuses.volume_to_db(AudioBuses.setting_value(AudioBuses.UI, settings)))


## Stops every sound and waits for the mixer thread to let go of them.
## Call (and await) before get_tree().quit(): the engine's AudioServer does
## not clear its playback list on exit, so sounds still playing at quit are
## reported as leaked resources.
func shutdown() -> void:
	set_process(false)
	for l in _layers:
		l.player.stop()
	for p in [_music, _oneshot, _ui]:
		p.stop()
	for w in _whoosh:
		w.stop()
	voices.stop_all()
	for c in ambience.get_children():
		if c is AudioStreamPlayer:
			(c as AudioStreamPlayer).stop()
		elif c is AudioStreamPlayer3D:
			(c as AudioStreamPlayer3D).stop()
	await get_tree().create_timer(0.1, true, false, true).timeout


func flight_params() -> Dictionary:
	return params


func bank_ready() -> bool:
	return bank != null and bank.is_ready()


## A readable snapshot for the dev HUD and logs.
func debug_snapshot() -> Dictionary:
	return {
		"state": Game.state_name(),
		"bank_ready": bank_ready(),
		"x": params.get("x", 0.0),
		"body_db": params.get("body_db", SILENT),
		"edge_db": params.get("edge_db", SILENT),
		"flutter_db": params.get("flutter_db", SILENT),
		"hum_db": params.get("hum_db", SILENT),
		"cutoff": _cut,
		"highpass": _hp,
		"threat": threat_level,
		"heart_bpm": 60.0 * FlightSoundMap.heart_rate(_danger_level) if FlightSoundMap.heart_db(_danger_level) > SILENT else 0.0,
		"voices": voices.active_count() if voices else 0,
		"zones": ambience.weights if ambience else {},
		"amb_speed_duck_db": ambience.duck_db if ambience else 0.0,
		"duck_db": _duck_db,
		"amb_duck_db": _amb_duck_db,
		"cue_duck_db": _world_duck_db,
		"music_db": _music_db,
		"perf_ms": perf_avg_ms(),
	}
