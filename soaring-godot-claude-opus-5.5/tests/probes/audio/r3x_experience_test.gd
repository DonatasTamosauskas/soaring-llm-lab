extends TestCase
## Round-3 verifier probes (experience & requirements lens) for the audio
## area. Everything is measured on the engine's own mix (capture taps), with
## the shipped Settings, the way a player meets it:
##  * how loud the game is at the output in ordinary play, against the menu
##    music (does pressing Play drop the level off a cliff?);
##  * whether the danger cue (heart + drone) is audible over the wind the
##    player is actually flying in (AU4 says it scales; can it be heard?);
##  * whether the reward cues (catch, tier-up, wingbeat) cut through flight;
##  * the pause menu entered from the loudest gameplay state;
##  * the chased prey's call at cruise, and left/right placement of calls;
##  * a long chaotic session (bird churn, pause spam, threats, catches,
##    world-scale changes): no errors, voice cap, clean release;
##  * extreme world scales (0.05, 5.0).
## Measurements go to artifacts/audio/verify/r3x/measurements.json, a plot
## to artifacts/audio/verify/r3x/*.png.

const Fixture := preload("res://tests/unit/audio/audio_fixture.gd")
const ErrorLog := preload("res://tests/unit/audio/audio_error_log.gd")
const SPARROW_WS := 0.24 / 1.7
const OCT: Array[float] = [63.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0]

var fx: Fixture
var _out := {}


func before_all() -> void:
	DirAccess.make_dir_recursive_absolute(Paths.artifacts("audio/verify/r3x"))
	Fixture.restore_default_settings()


func after_all() -> void:
	Fixture.restore_default_settings()
	# Merge into the file, so a single-test rerun keeps the other results.
	var path := Paths.artifacts("audio/verify/r3x").path_join("measurements.json")
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
	Fixture.restore_default_settings()
	fx = Fixture.new()
	fx.build(self)
	await wait_frames(2)


func after_each() -> void:
	fx.teardown()
	Fixture.restore_default_settings()
	await Fixture.wait(get_tree(), 0.1)


# ------------------------------------------------------------ helpers ---

static func _biquad_mag2(b0: float, b1: float, b2: float, a1: float, a2: float, om: float) -> float:
	var nr := b0 + b1 * cos(om) + b2 * cos(2.0 * om)
	var ni := -(b1 * sin(om) + b2 * sin(2.0 * om))
	var dr := 1.0 + a1 * cos(om) + a2 * cos(2.0 * om)
	var di := -(a1 * sin(om) + a2 * sin(2.0 * om))
	return (nr * nr + ni * ni) / maxf(dr * dr + di * di, 1e-30)


## ITU-R BS.1770 K-weighting (shelf + RLB high-pass, the 48 kHz
## coefficients evaluated at each bin's frequency), power per bin.
static func _k_weights(n: int, rate: float) -> PackedFloat32Array:
	var w := PackedFloat32Array()
	w.resize(n / 2 + 1)
	for i in w.size():
		var om := TAU * (i * rate / n) / 48000.0
		w[i] = _biquad_mag2(1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585, om) \
			* _biquad_mag2(1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621, om)
	return w


## Mean square of one channel after a per-bin weighting (Hann STFT: bin
## powers sum to 3x the mean square).
static func _weighted_ms(buf: PackedFloat32Array, w: PackedFloat32Array) -> float:
	var frames := AudioAnalysis.stft(buf, 1024, 512)
	if frames.is_empty():
		return 0.0
	var acc := 0.0
	for fr in frames:
		var s := 0.0
		for i in fr.size():
			s += fr[i] * fr[i] * w[i]
		acc += s / AudioAnalysis.BIN_POWER_PER_MS
	return acc / frames.size()


## Ungated integrated loudness (LUFS) of a stereo recording, plus a fader.
static func _lufs(rec: Dictionary, fader_db: float = 0.0) -> float:
	var w := _k_weights(1024, rec["rate"])
	var ms := _weighted_ms(rec["l"], w) + _weighted_ms(rec["r"], w)
	return -0.691 + 10.0 * log(maxf(ms, 1e-30)) / log(10.0) + fader_db


## Octave-band levels (dB RMS-referenced) of a mono buffer's mean power.
static func _octaves(buf: PackedFloat32Array, rate: float) -> PackedFloat32Array:
	var frames := AudioAnalysis.stft(buf, 2048, 1024)
	var p := PackedFloat32Array()
	p.resize(1025)
	p.fill(0.0)
	for fr in frames:
		for i in fr.size():
			p[i] += fr[i] * fr[i]
	for i in p.size():
		p[i] /= maxf(1.0, frames.size())
	var out := PackedFloat32Array()
	for f in OCT:
		out.append(AudioAnalysis.band_db(p, rate, f / sqrt(2.0), f * sqrt(2.0)))
	return out


## A-weighted power per STFT frame (hop 512), RMS-referenced.
static func _aw_frames(buf: PackedFloat32Array, rate: float) -> PackedFloat32Array:
	var w := AudioAnalysis.a_weights(1024, rate)
	var out := PackedFloat32Array()
	for fr in AudioAnalysis.stft(buf, 1024, 512):
		var s := 0.0
		for i in fr.size():
			s += fr[i] * fr[i] * w[i]
		out.append(s / AudioAnalysis.BIN_POWER_PER_MS)
	return out


