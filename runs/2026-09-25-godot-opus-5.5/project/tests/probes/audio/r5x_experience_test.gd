extends TestCase
## Round-5 verifier probes (experience & requirements lens) for the audio
## area. Measured on the engine's own mix (capture taps) or on the shipped
## files, aimed at what the earlier rounds did not cover:
##  * a living sky: how many NPC calls a player actually hears when the sky
##    is populated as the Ecosystem documents it (60 birds, mostly 60-110 m
##    out, spawns >= 40 m, prey within 80 m), at the start size and later;
##  * the shipped volume path: a director with no `settings` override reads
##    the Settings autoload and follows it live (the suite only drives an
##    in-memory store now);
##  * VR responsiveness: onset latency of the wingbeat, the crunch, the
##    stall buffet, the tuck and the danger cue after their trigger;
##  * fast flapping: each wingbeat stays a distinct transient and the pile
##    of whooshes keeps its headroom;
##  * the heartbeat through a continuous threat ramp (tempo rising steadily,
##    no dropped or doubled beats), as GameLoop emits it (0.02 steps);
##  * the shipped call recordings end at a natural decay, not mid-note.
## Only core contracts and the audio area's own fixture/public API are used.
## Run: tools/gd.sh audio_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/audio --suite=r5x
## Outputs: artifacts/audio/verify/r5x/.

const Fixture := preload("res://tests/unit/audio/audio_fixture.gd")
const ErrorLog := preload("res://tests/unit/audio/audio_error_log.gd")
const OUT := "audio/verify/r5x"

var fx: Fixture
var _out := {}


func before_all() -> void:
	DirAccess.make_dir_recursive_absolute(Paths.artifacts(OUT))


func after_all() -> void:
	var path := Paths.artifacts(OUT).path_join("measurements.json")
	var data := {}
	if FileAccess.file_exists(path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Dictionary:
			data = parsed
	for k in _out:
		data[k] = _out[k]
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "  ", true))
	f.close()
	await Fixture.wait(get_tree(), 0.3)


func before_each() -> void:
	Game.set_state(Game.State.PLAYING)
	fx = Fixture.new()
	fx.build(self)
	await wait_frames(2)


func after_each() -> void:
	fx.teardown()
	await Fixture.wait(get_tree(), 0.1)


# ------------------------------------------------------------ helpers ---

static func _db(x: float) -> float:
	return AudioAnalysis.db(x)


static func _fader(bus: StringName) -> float:
	return AudioServer.get_bus_volume_db(AudioServer.get_bus_index(bus))


## World scale for a species as flight sets it (span / (arm 1.6 + 0.2)).
static func _ws(species: StringName) -> float:
	return float(SizeRules.species_data(species)["span"]) / 1.8


## Flies the fixture player as `species` at cruise, level.
func _become(species: StringName) -> void:
	var m := float(SizeRules.species_data(species)["mass"])
	fx.player.mass = m
	fx.player.species = species
	var c := FlightSoundMap.cruise(m)
	fx.player.velocity = Vector3(0, 0, -c)
	fx.set_tel({"airspeed": c, "world_scale": _ws(species), "wing_extension": 1.0, "tucked": false,
		"stalled": false, "in_updraft": 0.0, "perched": false})


func _clear_npcs() -> void:
	for b in fx.npcs:
		if is_instance_valid(b):
			if b.is_inside_tree():
				b.get_parent().remove_child(b)
			b.queue_free()
	fx.npcs.clear()


## A continuous recording of a tap, drained every frame, with event marks
## at the sample the mixer had reached when the event fired.
class Rec:
	extends RefCounted
	var cap: AudioEffectCapture
	var frames := PackedVector2Array()
	var marks := {}

	func _init(c: AudioEffectCapture) -> void:
		cap = c
		cap.clear_buffer()

	func pump() -> void:
		var n := cap.get_frames_available()
		if n > 0:
			frames.append_array(cap.get_buffer(n))

	## The sample index "now" (everything mixed so far).
	func mark(name: String) -> void:
		pump()
		marks[name] = frames.size()

	func mono() -> PackedFloat32Array:
		return AudioAnalysis.split_frames(frames)["mono"]


func _run(rec: Rec, seconds: float) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(seconds * 1000.0):
		await get_tree().process_frame
		rec.pump()


func _run2(a: Rec, b: Rec, seconds: float) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(seconds * 1000.0):
		await get_tree().process_frame
		a.pump()
		b.pump()


## First time (s after `from`) the 10 ms RMS envelope of buf reaches
## `level` (linear), or INF.
static func _first_reach(buf: PackedFloat32Array, rate: float, from: int, level: float) -> float:
	var w := int(rate * 0.01)
	var i := from
	while i + w <= buf.size():
		if AudioAnalysis.rms(buf, i, i + w) >= level:
			return float(i + w - from) / rate
		i += w / 2
	return INF


# ------------------------------------------------------ a living sky ---

