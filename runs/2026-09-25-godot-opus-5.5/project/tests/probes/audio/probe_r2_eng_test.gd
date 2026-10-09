extends TestCase
## Verifier probes, round 2 (engineering and contract lens). Not part of the
## area's suite: run with
##   tools/gd.sh audio_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/audio --suite=probe_r2_eng
##
## 1. The heartbeat tempo, pinned on literal bpm ranges measured on the mix
##    (the suite compares the measured rate with FlightSoundMap.heart_rate(),
##    the function under test, so a heart that stopped speeding up passes).
## 2. The danger "safety net" (a predator that leaves the world silences the
##    danger cue) that the report claims but no suite test pins.
## 3. The director taken out of the tree and put back (reparenting, a scene
##    that is removed before it is freed): errors, and whether sound resumes.
## 4. The updraft hum (a brief deliverable no suite test touches).
## 5. The Calls bus crowd gain carried over from one director to the next.
## Expected on the round-2 code: 1, 2 and 4 pass; 3 and 5 fail (defects).

const Fixture := preload("res://tests/unit/audio/audio_fixture.gd")
const ErrorLog := preload("res://tests/unit/audio/audio_error_log.gd")

var fx: Fixture


func before_each() -> void:
	fx = Fixture.new()
	fx.build(self)
	await wait_frames(2)


func after_each() -> void:
	fx.teardown()
	await Fixture.wait(get_tree(), 0.1)


func after_all() -> void:
	await Fixture.wait(get_tree(), 0.3)


## Onsets of the heart's low band (< ~120 Hz; the drone's lowest partial is
## 165 Hz): rising crossings of half the top envelope, re-armed below a
## quarter. Returns onset times (s).
static func _low_onsets(mono: PackedFloat32Array, rate: float) -> PackedFloat32Array:
	var low := AudioSynth.filter(mono, [AudioSynth.lp(120.0, 0.707, rate), AudioSynth.lp(120.0, 0.707, rate)])
	var env := AudioAnalysis.envelope(low, rate, 0.02)
	var top := 0.0
	for e in env:
		top = maxf(top, e)
	var out := PackedFloat32Array()
	var armed := env.size() > 0 and env[0] < 0.25 * top
	for i in env.size():
		if armed and env[i] >= 0.5 * top:
			out.append(i * 0.02)
			armed = false
		elif env[i] < 0.25 * top:
			armed = true
	return out


## Beats per minute from lub onsets: every other onset is a lub (lub, dub,
## lub, dub ...), so the lub-to-lub spacing is the sum of two gaps.
static func _bpm(onsets: PackedFloat32Array) -> float:
	var periods := PackedFloat32Array()
	for i in range(2, onsets.size()):
		periods.append(onsets[i] - onsets[i - 2])
	if periods.is_empty():
		return 0.0
	return 60.0 / AudioAnalysis.median(periods)


func test_heart_tempo_rises_with_threat_on_literal_bpm() -> void:
	Game.set_state(Game.State.PLAYING)
	var cap := fx.tap(AudioBuses.DANGER)
	var hawk := fx.add_npc(&"hawk", Vector3(0, 100, 30))
	var bpm := {}
	for lv in [0.25, 1.0]:
		Events.threat_changed.emit(lv, hawk)
		await Fixture.wait(get_tree(), 0.4)
		var rec := await fx.record(get_tree(), cap, 4.0)
		var on := _low_onsets(rec["mono"], rec["rate"])
		bpm[lv] = _bpm(on)
		metric("onsets_%.2f" % lv, on.size())
	metric("bpm", bpm)
	print("[audio] probe r2: heart bpm at 0.25 = %.1f, at 1.0 = %.1f" % [bpm[0.25], bpm[1.0]])
	between(bpm[0.25], 60.0, 85.0, "a faint threat beats a resting 60-85 bpm")
	between(bpm[1.0], 100.0, 125.0, "contact beats 100-125 bpm")
	gt(bpm[1.0] / maxf(bpm[0.25], 1.0), 1.35, "the heart clearly speeds up with the threat")
	Events.threat_changed.emit(0.0, null)


func test_danger_silences_when_predator_leaves() -> void:
	Game.set_state(Game.State.PLAYING)
	var cap := fx.tap(AudioBuses.DANGER)
	var hawk := fx.add_npc(&"hawk", Vector3(0, 100, 30))
	var other := fx.add_npc(&"eagle", Vector3(0, 100, -30))
	Events.threat_changed.emit(0.8, hawk)
	await Fixture.wait(get_tree(), 0.5)
	var on := AudioAnalysis.db(AudioAnalysis.rms((await fx.record(get_tree(), cap, 0.6))["mono"]))
	# The predator is recycled the Ecosystem's way; GameLoop has not yet
	# reported a new level.
	fx.npcs.erase(hawk)
	hawk.alive = false
	hawk.get_parent().remove_child(hawk)
	hawk.queue_free()
	await Fixture.wait(get_tree(), 1.2)
	var gone := AudioAnalysis.db(AudioAnalysis.rms((await fx.record(get_tree(), cap, 0.6))["mono"]))
	# Control: a predator that stays keeps its heartbeat.
	Events.threat_changed.emit(0.8, other)
	await Fixture.wait(get_tree(), 1.2)
	var stays := AudioAnalysis.db(AudioAnalysis.rms((await fx.record(get_tree(), cap, 0.6))["mono"]))
	metric("danger_db", {"on": on, "after_predator_left": gone, "other_predator_stays": stays})
	gt(on, -40.0, "threat 0.8: the danger cue sounds")
	lt(gone, -70.0, "the predator left the world: the danger cue falls silent without a new threat report")
	gt(stays, -40.0, "a predator that stays keeps the danger cue")
	Events.threat_changed.emit(0.0, null)