## Loudest `win`-second A-weighted window (full windows only) between
## times t0 and t1 of a frame series (hop 512 at rate).
static func _aw_max(fp: PackedFloat32Array, rate: float, t0: float, t1: float, win: float) -> float:
	var hop := 512.0 / rate
	var per := maxi(1, int(round(win / hop)))
	var a := maxi(0, int(t0 / hop))
	var b := mini(fp.size(), int(t1 / hop))
	var best := 0.0
	for k in range(a, b - per + 1):
		var s := 0.0
		for j in per:
			s += fp[k + j]
		best = maxf(best, s / per)
	return 10.0 * log(maxf(best, 1e-30)) / log(10.0)


static func _db(x: float) -> float:
	return AudioAnalysis.db(x)


func _fader(bus: StringName) -> float:
	return AudioServer.get_bus_volume_db(AudioServer.get_bus_index(bus))


## Fires `fn` after `delay` s (process-always timer).
func _later(delay: float, fn: Callable) -> void:
	get_tree().create_timer(delay, true, false, true).timeout.connect(fn)


# ------------------------------------------ loudness of ordinary play ---

## The level a player actually hears, at the output with the shipped
## settings: the menu (music), then ordinary play. A demanding director
## expects no cliff when Play is pressed, and ordinary flight to be in the
## ballpark of what platforms ask of a game mix (ASWG-R001: -18 LUFS for
## portable devices, -24 for consoles). Measured ungated over 2 s.
func test_ordinary_play_is_not_a_cliff_below_the_menu() -> void:
	var marks: Array[Dictionary] = [
		{"name": "meadow", "kind": "meadow", "position": Vector3(0, 0, 0), "radius": 300.0},
		{"name": "wood", "kind": "forest", "position": Vector3(800, 0, 0), "radius": 200.0},
	]
	fx.add_world(marks)
	fx.director.ambience.set_world(fx.world)
	var master := fx.tap(AudioBuses.MASTER)  # after the limiter, before the master fader
	var master_fader := _fader(AudioBuses.MASTER)
	var res := {}
	var cruise := FlightSoundMap.cruise(0.03)
	var callers: Array[Bird] = []
	var scenes := [
		["menu", Game.State.MENU, Vector3(0, 2, 0), {"airspeed": 0.0, "perched": true}, false, false],
		["perched_forest_birds", Game.State.PLAYING, Vector3(800, 3, 0), {"airspeed": 0.0, "perched": true}, false, true],
		["glide_cruise_20m", Game.State.PLAYING, Vector3(0, 20, 0), {"airspeed": cruise, "perched": false}, false, false],
		["flapping_cruise_5m", Game.State.PLAYING, Vector3(0, 5, 0), {"airspeed": cruise, "perched": false}, true, true],
		["slow_glide_0.6x_5m", Game.State.PLAYING, Vector3(0, 5, 0), {"airspeed": cruise * 0.6, "perched": false}, false, false],
		["dive_2.4x_tucked", Game.State.PLAYING, Vector3(0, 30, 0), {"airspeed": cruise * 2.4, "perched": false, "tucked": true, "wing_extension": 0.1}, false, false],
	]
	for sc in scenes:
		Game.set_state(sc[1])
		fx.listener.global_position = sc[2]
		fx.player.global_position = sc[2]
		fx.set_tel({"tucked": false, "wing_extension": 1.0})
		fx.set_tel(sc[3])
		for b in callers:
			if is_instance_valid(b):
				fx.npcs.erase(b)
				b.queue_free()
		callers.clear()
		if sc[5]:
			for sp in [[&"wren", Vector3(6, 1, -4)], [&"sparrow", Vector3(-8, 0, 3)], [&"starling", Vector3(3, 4, 9)], [&"crow", Vector3(-20, 8, -15)]]:
				callers.append(fx.add_npc(sp[0], sc[2] + sp[1]))
		await Fixture.wait(get_tree(), 1.8 if sc[0] != "menu" else 2.2)
		fx.director.ambience.settle(sc[2])
		var driver := Timer.new()
		driver.wait_time = 0.3
		driver.process_mode = Node.PROCESS_MODE_ALWAYS
		fx.root.add_child(driver)
		var n := [0]
		var flap: bool = sc[4]
		driver.timeout.connect(func() -> void:
			n[0] += 1
			if flap:
				Events.player_flapped.emit(0, 0.6)
			if not callers.is_empty() and n[0] % 2 == 0:
				fx.director.voices.request_call(callers[(n[0] / 2) % callers.size()]))
		driver.start()
		var rec := await fx.record(get_tree(), master, 2.0)
		driver.stop()
		driver.queue_free()
		var lufs := _lufs(rec, master_fader)
		var rms := _db(AudioAnalysis.rms(rec["mono"])) + master_fader
		var aw: float = AudioAnalysis.loudness_aw(rec["mono"], rec["rate"], 0.4)["mean"] + master_fader
		res[sc[0]] = {"lufs": snappedf(lufs, 0.1), "rms_dbfs": snappedf(rms, 0.1), "dba": snappedf(aw, 0.1)}
		print("[audio-verify] %s: %.1f LUFS, %.1f dBFS RMS, %.1f dB A at the output" % [sc[0], lufs, rms, aw])
	_out["ordinary_play_loudness"] = res
	metric("ordinary_play_loudness", res)
	var menu: float = res["menu"]["lufs"]
	for k in ["flapping_cruise_5m", "glide_cruise_20m", "perched_forest_birds"]:
		var drop: float = menu - float(res[k]["lufs"])
		gt(-drop, -10.0, "%s is within 10 LU of the menu music (it is %.1f LU below it)" % [k, drop])
	gt(float(res["flapping_cruise_5m"]["lufs"]), -36.0, "ordinary flapping flight at cruise is at least -36 LUFS at the output (%.1f)" % float(res["flapping_cruise_5m"]["lufs"]))
	gt(float(res["glide_cruise_20m"]["lufs"]), -40.0, "a glide at cruise is at least -40 LUFS at the output (%.1f)" % float(res["glide_cruise_20m"]["lufs"]))