## The Ecosystem (AI.md) keeps ~60 NPCs "over the area the player circles,
## 60-110 m", spawns them no nearer than 40 m (SPAWN_MIN_SMALL), keeps prey
## "within 80 m 99-100 %, within 60 m 76-100 %", a 12-starling murmuration
## and a handful of threats patrolling. DESIGN: "You are a small bird in a
## big, alive sky" and audio must give "3D calls per species for NPCs".
## This lays the sky out that way around a player flying at cruise and
## counts the calls the director actually starts, per size. The birds
## circle the player at their distance (neither approaching nor leaving),
## so this is the sky's steady background, not a chase.
## Bar (verifier's, from the brief's "alive sky"): in a populated sky the
## player hears a bird call at least every 5 s on average at every size.
func _sky_layout(rng: RandomNumberGenerator) -> Array:
	var out := []
	var add := func(sp: StringName, d0: float, d1: float, n: int) -> void:
		for i in n:
			out.append([sp, rng.randf_range(d0, d1), rng.randf() * TAU, rng.randf_range(-10.0, 10.0)])
	# Murmuration: 12 starlings bunched ~85 m out.
	var ma := rng.randf() * TAU
	for i in 12:
		out.append([&"starling", 85.0 + rng.randf_range(-8.0, 8.0), ma + rng.randf_range(-0.12, 0.12), rng.randf_range(-6.0, 6.0)])
	add.call(&"wren", 40.0, 80.0, 3)       # prey for the small player
	add.call(&"moth", 40.0, 70.0, 4)       # "dust"
	add.call(&"sparrow", 50.0, 110.0, 5)   # peers
	add.call(&"swallow", 50.0, 110.0, 5)
	add.call(&"pigeon", 60.0, 140.0, 5)    # giants
	add.call(&"crow", 60.0, 140.0, 5)
	add.call(&"gull", 60.0, 140.0, 5)
	add.call(&"hawk", 60.0, 120.0, 3)      # threats patrolling (not attacking)
	add.call(&"eagle", 60.0, 120.0, 2)
	add.call(&"starling", 60.0, 110.0, 6)  # loose flocks
	add.call(&"sparrow", 60.0, 110.0, 5)
	return out


