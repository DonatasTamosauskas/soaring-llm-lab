extends TestCase
## Round-3 verifier probes (experience lens), second file:
##  * the wingbeat whooshes are AudioStreamPlayer3D too (attenuation off):
##    does Godot's air-absorption high shelf, whose depth follows the
##    player's volume_db, dull them? (measured with the shelf as shipped vs
##    switched off on this test's own players);
##  * the catch crunch in a tucked dive: how far over the (cue-ducked) dive
##    wind is the crunch itself? The SFX bus minus the Wind bus (the only
##    other layer sounding) isolates the one-shots.
## Measurements: artifacts/audio/verify/r3x/cues.json.

const Fixture := preload("res://tests/unit/audio/audio_fixture.gd")

var fx: Fixture
var _out := {}


func before_all() -> void:
	DirAccess.make_dir_recursive_absolute(Paths.artifacts("audio/verify/r3x"))
	Fixture.restore_default_settings()


func after_all() -> void:
	Fixture.restore_default_settings()
	# Merge into the file, so a single-test rerun keeps the other results.
	var path := Paths.artifacts("audio/verify/r3x").path_join("cues.json")
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


func _later(delay: float, fn: Callable) -> void:
	get_tree().create_timer(delay, true, false, true).timeout.connect(fn)


static func _aw_frames(buf: PackedFloat32Array, rate: float) -> PackedFloat32Array:
	var w := AudioAnalysis.a_weights(1024, rate)
	var out := PackedFloat32Array()
	for fr in AudioAnalysis.stft(buf, 1024, 512):
		var s := 0.0
		for i in fr.size():
			s += fr[i] * fr[i] * w[i]
		out.append(s / AudioAnalysis.BIN_POWER_PER_MS)
	return out


static func _pdb(p: float) -> float:
	return 10.0 * log(maxf(p, 1e-30)) / log(10.0)


## Wingbeat whooshes with the shelf as shipped vs off: A-weighted level
## and spectral centroid of the Body bus (nothing else sounds there when
## gliding without lift or stall), for a full and a half-strength flap, a
## sparrow and an eagle.
func test_whoosh_brightness_and_level_vs_the_air_absorption_shelf() -> void:
	Game.set_state(Game.State.PLAYING)
	var body := fx.tap(AudioBuses.BODY)
	var whooshes: Array[AudioStreamPlayer3D] = []
	for c in fx.director.get_children():
		if c is AudioStreamPlayer3D and String(c.name).begins_with("Whoosh"):
			whooshes.append(c)
	var shelf0 := whooshes[0].attenuation_filter_db
	var res := {"shelf_db_default": shelf0, "whoosh_voices": whooshes.size()}
	for size in [[&"sparrow", 0.03], [&"eagle", 3.0]]:
		fx.player.mass = size[1]
		for strength in [1.0, 0.5]:
			var row := {}
			for cond in [["shipped", shelf0], ["no_shelf", 0.0]]:
				for w in whooshes:
					w.attenuation_filter_db = cond[1]
				fx.set_tel({"airspeed": 0.0, "perched": true})
				await Fixture.wait(get_tree(), 0.2)
				var st: float = strength
				_later(0.05, func() -> void: Events.player_flapped.emit(0, st))
				var rec := await fx.record(get_tree(), body, 0.6)
				var rate: float = rec["rate"]
				var p := AudioAnalysis.mean_power(rec["mono"], 1024, 512, -30.0)
				var lv: float = AudioAnalysis.loudness_aw(rec["mono"], rate, 0.2)["max"]
				row[cond[0]] = {"dba_0.2s": snappedf(lv, 0.1), "centroid_hz": snappedf(AudioAnalysis.centroid(p, rate), 1.0),
					"above_2k_share": snappedf(AudioAnalysis.band_fraction(p, rate, 2000.0, 20000.0), 0.001)}
			var key := "%s_%.1f" % [size[0], strength]
			row["shelf_cut_dba"] = snappedf(float(row["shipped"]["dba_0.2s"]) - float(row["no_shelf"]["dba_0.2s"]), 0.1)
			row["centroid_ratio"] = snappedf(float(row["shipped"]["centroid_hz"]) / maxf(1.0, float(row["no_shelf"]["centroid_hz"])), 0.01)
			res[key] = row
			print("[audio-verify] whoosh %s: %s" % [key, row])
			gt(float(row["shelf_cut_dba"]), -3.0, "%s whoosh at strength %.1f loses < 3 dB A to the shelf (%.1f)" % [size[0], strength, float(row["shelf_cut_dba"])])
			gt(float(row["centroid_ratio"]), 0.85, "%s whoosh at strength %.1f keeps >= 85%% of its designed brightness (centroid x%.2f)" % [size[0], strength, float(row["centroid_ratio"])])
	for w in whooshes:
		w.attenuation_filter_db = shelf0
	_out["whoosh_shelf"] = res
	metric("whoosh_shelf", res)