# ------------------------------------------- danger over the flight wind ---

## AU4 / DESIGN "danger (predator screech getting louder)": the heart and
## drone must be audible over the wind the player is flying in. Compared
## per octave band on the two buses (both feed SFX, so pre-fader levels
## compare directly) in the bands a headset speaker plays and the heart
## lives in (125 and 250 Hz): at threat 1 the danger cue must beat the
## wind by >= 6 dB in one of them, at 0.5 by >= 0 dB, in a glide at cruise,
## fast flight (1.5x) and a tucked dive (2.4x). (A first version compared
## A-weighted totals; that is not a masking test: the tucked wind is
## high-passed at 350 Hz and cannot mask a 60-250 Hz heart, so the
## A-weighted numbers are recorded, not asserted.)
func test_danger_is_audible_over_the_flight_wind() -> void:
	Game.set_state(Game.State.PLAYING)
	var wind := fx.tap(AudioBuses.WIND)
	var danger := fx.tap(AudioBuses.DANGER)
	var hawk := fx.add_npc(&"hawk", Vector3(0, 180, -150))
	var cruise := FlightSoundMap.cruise(0.03)
	var res := {}
	var plot_series := []
	for fl in [["cruise", cruise, false], ["fast_1.5x", cruise * 1.5, false], ["dive_2.4x_tucked", cruise * 2.4, true]]:
		fx.set_tel({"airspeed": fl[1], "tucked": fl[2], "wing_extension": 0.1 if fl[2] else 1.0})
		for lvl in [0.5, 1.0]:
			Events.threat_changed.emit(lvl, hawk)
			await Fixture.wait(get_tree(), 0.5)
			var pair := await fx.record2(get_tree(), wind, danger, 1.3)
			var rate: float = pair[0]["rate"]
			var wo := _octaves(pair[0]["mono"], rate)
			var do_ := _octaves(pair[1]["mono"], rate)
			var best := -INF
			var best_hz := 0.0
			var margins := {}
			for i in OCT.size():
				var m := do_[i] - wo[i]
				margins["%d" % int(OCT[i])] = snappedf(m, 0.1)
				if m > best:
					best = m
					best_hz = OCT[i]
			# To the ear: the loudest 0.1 s of the danger bus (a beat) against
			# the wind's A-weighted mean.
			var dfp := _aw_frames(pair[1]["mono"], rate)
			var wfp := _aw_frames(pair[0]["mono"], rate)
			var d_beat := _aw_max(dfp, rate, 0.0, 1.3, 0.1)
			var w_mean: float = AudioAnalysis.loudness_aw(pair[0]["mono"], rate, 0.4)["mean"]
			var key := "%s@%.1f" % [fl[0], lvl]
			res[key] = {"best_band_margin_db": snappedf(best, 0.1), "best_band_hz": best_hz, "band_margins": margins,
				"danger_beat_dba": snappedf(d_beat, 0.1), "wind_dba": snappedf(w_mean, 0.1), "beat_minus_wind_dba": snappedf(d_beat - w_mean, 0.1)}
			print("[audio-verify] danger %s: best band %+.1f dB at %d Hz; beat %+.1f dB A vs wind" % [key, best, int(best_hz), d_beat - w_mean])
			if lvl == 1.0:
				var xs := PackedFloat32Array(OCT)
				var ys := PackedFloat32Array()
				for i in OCT.size():
					ys.append(do_[i] - wo[i])
				plot_series.append({"name": "THREAT 1, " + String(fl[0]).to_upper(), "x": xs, "y": ys, "dots": true, "line": true})
			var spk := maxf(float(margins["125"]), float(margins["250"]))
			res[key]["speaker_band_margin_db"] = spk
			if lvl == 1.0:
				gt(spk, 6.0, "%s: at threat 1 the danger cue beats the wind by >= 6 dB at 125 or 250 Hz (%+.1f dB)" % [fl[0], spk])
			else:
				gt(spk, 0.0, "%s: at threat 0.5 the danger cue reaches the wind's level at 125 or 250 Hz (%+.1f dB)" % [fl[0], spk])
		Events.threat_changed.emit(0.0, null)
		await Fixture.wait(get_tree(), 0.3)
	_out["danger_over_wind"] = res
	metric("danger_over_wind", res)
	var img := AudioPlot.chart("R3 VERIFY: DANGER BUS MINUS WIND BUS PER OCTAVE (THREAT 1)", plot_series,
		{"x_label": "OCTAVE BAND HZ", "y_label": "DB (DANGER - WIND)", "log_x": true, "hlines": [{"y": 0.0, "label": "EQUAL"}],
		"note": "SPARROW, HAWK AT THREAT 1. ABOVE 0 = THE HEART/DRONE IS OVER THE WIND IN THAT BAND."})
	img.save_png(Paths.artifacts("audio/verify/r3x").path_join("danger_minus_wind_octaves.png"))


# ------------------------------------------- reward cues through flight ---