func test_living_sky_at_realistic_distances() -> void:
	var calls_cap := fx.tap(AudioBuses.CALLS)
	var wind_cap := fx.tap(AudioBuses.WIND)
	var sizes: Array[StringName] = [&"sparrow", &"pigeon", &"eagle"]
	var window := 14.0
	var res := {}
	var reach_table := {}
	for size in sizes:
		_clear_npcs()
		_become(size)
		var rng := RandomNumberGenerator.new()
		rng.seed = 505
		var at := fx.listener.global_position
		var lay := _sky_layout(rng)
		var birds: Array = []
		for e in lay:
			var b := fx.add_npc(e[0], at + Vector3(cos(e[2]) * e[1], e[3], sin(e[2]) * e[1]))
			b.state_str = "flock" if e[0] == &"starling" else "wander"
			birds.append([b, e[1], e[2], e[3]])
		await wait_frames(3)
		var v: CallVoices = fx.director.voices
		var started0: int = v.stats["started"]
		var species_heard := {}
		var nearest_heard := INF
		var calls := Rec.new(calls_cap)
		var wind := Rec.new(wind_cap)
		var t0 := Time.get_ticks_msec()
		var last := t0
		while Time.get_ticks_msec() - t0 < int(window * 1000.0):
			await get_tree().process_frame
			calls.pump()
			wind.pump()
			var now := Time.get_ticks_msec()
			var dt := (now - last) / 1000.0
			last = now
			# Circle the player at 8 m/s (distance unchanged).
			for bb in birds:
				var b: Node3D = bb[0]
				bb[2] = float(bb[2]) + 8.0 / float(bb[1]) * dt
				b.global_position = at + Vector3(cos(bb[2]) * bb[1], bb[3], sin(bb[2]) * bb[1])
			for p in v.playing():
				if p["bird"] != null:
					species_heard[String(p["species"])] = true
					nearest_heard = minf(nearest_heard, at.distance_to((p["bird"] as Bird).global_position))
		var started: int = int(v.stats["started"]) - started0
		var cm := calls.mono()
		var rate := AudioServer.get_mix_rate()
		var win := int(rate * 0.5)
		var windows := 0
		var with_call := 0
		var i := 0
		while i + win <= cm.size():
			windows += 1
			if _db(AudioAnalysis.rms(cm, i, i + win)) > -60.0:
				with_call += 1
			i += win
		var wl := AudioAnalysis.loudness_aw(wind.mono(), rate)
		var cl := AudioAnalysis.loudness_aw(cm, rate)
		# How far (world m) each species can be and still call, at this size.
		var reach := {}
		for sp in [&"wren", &"sparrow", &"starling", &"pigeon", &"crow", &"gull", &"hawk"]:
			reach[String(sp)] = snappedf(float(CallVoices.VOICE[sp]["reach"]) * _ws(size), 0.1)
		reach_table[String(size)] = reach
		var r := {"world_scale": snappedf(_ws(size), 0.001), "calls_started": started,
			"calls_per_min": snappedf(started * 60.0 / window, 0.1),
			"windows_with_a_call_pct": snappedf(100.0 * with_call / maxi(1, windows), 0.1),
			"species_heard": species_heard.keys(), "nearest_heard_m": snappedf(nearest_heard, 0.1) if is_finite(nearest_heard) else -1.0,
			"calls_bus_loudest_dBA": snappedf(float(cl["max"]), 0.1), "wind_dBA": snappedf(float(wl["mean"]), 0.1),
			"reach_world_m": reach}
		res[String(size)] = r
		print("[audio-verify] living sky %s: %s" % [size, r])
	_out["living_sky"] = res
	metric("living_sky", res)
	var xs := PackedFloat32Array([1.0, 2.0, 3.0])
	var cpm := PackedFloat32Array()
	var loud := PackedFloat32Array()
	for size in sizes:
		cpm.append(float(res[String(size)]["calls_per_min"]))
		loud.append(maxf(-80.0, float(res[String(size)]["calls_bus_loudest_dBA"]) - float(res[String(size)]["wind_dBA"])))
	AudioPlot.chart("R5 VERIFY: CALLS HEARD IN A SKY LAID OUT AS THE ECOSYSTEM DOES", [
		{"name": "CALLS STARTED PER MINUTE", "x": xs, "y": cpm, "dots": true, "line": true},
		{"name": "LOUDEST CALL (0.4 S) MINUS CRUISE WIND, DB A (-80 = NONE)", "x": xs, "y": loud, "dots": true, "line": true}],
		{"note": "60 NPCS, MOSTLY 60-110 M OUT (AI.MD). 1 SPARROW (WS 0.13)  2 PIGEON (WS 0.37)  3 EAGLE (WS 1.17). PLAYER AT CRUISE.",
		"x_label": "PLAYER SIZE", "y_label": "", "hlines": [{"y": 12.0, "label": "ONE CALL EVERY 5 S"}, {"y": 0.0, "label": "WIND LEVEL"}]}
		).save_png(Paths.artifacts(OUT).path_join("living_sky.png"))
	for size in sizes:
		var r: Dictionary = res[String(size)]
		gt(float(r["calls_started"]), window / 5.0 - 0.01,
			"%s-sized player (world_scale %.3f) in a sky laid out as the Ecosystem documents hears a call at least every 5 s: %d calls in %.0f s (reach in world m: %s)"
			% [size, r["world_scale"], r["calls_started"], window, r["reach_world_m"]])


# ---------------------------------------------- the shipped volume path ---

## The shipped director has no `settings` override: it reads the Settings
## autoload, and the UI's settings screen writes master_volume and
## music_volume through Settings.set_value. The suite now drives only an
## in-memory store, so this checks the production path: faders follow the
## autoload live, with the documented taper, and muting works.
## (This sandbox has its own user://, so the writes are local; restored.)
func test_shipped_settings_path_is_live() -> void:
	var keys := ["master_volume", "music_volume", "sfx_volume", "ambience_volume", "ui_volume"]
	var saved := {}
	for k in keys:
		saved[k] = Settings.get_value(k, AudioBuses.SETTING_DEFAULT[k])
	# Replace the fixture's director with a shipped one (settings = null).
	var old := fx.director
	old.get_parent().remove_child(old)
	old.free()
	var d := (load(Fixture.DIRECTOR) as PackedScene).instantiate() as AudioDirector
	d.async_build = false
	fx.root.add_child(d)
	fx.director = d
	await wait_frames(2)
	var got := {}
	Settings.set_value("master_volume", 0.25)
	got["master_0.25"] = _fader(AudioBuses.MASTER)
	Settings.set_value("music_volume", 0.0)
	got["music_0"] = _fader(AudioBuses.MUSIC)
	got["music_0_muted"] = AudioServer.is_bus_mute(AudioServer.get_bus_index(AudioBuses.MUSIC))
	Settings.set_value("music_volume", 0.5)
	got["music_0.5"] = _fader(AudioBuses.MUSIC)
	got["music_0.5_muted"] = AudioServer.is_bus_mute(AudioServer.get_bus_index(AudioBuses.MUSIC))
	Settings.set_value("master_volume", 1.0)
	got["master_1"] = _fader(AudioBuses.MASTER)
	for k in keys:
		Settings.set_value(k, saved[k])
	_out["settings_path"] = got
	print("[audio-verify] shipped settings path: %s" % [got])
	near(float(got["master_0.25"]), 40.0 * log(0.25) / log(10.0), 0.05, "master_volume 0.25 via the Settings autoload lands on Master at once")
	check(bool(got["music_0_muted"]), "music_volume 0 mutes the Music bus")
	near(float(got["music_0.5"]), -12.04, 0.05, "music_volume 0.5 -> -12 dB, unmuted")
	check(not bool(got["music_0.5_muted"]), "music unmuted again")
	near(float(got["master_1"]), 0.0, 0.05, "master_volume 1 -> 0 dB")