func test_director_out_of_tree_and_back() -> void:
	Game.set_state(Game.State.PLAYING)
	fx.set_tel({"airspeed": 16.0})
	var wind := fx.tap(AudioBuses.WIND)
	await Fixture.wait(get_tree(), 0.5)
	var before := AudioAnalysis.db(AudioAnalysis.rms((await fx.record(get_tree(), wind, 0.3))["mono"]))
	var log := ErrorLog.install()
	var d := fx.director
	var parent := d.get_parent()
	parent.remove_child(d)
	# Events while it is out of the tree (a scene removed before it is freed).
	Events.player_flapped.emit(-1, 1.0)
	Events.bird_caught.emit(fx.player, fx.add_npc(&"wren", Vector3(0, 100, -2)))
	var out_errors: int = log.errors
	var out_samples: Array = log.samples.duplicate()
	# Back in (reparenting).
	parent.add_child(d)
	await wait_frames(10)
	var back_errors: int = log.errors - out_errors
	var after := AudioAnalysis.db(AudioAnalysis.rms((await fx.record(get_tree(), wind, 0.3))["mono"]))
	log.uninstall()
	metric("errors_out_of_tree", out_errors)
	metric("errors_back_in_tree_10_frames", back_errors)
	metric("samples", log.samples)
	metric("wind_db", [before, after])
	print("[audio] probe r2: out-of-tree errors %d, back-in-tree errors %d, wind %.1f -> %.1f dBFS, %s" % [out_errors, back_errors, before, after, log.samples])
	eq(out_errors, 0, "events while the director is out of the tree raise no errors (%s)" % [out_samples])
	eq(back_errors, 0, "a director put back in the tree runs without errors (%s)" % [log.samples])
	near(after, before, 3.0, "and its wind plays again")


## The updraft hum is a brief deliverable that no suite test touches (a
## mutant that silences it passes all 28 tests). Measured here on the Body
## bus: silent without lift, audible in a thermal, louder and higher-pitched
## in strong lift. Glide at 0.5x cruise (no buffet, no wingbeats).
func test_updraft_hum_follows_lift() -> void:
	Game.set_state(Game.State.PLAYING)
	var cap := fx.tap(AudioBuses.BODY)
	var slow := FlightSoundMap.cruise(fx.player.mass) * 0.9
	var out := {}
	for lift in [0.0, 1.0, 4.0]:
		fx.set_tel({"airspeed": slow, "in_updraft": lift})
		await Fixture.wait(get_tree(), 0.6)
		var rec := await fx.record(get_tree(), cap, 1.0)
		var pw := AudioAnalysis.mean_power(rec["mono"], 4096, 2048, -80.0)
		out[lift] = {"db": AudioAnalysis.db(AudioAnalysis.rms(rec["mono"])), "centroid": AudioAnalysis.centroid(pw, rec["rate"], 60.0, 600.0)}
	metric("hum", out)
	print("[audio] probe r2: updraft hum %s" % [out])
	lt(out[0.0]["db"], -70.0, "no lift: no hum")
	gt(out[1.0]["db"], -60.0, "1 m/s of lift: the hum sounds (it is quiet there: ~-49 dBFS, 12 dB under the wind)")
	gt(out[4.0]["db"] - out[1.0]["db"], 3.0, "stronger lift: louder hum")
	gt(out[4.0]["centroid"], out[1.0]["centroid"] * 1.03, "stronger lift: the chord rises (variometer)")


## The Calls bus volume (crowd normalisation) is written by CallVoices but
## never reset when the director goes; a new director's CallVoices assumes
## the bus is at 0 dB and only writes when its own target moves. So a crowd
## gain left by one director carries over to the next (tests, dev scenes, a
## reloaded main scene).
func test_calls_bus_gain_does_not_leak_to_the_next_director() -> void:
	Game.set_state(Game.State.PLAYING)
	var voices := fx.director.voices
	var birds: Array[Bird] = []
	for i in 10:
		var a := TAU * i / 10.0
		birds.append(fx.add_npc(&"sparrow", Vector3(cos(a) * 5.0, 100.0, sin(a) * 5.0)))
	for b in birds:
		voices.request_call(b)
	await Fixture.wait(get_tree(), 0.3)
	var calls := AudioBuses.index(AudioBuses.CALLS)
	var during := AudioServer.get_bus_volume_db(calls)
	# The whole stage goes (as the suites' teardown and a scene change do).
	fx.teardown()
	await Fixture.wait(get_tree(), 0.1)
	fx = Fixture.new()
	fx.build(self)
	Game.set_state(Game.State.PLAYING)
	await Fixture.wait(get_tree(), 1.5)
	var next := AudioServer.get_bus_volume_db(calls)
	metric("calls_bus_db", {"crowd_of_8": during, "next_director_after_1_5s": next, "next_crowd_db": fx.director.voices.crowd_db})
	print("[audio] probe r2: Calls bus %.2f dB with a crowd, %.2f dB under the next director (its crowd_db %.2f)" % [during, next, fx.director.voices.crowd_db])
	lt(during, -3.0, "a crowd of 8 lowers the Calls bus")
	near(next, 0.0, 0.05, "a new director with no crowd starts with the Calls bus at 0 dB")
	# Put the shared bus back for whatever runs next.
	AudioServer.set_bus_volume_db(calls, 0.0)