## A catch in a tucked dive with the heart racing, a tier-up fanfare in
## fast flight, a full wingbeat at 1.5x cruise: each must lift the SFX mix
## clearly (>= 4 dB A over its loudest moment before, 3 dB for the flap).
func test_reward_cues_cut_through_flight() -> void:
	Game.set_state(Game.State.PLAYING)
	var sfx := fx.tap(AudioBuses.SFX)
	var cruise := FlightSoundMap.cruise(0.03)
	var res := {}
	# [name, airspeed, tucked, threat, event, min lift dB]. The fanfare (2.6 s,
	# with a 2 s duck) goes last so no cue rings into the next case.
	var cases := [
		["catch_in_tucked_dive_threat_0.8", cruise * 2.4, true, 0.8, "catch", 4.0],
		["catch_in_tucked_dive_calm", cruise * 2.4, true, 0.0, "catch", 4.0],
		["catch_at_cruise", cruise, false, 0.0, "catch", 4.0],
		["flap_1.0_at_1.5x", cruise * 1.5, false, 0.0, "flap", 3.0],
		["flap_0.5_at_cruise", cruise, false, 0.0, "flap_half", 3.0],
		["fanfare_fast_1.5x", cruise * 1.5, false, 0.0, "fanfare", 4.0],
	]
	for c in cases:
		fx.set_tel({"airspeed": c[1], "tucked": c[2], "wing_extension": 0.1 if c[2] else 1.0})
		# The heart at the level without a named predator: a rising edge
		# with a predator would add its scream, which is not under test here.
		Events.threat_changed.emit(c[3], null)
		await Fixture.wait(get_tree(), 1.0)
		# The prey is far out of earshot: it must not call during the take.
		var prey := fx.add_npc(&"wren", Vector3(5000, 100, 0))
		var kind: String = c[4]
		_later(0.7, func() -> void:
			if kind == "catch":
				Events.bird_caught.emit(fx.player, prey)
			elif kind == "fanfare":
				Events.player_tier_changed.emit(2, 3)
			elif kind == "flap":
				Events.player_flapped.emit(0, 1.0)
			else:
				Events.player_flapped.emit(0, 0.5))
		var rec := await fx.record(get_tree(), sfx, 1.7)
		var rate: float = rec["rate"]
		var fp := _aw_frames(rec["mono"], rate)
		var before := _aw_max(fp, rate, 0.05, 0.65, 0.2)
		var after := _aw_max(fp, rate, 0.66, 1.7, 0.2)
		res[c[0]] = {"before_dba": snappedf(before, 0.1), "after_dba": snappedf(after, 0.1), "lift_db": snappedf(after - before, 0.1),
			"voices_during": fx.director.voices.active_count()}
		print("[audio-verify] %s: %+.1f dB A (before %.1f, after %.1f)" % [c[0], after - before, before, after])
		gt(after - before, c[5], "%s lifts the mix by >= %.0f dB A over the loudest 0.2 s before it (%+.1f)" % [c[0], c[5], after - before])
		Events.threat_changed.emit(0.0, null)
		fx.npcs.erase(prey)
		prey.queue_free()
		await Fixture.wait(get_tree(), 0.6)
	_out["reward_cues"] = res
	metric("reward_cues", res)


# ------------------------------------------------ calls on the mixer ---