# ------------------------------------------------ VR responsiveness ---

## In VR a sound that lags its cause by more than a few tens of ms reads as
## detached. From the trigger (event or telemetry change) to the sound on
## its bus, measured in mixed samples: wingbeat and crunch reach within
## 6 dB of their peak in <= 80 ms; the stall buffet reaches within 6 dB of
## its steady level in <= 150 ms; the tuck's bright edge (Wind bus above
## 3 kHz) comes within 3 dB of its steady level in <= 250 ms; the danger cue
## (threat 0 -> 0.5) reaches within 6 dB of its steady level in <= 250 ms.
func test_cue_onsets_follow_their_cause() -> void:
	var rate := AudioServer.get_mix_rate()
	var body := fx.tap(AudioBuses.BODY)
	var sfx := fx.tap(AudioBuses.SFX)
	var windb := fx.tap(AudioBuses.WIND)
	var dang := fx.tap(AudioBuses.DANGER)
	var c := FlightSoundMap.cruise(0.03)
	fx.set_tel({"airspeed": 0.6 * c, "world_scale": _ws(&"sparrow")})
	await Fixture.wait(get_tree(), 0.6)
	var res := {}
	# Wingbeat (right wing, full strength).
	var r := Rec.new(body)
	await _run(r, 0.15)
	r.mark("flap")
	Events.player_flapped.emit(1, 1.0)
	await _run(r, 0.45)
	var m := r.mono()
	var pk := AudioAnalysis.peak(AudioAnalysis.envelope(m.slice(int(r.marks["flap"])), rate, 0.01))
	res["whoosh_ms"] = 1000.0 * _first_reach(m, rate, int(r.marks["flap"]), pk * 0.5)
	# Catch crunch.
	var prey := fx.add_npc(&"wren", fx.listener.global_position + Vector3(0, 0, -0.5))
	await Fixture.wait(get_tree(), 0.4)
	var s := Rec.new(sfx)
	await _run(s, 0.15)
	s.mark("catch")
	Events.bird_caught.emit(fx.player, prey)
	await _run(s, 0.35)
	var sm := s.mono()
	var from := int(s.marks["catch"])
	var pre := AudioAnalysis.rms(sm, from - int(rate * 0.1), from)
	var spk := AudioAnalysis.peak(AudioAnalysis.envelope(sm.slice(from), rate, 0.01))
	res["crunch_ms"] = 1000.0 * _first_reach(sm, rate, from, maxf(spk * 0.5, pre * 2.0))
	await Fixture.wait(get_tree(), 0.5)
	# Stall buffet onset.
	var b := Rec.new(body)
	await _run(b, 0.2)
	b.mark("stall")
	fx.set_tel({"stalled": true})
	await _run(b, 0.8)
	var bm := b.mono()
	var steady := AudioAnalysis.rms(bm, int(b.marks["stall"]) + int(rate * 0.4), bm.size())
	res["buffet_ms"] = 1000.0 * _first_reach(bm, rate, int(b.marks["stall"]), steady * 0.5)
	fx.set_tel({"stalled": false, "airspeed": 2.2 * c})
	await Fixture.wait(get_tree(), 0.8)
	# Tuck at 2.2x: the bright edge above 3 kHz.
	var w := Rec.new(windb)
	await _run(w, 0.3)
	w.mark("tuck")
	fx.set_tel({"tucked": true, "wing_extension": 0.1})
	await _run(w, 0.9)
	var wm := w.mono()
	var t_at := int(w.marks["tuck"])
	var hi_env := PackedFloat32Array()
	var hop := int(rate * 0.01)
	var frames := AudioAnalysis.stft(wm, 1024, hop)
	for fr in frames:
		var e := 0.0
		for k in range(int(3000.0 / (rate / 1024.0)), fr.size()):
			e += fr[k] * fr[k]
		hi_env.append(e)
	var steady_hi := 0.0
	var n_st := 0
	for k in range(int((t_at + int(rate * 0.55)) / float(hop)), hi_env.size()):
		steady_hi += hi_env[k]
		n_st += 1
	steady_hi /= maxf(1.0, n_st)
	var tuck_ms := INF
	for k in range(int(t_at / float(hop)), hi_env.size()):
		if hi_env[k] >= steady_hi * 0.5:
			tuck_ms = (k * hop + 1024 - t_at) * 1000.0 / rate
			break
	res["tuck_edge_ms"] = tuck_ms
	fx.set_tel({"tucked": false, "wing_extension": 1.0, "airspeed": c})
	await Fixture.wait(get_tree(), 0.5)
	# Danger 0 -> 0.5.
	var hawk := fx.add_npc(&"hawk", fx.listener.global_position + Vector3(0, 10, -60))
	var dr := Rec.new(dang)
	await _run(dr, 0.2)
	dr.mark("threat")
	Events.threat_changed.emit(0.5, hawk)
	await _run(dr, 1.6)
	var dm := dr.mono()
	var dsteady := AudioAnalysis.rms(dm, int(dr.marks["threat"]) + int(rate * 0.6), dm.size())
	res["danger_ms"] = 1000.0 * _first_reach(dm, rate, int(dr.marks["threat"]), dsteady * 0.5)
	Events.threat_changed.emit(0.0, null)
	for k in res:
		res[k] = snappedf(float(res[k]), 0.1) if is_finite(float(res[k])) else -1.0
	_out["onsets"] = res
	metric("onsets", res)
	print("[audio-verify] onsets (ms from trigger to within 6 dB / 3 dB): %s" % [res])
	between(float(res["whoosh_ms"]), 0.0, 80.0, "wingbeat within 6 dB of its peak <= 80 ms after the flap event")
	between(float(res["crunch_ms"]), 0.0, 80.0, "crunch within 6 dB of its peak <= 80 ms after the catch")
	between(float(res["buffet_ms"]), 0.0, 150.0, "stall buffet within 6 dB of steady <= 150 ms after the stall")
	between(float(res["tuck_edge_ms"]), 0.0, 250.0, "tuck's bright edge within 3 dB of steady <= 250 ms")
	between(float(res["danger_ms"]), 0.0, 250.0, "danger cue (0 -> 0.5) within 6 dB of steady <= 250 ms")