## The catch in a tucked dive (and at cruise for reference): the crunch
## and puff themselves, isolated as SFX minus Wind power, against the wind
## as it is at that moment (cue-ducked 5 dB), loudest 0.2 s A-weighted.
## A reward should stand >= 6 dB over the air it lands in.
func test_catch_crunch_over_the_dive_wind() -> void:
	Game.set_state(Game.State.PLAYING)
	var sfx := fx.tap(AudioBuses.SFX)
	var wind := fx.tap(AudioBuses.WIND)
	var cruise := FlightSoundMap.cruise(0.03)
	var res := {}
	for c in [["tucked_dive_2.4x", cruise * 2.4, true], ["fast_1.5x", cruise * 1.5, false], ["cruise", cruise, false]]:
		fx.set_tel({"airspeed": c[1], "tucked": c[2], "wing_extension": 0.1 if c[2] else 1.0, "perched": false})
		await Fixture.wait(get_tree(), 1.0)
		var prey := fx.add_npc(&"wren", Vector3(5000, 100, 0))
		_later(0.3, func() -> void: Events.bird_caught.emit(fx.player, prey))
		var pair := await fx.record2(get_tree(), sfx, wind, 1.0)
		var rate: float = pair[0]["rate"]
		var fs := _aw_frames(pair[0]["mono"], rate)
		var fw := _aw_frames(pair[1]["mono"], rate)
		# 0.2 s windows (17 frames) from 0.3 s on: the cue (SFX - Wind) at its
		# loudest, and the wind in that same window.
		var per := 17
		var best_cue := 0.0
		var wind_then := 0.0
		for k in range(int(0.28 / (512.0 / rate)), mini(fs.size(), fw.size()) - per):
			var sc := 0.0
			var sw := 0.0
			for j in per:
				sc += maxf(0.0, fs[k + j] - fw[k + j])
				sw += fw[k + j]
			if sc > best_cue:
				best_cue = sc
				wind_then = sw
		var cue_db := _pdb(best_cue / per)
		var wind_db := _pdb(wind_then / per)
		res[c[0]] = {"cue_dba": snappedf(cue_db, 0.1), "wind_dba_then": snappedf(wind_db, 0.1), "cue_over_wind_db": snappedf(cue_db - wind_db, 0.1)}
		print("[audio-verify] catch %s: crunch+puff %.1f dB A vs wind %.1f dB A (%+.1f)" % [c[0], cue_db, wind_db, cue_db - wind_db])
		gt(cue_db - wind_db, 6.0, "%s: the catch crunch stands >= 6 dB A over the wind it lands in (%+.1f)" % [c[0], cue_db - wind_db])
		fx.npcs.erase(prey)
		prey.queue_free()
		await Fixture.wait(get_tree(), 0.5)
	_out["catch_over_wind"] = res
	metric("catch_over_wind", res)


## A sparrow-sized player (world_scale 0.141) perched in a forest: a wren
## and a sparrow calling 2 and 4 world m away (14 and 28 perceived m).
## Is the call heard over the forest bed? Calls bus loudest 0.4 s vs the
## Ambience bus mean, A-weighted, L+R power (both pre-fader, and the
## Ambience fader is 0 dB in PLAYING at the default ambience_volume), with
## the voices' air-absorption shelf as shipped and switched off.
func test_songbirds_heard_over_the_forest_when_perched() -> void:
	Game.set_state(Game.State.PLAYING)
	var marks: Array[Dictionary] = [{"name": "wood", "kind": "forest", "position": Vector3(0, 0, 0), "radius": 200.0}]
	fx.add_world(marks)
	var at := Vector3(0, 3, 0)
	fx.listener.global_position = at
	fx.player.global_position = at
	fx.set_tel({"airspeed": 0.0, "perched": true, "world_scale": 0.24 / 1.7})
	fx.director.ambience.set_world(fx.world)
	await Fixture.wait(get_tree(), 0.3)
	fx.director.ambience.settle(at)
	var voices := fx.director.voices
	voices.scheduling = false
	var calls := fx.tap(AudioBuses.CALLS)
	var amb := fx.tap(AudioBuses.AMBIENCE)
	var arec := await fx.record(get_tree(), amb, 1.5)
	var rate: float = arec["rate"]
	var a_db := _pdb(pow(10.0, AudioAnalysis.loudness_aw(arec["l"], rate, 0.4)["mean"] / 10.0) + pow(10.0, AudioAnalysis.loudness_aw(arec["r"], rate, 0.4)["mean"] / 10.0))
	var res := {"forest_bed_dba": snappedf(a_db, 0.1)}
	var shelf0: float = voices.voices[0].player.attenuation_filter_db
	for cond in [["shipped", shelf0], ["no_shelf", 0.0]]:
		for v in voices.voices:
			v.player.attenuation_filter_db = cond[1]
		for sp in [&"wren", &"sparrow"]:
			for d in [2.0, 4.0]:
				var clip: AudioStream = fx.director.bank.calls_for(sp)[0]
				var b := fx.add_npc(sp, at + Vector3(0, 0, -d))
				await wait_frames(1)
				voices._request(b, {"species": sp, "stream": clip, "kind": &"call", "prio": 0.0,
					"db": CallVoices.clip_gain_db(sp, clip), "pitch": 1.0})
				var rec := await fx.record(get_tree(), calls, clip.get_length() + 0.15)
				var c_db := _pdb(pow(10.0, AudioAnalysis.loudness_aw(rec["l"], rate, 0.4)["max"] / 10.0) + pow(10.0, AudioAnalysis.loudness_aw(rec["r"], rate, 0.4)["max"] / 10.0))
				var key := "%s_%s_%.0fm" % [cond[0], sp, d]
				res[key] = {"call_dba": snappedf(c_db, 0.1), "over_bed_db": snappedf(c_db - a_db, 0.1)}
				print("[audio-verify] perched in forest, %s: call %.1f dB A, %+.1f over the bed" % [key, c_db, c_db - a_db])
				if cond[0] == "shipped" and d == 2.0:
					gt(c_db - a_db, 3.0, "a %s 2 m away (14 perceived m) is heard over the forest bed while perched (%+.1f dB A)" % [sp, c_db - a_db])
				fx.npcs.erase(b)
				b.queue_free()
				await Fixture.wait(get_tree(), 0.1)
	for v in voices.voices:
		v.player.attenuation_filter_db = shelf0
	_out["songbirds_over_forest"] = res
	metric("songbirds_over_forest", res)