## AU2 balance, measured on the mixer instead of by Godot's law on paper:
## every species' first clip, straight ahead at 25 m (world_scale 1, the
## player perched: no wind, no speed duck, one voice so no crowd gain),
## A-weighted loudest 0.4 s (L and R power sum) on the Calls bus. Once as
## shipped, once with the voices' high-shelf "air absorption" filter
## switched off on this test's own players (a reference for what the
## builder's table models). The builder's claim: wren..pigeon within
## 4.1 dB at 25 m, the starling within 2 dB of the wren. Also at each
## species' own unit distance (the level VOICE.loud promises there).
func test_calls_on_the_mixer_match_the_balance_claim() -> void:
	Game.set_state(Game.State.PLAYING)
	fx.set_tel({"airspeed": 0.0, "perched": true, "world_scale": 1.0})
	await wait_frames(2)
	var voices := fx.director.voices
	voices.scheduling = false
	var calls := fx.tap(AudioBuses.CALLS)
	var bank := fx.director.bank
	var species: Array[StringName] = [&"wren", &"sparrow", &"swallow", &"starling", &"pigeon", &"crow", &"gull", &"hawk", &"eagle"]
	var shelf0: float = voices.voices[0].player.attenuation_filter_db
	var res := {"shelf_db_default": shelf0, "shelf_hz": voices.voices[0].player.attenuation_filter_cutoff_hz}
	var plot := {}
	for cond in [["as_shipped_25m", 25.0, shelf0], ["no_shelf_25m", 25.0, 0.0], ["as_shipped_unit", -1.0, shelf0], ["no_shelf_unit", -1.0, 0.0]]:
		for v in voices.voices:
			v.player.attenuation_filter_db = cond[2]
		var row := {}
		for sp in species:
			var clip: AudioStream = bank.calls_for(sp)[0]
			var d: float = cond[1] if cond[1] > 0.0 else float(CallVoices.VOICE[sp]["unit"])
			var b := fx.add_npc(sp, Vector3(0, 100, -d))
			await wait_frames(1)
			var ok: bool = voices._request(b, {"species": sp, "stream": clip, "kind": &"call", "prio": 0.0,
				"db": CallVoices.clip_gain_db(sp, clip), "pitch": 1.0})
			var rec := await fx.record(get_tree(), calls, clip.get_length() + 0.15)
			var rate: float = rec["rate"]
			var lw: float = AudioAnalysis.loudness_aw(rec["l"], rate, 0.4)["max"]
			var rw: float = AudioAnalysis.loudness_aw(rec["r"], rate, 0.4)["max"]
			var lvl := 10.0 * log(pow(10.0, lw / 10.0) + pow(10.0, rw / 10.0)) / log(10.0)
			row[String(sp)] = {"dba": snappedf(lvl, 0.1), "started": ok, "clip": String(clip.get_meta(&"clip", &"")),
				"volume_db": snappedf(CallVoices.clip_gain_db(sp, clip), 0.1)}
			fx.npcs.erase(b)
			b.queue_free()
			await Fixture.wait(get_tree(), 0.1)
		res[cond[0]] = row
		print("[audio-verify] calls %s: %s" % [cond[0], row])
	for v in voices.voices:
		v.player.attenuation_filter_db = shelf0
	# Spread of the small birds (wren..pigeon) and the starling vs the wren.
	var small := ["wren", "sparrow", "swallow", "starling", "pigeon"]
	for cond in ["as_shipped_25m", "no_shelf_25m", "as_shipped_unit", "no_shelf_unit"]:
		var lo := INF
		var hi := -INF
		for sp in small:
			var v: float = res[cond][sp]["dba"]
			lo = minf(lo, v)
			hi = maxf(hi, v)
		res[cond + "_small_spread_db"] = snappedf(hi - lo, 0.1)
	var shelf_cut := {}
	for sp in species:
		shelf_cut[String(sp)] = {"at_25m": snappedf(float(res["as_shipped_25m"][sp]["dba"]) - float(res["no_shelf_25m"][sp]["dba"]), 0.1),
			"at_unit": snappedf(float(res["as_shipped_unit"][sp]["dba"]) - float(res["no_shelf_unit"][sp]["dba"]), 0.1)}
	res["shelf_cut_db"] = shelf_cut
	_out["calls_on_mixer"] = res
	metric("calls_on_mixer", res)
	print("[audio-verify] shelf cut per species: %s" % [shelf_cut])
	print("[audio-verify] small-bird spread: shipped 25 m %.1f dB, no shelf 25 m %.1f dB" % [res["as_shipped_25m_small_spread_db"], res["no_shelf_25m_small_spread_db"]])
	lt(float(res["as_shipped_25m_small_spread_db"]), 6.0, "as shipped, wren..pigeon at 25 m are within 6 dB of each other on the mixer (%.1f dB; the doc claims 4.1)" % float(res["as_shipped_25m_small_spread_db"]))
	var st_w := float(res["as_shipped_25m"]["starling"]["dba"]) - float(res["as_shipped_25m"]["wren"]["dba"])
	lt(absf(st_w), 2.0, "as shipped, the starling is within 2 dB of the wren at 25 m (%+.1f)" % st_w)
	for sp in species:
		gt(float(shelf_cut[String(sp)]["at_unit"]), -3.0, "%s at its unit distance loses < 3 dB to the air-absorption shelf (%.1f dB)" % [sp, float(shelf_cut[String(sp)]["at_unit"])])
	# Draw the two 25 m profiles.
	var xs := PackedFloat32Array()
	var ya := PackedFloat32Array()
	var yb := PackedFloat32Array()
	for i in species.size():
		xs.append(i + 1)
		ya.append(float(res["as_shipped_25m"][species[i]]["dba"]))
		yb.append(float(res["no_shelf_25m"][species[i]]["dba"]))
	var img := AudioPlot.chart("R3 VERIFY: CALLS AT 25 M, MEASURED ON THE MIXER", [
		{"name": "AS SHIPPED (GODOT AIR-ABSORPTION SHELF ON)", "x": xs, "y": ya, "dots": true, "line": true},
		{"name": "SAME VOICES, SHELF OFF (WHAT THE BALANCE TABLE MODELS)", "x": xs, "y": yb, "dots": true, "line": true}],
		{"x_label": "1 WREN 2 SPARROW 3 SWALLOW 4 STARLING 5 PIGEON 6 CROW 7 GULL 8 HAWK 9 EAGLE", "y_label": "DB A",
		"note": "CALLS BUS, A-WEIGHTED LOUDEST 0.4 S (L+R). FIRST CLIP PER SPECIES, STRAIGHT AHEAD, WORLD_SCALE 1, PERCHED, ONE VOICE."})
	img.save_png(Paths.artifacts("audio/verify/r3x").path_join("calls_at_25m_on_mixer.png"))


# --------------------------------------------- pause from the loudest ---