# ------------------------------------------------------ fast flapping ---

## A small bird hovering flaps hard and fast. Every wingbeat must stay a
## distinct transient (not smear into a hiss): within each flap period the
## Body bus's 10 ms envelope swings >= 10 dB at a realistic 3 Hz and
## >= 6 dB at an extreme 5 Hz; no flap's 10 ms peak lands more than 3 dB
## over a lone flap's (the tails do not pile up) and the mix keeps headroom
## (pre-limiter Master peak < -1.5 dBFS). Also a large bird at 2 Hz (its
## whoosh is the longest).
func test_fast_flapping_keeps_each_beat_distinct() -> void:
	var rate := AudioServer.get_mix_rate()
	var body := fx.tap(AudioBuses.BODY)
	var pre := fx.tap(AudioBuses.MASTER, 0)
	var res := {}
	for case in [[&"sparrow", 3.0], [&"sparrow", 5.0], [&"eagle", 2.0]]:
		var sp: StringName = case[0]
		var hz: float = case[1]
		_become(sp)
		fx.set_tel({"airspeed": 0.3 * FlightSoundMap.cruise(fx.player.mass)})
		await Fixture.wait(get_tree(), 0.5)
		# One flap alone for reference.
		var one := Rec.new(body)
		Events.player_flapped.emit(0, 1.0)
		await _run(one, 0.6)
		var one_l := float(AudioAnalysis.loudness_aw(one.mono(), rate)["max"])
		var one_pk := AudioAnalysis.peak(AudioAnalysis.envelope(one.mono(), rate, 0.01))
		await Fixture.wait(get_tree(), 0.3)
		var rb := Rec.new(body)
		var rp := Rec.new(pre)
		var period := 1.0 / hz
		var n := int(3.0 * hz)
		var t0 := Time.get_ticks_msec()
		var fired := 0
		var starts: Array[int] = []
		while fired < n or Time.get_ticks_msec() - t0 < int((n * period + 0.4) * 1000.0):
			await get_tree().process_frame
			rb.pump()
			rp.pump()
			if fired < n and Time.get_ticks_msec() - t0 >= int(fired * period * 1000.0):
				starts.append(rb.frames.size())
				Events.player_flapped.emit(0, 1.0)
				fired += 1
		var bm := rb.mono()
		var depths := PackedFloat32Array()
		var worst_pk := 0.0
		for k in range(1, starts.size() - 1):
			var a := starts[k]
			var e := starts[k + 1]
			var env := AudioAnalysis.envelope(bm.slice(a, e), rate, 0.01)
			if env.size() < 3:
				continue
			var hi := 0.0
			var lo := INF
			for x in env:
				hi = maxf(hi, x)
				lo = minf(lo, x)
			depths.append(_db(hi) - _db(maxf(lo, 1e-7)))
			worst_pk = maxf(worst_pk, hi)
		depths.sort()
		var many_l := float(AudioAnalysis.loudness_aw(bm, rate)["max"])
		var pd := AudioAnalysis.split_frames(rp.frames)
		var ppk := _db(maxf(AudioAnalysis.peak(pd["l"]), AudioAnalysis.peak(pd["r"])))
		var key := "%s_%dHz" % [sp, int(hz)]
		res[key] = {"min_depth_db": snappedf(depths[0], 0.1) if depths.size() > 0 else -1.0,
			"median_depth_db": snappedf(AudioAnalysis.median(depths), 0.1) if depths.size() > 0 else -1.0,
			"loudest_0.4s_over_one_dBA": snappedf(many_l - one_l, 0.1),
			"flap_peak_over_lone_flap_db": snappedf(_db(worst_pk) - _db(one_pk), 0.1), "prelimiter_peak_dbfs": snappedf(ppk, 0.01)}
		print("[audio-verify] fast flapping %s: %s" % [key, res[key]])
		await Fixture.wait(get_tree(), 0.4)
	_out["fast_flapping"] = res
	metric("fast_flapping", res)
	gt(float(res["sparrow_3Hz"]["min_depth_db"]), 10.0, "sparrow at 3 Hz: every wingbeat distinct (envelope swing >= 10 dB)")
	gt(float(res["eagle_2Hz"]["min_depth_db"]), 10.0, "eagle at 2 Hz: every wingbeat distinct (>= 10 dB)")
	gt(float(res["sparrow_5Hz"]["min_depth_db"]), 6.0, "sparrow at 5 Hz: wingbeats still distinct (>= 6 dB)")
	for k in res:
		lt(float(res[k]["flap_peak_over_lone_flap_db"]), 3.0, "%s: no wingbeat's 10 ms peak more than 3 dB over a lone flap's (no pile-up)" % k)
		lt(float(res[k]["prelimiter_peak_dbfs"]), -1.5, "%s: headroom kept (pre-limiter peak)" % k)