## Paused from a tucked dive with the heart at 1 and wings flapping: the
## pause menu must read as a menu. After the ramps, the music at the
## output is >= 6 dB A over the ducked, muffled gameplay, and a UI select
## is >= 10 dB A over it.
func test_pause_from_the_loudest_state_reads_as_a_menu() -> void:
	Game.set_state(Game.State.PLAYING)
	var hawk := fx.add_npc(&"hawk", Vector3(0, 110, -20))
	var cruise := FlightSoundMap.cruise(0.03)
	fx.set_tel({"airspeed": cruise * 2.6, "tucked": true, "wing_extension": 0.1, "stalled": false})
	Events.threat_changed.emit(1.0, hawk)
	await Fixture.wait(get_tree(), 0.6)
	Game.set_state(Game.State.PAUSED)
	await Fixture.wait(get_tree(), 2.2)
	var sfx := fx.tap(AudioBuses.SFX)
	var music := fx.tap(AudioBuses.MUSIC)
	var ui := fx.tap(AudioBuses.UI)
	var amb := fx.tap(AudioBuses.AMBIENCE)
	var pair := await fx.record2(get_tree(), sfx, music, 1.2)
	var rate: float = pair[0]["rate"]
	var game_db: float = AudioAnalysis.loudness_aw(pair[0]["mono"], rate, 0.4)["mean"] + _fader(AudioBuses.SFX)
	var music_db: float = AudioAnalysis.loudness_aw(pair[1]["mono"], rate, 0.4)["mean"] + _fader(AudioBuses.MUSIC)
	_later(0.05, func() -> void: fx.director.play_ui(&"select"))
	var urec := await fx.record(get_tree(), ui, 0.5)
	var ufp := _aw_frames(urec["mono"], rate)
	var ui_db := _aw_max(ufp, rate, 0.0, 0.5, 0.1) + _fader(AudioBuses.UI)
	var r := {"gameplay_dba": snappedf(game_db, 0.1), "music_dba": snappedf(music_db, 0.1), "ui_select_dba_0.1s": snappedf(ui_db, 0.1)}
	_out["pause_from_dive"] = r
	metric("pause_from_dive", r)
	print("[audio-verify] pause from dive: gameplay %.1f, music %.1f, select %.1f dB A (pre-master)" % [game_db, music_db, ui_db])
	gt(music_db - game_db, 6.0, "paused from a dive: the music is >= 6 dB A over the ducked gameplay (%+.1f)" % (music_db - game_db))
	gt(ui_db - game_db, 10.0, "paused from a dive: a UI select is >= 10 dB A over the ducked gameplay (%+.1f)" % (ui_db - game_db))
	Game.set_state(Game.State.PLAYING)
	Events.threat_changed.emit(0.0, null)


# ------------------------------------------------ calls in flight ---

## A sparrow-sized player at cruise chasing a wren (its target): how far
## away is the wren's call heard over the wind? And is a call placed
## left/right? The call is compared, loudest 0.4 s A-weighted on the Calls
## bus, with the Wind bus A-weighted mean (both feed SFX).
func test_chased_prey_call_over_cruise_wind_and_placement() -> void:
	Game.set_state(Game.State.PLAYING)
	var cruise := FlightSoundMap.cruise(0.03)
	fx.set_tel({"airspeed": cruise, "world_scale": SPARROW_WS})
	var wind := fx.tap(AudioBuses.WIND)
	var calls := fx.tap(AudioBuses.CALLS)
	await Fixture.wait(get_tree(), 0.5)
	var wrec := await fx.record(get_tree(), wind, 0.8)
	var rate: float = wrec["rate"]
	var w_db: float = AudioAnalysis.loudness_aw(wrec["mono"], rate, 0.4)["mean"]
	var res := {"wind_dba": snappedf(w_db, 0.1)}
	for d in [1.5, 3.0, 5.0, 8.0]:
		var wren := fx.add_npc(&"wren", Vector3(0, 100, -d))
		Events.target_changed.emit(wren)
		await wait_frames(2)
		var ok := fx.director.voices.request_call(wren)
		var rec := await fx.record(get_tree(), calls, 1.5)
		var c_db: float = AudioAnalysis.loudness_aw(rec["mono"], rate, 0.4)["max"]
		res["%.1fm" % d] = {"started": ok, "call_dba": snappedf(c_db, 0.1), "over_wind_db": snappedf(c_db - w_db, 0.1),
			"perceived_m": snappedf(d / SPARROW_WS, 0.1)}
		print("[audio-verify] wren %.1f m (%.0f perceived): %+.1f dB A over the cruise wind" % [d, d / SPARROW_WS, c_db - w_db])
		if d == 1.5:
			gt(c_db - w_db, 3.0, "a chased wren 1.5 m ahead (11 perceived m) is heard over the cruise wind (%+.1f dB A)" % (c_db - w_db))
		fx.npcs.erase(wren)
		wren.queue_free()
		await Fixture.wait(get_tree(), 0.2)
	Events.target_changed.emit(null)
	# Placement: a crow 3 m to the left (world_scale 1).
	fx.set_tel({"airspeed": 0.0, "world_scale": 1.0, "perched": true})
	await Fixture.wait(get_tree(), 0.4)
	var crow := fx.add_npc(&"crow", Vector3(-3, 100, 0))
	await wait_frames(2)
	fx.director.voices.request_call(crow)
	var crec := await fx.record(get_tree(), calls, 1.0)
	var lr := _db(AudioAnalysis.rms(crec["l"])) - _db(AudioAnalysis.rms(crec["r"]))
	res["crow_left_minus_right_db"] = snappedf(lr, 0.1)
	gt(lr, 6.0, "a crow 3 m to the left is clearly in the left ear (%+.1f dB L-R)" % lr)
	_out["prey_call_over_wind"] = res
	metric("prey_call_over_wind", res)


# ------------------------------------------------ long chaotic session ---

## About 11 s of chaos with a seeded RNG: 30 NPCs of every species churned
## like the Ecosystem (removed and freed mid-call, new ones added), random
## flight (speed, tuck, stall, updraft, world_scale 0.14..1.3), flaps,
## threats switching between predators, catches of birds that are freed a
## frame later, pause toggled every 2.5 s, bell tolls. Asserts: no engine or
## script errors, never more than 8 voices, output peak < -1 dBFS, a median
## frame cost < 0.3 ms; after the sky clears everything releases (no voice,
## heart silent, Calls bus back to 0 dB).
func test_long_chaotic_session_stays_clean() -> void:
	var log := ErrorLog.install()
	Game.set_state(Game.State.PLAYING)
	var marks: Array[Dictionary] = [
		{"name": "f", "kind": "forest", "position": Vector3(0, 0, 0), "radius": 60.0},
		{"name": "l", "kind": "lake", "position": Vector3(80, 0, 0), "radius": 60.0},
		{"name": "t", "kind": "town", "position": Vector3(0, 0, 80), "radius": 60.0},
		{"name": "church_spire", "kind": "landmark", "position": Vector3(0, 20, 80), "radius": 4.0},
	]
	fx.add_world(marks)
	fx.director.ambience.set_world(fx.world)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var species: Array[StringName] = [&"moth", &"wren", &"sparrow", &"swallow", &"starling", &"pigeon", &"crow", &"gull", &"hawk", &"eagle"]
	var at := Vector3(0, 8, 40)
	fx.listener.global_position = at
	fx.player.global_position = at
	var alive: Array[Bird] = []
	for i in 30:
		alive.append(fx.add_npc(species[rng.randi() % species.size()], at + Vector3(rng.randf_range(-40, 40), rng.randf_range(-6, 20), rng.randf_range(-40, 40))))
	var post := fx.tap(AudioBuses.MASTER)
	fx.director.reset_perf()
	var max_voices := [0]
	var stats := {"removed": 0, "added": 0, "catches": 0, "threats": 0, "pauses": 0, "tolls": 0}
	var cruise := FlightSoundMap.cruise(0.03)
	var tick := [0]
	var driver := Timer.new()
	driver.wait_time = 0.1
	driver.process_mode = Node.PROCESS_MODE_ALWAYS
	fx.root.add_child(driver)
	driver.timeout.connect(func() -> void:
		tick[0] += 1
		max_voices[0] = maxi(max_voices[0], fx.director.voices.active_count())
		# Flight random walk.
		fx.set_tel({"airspeed": clampf(float(fx.player.tel["airspeed"]) + rng.randf_range(-3, 3), 0.0, cruise * 2.6),
			"tucked": rng.randf() < 0.2, "stalled": rng.randf() < 0.08, "in_updraft": rng.randf_range(0, 4) if rng.randf() < 0.3 else 0.0,
			"world_scale": clampf(float(fx.player.tel.get("world_scale", 1.0)) * exp(rng.randf_range(-0.2, 0.2)), 0.14, 1.3)})
		if rng.randf() < 0.6:
			Events.player_flapped.emit(rng.randi_range(-1, 1), rng.randf())
		# Birds move, leave and arrive.
		for b in alive:
			if is_instance_valid(b) and b.is_inside_tree():
				b.global_position += Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.5, 0.5), rng.randf_range(-1, 1))
		if rng.randf() < 0.5 and not alive.is_empty():
			var v: Bird = alive.pop_at(rng.randi() % alive.size())
			if is_instance_valid(v):
				fx.npcs.erase(v)
				v.alive = false
				v.get_parent().remove_child(v)
				v.queue_free()
				stats["removed"] += 1
		if rng.randf() < 0.5:
			alive.append(fx.add_npc(species[rng.randi() % species.size()], at + Vector3(rng.randf_range(-30, 30), rng.randf_range(-5, 15), rng.randf_range(-30, 30))))
			stats["added"] += 1
		if rng.randf() < 0.4 and not alive.is_empty():
			var c: Bird = alive[rng.randi() % alive.size()]
			if is_instance_valid(c):
				fx.director.voices.request_call(c, rng.randf_range(0, 20))
		# Threats switch between predators, with rising edges.
		if rng.randf() < 0.15 and not alive.is_empty():
			var p: Bird = alive[rng.randi() % alive.size()]
			Events.threat_changed.emit(rng.randf(), p if is_instance_valid(p) else null)
			stats["threats"] += 1
		# A catch: the prey is freed right after (as GameLoop + Ecosystem do).
		if rng.randf() < 0.08 and not alive.is_empty():
			var q: Bird = alive.pop_at(rng.randi() % alive.size())
			if is_instance_valid(q):
				Events.bird_caught.emit(fx.player if rng.randf() < 0.5 else fx.npcs[0] if not fx.npcs.is_empty() else fx.player, q)
				fx.npcs.erase(q)
				q.alive = false
				q.queue_free()
				stats["catches"] += 1
		if tick[0] % 25 == 0:
			Game.set_state(Game.State.PAUSED if Game.state == Game.State.PLAYING else Game.State.PLAYING)
			stats["pauses"] += 1
		if tick[0] % 40 == 0 and fx.director.ambience.toll():
			stats["tolls"] += 1)
	driver.start()
	var rec := await fx.record(get_tree(), post, 11.0)
	driver.stop()
	driver.queue_free()
	var perf := fx.director.perf_stats()
	var pk := _db(maxf(AudioAnalysis.peak(rec["l"]), AudioAnalysis.peak(rec["r"])))
	# Clear the sky and release everything.
	Game.set_state(Game.State.PLAYING)
	Events.threat_changed.emit(0.0, null)
	for b in alive:
		if is_instance_valid(b):
			fx.npcs.erase(b)
			if b.is_inside_tree():
				b.get_parent().remove_child(b)
			b.queue_free()
	alive.clear()
	for b in fx.npcs.duplicate():
		if is_instance_valid(b):
			b.queue_free()
	fx.npcs.clear()
	fx.set_tel({"airspeed": 0.0, "perched": true, "stalled": false, "in_updraft": 0.0, "world_scale": 1.0})
	await Fixture.wait(get_tree(), 1.0)
	var voices_after := fx.director.voices.active_count()
	var dcap := fx.tap(AudioBuses.DANGER)
	var drec := await fx.record(get_tree(), dcap, 0.3)
	var heart_after := _db(AudioAnalysis.rms(drec["mono"]))
	var t0 := Time.get_ticks_msec()
	while _fader(AudioBuses.CALLS) < -0.05 and Time.get_ticks_msec() - t0 < 4000:
		await get_tree().process_frame
	var calls_after := _fader(AudioBuses.CALLS)
	log.uninstall()
	var r := {"stats": stats, "max_voices": max_voices[0], "output_peak_dbfs": snappedf(pk, 0.01), "perf": perf,
		"voices_after": voices_after, "heart_after_dbfs": heart_after, "calls_bus_after_db": calls_after,
		"errors": log.errors, "error_samples": log.samples, "vstats": fx.director.voices.stats}
	_out["chaos"] = r
	metric("chaos", r)
	print("[audio-verify] chaos: %s" % [r])
	eq(log.errors, 0, "no engine or script errors in 11 s of chaos: %s" % [log.samples])
	lt(float(max_voices[0]), 8.5, "never more than 8 voices (max %d)" % max_voices[0])
	lt(pk, -1.0, "output peak under -1 dBFS through the chaos (%.2f)" % pk)
	lt(float(perf["median"]), 0.3, "median director cost < 0.3 ms per frame in the chaos (%.3f)" % float(perf["median"]))
	eq(voices_after, 0, "no voice left sounding once the sky is clear")
	lt(heart_after, -70.0, "the heart is silent once the threat is gone (%.1f dBFS)" % heart_after)
	gt(calls_after, -0.05, "the Calls bus returns to 0 dB (%.2f)" % calls_after)
	gt(float(stats["removed"]), 20.0, "the churn was real (%d removed)" % stats["removed"])