# ------------------------------------------- heartbeat through a ramp ---

## A hawk closes in: GameLoop re-emits the threat whenever it moves by 0.02,
## here from 0.3 to 1.0 over 6 s. On the Danger bus's 30-110 Hz band (the
## heart's fundamental; the drone has nothing there) every beat is found:
## the lub-to-lub period must shorten steadily (no period more than 40 ms
## longer than the one before), stay within 0.5-1.0 s (60-111 bpm by
## design, a little latency allowed), and follow the design's tempo for the
## level at that moment within 12% (after the 0.15 s generator latency).
## No beat may be dropped or doubled (lub-dub pairs strictly alternate
## short/long gaps).
func test_heartbeat_through_a_threat_ramp() -> void:
	var rate := AudioServer.get_mix_rate()
	var dang := fx.tap(AudioBuses.DANGER)
	var hawk := fx.add_npc(&"hawk", fx.listener.global_position + Vector3(0, 10, -40))
	Events.threat_changed.emit(0.3, hawk)
	await Fixture.wait(get_tree(), 1.2)
	var r := Rec.new(dang)
	r.mark("start")
	var t0 := Time.get_ticks_msec()
	var lv := 0.3
	var emitted := 0.3
	var level_at := []  # [sample, level]
	while Time.get_ticks_msec() - t0 < 7000:
		await get_tree().process_frame
		r.pump()
		var t := (Time.get_ticks_msec() - t0) / 1000.0
		lv = clampf(0.3 + 0.7 * t / 6.0, 0.3, 1.0)
		if absf(lv - emitted) >= 0.02 or (lv >= 1.0 and emitted < 1.0):
			emitted = lv
			Events.threat_changed.emit(lv, hawk)
		level_at.append([r.frames.size(), emitted])
	Events.threat_changed.emit(0.0, null)
	var m := r.mono()
	# Band envelope 30-110 Hz, 2048-point frames, 5 ms hop.
	var hop := int(rate * 0.005)
	var frames := AudioAnalysis.stft(m, 2048, hop)
	var k_lo := int(30.0 / (rate / 2048.0))
	var k_hi := int(110.0 / (rate / 2048.0)) + 1
	var env := PackedFloat32Array()
	for fr in frames:
		var e := 0.0
		for k in range(k_lo, mini(k_hi, fr.size())):
			e += fr[k] * fr[k]
		env.append(e)
	var mx := 0.0
	for x in env:
		mx = maxf(mx, x)
	# Onsets: rising crossings of 10% of the local (1 s) max power, 120 ms refractory.
	var onsets: Array[float] = []
	var last_on := -1e9
	var above := false
	for i in env.size():
		var a0 := maxi(0, i - int(0.5 / 0.005))
		var a1 := mini(env.size(), i + int(0.5 / 0.005))
		var lm := 0.0
		for j in range(a0, a1):
			lm = maxf(lm, env[j])
		var th := 0.1 * lm
		var t := (i * hop + 1024) / rate
		if env[i] >= th and not above and t - last_on > 0.12:
			onsets.append(t)
			last_on = t
		above = env[i] >= th
	# Alternating gaps: lub -> dub short, dub -> lub long.
	var gaps: Array[float] = []
	for i in range(1, onsets.size()):
		gaps.append(onsets[i] - onsets[i - 1])
	# The sign of successive gap differences must flip every step.
	var alternates := gaps.size() >= 3
	for i in range(2, gaps.size()):
		if (gaps[i] > gaps[i - 1]) == (gaps[i - 1] > gaps[i - 2]):
			alternates = false
	# If the first gap is long it runs dub -> lub, so onset 1 is a lub.
	var start_i := 1 if gaps.size() > 1 and gaps[0] > gaps[1] else 0
	var lubs: Array[float] = []
	for i in range(start_i, onsets.size(), 2):
		lubs.append(onsets[i])
	var periods: Array[float] = []
	var worst_rise := 0.0
	var worst_dev := 0.0
	for i in range(1, lubs.size()):
		var p := lubs[i] - lubs[i - 1]
		periods.append(p)
		if periods.size() >= 2:
			worst_rise = maxf(worst_rise, p - periods[periods.size() - 2])
		# The design's tempo at the level ~0.15 s before this beat began.
		var s_at := int((lubs[i - 1] - 0.15) * rate)
		var l_then := 0.3
		for la in level_at:
			if int(la[0]) <= s_at:
				l_then = float(la[1])
		var want := 1.0 / FlightSoundMap.heart_rate(l_then)
		worst_dev = maxf(worst_dev, absf(p - want) / want)
	var pmin := 99.0
	var pmax := 0.0
	for p in periods:
		pmin = minf(pmin, p)
		pmax = maxf(pmax, p)
	var res := {"onsets": onsets.size(), "beats": lubs.size(), "periods": periods.map(func(p: float) -> float: return snappedf(p, 0.001)),
		"gaps": gaps.map(func(g: float) -> float: return snappedf(g, 0.001)),
		"alternating": alternates, "worst_period_rise_s": snappedf(worst_rise, 0.001), "worst_tempo_dev": snappedf(worst_dev, 0.001),
		"period_min": snappedf(pmin, 0.001), "period_max": snappedf(pmax, 0.001)}
	_out["heart_ramp"] = res
	metric("heart_ramp", res)
	print("[audio-verify] heartbeat through a 0.3 -> 1.0 ramp: %s" % [res])
	gt(float(lubs.size()), 7.0, "at least 8 beats found in 7 s")
	check(alternates, "lub-dub gaps strictly alternate short/long (no dropped or doubled beat): %s" % [res["gaps"]])
	lt(worst_rise, 0.04, "the beat never slows by more than 40 ms while the threat rises")
	between(pmin, 0.5, 1.0, "fastest period within 0.5-1.0 s")
	between(pmax, 0.5, 1.0, "slowest period within 0.5-1.0 s")
	lt(worst_dev, 0.12, "each period within 12% of the design tempo for the level then")