# ------------------------------------------------- extreme scales ---

## world_scale at its clamps (0.05 and 5.0): the threatening hawk still
## screams, calls play with finite, positive distances, the bell stays
## capped, and nothing errors.
func test_extreme_world_scales() -> void:
	var log := ErrorLog.install()
	Game.set_state(Game.State.PLAYING)
	var marks: Array[Dictionary] = [
		{"name": "village", "kind": "town", "position": Vector3(0, 0, 0), "radius": 130.0},
		{"name": "church_spire", "kind": "landmark", "position": Vector3(0, 25, 0), "radius": 4.0},
	]
	fx.add_world(marks)
	fx.director.ambience.set_world(fx.world)
	var calls := fx.tap(AudioBuses.CALLS)
	var res := {}
	var cues: Array = []
	fx.director.cue.connect(func(n: StringName, _i: Dictionary) -> void: cues.append(n))
	for ws in [0.05, 5.0]:
		fx.set_tel({"world_scale": ws, "airspeed": FlightSoundMap.cruise(0.03)})
		var at := Vector3(8, 25, 0)
		fx.listener.global_position = at
		fx.player.global_position = at
		await Fixture.wait(get_tree(), 0.3)
		var hawk := fx.add_npc(&"hawk", at + Vector3(0, 10, -60))
		# One scream per 5 s by design: start each scale off cooldown.
		fx.director._screech_cool = 0.0
		var before := cues.count(&"screech")
		Events.threat_changed.emit(0.3, hawk)
		await wait_frames(2)
		Events.threat_changed.emit(0.9, hawk)
		var rec := await fx.record(get_tree(), calls, 1.2)
		var pk := _db(AudioAnalysis.peak(rec["mono"]))
		var sparrow := fx.add_npc(&"sparrow", at + Vector3(2, 0, 0))
		fx.director.voices.request_call(sparrow)
		await wait_frames(3)
		var finite_ok := true
		for v in fx.director.voices.voices:
			var p := v.player
			if not (is_finite(p.unit_size) and p.unit_size > 0.0 and is_finite(p.max_distance) and is_finite(p.volume_db)):
				finite_ok = false
		res["%.2f" % ws] = {"screech": cues.count(&"screech") > before, "calls_peak_dbfs": snappedf(pk, 0.1), "finite": finite_ok}
		check(cues.count(&"screech") > before, "world_scale %.2f: the threatening hawk 60 m away screams" % ws)
		gt(pk, -40.0, "world_scale %.2f: and it is heard (%.1f dBFS peak on Calls)" % [ws, pk])
		check(finite_ok, "world_scale %.2f: voice distances and volumes are finite and positive" % ws)
		Events.threat_changed.emit(0.0, null)
		for b in [hawk, sparrow]:
			fx.npcs.erase(b)
			b.queue_free()
		await Fixture.wait(get_tree(), 0.3)
	# The bell at the tower for a giant listener: still capped.
	fx.set_tel({"world_scale": 5.0, "airspeed": 0.0, "perched": true})
	await Fixture.wait(get_tree(), 0.3)
	var bell: AudioStreamPlayer3D = fx.director.ambience.get_node("Bell")
	lt(bell.max_db, AmbienceZones.BELL_DB + 0.01, "the bell's ceiling stays at its cap at world_scale 5 (%.1f)" % bell.max_db)
	log.uninstall()
	eq(log.errors, 0, "no errors at extreme world scales: %s" % [log.samples])
	_out["extreme_scales"] = res
	metric("extreme_scales", res)