# ---------------------------------- recordings end at a natural decay ---

## The shipped calls are cut from longer recordings. The builder's trim
## rule (call_prep.gd) ends a call "once it has decayed 40 dB", then fades
## the last 40 ms. Where the source window ends first, the fade lands on a
## note that is still sounding: the call stops dead. Bar: the 50 ms just
## before the final 40 ms fade sit >= 20 dB under the clip's loudest 50 ms
## (a note cut higher than that is heard as chopped).
func test_calls_end_at_a_natural_decay() -> void:
	var bank: AudioBank = fx.director.bank
	var rows := {}
	var chopped: Array[String] = []
	for sp in [&"wren", &"sparrow", &"swallow", &"pigeon", &"crow", &"gull", &"hawk", &"eagle"]:
		for st in bank.calls_for(sp):
			var clip := String((st as AudioStream).get_meta(&"clip", ""))
			var pcm := AudioAnalysis.clip_pcm(st)
			if pcm.is_empty():
				fail("could not decode %s" % clip)
				continue
			var buf: PackedFloat32Array = pcm["mono"]
			var rate := float(pcm["rate"])
			var w := int(0.05 * rate)
			var loud := 0.0
			var i := 0
			while i + w <= buf.size():
				loud = maxf(loud, AudioAnalysis.rms(buf, i, i + w))
				i += w / 4
			var endl := AudioAnalysis.rms(buf, buf.size() - int(0.09 * rate), buf.size() - int(0.04 * rate))
			var rel := _db(endl) - _db(loud)
			rows[clip] = snappedf(rel, 0.1)
			if rel > -20.0:
				chopped.append("%s %.1f dB" % [clip, rel])
	var series := []
	for name in ["hawk_1", "hawk_3", "gull_4", "wren_1"]:
		for sp in [&"hawk", &"gull", &"wren"]:
			for st in bank.calls_for(sp):
				if String((st as AudioStream).get_meta(&"clip", "")) != name:
					continue
				var pcm2 := AudioAnalysis.clip_pcm(st)
				var b2: PackedFloat32Array = pcm2["mono"]
				var r2 := float(pcm2["rate"])
				var env := AudioAnalysis.envelope(b2, r2, 0.005)
				var lpk := 0.0
				for x in env:
					lpk = maxf(lpk, x)
				var xs2 := PackedFloat32Array()
				var ys2 := PackedFloat32Array()
				var n0 := maxi(0, env.size() - int(0.4 / 0.005))
				for k in range(n0, env.size()):
					xs2.append((k - env.size()) * 0.005)
					ys2.append(maxf(-80.0, _db(env[k]) - _db(lpk)))
				series.append({"name": name.to_upper() + " (%.1f DB)" % float(rows.get(name, 0.0)), "x": xs2, "y": ys2, "line": true})
	AudioPlot.chart("R5 VERIFY: HOW THE SHIPPED CALLS END", series,
		{"note": "5 MS ENVELOPE OF THE LAST 0.4 S, DB RE THE CLIP'S PEAK WINDOW. HAWK_1 DECAYS; HAWK_3, GULL_4, WREN_1 ARE CUT BY A 40 MS FADE.",
		"x_label": "SECONDS BEFORE THE END", "y_min": -80.0, "y_max": 0.0}).save_png(Paths.artifacts(OUT).path_join("call_endings.png"))
	_out["call_endings_db_re_loudest"] = rows
	metric("call_endings", rows)
	print("[audio-verify] call endings (50 ms before the end fade, dB re loudest 50 ms): %s" % [rows])
	print("[audio-verify] chopped: %s" % [chopped])
	eq(chopped.size(), 0, "every call ends at a natural decay (>= 20 dB down before its 40 ms fade); chopped: %s" % [chopped])


# ------------------------------------------- the big player's chorus ---

## At eagle size every NPC in the sky is in reach. Calls then compete for the
## 8 voices, and a stolen voice fades out in 50 ms: a call cut short. How
## many of the calls the player hears are cut before their end? Layout as
## above, and again with every distance doubled (an eagle's sky is wider).
## Bar (verifier's): at most a quarter of started calls are stolen, i.e.
## most calls are heard to their end rather than as fragments.
func test_big_player_chorus_is_not_fragmented() -> void:
	var res := {}
	for spread in [1.0, 2.0]:
		_clear_npcs()
		_become(&"eagle")
		var rng := RandomNumberGenerator.new()
		rng.seed = 505
		var at := fx.listener.global_position
		for e in _sky_layout(rng):
			var b := fx.add_npc(e[0], at + Vector3(cos(e[2]) * e[1] * spread, e[3], sin(e[2]) * e[1] * spread))
			b.state_str = "flock" if e[0] == &"starling" else "wander"
		await wait_frames(3)
		var v: CallVoices = fx.director.voices
		var s0: Dictionary = v.stats.duplicate()
		# Track how long each voice's call runs before it fades or ends.
		var began := {}
		var lengths := PackedFloat32Array()
		var cut := PackedFloat32Array()
		var t0 := Time.get_ticks_msec()
		var prev_stream := {}
		while Time.get_ticks_msec() - t0 < 10000:
			await get_tree().process_frame
			var now := (Time.get_ticks_msec() - t0) / 1000.0
			for i in v.voices.size():
				var vo: CallVoices.Voice = v.voices[i]
				var key := "%d:%d" % [i, vo.player.stream.get_instance_id() if vo.player.stream else 0]
				var sounding := vo.player.playing and not vo.fading
				if sounding and (not began.has(i) or began[i][1] != vo.started):
					began[i] = [now, vo.started, (vo.player.stream as AudioStream).get_length() / maxf(vo.player.pitch_scale, 0.01)]
				elif not sounding and began.has(i):
					var ran: float = now - float(began[i][0])
					var full: float = began[i][2]
					lengths.append(ran)
					if vo.fading or ran < full - 0.15:
						cut.append(ran / full)
					began.erase(i)
		var started: int = int(v.stats["started"]) - int(s0["started"])
		var stolen: int = int(v.stats["stolen"]) - int(s0["stolen"])
		var dropped: int = int(v.stats["dropped"]) - int(s0["dropped"])
		var k := "spread_x%d" % int(spread)
		res[k] = {"started": started, "stolen": stolen, "dropped": dropped,
			"stolen_share": snappedf(float(stolen) / maxi(1, started), 0.01),
			"calls_ended": lengths.size(), "cut_short": cut.size(),
			"cut_short_share": snappedf(float(cut.size()) / maxi(1, lengths.size()), 0.01),
			"median_played_s": snappedf(AudioAnalysis.median(lengths), 0.01) if lengths.size() > 0 else -1.0}
		print("[audio-verify] eagle chorus %s: %s" % [k, res[k]])
	_out["eagle_chorus"] = res
	metric("eagle_chorus", res)
	for k in res:
		lt(float(res[k]["cut_short_share"]), 0.25, "%s: at most a quarter of the calls heard are cut short by stealing (%s)" % [k, res[k]])
