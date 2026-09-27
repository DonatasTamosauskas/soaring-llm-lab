extends TestCase
## The AudioDirector end to end, measured on the engine's real mix:
##  AU3 a wingbeat is a transient, placed on the flapping wing's side, and
##      scales with flap strength;
##  AU4 the danger cue gets strictly louder with the threat level;
##  AU5 NPC voices are pooled and capped at 8, go to the nearest / most
##      relevant birds, let go cleanly of birds that leave the world, and
##      the director costs well under 1 ms a frame;
##  AU6 pause and menus duck and muffle gameplay but keep UI and music;
##      Settings volumes land on the buses with the documented taper;
## plus every Events cue and the ambience zones.

const Fixture := preload("res://tests/unit/audio/audio_fixture.gd")
const ErrorLog := preload("res://tests/unit/audio/audio_error_log.gd")
## The brief's voice limit ("voice limit ~8"), pinned here rather than read
## from CallVoices.MAX_VOICES so a change to the pool size fails the test.
const VOICE_LIMIT := 8

var fx: Fixture
## A PAUSABLE parent for the tests that pause the game (see
## _stage_under_pausable_parent), freed after each test.
var _pausable: Node = null


func after_all() -> void:
	# Before the suite ends (the runner may quit next): give the mixer time
	# to drop every stopped playback (a few 12 ms blocks), or the engine
	# reports them as leaked.
	await Fixture.wait(get_tree(), 0.15)


func before_each() -> void:
	# Every director reads the fixture's in-memory settings (the shipped
	# defaults): no test writes user://settings.cfg.
	# The director starts in play (unducked), as after a scene reload: no
	# test waits out a BOOT duck. (Tests of other states set them.)
	Game.set_state(Game.State.PLAYING)
	fx = Fixture.new()
	fx.build(self)
	await wait_frames(2)


func after_each() -> void:
	fx.teardown()
	if _pausable != null:
		_pausable.free()
		_pausable = null
	get_tree().paused = false
	# A frame: the mixer drops the freed players' playbacks in its next
	# block, while the next test builds its stage and settles (after_all
	# waits longer before the runner may quit).
	await get_tree().process_frame


## Rebuilds the stage, in `state`, under a PROCESS_MODE_PAUSABLE parent, as
## in the game (Main is pausable and Game.PAUSED pauses the tree). The test
## runner is PROCESS_MODE_ALWAYS and every stage under it inherits that, so
## a director that lost its own PROCESS_MODE_ALWAYS would pass there and
## freeze in the game's pause menu (round 5's mutant R7: no duck, no music).
func _stage_under_pausable_parent(state: int) -> void:
	fx.teardown()
	_pausable = Node.new()
	_pausable.name = "PausableMain"
	_pausable.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(_pausable)
	Game.set_state(state)
	fx = Fixture.new()
	fx.build(_pausable)
	await wait_frames(2)


# ------------------------------------------------------------------ AU3 ---

## Envelope check shared by clip and render tests: onset = first 5 ms window
## at >= 10% of the peak; returns {peak_t, last_above_t} relative to onset.
static func transient(buf: PackedFloat32Array, rate: float) -> Dictionary:
	var env := AudioAnalysis.envelope(buf, rate, 0.005)
	var pk := 0.0
	var pk_i := 0
	for i in env.size():
		if env[i] > pk:
			pk = env[i]
			pk_i = i
	var onset := 0
	while onset < env.size() and env[onset] < pk * 0.1:
		onset += 1
	var last := onset
	for i in range(onset, env.size()):
		if env[i] >= pk * 0.1:
			last = i
	return {"peak_t": (pk_i - onset) * 0.005, "last_above_t": (last - onset + 1) * 0.005, "peak": pk}


func test_wingbeat_clips_are_transients() -> void:
	var bank := fx.director.bank
	var worst := 0.0
	for s in 3:
		for v in AudioBank.WHOOSH_VARIANTS:
			var d := AudioAnalysis.decode_wav(bank.get_stream(StringName("whoosh_%d_%d" % [s, v])))
			var tr := transient(d["mono"], d["rate"])
			worst = maxf(worst, tr["last_above_t"])
			lt(tr["last_above_t"], 0.3, "whoosh %d/%d: envelope below 10%% of peak within 300 ms of onset" % [s, v])
			lt(tr["peak_t"], 0.08, "whoosh %d/%d: peaks within 80 ms (a stroke, not a swell)" % [s, v])
	metric("worst_decay_s", worst)


## A wingbeat on the mix: a one-wing flap on its side (left, right), a soft
## flap quieter, and a both-wings flap (side 0, the common case: WingInput
## merges left and right onsets within 60 ms into one event) centred and as
## loud as a one-wing flap; every one a transient with its clip's
## brightness.
func test_wingbeat_render_side_strength_and_decay() -> void:
	Game.set_state(Game.State.PLAYING)
	var cap := fx.tap(AudioBuses.BODY)
	var out := {}
	var bright := []  # [rendered centroid, the played clip's centroid at its pitch]
	for spec in [[-1, 1.0], [1, 1.0], [-1, 0.3], [0, 1.0]]:
		cap.clear_buffer()
		Events.player_flapped.emit(spec[0], spec[1])
		# The whoosh player that took it: its clip and pitch.
		var w: AudioStreamPlayer3D = fx.director._whoosh[(fx.director._whoosh_i + AudioDirector.WHOOSH_VOICES - 1) % AudioDirector.WHOOSH_VOICES]
		# 0.36 s: past the 0.3 s limit with room to see a slow decay fail.
		var rec := await fx.record(get_tree(), cap, 0.36)
		var l := AudioAnalysis.db(AudioAnalysis.rms(rec["l"]))
		var r := AudioAnalysis.db(AudioAnalysis.rms(rec["r"]))
		var tr := transient(rec["mono"], rec["rate"])
		out["%d_%.1f" % [spec[0], spec[1]]] = {"l": l, "r": r, "decay": tr["last_above_t"]}
		var clip := AudioAnalysis.decode_wav(w.stream as AudioStreamWAV)
		var c_clip := AudioAnalysis.centroid(AudioAnalysis.mean_power(clip["mono"], 1024, 512, -30.0), clip["rate"]) * w.pitch_scale
		var c_mix := AudioAnalysis.centroid(AudioAnalysis.mean_power(rec["mono"], 1024, 512, -30.0), rec["rate"])
		bright.append([c_mix, c_clip])
		lt(tr["last_above_t"], 0.3, "rendered wingbeat (side %d, strength %.1f) decays below 10%% within 300 ms" % spec)
		await Fixture.wait(get_tree(), 0.05)
	var left: Dictionary = out["-1_1.0"]
	var right: Dictionary = out["1_1.0"]
	var soft: Dictionary = out["-1_0.3"]
	var both: Dictionary = out["0_1.0"]
	metric("left_flap_lr_db", [left["l"], left["r"]])
	metric("right_flap_lr_db", [right["l"], right["r"]])
	metric("soft_flap_l_db", soft["l"])
	metric("both_wings_flap_lr_db", [both["l"], both["r"]])
	# Clearly on its side, yet heard by both ears (as with real ears).
	between(left["l"] - left["r"], 6.0, 20.0, "left-wing flap: left ear 6-20 dB louder")
	between(right["r"] - right["l"], 6.0, 20.0, "right-wing flap: right ear 6-20 dB louder")
	gt(left["l"] - soft["l"], 6.0, "a 0.3-strength flap is at least 6 dB quieter than a full one")
	# Both wings: one whoosh at each hand, centred, and (at -3 dB each) as
	# loud in total as a one-wing flap, not twice as loud.
	lt(absf(both["l"] - both["r"]), 2.0, "both-wings flap: centred, the ears within 2 dB (L %.1f, R %.1f)" % [both["l"], both["r"]])
	var p_both := _pow_sum_db(both["l"], both["r"])
	var p_one := _pow_sum_db(left["l"], left["r"])
	metric("both_vs_one_wing_power_db", p_both - p_one)
	near(p_both, p_one, 3.0, "both-wings flap: total power within 3 dB of a one-wing flap (%+.1f dB)" % (p_both - p_one))
	# The whoosh keeps its designed brightness at the ear: no filter between
	# the clip and the Body bus (Godot's default 3D air-absorption shelf
	# follows volume_db and took a small bird's flutter from 3.6 to 2.0 kHz).
	metric("whoosh_centroid_mix_vs_clip_hz", bright)
	for b in bright:
		near(float(b[0]) / float(b[1]), 1.0, 0.1, "the rendered whoosh is as bright as its clip (centroid %.0f vs %.0f Hz)" % [b[0], b[1]])
	out["centroid_mix_vs_clip_hz"] = bright
	Fixture.save_measure("wingbeat", out)


# ------------------------------------------------------------------ AU4 ---

## The danger cue's loudness, tempo and place over the wind are measured in
## the flight session (audio_wind_test.test_danger_cue_scales_with_threat).
## Here: if the predator leaves the world (recycled by the Ecosystem) before
## GameLoop reports a new level, its heart must not beat on for a bird that
## is not there. Within 0.7 s the danger bus is 20 dB down.
func test_danger_falls_silent_when_its_predator_leaves() -> void:
	Game.set_state(Game.State.PLAYING)
	var cap := fx.tap(AudioBuses.DANGER)
	var predator := fx.add_npc(&"hawk", Vector3(0, 100, 30))
	fx.director.voices.scheduling = false  # (no call from the hawk meanwhile)
	Events.threat_changed.emit(1.0, predator)
	await Fixture.wait(get_tree(), 0.2)
	var on := AudioAnalysis.db(AudioAnalysis.rms((await fx.record(get_tree(), cap, 0.25))["mono"]))
	await Fixture.past_hitch(get_tree())
	fx.npcs.erase(predator)
	predator.alive = false
	predator.get_parent().remove_child(predator)
	predator.queue_free()
	await Fixture.wait(get_tree(), 0.5)
	var gone := AudioAnalysis.db(AudioAnalysis.rms((await fx.record(get_tree(), cap, 0.2))["mono"]))
	metric("danger_db", [on, gone])
	gt(on, -30.0, "threat 1 with the predator there: the danger cue sounds (%.1f dBFS)" % on)
	lt(gone, on - 20.0, "the danger cue falls silent once its predator has left the world (%.1f dBFS)" % gone)
	Fixture.save_measure("danger_predator_left", {"with_predator_db": on, "after_predator_left_db": gone})
	Events.threat_changed.emit(0.0, null)


func test_predator_screams_when_threat_turns_serious() -> void:
	Game.set_state(Game.State.PLAYING)
	var hawk := fx.add_npc(&"hawk", Vector3(0, 100, 30))
	var cues: Array = []
	fx.director.cue.connect(func(n: StringName, _i: Dictionary) -> void: cues.append(n))
	Events.threat_changed.emit(0.3, hawk)
	await wait_frames(2)
	eq(cues.count(&"screech"), 0, "no scream at a mild threat")
	Events.threat_changed.emit(0.7, hawk)
	await wait_frames(2)
	eq(cues.count(&"screech"), 1, "the hawk screams once as the threat crosses 0.6")
	var voice_birds := fx.director.voices.playing().map(func(v: Dictionary) -> Bird: return v["bird"])
	check(hawk in voice_birds, "the scream plays in 3D from the hawk")
	Events.threat_changed.emit(0.5, hawk)
	Events.threat_changed.emit(0.8, hawk)
	await wait_frames(2)
	eq(cues.count(&"screech"), 1, "cooldown: no second scream within 5 s")
	Events.threat_changed.emit(0.0, null)


## Gain (dB) Godot's inverse-distance law gives a 3D voice at the listener:
## volume + 20 log10(unit / d), capped at max_db, times the linear fade to
## max_distance (AudioStreamPlayer3D).
static func _voice_gain_db(p: AudioStreamPlayer3D, listener: Vector3) -> float:
	var d := maxf(p.global_position.distance_to(listener), 0.001)
	var att := minf(p.volume_db + 20.0 * log(p.unit_size / d) / log(10.0), p.max_db)
	return att + 20.0 * log(maxf(1.0 - d / p.max_distance, 1e-5)) / log(10.0)


## The DESIGN's "predator screech getting louder" for the smallest player
## (world_scale 0.141): ThreatWatch names a stooping hawk 45-60 m out. Its
## scream must sound from there, well over the wind, grow as it closes in,
## and a scream that could not sound must not use up the cooldown. The
## threatening hawk is heard from anywhere: an ordinary one 350 m away is
## out of its 300 m reach (world metres, at every size since round 5; until
## then an ordinary hawk 50 m from a sparrow-sized player was cut).
func test_small_player_hears_the_predator_scream_from_afar() -> void:
	Game.set_state(Game.State.PLAYING)
	var ws := 0.24 / 1.7  # WorldScaleDriver.target_scale, sparrow, 1.5 m arms
	fx.set_tel({"world_scale": ws, "airspeed": FlightSoundMap.cruise(0.03)})
	var calls := fx.tap(AudioBuses.CALLS)
	var voices := fx.director.voices
	var cues: Array = []
	fx.director.cue.connect(func(n: StringName, _i: Dictionary) -> void: cues.append(n))
	await wait_frames(3)
	# An ordinary hawk 50 m away calls for a sparrow-sized player too, one
	# 350 m away is out of earshot...
	var mid := fx.add_npc(&"hawk", Vector3(0, 100, 50))
	var far := fx.add_npc(&"hawk", Vector3(0, 100, -350))
	await wait_frames(2)
	check(voices.request_call(mid), "an ordinary hawk call 50 m away sounds for a sparrow-sized player (world metres)")
	check(not voices.request_call(far), "an ordinary hawk call 350 m away is out of reach")
	voices.stop_all()
	fx.npcs.erase(mid)
	mid.queue_free()
	# ... but the hawk that threatens the player screams from 65 m.
	var hawk := fx.add_npc(&"hawk", Vector3(0, 100, -65))
	await wait_frames(2)
	Events.threat_changed.emit(0.3, hawk)
	await wait_frames(2)
	Events.threat_changed.emit(0.65, hawk)
	await wait_frames(2)
	eq(cues.count(&"screech"), 1, "the threatening hawk 65 m away (460 perceived m) screams at the 0.6 crossing")
	# Its own calls too: the scheduler keeps it in reach, the ordinary hawk
	# stays out.
	check(voices.in_reach(hawk), "the scheduler keeps the threatening hawk in reach")
	check(not voices.in_reach(far), "and the ordinary hawk 350 m away out of it")
	var v: CallVoices.Voice = null
	for vv in voices.voices:
		if vv.follows and vv.bird == hawk and vv.player.playing:
			v = vv
	check(v != null, "the scream plays in 3D from the hawk")
	if v == null:
		return
	var g_far := _voice_gain_db(v.player, fx.listener.global_position)
	# Heard over the player's own wind at cruise (both A-weighted: the
	# scream's loudest 0.4 s, the wind's mean), measured together.
	var wind := fx.tap(AudioBuses.WIND)
	var pair := await fx.record2(get_tree(), calls, wind, 0.6)
	var loud: float = AudioAnalysis.loudness_aw(pair[0]["mono"], pair[0]["rate"], 0.4)["max"]
	var wind_aw: float = AudioAnalysis.loudness_aw(pair[1]["mono"], pair[1]["rate"], 0.4)["mean"]
	# Getting louder as it stoops: the voice follows the hawk to 12 m.
	hawk.global_position = Vector3(0, 100, -12)
	await wait_frames(3)
	check(v.player.playing and v.bird == hawk, "the scream still follows the hawk")
	var g_near := _voice_gain_db(v.player, fx.listener.global_position)
	metric("scream", {"gain_65m_db": g_far, "gain_12m_db": g_near, "calls_bus_aw_max": loud, "wind_aw_mean": wind_aw})
	gt(g_far - v.base_db, CallVoices.THREAT_FLOOR_DB - 0.5, "at 65 m it starts no quieter than %.0f dB under its unit level (%.1f)" % [-CallVoices.THREAT_FLOOR_DB, g_far - v.base_db])
	gt(loud - wind_aw, 10.0, "measured: the scream stands %.1f dB over the cruise wind, to the ear" % (loud - wind_aw))
	# From the floor (-6 dB under its unit level) up to the near-field cap
	# (0 dB of gain): 6 dB or more, a clear rise.
	gt(g_near - g_far, 6.0, "and it grows louder as the hawk closes in to 12 m (+%.1f dB)" % (g_near - g_far))
	# A scream that cannot sound (the hawk is already mid-call) does not
	# start the cooldown: the next crossing of the attack screams.
	voices.stop_all()
	Events.threat_changed.emit(0.0, null)
	fx.director._screech_cool = 0.0
	await wait_frames(2)
	var busy := fx.add_npc(&"hawk", Vector3(0, 100, -20))
	await wait_frames(2)
	voices.request_call(busy, 30.0)
	Events.threat_changed.emit(0.3, busy)
	Events.threat_changed.emit(0.7, busy)
	await wait_frames(2)
	eq(cues.count(&"screech"), 1, "a hawk already mid-call does not start a second voice")
	voices.stop_all()
	Events.threat_changed.emit(0.5, busy)
	Events.threat_changed.emit(0.8, busy)
	await wait_frames(2)
	eq(cues.count(&"screech"), 2, "the attempt that could not sound left no cooldown: the next crossing screams")
	Events.threat_changed.emit(0.0, null)


## "Predator screech getting louder" (DESIGN) between calls, not only within
## one: a hawk hunting a sparrow-sized player calls again and again as it
## closes in, and each new call starts louder than the one before, until it
## reaches its voice's full level (its ceiling: the loudest one voice plays,
## for headroom), and never quieter; one from 10 m at least 3 dB louder than
## one from 60 m. (Round 4 found a flat floor: every new call from 65 m
## down to 6 m started at the same -6 dB.) The far call keeps its floor
## (>= -6.5 dB relative to the unit level). Since round 5 the law is in
## world metres, so from about 20 m the call is at its natural level and
## soon at its ceiling. Gain at each call's start by Godot's law on the
## voice's own settings, which audio_calls_test checks against the mixer
## within 0.7 dB; the same clip, variety and pitch every time (the voices'
## rng reseeded).
func test_successive_screams_grow_as_the_predator_closes() -> void:
	var ws := 0.24 / 1.7  # sparrow, 1.5 m arms (WorldScaleDriver)
	fx.set_tel({"world_scale": ws, "airspeed": FlightSoundMap.cruise(0.03)})
	var voices := fx.director.voices
	var hawk := fx.add_npc(&"hawk", Vector3(0, 100, -60))
	# Only the calls this test asks for: the hawk's own next call is put off
	# (stop_all() forgets the call timers, so again after each).
	var hold := func() -> void: voices._next[hawk.get_instance_id()] = 1e9
	hold.call()
	Events.threat_changed.emit(0.8, hawk)
	await wait_frames(2)
	var dists := [60.0, 40.0, 20.0, 10.0, 5.0]
	var gains := PackedFloat32Array()
	var capped := []
	for dist: float in dists:
		voices.stop_all()
		hold.call()
		hawk.global_position = Vector3(0, 100, -dist)
		await wait_frames(2)
		voices._rng.seed = 99
		voices.request_call(hawk, 20.0, true)
		await wait_frames(1)
		var v := _voice_of(voices, hawk)
		check(v != null, "a new call from %d m sounds" % int(dist))
		if v == null:
			return
		gains.append(_voice_gain_db(v.player, fx.listener.global_position) - v.base_db)
		# At its ceiling when the inverse-distance level reaches max_db.
		var d := v.player.global_position.distance_to(fx.listener.global_position)
		capped.append(v.player.volume_db + 20.0 * log(v.player.unit_size / d) / log(10.0) >= v.player.max_db - 0.01)
	metric("new_call_gain_rel_unit_db", {"dist_m": dists, "gain_db": Array(gains), "at_ceiling": capped})
	gt(gains[0], -6.5, "the far call (60 m, 425 perceived m) keeps its floor (%.1f dB)" % gains[0])
	for i in range(1, gains.size()):
		if capped[i]:
			gt(gains[i], gains[i - 1] - 0.05, "a new call from %d m, at its voice's full level, is no quieter than one from %d m (%.1f -> %.1f dB)" % [
				int(dists[i]), int(dists[i - 1]), gains[i - 1], gains[i]])
		else:
			gt(gains[i], gains[i - 1] + 0.3, "a new call from %d m starts louder than one from %d m (%.1f -> %.1f dB)" % [
				int(dists[i]), int(dists[i - 1]), gains[i - 1], gains[i]])
	check(capped[capped.size() - 1], "from 5 m the scream is at its voice's full level")
	check(not capped[0] and not capped[1], "from 60 and 40 m it is not (it grows as the hawk closes)")
	gt(gains[3] - gains[0], 3.0, "a new call from 10 m is at least 3 dB louder than one from 60 m (%+.1f dB)" % (gains[3] - gains[0]))
	# Fleeing in a tucked full dive: the Calls bus's speed duck (about 6 dB
	# at 2.6x) masks ordinary calls, but the threatening predator's voice
	# makes it up (round 4: the scream sat 7 dB under a tucked dive's wind in
	# its own band), and rises over the wind's edge layer, the hiss that
	# fills its band (round 5: it still sat at the wind's level there): its
	# voice is lifted 10 dB (literal: the 6 dB duck and 4 dB with the edge
	# fully in). The loudest one voice may play is still a full voice (0 dB
	# of gain) under the duck: the crowd rule brings the Calls bus down by
	# whatever the lift takes it over that (headroom). So from 60 m (its
	# floor, 425 perceived m) the call reaches the ear louder than at cruise
	# and at a full voice under the duck; from 2 m no louder either. Level at
	# the ear = voice gain + the Calls bus (speed duck and crowd gain, once
	# the crowd gain has landed). The ducks and the lift are set at their
	# targets (the director keeps the targets from the telemetry).
	var net := {}
	var lifts := {}
	for flight in [["cruise", 1.0, false], ["dive", 2.6, true]]:
		fx.set_tel({"airspeed": FlightSoundMap.cruise(0.03) * flight[1], "tucked": flight[2], "wing_extension": 0.1 if flight[2] else 1.0})
		voices.speed_duck_target_db = FlightSoundMap.calls_duck_db(flight[1])
		voices.speed_duck_db = voices.speed_duck_target_db
		voices.edge_lift_target_db = 4.0 if flight[2] else 0.0
		voices.edge_lift_db = voices.edge_lift_target_db
		for dist: float in [60.0, 2.0]:
			voices.stop_all()
			hold.call()
			hawk.global_position = Vector3(0, 100, -dist)
			await wait_frames(2)
			voices._rng.seed = 99
			voices.request_call(hawk, 20.0, true)
			await Fixture.wait(get_tree(), 0.15)  # (the crowd gain's attack: 0.03 s)
			var v := _voice_of(voices, hawk)
			net["%s_%dm" % [flight[0], int(dist)]] = _voice_gain_db(v.player, fx.listener.global_position) + voices.speed_duck_db + voices.crowd_db if v else -INF
			lifts["%s_%dm" % [flight[0], int(dist)]] = v.lift_db if v else NAN
	lt(voices.speed_duck_db, -5.0, "(a dive's speed duck is in place: %.1f dB)" % voices.speed_duck_db)
	near(voices.edge_lift_target_db, 4.0, 0.05, "(the director asks for the edge lift in a tucked full dive: %.2f dB)" % voices.edge_lift_target_db)
	# Pulling out of the dive mid-scream: the voice's make-up follows the
	# bus's duck back down, so the call does not jump by the 6 dB it made
	# up (round 4's first version fixed the make-up at the call's start:
	# heavy play's belfry scene, entered straight from a dive, then peaked
	# 0.6 dB under the limiter's ceiling); the edge lift goes as the edge
	# does. It never jumps up, and drops by no more than the edge lift.
	voices.stop_all()
	hold.call()
	hawk.global_position = Vector3(0, 100, -60)
	await wait_frames(2)
	voices._rng.seed = 99
	voices.request_call(hawk, 20.0, true)
	await Fixture.wait(get_tree(), 0.15)
	var vd := _voice_of(voices, hawk)
	# (Voice gain and speed duck: the crowd gain is still releasing from the
	# 2 m call, the same in both readings.)
	net["pull_out_in_dive"] = _voice_gain_db(vd.player, fx.listener.global_position) + voices.speed_duck_db if vd else -INF
	fx.set_tel({"airspeed": FlightSoundMap.cruise(0.03), "tucked": false, "wing_extension": 1.0})
	voices.speed_duck_target_db = 0.0
	voices.speed_duck_db = 0.0
	await wait_frames(3)
	net["pull_out_at_cruise"] = _voice_gain_db(vd.player, fx.listener.global_position) + voices.speed_duck_db if vd else -INF
	var drop: float = float(net["pull_out_in_dive"]) - float(net["pull_out_at_cruise"])
	between(drop, -0.3, 4.3, "pulling out of the dive mid-scream, the call never jumps up and loses at most the edge lift (%.1f -> %.1f dB)" % [net["pull_out_in_dive"], net["pull_out_at_cruise"]])
	metric("threat_call_at_the_ear_db", net)
	metric("threat_voice_lift_db", lifts)
	near(float(lifts["dive_60m"]), 10.0, 0.1, "in a tucked full dive the threat's voice is lifted by the 6 dB duck and 4 dB over the edge (%.2f dB)" % float(lifts["dive_60m"]))
	near(float(lifts["cruise_60m"]), 0.0, 0.05, "and not at cruise (%.2f dB)" % float(lifts["cruise_60m"]))
	gt(float(net["dive_60m"]) - float(net["cruise_60m"]), 1.0, "fleeing in a tucked dive, the far threat's call (60 m) reaches the ear louder than at cruise (%.1f vs %.1f dB)" % [net["dive_60m"], net["cruise_60m"]])
	lt(float(net["dive_60m"]), FlightSoundMap.calls_duck_db(2.6) + 0.3, "and no louder than a full voice under the dive's speed duck (%.1f dB)" % float(net["dive_60m"]))
	lt(float(net["dive_2m"]), FlightSoundMap.calls_duck_db(2.6) + 0.3, "from 2 m, over a full voice, the crowd rule holds it to a full voice under the dive's speed duck (%.1f dB; cruise %.1f)" % [net["dive_2m"], net["cruise_2m"]])
	Fixture.save_measure("successive_screams", {"dist_m": dists, "gain_db": Array(gains), "at_ceiling": capped, "at_the_ear_db": net})
	voices.stop_all()
	Events.threat_changed.emit(0.0, null)


# ------------------------------------------------------------------ AU5 ---

func _crowd(count: int, rng: RandomNumberGenerator) -> Array[Bird]:
	var species := [&"wren", &"sparrow", &"swallow", &"starling", &"pigeon", &"crow", &"gull", &"hawk", &"eagle"]
	var out: Array[Bird] = []
	for i in count:
		var a := rng.randf() * TAU
		var d := 2.0 + 2.2 * i  # distinct distances, 2 .. ~66 m
		out.append(fx.add_npc(species[i % species.size()], Vector3(cos(a) * d, 100.0 + rng.randf_range(-3, 3), sin(a) * d)))
	return out


func test_voices_are_pooled_and_capped() -> void:
	Game.set_state(Game.State.PLAYING)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var birds := _crowd(30, rng)
	var voices := fx.director.voices
	var nodes_before := voices.get_child_count()
	var max_active := 0
	var min_crowd := 0.0
	var crowd_checks := []  # [model dB, CallVoices' target dB]
	for frame in 120:
		# Everyone asks to call, every 10 frames, in a shuffled order.
		if frame % 10 == 0:
			var order := birds.duplicate()
			for i in range(order.size() - 1, 0, -1):
				var j := rng.randi_range(0, i)
				var t: Bird = order[i]
				order[i] = order[j]
				order[j] = t
			for b in order:
				voices.request_call(b)
		await get_tree().process_frame
		max_active = maxi(max_active, voices.active_count())
		min_crowd = minf(min_crowd, voices.crowd_db)
		if frame % 10 == 5:
			# The crowd rule, from the players as Godot sets them (this test's
			# own copy of the distance law): the bus comes down by what the
			# voices add up to at the ear over one voice at full level.
			var p := 0.0
			for v in voices.voices:
				if v.player.playing:
					p += pow(10.0, _voice_gain_db(v.player, fx.listener.global_position) / 10.0)
			crowd_checks.append([-maxf(0.0, 10.0 * log(p) / log(10.0)), voices.crowd_target_db()])
	metric("max_active", max_active)
	metric("stats", voices.stats.duplicate())
	metric("crowd_db_min", min_crowd)
	metric("crowd_model_vs_target_db", crowd_checks)
	eq(max_active, VOICE_LIMIT, "exactly 8 voices in use at the peak, never more")
	eq(voices.get_child_count(), nodes_before, "no players created or freed (pooled)")
	gt(voices.stats["stolen"], 0.0, "far voices were stolen by nearer ones")
	gt(voices.stats["dropped"], 0.0, "calls that could not win a voice were dropped")
	# Crowd normalisation: eight voices 2-20 m away bring the Calls bus down
	# to what one voice at full level plays ...
	var worst := 0.0
	for c in crowd_checks:
		worst = maxf(worst, absf(float(c[0]) - float(c[1])))
	lt(worst, 0.2, "the crowd target is the voices' summed gain at the ear over one full voice (worst %.2f dB off)" % worst)
	lt(min_crowd, -3.0, "eight near voices bring the Calls bus down (%.1f dB)" % min_crowd)
	# ... and the release writes the bus only when the gain has moved
	# (0.05 dB steps), then never again once it has landed. (Frames stepped
	# directly: 10 s of release at 60 Hz.)
	voices.stop_all()
	var w0: int = voices.stats["crowd_writes"]
	for i in 600:
		voices._update_crowd(1.0 / 60.0)
	var release_writes: int = voices.stats["crowd_writes"] - w0
	var w1: int = voices.stats["crowd_writes"]
	for i in 300:
		voices._update_crowd(1.0 / 60.0)
	metric("crowd_release_writes", release_writes)
	eq(voices.crowd_db, 0.0, "the crowd gain lands exactly on 0 dB")
	near(AudioServer.get_bus_volume_db(AudioBuses.index(AudioBuses.CALLS)), 0.0, 1e-4, "and the Calls bus is back at 0 dB")
	lt(release_writes, 100, "the release writes the bus once per audible step, not every frame (%d writes in 600 frames)" % release_writes)
	eq(voices.stats["crowd_writes"] - w1, 0, "once settled, the Calls bus is never rewritten")
	# On the bus: two crows cawing 4 m away, each at its full level (0 dB of
	# gain), add up to one voice at full level: the bus comes down about
	# 3 dB (a count of voices would leave two alone).
	var pair: Array[Bird] = [fx.add_npc(&"crow", Vector3(-3, 100, -2.6)), fx.add_npc(&"crow", Vector3(3, 100, -2.6))]
	await wait_frames(1)
	for b in pair:
		voices.request_call(b)
	await Fixture.wait(get_tree(), 0.12)
	var p2 := 0.0
	for v in voices.voices:
		if v.player.playing:
			p2 += pow(10.0, _voice_gain_db(v.player, fx.listener.global_position) / 10.0)
	var model2 := -maxf(0.0, 10.0 * log(p2) / log(10.0))
	var bus2 := AudioServer.get_bus_volume_db(AudioBuses.index(AudioBuses.CALLS))
	metric("two_near_crows_bus_db", [bus2, model2])
	near(bus2, model2, 0.3, "two crows at arm's length: the Calls bus comes down by their summed gain over one full voice (%.2f dB, model %.2f)" % [bus2, model2])
	lt(bus2, -2.0, "two loud voices close by are normalised too (%.1f dB)" % bus2)


func test_voices_go_to_the_most_relevant_birds() -> void:
	Game.set_state(Game.State.PLAYING)
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	var birds := _crowd(24, rng)
	var voices := fx.director.voices
	# A far hawk that is hunting the player outranks nearer small birds.
	var hawk := fx.add_npc(&"hawk", Vector3(0, 100, 120))
	Events.threat_changed.emit(0.5, hawk)
	await wait_frames(2)
	var order: Array[Bird] = birds.duplicate()
	order.append(hawk)
	order.reverse()  # farthest first: the worst case for stealing
	for b in order:
		voices.request_call(b)
	await Fixture.wait(get_tree(), 0.12)
	var playing := voices.playing()
	var in_voice := {}
	var weakest := INF
	for v in playing:
		in_voice[v["bird"]] = true
		weakest = minf(weakest, voices.priority(v["bird"]))
	var strongest_left := -INF
	for b in order:
		if not in_voice.has(b):
			strongest_left = maxf(strongest_left, voices.priority(b))
	metric("playing", playing.size())
	metric("weakest_playing_db", weakest)
	metric("strongest_waiting_db", strongest_left)
	eq(playing.size(), VOICE_LIMIT, "all 8 voices busy")
	check(in_voice.has(birds[0]), "the nearest bird has a voice")
	check(in_voice.has(hawk), "the threatening hawk (120 m away) has a voice")
	check(weakest >= strongest_left - CallVoices.STEAL_MARGIN_DB,
		"no waiting bird outranks a playing one by more than the steal margin (%.1f vs %.1f dB)" % [weakest, strongest_left])
	Events.threat_changed.emit(0.0, null)


## Reach and level follow world metres at every player size (round 5: the
## perceived-distance law cut a songbird at 12 m and a crow at 27 m for a
## sparrow-sized player, and the Ecosystem's sky, 60-110 m out, was
## silent). Literal distances: a songbird 60 m away is in reach at the
## sparrow's scale, one 300 m away at no scale; the same bird ranks the
## same whoever listens. The perceived distance (the urgency floor's) still
## scales with 1 / world_scale.
func test_scheduler_calls_respect_reach_and_scale() -> void:
	Game.set_state(Game.State.PLAYING)
	var voices := fx.director.voices
	var near := fx.add_npc(&"sparrow", Vector3(10, 100, 0))
	var mid := fx.add_npc(&"sparrow", Vector3(0, 100, 60))
	var crow := fx.add_npc(&"crow", Vector3(-150, 100, 0))
	var far := fx.add_npc(&"sparrow", Vector3(300, 100, 0))
	await Fixture.wait(get_tree(), 0.3)
	var ranks := {}
	for ws in [1.0, 0.13]:
		voices.world_scale = ws
		var tag := "world_scale %.2f" % ws
		check(voices.in_reach(near), "%s: a sparrow 10 m away is in reach" % tag)
		check(voices.in_reach(mid), "%s: a sparrow 60 m away is in reach" % tag)
		check(voices.in_reach(crow), "%s: a crow 150 m away is in reach" % tag)
		check(not voices.in_reach(far), "%s: a sparrow 300 m away is out of reach" % tag)
		ranks[ws] = [voices.priority(near), voices.priority(mid), voices.priority(crow)]
	for k in 3:
		near(float(ranks[0.13][k]), float(ranks[1.0][k]), 1e-4, "the same bird ranks the same for a sparrow-sized player (world metres)")
	metric("priority_by_scale_db", ranks)
	voices.world_scale = 0.13
	near_eq(voices.perceived_distance(near.get_body_position()), 10.0 / 0.13, 0.5)
	eq(voices.request_call(far), false, "an out-of-reach call is dropped")
	check(voices.request_call(mid), "a sparrow-sized player's call request from 60 m sounds")
	# Air absorption from distance (world metres): the crow 150 m away is
	# duller as well as quieter. Literal, ISO 9613-1 in mild humid air: 23
	# and 77 dB/km at 4 and 8 kHz, about 40 dB/km over the band above
	# 5 kHz: a 5-7 dB shelf at 150 m.
	check(voices.request_call(crow), "the crow 150 m away calls")
	var cv := _voice_of(voices, crow)
	check(cv != null, "(its voice)")
	if cv:
		metric("air_shelf_150m_db", cv.player.attenuation_filter_db)
		between(cv.player.attenuation_filter_db, -7.0, -5.0, "a call 150 m away loses 5-7 dB above 5 kHz to the air (%.1f dB)" % cv.player.attenuation_filter_db)
		near(cv.player.attenuation_filter_cutoff_hz, 5000.0, 1.0, "(the shelf starts at 5 kHz)")
	var nv := _voice_of(voices, mid)
	if nv:
		between(nv.player.attenuation_filter_db, -3.0, -1.5, "and one 60 m away 1.5-3 dB (%.1f dB)" % nv.player.attenuation_filter_db)


## In the game the XR rig rules: its world_scale (the telemetry's copy is
## only the fallback) and its hands, where each wingbeat plays. The suite's
## other stages have no rig, so only the fallbacks ran there (round 5's
## mutants R1, hands swapped, and R2, the rig's scale ignored, passed it).
func test_vr_rig_sets_the_scale_and_the_hands() -> void:
	fx.set_tel({"airspeed": 9.0, "world_scale": 1.0})
	var rig := XROrigin3D.new()
	rig.name = "Rig"
	rig.add_to_group(&"player_rig")
	fx.root.add_child(rig)
	rig.global_position = Vector3(0, 100, 0)
	rig.world_scale = 0.14
	for side in [["LeftHand", -1.0], ["RightHand", 1.0]]:
		var h := Node3D.new()
		h.name = side[0]
		rig.add_child(h)
		h.position = Vector3(0.3 * side[1], -0.1, -0.2)
	# The director looks the rig up twice a second.
	fx.director._rig_check = 0
	await wait_frames(3)
	near(fx.director.voices.world_scale, 0.14, 1e-4, "the voices take the rig's world_scale, not the telemetry's 1.0 (%.3f)" % fx.director.voices.world_scale)
	var hands := {-1: rig.get_node("LeftHand") as Node3D, 1: rig.get_node("RightHand") as Node3D}
	for side in [-1, 1]:
		var w: AudioStreamPlayer3D = fx.director._whoosh[fx.director._whoosh_i]
		Events.player_flapped.emit(side, 1.0)
		check(w.playing, "flap %d: a whoosh voice plays" % side)
		vnear(w.global_position, (hands[side] as Node3D).global_position, 1e-4, "a %s flap plays at the %s" % ["left" if side < 0 else "right", hands[side].name])
	# Both wings: one whoosh at each hand.
	var w0: AudioStreamPlayer3D = fx.director._whoosh[fx.director._whoosh_i]
	var w1: AudioStreamPlayer3D = fx.director._whoosh[(fx.director._whoosh_i + 1) % AudioDirector.WHOOSH_VOICES]
	Events.player_flapped.emit(0, 1.0)
	vnear(w0.global_position, (hands[-1] as Node3D).global_position, 1e-4, "a both-wings flap: one whoosh at the left hand")
	vnear(w1.global_position, (hands[1] as Node3D).global_position, 1e-4, "and one at the right hand")
	# Growing mid-flight: the rig's scale changes, the voices follow.
	rig.world_scale = 1.3
	await wait_frames(2)
	near(fx.director.voices.world_scale, 1.3, 1e-4, "the voices follow the rig's world_scale as the player grows")


## "Silent ones paused so it costs no mixing" (the Quest budget): at cruise
## with no stall, no lift and no threat, the buffet, hum, heartbeat and
## drone are paused, and 100 m up every ambience bed is (round 5's mutant R3,
## layers never paused, passed the suite).
func test_silent_layers_cost_no_mixing() -> void:
	fx.set_tel({"airspeed": FlightSoundMap.cruise(fx.player.mass), "stalled": false, "in_updraft": 0.0})
	fx.add_world([{"name": "wood", "kind": "forest", "position": Vector3(0, 0, 0), "radius": 80.0}])
	fx.director.ambience.set_world(fx.world)
	await Fixture.wait(get_tree(), 0.3)
	var d := fx.director
	var st := {}
	for l in d._layers:
		st[String(l.key)] = {"stream_paused": l.player.stream_paused, "playing": l.player.playing}
	for key in d.ambience._players:
		var p: AudioStreamPlayer = d.ambience._players[key]["player"]
		st["bed." + String(key)] = {"stream_paused": p.stream_paused, "playing": p.playing}
	metric("idle_players", st)
	for key in ["stall_flutter", "updraft_hum", "drone", "heartbeat"]:
		check(bool(st[key]["stream_paused"]) or not bool(st[key]["playing"]), "%s: silent, and not mixing (%s)" % [key, st[key]])
	check(bool(st["wind_body"]["playing"]) and not bool(st["wind_body"]["stream_paused"]), "the wind body plays at cruise")
	for key in d.ambience._players:
		var e: Dictionary = st["bed." + String(key)]
		check(bool(e["stream_paused"]) or not bool(e["playing"]), "bed %s: silent 100 m up, and not mixing (%s)" % [key, e])


func _voice_of(voices: CallVoices, b: Bird) -> CallVoices.Voice:
	for v in voices.voices:
		if v.follows and v.bird == b and v.player.playing:
			return v
	return null


## As the Ecosystem removes a bird (scripts/ai/ecosystem.gd _remove): dead,
## out of the tree, freed at the end of the frame.
func _remove_like_ecosystem(b: Bird) -> void:
	fx.npcs.erase(b)
	b.alive = false
	b.get_parent().remove_child(b)
	b.queue_free()


## Birds leave mid-call all the time: prey is eaten, the Ecosystem recycles
## far/surplus/outgrown birds, Restart clears the sky. A voice must let go
## of its bird at once: no engine errors from reading a bird outside the
## tree, no call jumping to the world origin, no moth loop left running, no
## script error when a queued caller is freed during the steal fade.
func test_voices_let_go_of_birds_that_leave() -> void:
	Game.set_state(Game.State.PLAYING)
	var log := ErrorLog.install()
	var voices := fx.director.voices
	var hawk := fx.add_npc(&"hawk", Vector3(40, 100, 0))
	var moth := fx.add_npc(&"moth", Vector3(0.5, 100, 0))
	var moth2 := fx.add_npc(&"moth", Vector3(-0.5, 100, 0.3))
	await Fixture.wait(get_tree(), 0.3)  # the scheduler gives the moths their loops (every 12 frames)
	voices.request_call(hawk, 30.0)  # (or its own timer already did)
	await wait_frames(3)
	var hv := _voice_of(voices, hawk)
	var mv := _voice_of(voices, moth)
	var mv2 := _voice_of(voices, moth2)
	check(hv != null and mv != null and mv2 != null, "the hawk's call and both moths' flutter loops are playing")
	if hv == null or mv == null or mv2 == null:
		log.uninstall()
		return
	var hawk_at := hv.player.global_position
	var moth_at := mv.player.global_position
	# 1. Removed the Ecosystem's way at the start of a frame, before the
	# director's _process.
	await get_tree().process_frame
	_remove_like_ecosystem(hawk)
	_remove_like_ecosystem(moth)
	check(hv.bird == null and mv.bird == null, "their voices let go at once (Events.bird_removed)")
	await wait_frames(3)
	vnear(hv.player.global_position, hawk_at, 0.01, "the hawk's call stays where the hawk was (no jump to the origin)")
	vnear(mv.player.global_position, moth_at, 0.01, "so does the moth's flutter")
	await Fixture.wait(get_tree(), CallVoices.GONE_FADE + 0.1)
	check(not hv.player.playing, "the gone hawk's call has faded out")
	check(not mv.player.playing, "the removed moth's loop has stopped")
	# 2. A moth freed outright (a teardown).
	fx.npcs.erase(moth2)
	moth2.free()
	await Fixture.wait(get_tree(), CallVoices.GONE_FADE + 0.1)
	check(not mv2.player.playing, "a freed moth's loop has stopped")
	# 3. A queued steal whose caller is freed inside the 50 ms fade, and one
	# whose caller is caught (alive = false) in it: the call is dropped, the
	# voice is left free, nothing reads the gone bird. (Only these requests:
	# the scheduler's own timers would add calls of their own.)
	voices.scheduling = false
	for gone_how in ["freed", "caught"]:
		var far: Array[Bird] = []
		for i in VOICE_LIMIT:
			var a := TAU * i / VOICE_LIMIT
			far.append(fx.add_npc(&"sparrow", Vector3(cos(a) * 60.0, 100.0, sin(a) * 60.0)))
		for b in far:
			voices.request_call(b)
		await wait_frames(1)
		var crow := fx.add_npc(&"crow", Vector3(0, 100, -3))
		var stolen: int = voices.stats["stolen"]
		var started: int = voices.stats["started"]
		check(voices.request_call(crow) and voices.stats["stolen"] == stolen + 1, "%s: the near crow steals a voice (queued on a fading one)" % gone_how)
		if gone_how == "freed":
			fx.npcs.erase(crow)
			crow.free()
		else:
			crow.alive = false
		await Fixture.wait(get_tree(), 0.2)
		eq(voices.stats["started"], started, "%s: the queued call never starts" % gone_how)
		var stale := 0
		for v in voices.voices:
			if v.follows and not CallVoices._present(v.bird):
				stale += 1
		eq(stale, 0, "%s: no voice follows a gone bird" % gone_how)
		for v in voices.playing():
			check(v["bird"] == null or CallVoices._present(v["bird"]), "%s: playing() lists only live birds" % gone_how)
		lt(voices.active_count(), VOICE_LIMIT, "%s: the stolen voice is free again" % gone_how)
		voices.stop_all()
		for b in far:
			_remove_like_ecosystem(b)
		if gone_how == "caught":
			_remove_like_ecosystem(crow)
		await wait_frames(2)
	log.uninstall()
	metric("errors", log.errors)
	metric("gone", voices.stats["gone"])
	eq(log.errors, 0, "no engine or script errors (%s)" % [log.samples])


## A director taken out of the tree and put back (a re-parent; a scene
## removed before it is freed): events arriving while it is out are not
## heard and raise no error, its sound resumes when it is back, and the
## crowd gain it put on the shared Calls bus does not outlive it (a
## reloaded scene's director would otherwise play every call 4.3 dB down).
func test_director_leaves_the_tree_and_comes_back() -> void:
	Game.set_state(Game.State.PLAYING)
	fx.set_tel({"airspeed": 16.0})
	var wind := fx.tap(AudioBuses.WIND)
	await Fixture.wait(get_tree(), 0.3)
	var before := AudioAnalysis.db(AudioAnalysis.rms((await fx.record(get_tree(), wind, 0.25))["mono"]))
	var log := ErrorLog.install()
	var d := fx.director
	var parent := d.get_parent()
	var hawk := fx.add_npc(&"hawk", Vector3(0, 100, -20))
	parent.remove_child(d)
	Events.player_flapped.emit(-1, 1.0)
	Events.bird_caught.emit(fx.player, fx.add_npc(&"wren", Vector3(0, 100, -2)))
	Events.threat_changed.emit(0.7, hawk)
	Events.player_collided.emit(3.0, Vector3.UP)
	Game.set_state(Game.State.PAUSED)
	Game.set_state(Game.State.PLAYING)
	var out_errors: int = log.errors
	parent.add_child(d)
	await wait_frames(10)
	var after := AudioAnalysis.db(AudioAnalysis.rms((await fx.record(get_tree(), wind, 0.25))["mono"]))
	log.uninstall()
	metric("errors_out_and_back", [out_errors, log.errors - out_errors])
	metric("wind_db", [before, after])
	eq(out_errors, 0, "events while the director is out of the tree raise no errors (%s)" % [log.samples])
	eq(log.errors - out_errors, 0, "back in the tree it runs without errors (%s)" % [log.samples])
	near(after, before, 3.0, "and its wind plays again (%.1f -> %.1f dBFS)" % [before, after])
	Events.threat_changed.emit(0.0, null)
	# A crowd of eight on the Calls bus, then the director goes for good.
	var calls := AudioBuses.index(AudioBuses.CALLS)
	for i in 10:
		var a := TAU * i / 10.0
		d.voices.request_call(fx.add_npc(&"sparrow", Vector3(cos(a) * 5.0, 100.0, sin(a) * 5.0)))
	await Fixture.wait(get_tree(), 0.15)
	lt(AudioServer.get_bus_volume_db(calls), -3.0, "a crowd of eight lowers the Calls bus")
	fx.teardown()
	near(AudioServer.get_bus_volume_db(calls), 0.0, 1e-4, "the Calls bus is back at 0 dB when the director leaves")
	# And a new director corrects a bus someone else left down.
	AudioServer.set_bus_volume_db(calls, -4.26)
	fx = Fixture.new()
	fx.build(self)
	Game.set_state(Game.State.PLAYING)
	await wait_frames(3)
	near(AudioServer.get_bus_volume_db(calls), 0.0, 1e-4, "a new director with no crowd sets the Calls bus to 0 dB")


func near_eq(a: float, b: float, tol: float) -> void:
	near(a, b, tol, "perceived distance (the urgency floor's) scales with 1 / world_scale")


## AU5: the director's cost per frame (< 1 ms on a Quest) with 60 birds,
## 40 landmarks and the flight changing every frame, measured two ways:
## the CPU-bound tight loop (the cost itself) and the wall-clock frames,
## held by their fastest quarter (see below).
func test_director_cost_under_load() -> void:
	Game.set_state(Game.State.PLAYING)
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var marks: Array[Dictionary] = []
	for i in 40:
		var kinds := ["forest", "lake", "town", "meadow", "field", "orchard", "farm", "hedge"]
		marks.append({"name": "m%d" % i, "kind": kinds[i % kinds.size()], "radius": rng.randf_range(20, 150),
			"position": Vector3(rng.randf_range(-400, 400), 0, rng.randf_range(-400, 400))})
	fx.add_world(marks)
	fx.player.global_position = Vector3(0, 10, 0)
	fx.listener.global_position = Vector3(0, 10, 0)
	var birds := _crowd(60, rng)
	var hawk: Bird = birds[7]
	await Fixture.wait(get_tree(), 0.15)
	fx.director.reset_perf()
	# 120 frames: through a whole speed cycle (tuck, stall, lift, threats).
	for frame in 120:
		var t := frame / 24.0
		fx.set_tel({"airspeed": 9.0 + 8.0 * sin(t), "tucked": sin(t) > 0.5, "wing_extension": 0.5 + 0.5 * cos(t),
			"stalled": frame % 40 < 6, "in_updraft": maxf(0.0, 3.0 * sin(t * 0.7))})
		fx.player.velocity = Vector3(sin(t), 0, -cos(t)) * 9.0
		if frame % 12 == 0:
			Events.player_flapped.emit([-1, 0, 1][frame % 3], 0.8)
		if frame % 18 == 0:
			Events.threat_changed.emit(absf(sin(t)), hawk)
		for b in birds:
			b.global_position += Vector3(0.05, 0, 0).rotated(Vector3.UP, t)
		await get_tree().process_frame
	var st := fx.director.perf_stats()
	for k in st:
		metric(k + "_ms" if k != "frames" else k, st[k])
	# The brief's own bar, on the wall clock: the average frame under 1 ms.
	gt(st["frames"], 110.0, "~120 frames measured")
	lt(st["mean"], 1.0, "AU5: the director's frame costs under 1 ms on average (%.3f ms; 60 birds, 40 landmarks, full flight)" % st["mean"])
	# The scheduler visits a few birds a frame in round-robin, never all 60
	# (ceil(60 / 12) = 5; a regression to all of them is 12x the work).
	var voices := fx.director.voices
	var n_birds := Birds.all().size()
	var i0: int = voices._sched_i
	fx.director._process(1.0 / 72.0)
	var visited := posmod(voices._sched_i - i0, n_birds)
	metric("birds_visited_per_frame", visited)
	eq(visited, ceili(n_birds / 12.0), "one frame visits ceil(%d / 12) birds, not all of them (%d)" % [n_birds, visited])
	# CPU-bound: _process called back to back with the flight changing on
	# every call, as in real frames (the frozen state of round 4's loop
	# wrote nothing to the engine), best of 5 blocks of 200 calls. A frame
	# passes between blocks: thousands of engine writes queued inside one
	# frame stall the next frames (round 5's verifier: 5 s after 4000
	# calls), which is the test's cost, not the director's. Quest Pro runs
	# GDScript roughly 3-4x slower than this M1 Pro, so 0.25 ms here is the
	# brief's 1 ms there. (Round 4 asserted 0.1 ms, a regression tripwire
	# with no footing in the brief; it failed once at 0.106 ms under load,
	# with the thread on an efficiency core. It is recorded.)
	var best := INF
	var k := [0]
	var change := func() -> void:
		var t: float = k[0] / 24.0
		fx.set_tel({"airspeed": 9.0 + 8.0 * sin(t), "tucked": sin(t) > 0.5, "wing_extension": 0.5 + 0.5 * cos(t),
			"stalled": k[0] % 40 < 6, "in_updraft": maxf(0.0, 3.0 * sin(t * 0.7))})
		fx.player.velocity = Vector3(sin(t), 0, -cos(t)) * 9.0
		fx.listener.rotation.y = 0.3 * sin(t * 0.5)
		k[0] += 1
	for block in 5:
		var us := 0
		for i in 200:
			change.call()
			var t0 := Time.get_ticks_usec()
			fx.director._process(1.0 / 72.0)
			us += Time.get_ticks_usec() - t0
		best = minf(best, us / 200.0 / 1000.0)
		await get_tree().process_frame
	metric("tight_loop_ms", best)
	lt(best, 0.25, "director _process CPU cost under 0.25 ms per call with the flight changing every call (tight loop, 60 birds): 1 ms on a Quest (%.3f ms)" % best)
	# Event handlers run outside _process, only on events; the most frequent
	# is a wingbeat (a few per second while flapping). Timed the same way.
	var t1 := Time.get_ticks_usec()
	for i in 100:
		Events.player_flapped.emit([-1, 1, 0][i % 3], 0.8)
	var flap_ms := (Time.get_ticks_usec() - t1) / 100.0 / 1000.0
	metric("flap_event_ms", flap_ms)
	lt(flap_ms, 0.1, "a wingbeat event costs under 0.1 ms")
	Fixture.save_measure("cost", {"stats": st, "tight_loop_ms": best, "flap_event_ms": flap_ms, "birds": 60, "landmarks": 40})
	Events.threat_changed.emit(0.0, null)


# ------------------------------------------------------------------ AU6 ---

## Level of the master tap relative to the wind bus over the same stretch:
## the wind's own gusts cancel out, what is left is the mixer's gain.
static func _gain_db(pair: Array) -> float:
	return AudioAnalysis.db(AudioAnalysis.rms(pair[1]["mono"])) - AudioAnalysis.db(AudioAnalysis.rms(pair[0]["mono"]))


## AU6 on the mix, menu -> flight -> pause, as a player meets them:
##  * the menu: music and UI sounds at the shipped Settings (master 0.8,
##    music 0.5): the music gentle but clearly present, the UI sounds over it
##    without jumping out (each at its measured level, UI_LEVEL);
##  * flight: the music fades out and pauses; the programme loudness the
##    player meets at the output (ITU-R BS.1770, K-weighted): the menu is
##    where the headset volume gets set, so the music sits at the loudness
##    of ordinary play and a glide at cruise (the wind alone: the quietest
##    ordinary flight) is within 8 LU under it (round 3 measured 11.6 LU:
##    pressing Play fell off a cliff);
##  * sfx_volume 0.5 is the documented 40 log10(0.5) = 12.04 dB quieter on
##    the mix (in flight, with the music and UI faders at 0);
##  * the pause menu, entered from flight (the usual way in): the music comes
##    back, gameplay (the SFX bus) is ducked 18 dB or more and muffled, a UI
##    sound plays and the UI bus is untouched.
## Gameplay's level is the SFX bus against the Wind bus recorded alongside
## (the wind's own gusts cancel), plus the SFX fader (the taps are before the
## faders). Under a pausable parent, as in the game: the pause pauses the
## tree, and a director that lost its PROCESS_MODE_ALWAYS would freeze there.
## (Until round 5 the pause had a test of its own with the music muted; its
## resume check is the state test's.)
func test_menu_music_and_the_pause_mix() -> void:
	# A director that starts in the menu (as at boot): the music at full.
	# Under a pausable parent, as in the game (the pause menu below pauses
	# the tree).
	await _stage_under_pausable_parent(Game.State.MENU)
	var cap := fx.tap(AudioBuses.MUSIC)
	var ui_cap := fx.tap(AudioBuses.UI)
	var sfx_cap := fx.tap(AudioBuses.SFX)
	var wind_cap := fx.tap(AudioBuses.WIND)
	var sfx_bus := AudioBuses.index(AudioBuses.SFX)
	var music: AudioStreamPlayer = fx.director.get_node("Music")
	await Fixture.wait(get_tree(), 0.1)
	near(music.volume_db, AudioDirector.MUSIC_GAIN_DB, 0.1, "menu: music at full level (with its make-up gain)")
	# The UI sounds, one per slot, over the music (both taps at once).
	const SLOT := 0.2
	var kinds: Array[StringName] = [&"click", &"select", &"back", &"open", &"confirm"]
	# Slot of each (the 0.31 s open gets two).
	var at_slot := [1, 2, 3, 4, 6]
	var driver := Timer.new()
	driver.wait_time = SLOT
	fx.root.add_child(driver)
	var k := [0]
	driver.timeout.connect(func() -> void:
		k[0] += 1
		var i := at_slot.find(k[0])
		if i >= 0:
			fx.director.play_ui(kinds[i]))
	fx.director.play_ui(&"hover")
	driver.start()
	var pair := await fx.record2(get_tree(), cap, ui_cap, SLOT * 7.0 + 0.1)
	driver.stop()
	driver.queue_free()
	var rate: float = pair[0]["rate"]
	# Levels at the output: the bus taps are before the faders.
	var master_db := AudioBuses.volume_to_db(AudioBuses.setting_value(AudioBuses.MASTER, fx.settings))
	var music_fader := AudioBuses.volume_to_db(AudioBuses.setting_value(AudioBuses.MUSIC, fx.settings))
	var ui_fader := AudioBuses.volume_to_db(AudioBuses.setting_value(AudioBuses.UI, fx.settings))
	var m_rms := AudioAnalysis.db(AudioAnalysis.rms(pair[0]["mono"])) + music_fader + master_db
	var m_aw: float = AudioAnalysis.loudness_aw(pair[0]["mono"], rate, 0.4)["mean"] + music_fader + master_db
	var m_lufs := AudioAnalysis.lufs(pair[0]["l"], pair[0]["r"], rate, music_fader + master_db)
	var ui_mono: PackedFloat32Array = pair[1]["mono"]
	var ui := {}
	var all_kinds: Array[StringName] = [&"hover"]
	all_kinds.append_array(kinds)
	# Each sound from its own onset on the (otherwise silent) UI bus: timer
	# ticks land a frame or two late, so fixed slots would cut sounds.
	var env := AudioAnalysis.envelope(ui_mono, rate, 0.005)
	var onsets: Array[int] = []
	var quiet := 4
	for i in env.size():
		if env[i] > 0.002:
			if quiet >= 4:
				onsets.append(i)
			quiet = 0
		else:
			quiet += 1
	eq(onsets.size(), all_kinds.size(), "each UI sound found on the UI bus (%d onsets)" % onsets.size())
	for i in mini(onsets.size(), all_kinds.size()):
		var from := maxi(0, int((onsets[i] - 1) * 0.005 * rate))
		var to := int((onsets[i + 1] - 1) * 0.005 * rate) if i + 1 < onsets.size() else ui_mono.size()
		var seg := ui_mono.slice(from, to)
		ui[all_kinds[i]] = {"aw": AudioAnalysis.loudness_aw(seg, rate, 0.1)["max"] + ui_fader + master_db,
			"peak": AudioAnalysis.db(AudioAnalysis.peak(seg))}
	if ui.size() < all_kinds.size():
		return
	metric("menu_music_out_rms_dbfs", m_rms)
	metric("menu_music_out_aw_db", m_aw)
	metric("menu_music_out_lufs", m_lufs)
	metric("ui_out_aw_db", ui)
	# Gentle but present: at the loudness of ordinary play near the ground
	# (perched in a wood with birds calling, flapping at cruise), well under
	# a dive. (Round 2 pinned -34..-24 dBFS RMS on this window, from round
	# 1's "very quiet" at -36; round 3 set the level by the programme
	# instead, 2 dB under round 2 and 1 dB over round 1: see AUDIO.md.)
	between(m_lufs, -32.0, -27.0, "menu music at the loudness of ordinary play (%.1f LUFS at the output)" % m_lufs)
	# Loudness integrated over 0.1 s (A-weighted) against the music's mean.
	for kind in [&"select", &"back", &"confirm", &"open"]:
		between(ui[kind]["aw"] - m_aw, 3.0, 12.0, "%s sits 3-12 dB over the music, to the ear (+%.1f)" % [kind, ui[kind]["aw"] - m_aw])
	for kind in [&"click", &"hover"]:
		gt(ui[kind]["aw"] - m_aw, -6.0, "%s, a 20-90 ms tick, integrates to within 6 dB of the music (%+.1f dB)" % [kind, ui[kind]["aw"] - m_aw])
	for kind in all_kinds:
		lt(ui[kind]["peak"], -2.9, "%s peaks under -3 dBFS on the UI bus (%.1f)" % [kind, ui[kind]["peak"]])
	# Flight, gliding at cruise: the music fades out and pauses. Meanwhile
	# the glide is measured at the output: the SFX bus (the wind; nothing
	# else sounds) through its fader and the master's, once the menu duck
	# has ramped out (20 dB at 60 dB/s) and the wind has settled.
	await Fixture.past_hitch(get_tree())  # (after the UI analysis)
	fx.set_tel({"airspeed": FlightSoundMap.cruise(fx.player.mass)})
	Game.set_state(Game.State.PLAYING)
	var t0 := Time.get_ticks_msec()
	# The Music and UI faders to 0 in flight: the output is then gameplay
	# alone, for the sfx_volume check below (the taps are before the faders,
	# so the music's own fade-out is still seen on its tap).
	fx.settings.set_value("music_volume", 0.0)
	fx.settings.set_value("ui_volume", 0.0)
	var master := fx.tap(AudioBuses.MASTER, 0)
	# When the music stops mixing, noted every frame (the recordings below
	# run on past it).
	var paused_at := [-1.0]
	var watch := func() -> void:
		if paused_at[0] < 0.0 and music.stream_paused:
			paused_at[0] = (Time.get_ticks_msec() - t0) / 1000.0
	get_tree().process_frame.connect(watch)
	await Fixture.wait(get_tree(), 0.45)
	var glide_rec := await fx.record_many(get_tree(), [sfx_cap, wind_cap, master], 0.9)
	var glide: Dictionary = glide_rec[0]
	var sfx_fader := AudioServer.get_bus_volume_db(sfx_bus)
	# Settings on the mix: sfx_volume 0.5 is the documented 40 log10(0.5) =
	# 12.04 dB quieter at the output (the master tap is before the limiter,
	# which does not act at these levels). (Analysed after the fade: a long
	# analysis frame would slow the fade down in wall time.)
	fx.settings.set_value("sfx_volume", 0.5)
	await wait_frames(2)
	var half := await fx.record2(get_tree(), wind_cap, master, 0.3)
	fx.settings.set_value("sfx_volume", 1.0)
	while paused_at[0] < 0.0 and Time.get_ticks_msec() - t0 < 3000:
		await get_tree().process_frame
	get_tree().process_frame.disconnect(watch)
	var fade_s: float = paused_at[0] if paused_at[0] >= 0.0 else 3.0
	metric("music_fade_out_s", fade_s)
	check(music.stream_paused, "silent music is paused (no mixing cost in flight)")
	# A linear 1.5 s fade (on a busy machine a frame's delta is clamped to
	# 0.1 s, so it can run a little long in wall time).
	between(fade_s, AudioDirector.MUSIC_FADE_OUT - 0.1, AudioDirector.MUSIC_FADE_OUT + 0.5, "the music fades out over about 1.5 s of flight (%.2f s)" % fade_s)
	var p_gain := sfx_fader + _gain_db([glide_rec[1], glide])
	var c_play := AudioAnalysis.centroid(AudioAnalysis.mean_power(glide["mono"], 2048, 1024, -60.0), rate)
	var drop := _gain_db([glide_rec[1], glide_rec[2]]) - _gain_db(half)
	metric("sfx_half_drop_db", drop)
	near(drop, 12.04, 0.3, "sfx_volume 0.5 measured 12 dB quieter on the mix (%.2f dB)" % drop)
	# (The mixer is a block or two behind the pause: let it drain.)
	await Fixture.wait(get_tree(), 0.05)
	var flight := await fx.record(get_tree(), cap, 0.1)
	var f := AudioAnalysis.db(AudioAnalysis.rms(flight["mono"]))
	metric("flight_db", f)
	lt(f, -90.0, "then the music is silent in flight")
	fx.settings.set_value("music_volume", AudioBuses.SETTING_DEFAULT["music_volume"])
	fx.settings.set_value("ui_volume", AudioBuses.SETTING_DEFAULT["ui_volume"])
	# The glide at the output, against the menu music.
	var g_lufs := AudioAnalysis.lufs(glide["l"], glide["r"], rate, sfx_fader + master_db)
	metric("glide_cruise_out_lufs", g_lufs)
	metric("menu_minus_glide_lu", m_lufs - g_lufs)
	between(m_lufs - g_lufs, 0.0, 8.0, "a glide at cruise sits within 8 LU under the menu music (%.1f vs %.1f LUFS)" % [g_lufs, m_lufs])
	Fixture.save_measure("programme_loudness", {"menu_lufs": m_lufs, "glide_cruise_lufs": g_lufs, "menu_rms_dbfs": m_rms})
	# Paused straight from flight: the music comes back, 3 dB under the menu
	# level (a linear fade: most of the way in 1.2 s, all of it by 2 s); the
	# gameplay duck (20 dB at 60 dB/s) has landed by the recording. Paused
	# from fast flight (1.8x cruise: a brighter wind, where a 900 Hz muffle
	# has something to take): the SFX bus against the Wind bus at the same
	# moment, so only the muffle tells them apart.
	fx.set_tel({"airspeed": FlightSoundMap.cruise(fx.player.mass) * 1.8})
	Game.set_state(Game.State.PAUSED)
	await Fixture.wait(get_tree(), 0.6)
	check(get_tree().paused, "(the game's pause pauses the tree)")
	fx.director.play_ui(&"select", 0.0)
	var in_pause := await fx.record_many(get_tree(), [cap, sfx_cap, wind_cap, ui_cap], 0.3)
	var p := AudioAnalysis.db(AudioAnalysis.rms(in_pause[0]["mono"]))
	metric("pause_from_flight_db", p)
	gt(p, -40.0, "music audible again in the pause menu entered from flight (%.1f dBFS)" % p)
	between(music.volume_db, AudioDirector.MUSIC_GAIN_DB - 12.0, AudioDirector.MUSIC_GAIN_DB - 3.0 + 0.1, "and on its way to 3 dB under the menu level (%.1f dB)" % music.volume_db)
	var q_gain := AudioServer.get_bus_volume_db(sfx_bus) + _gain_db([in_pause[2], in_pause[1]])
	var c_pause := AudioAnalysis.centroid(AudioAnalysis.mean_power(in_pause[1]["mono"], 2048, 1024, -60.0), rate)
	var c_wind := AudioAnalysis.centroid(AudioAnalysis.mean_power(in_pause[2]["mono"], 2048, 1024, -60.0), rate)
	metric("playing_gain_db", p_gain)
	metric("paused_gain_db", q_gain)
	metric("centroid_playing", c_play)
	metric("centroid_paused_vs_wind", [c_pause, c_wind])
	near(p_gain, 0.0, 0.5, "in flight the wind reaches the output unducked (%.2f dB)" % p_gain)
	gt(p_gain - q_gain, 18.0, "pause ducks gameplay sound by at least 18 dB (%.1f dB)" % (p_gain - q_gain))
	lt(c_pause, c_wind * 0.8, "and muffles it (spectral centroid %.0f Hz, the wind it carries %.0f Hz)" % [c_pause, c_wind])
	near(AudioServer.get_bus_volume_db(AudioBuses.index(AudioBuses.UI)), ui_fader, 0.01, "UI bus not ducked while paused")
	gt(AudioAnalysis.peak(in_pause[3]["mono"]), 0.05, "a UI sound plays while paused")
	Fixture.save_render(pair[0], "menu_music_excerpt")
	Fixture.save_render(glide, "pause_before")
	Fixture.save_render(in_pause[1], "pause_during")
	Fixture.save_measure("pause", {"playing_gain_db": p_gain, "paused_gain_db": q_gain, "centroid": [c_wind, c_pause], "sfx_half_drop_db": drop})


## Every volume key lands on its bus with the documented taper, read from
## the director's settings source: here the fixture's in-memory store, so
## the test changes neither the Settings autoload nor user://settings.cfg
## (round 4: suite runs used to reset a developer's volumes).
func test_settings_volumes_drive_the_buses() -> void:
	Game.set_state(Game.State.PLAYING)  # (built in play: no duck on SFX or Ambience)
	var cfg := "user://settings.cfg"
	var cfg_before := FileAccess.get_file_as_string(cfg) if FileAccess.file_exists(cfg) else "<none>"
	var real_before := {}
	for key in AudioBuses.SETTING_DEFAULT:
		real_before[key] = Settings.get_value(key, null)
	for key in ["master_volume", "music_volume", "sfx_volume", "ambience_volume", "ui_volume"]:
		var bus: StringName = AudioBuses.SETTING.find_key(key)
		for v in [1.0, 0.5, 0.25]:
			fx.settings.set_value(key, v)
			await wait_frames(1)
			var want := 40.0 * log(v) / log(10.0)
			near(AudioServer.get_bus_volume_db(AudioBuses.index(bus)), want, 0.05, "%s %.2f -> %s bus %.1f dB" % [key, v, bus, want])
		fx.settings.set_value(key, 0.0)
		await wait_frames(1)
		check(AudioServer.is_bus_mute(AudioBuses.index(bus)), "%s 0 mutes the %s bus" % [key, bus])
		fx.settings.set_value(key, 1.0)
	# (Measured on the mix too: test_pause_ducks_and_muffles_gameplay_...
	# checks sfx_volume 0.5 is 12.04 dB quieter at the master.)
	for key in AudioBuses.SETTING_DEFAULT:
		eq(Settings.get_value(key, null), real_before[key], "the Settings autoload's %s is untouched" % key)
	var cfg_after := FileAccess.get_file_as_string(cfg) if FileAccess.file_exists(cfg) else "<none>"
	check(cfg_after == cfg_before, "user://settings.cfg is not rewritten by the test")


# ------------------------------------------------------------- events ---

## Peak (dBFS) of the first `seconds` of a clip played at `pitch`.
static func _clip_peak_db(st: AudioStream, seconds: float, pitch: float) -> float:
	var d := AudioAnalysis.decode_wav(st as AudioStreamWAV)
	var mono: PackedFloat32Array = d["mono"]
	return AudioAnalysis.db(AudioAnalysis.peak(mono.slice(0, int(seconds * pitch * float(d["rate"])))))


## Waits until the tap has captured `frames` consecutive frames of silence
## (below -80 dBFS; 1024 frames are two mix blocks, and every clip's noise
## floor sits well above that): the mixer runs a block or two ahead of the
## main thread,
## so a stop() takes effect only in blocks mixed after it, and a headless
## frame is shorter than a block. Returns false if that never happens
## within `timeout` s. The buffer is left empty at the silent point.
func _drain(cap: AudioEffectCapture, frames: int = 1024, timeout: float = 0.6) -> bool:
	cap.clear_buffer()
	var run := 0
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(timeout * 1000.0):
		await get_tree().process_frame
		var n := cap.get_frames_available()
		if n <= 0:
			continue
		for f in cap.get_buffer(n):
			if absf(f.x) < 1e-4 and absf(f.y) < 1e-4:
				run += 1
			else:
				run = 0
		if run >= frames:
			return true
	return false


## Every Events cue plays, alone in its window on the SFX bus, at the level
## AudioDirector.LEVEL gives it (clip peak + level, within 2 dB); the
## signal alone is not enough (it fires even if the stream is missing).
## Each window is the cue itself: the bus is first drained to silence
## (round 4: stop() plus two short headless frames left the previous cue's
## tail in the window, and the caught stinger's tail passed for a missing
## fanfare). Two catches in one frame (two prey in one sweep) measure
## +3.5 dB over one, the sum of a full crunch and one 6 dB down
## (CUE_STACK_DB), not +6 dB: the director's rng is reseeded before each
## catch so every crunch is the same clip at the same pitch.
func test_event_cues() -> void:
	Game.set_state(Game.State.PLAYING)
	var cues: Array = []
	fx.director.cue.connect(func(n: StringName, _i: Dictionary) -> void: cues.append(n))
	# No NPC call may land in a window (the prey sits 1 m away).
	fx.director.voices.scheduling = false
	var prey := fx.add_npc(&"wren", Vector3(0, 100, -1))
	var cap := fx.tap(AudioBuses.SFX)
	var oneshots: AudioStreamPlayer = fx.director.get_node("OneShots")
	var bank := fx.director.bank
	const WIN := 0.2
	const SEED := 4242
	var crunch_pitch := clampf(pow(0.03 / prey.mass, 0.1), 0.8, 1.3)
	var catch_lo := INF
	var catch_hi := -INF
	for v in AudioBank.CRUNCH_VARIANTS:
		var e := maxf(_clip_peak_db(bank.get_stream(StringName("crunch_%d" % v)), WIN, crunch_pitch) + AudioDirector.LEVEL["crunch"],
			_clip_peak_db(bank.get_stream(StringName("puff_%d" % v)), WIN, crunch_pitch) + AudioDirector.LEVEL["puff"])
		catch_lo = minf(catch_lo, e)
		catch_hi = maxf(catch_hi, e)
	var bump_db: float = AudioDirector.LEVEL["bump_min"] + (AudioDirector.LEVEL["bump_max"] - AudioDirector.LEVEL["bump_min"]) * 6.0 / 8.0
	var catch_once := func() -> void:
		fx.director._rng.seed = SEED
		Events.bird_caught.emit(fx.player, prey)
	# (The mixer runs on its own thread: locked, so no mix block can fall
	# between the two and start them apart.)
	var catch_twice := func() -> void:
		AudioServer.lock()
		catch_once.call()
		catch_once.call()
		AudioServer.unlock()
	# [cue, fire, expected peak range (dBFS)] (the stack step is judged
	# against the single catch below, not on its own).
	var plan := [
		[&"catch", catch_once, catch_lo, catch_hi + 3.0],
		[&"bump", func() -> void: Events.player_collided.emit(6.0, Vector3.UP), _clip_peak_db(bank.get_stream(&"bump"), WIN, 1.0) + bump_db, NAN],
		[&"brush", func() -> void: Events.player_collided.emit(0.0, Vector3.UP), _clip_peak_db(bank.get_stream(&"brush"), WIN, 1.0) + AudioDirector.LEVEL["brush"], NAN],
		[&"perch", func() -> void: Events.player_perched.emit(Vector3.ZERO), _clip_peak_db(bank.get_stream(&"brush"), WIN, 1.1) + AudioDirector.LEVEL["perch"], NAN],
		[&"catch", catch_twice, -INF, INF],
		[&"caught", func() -> void: Events.player_caught.emit(prey), _clip_peak_db(bank.get_stream(&"caught"), WIN, 1.0) + AudioDirector.LEVEL["caught"], NAN],
		[&"fanfare", func() -> void: Events.player_tier_changed.emit(3, 4), _clip_peak_db(bank.get_stream(&"fanfare"), WIN, 1.0) + AudioDirector.LEVEL["fanfare"], NAN],
	]
	var got := {}
	var peaks := []
	for i in plan.size():
		var step: Array = plan[i]
		var label := "catch_x2" if i == 4 else String(step[0])
		oneshots.stop()  # each cue alone in its window
		var quiet: bool = await _drain(cap)
		check(quiet, "%s: the SFX bus is silent before the cue (no tail of the one before)" % label)
		cues.clear()
		(step[1] as Callable).call()
		var rec := await fx.record(get_tree(), cap, WIN)
		var pk := AudioAnalysis.db(maxf(AudioAnalysis.peak(rec["l"]), AudioAnalysis.peak(rec["r"])))
		peaks.append(pk)
		var lo: float = step[2]
		var hi: float = step[3] if not is_nan(step[3]) else lo
		got[label] = [pk, lo, hi]
		check(step[0] in cues, "%s: the cue fires" % label)
		if is_finite(lo):
			between(pk, lo - 2.0, hi + 2.0, "%s: heard on the mix at its designed level (peak %.1f dBFS, want %.1f..%.1f)" % [label, pk, lo, hi])
	# Two catches in one frame: a full crunch plus one 6 dB down is
	# 20 log10(1.5) = +3.5 dB over one (the same clip, sample-aligned); two
	# at full level would be +6.
	var stack: float = peaks[4] - peaks[0]
	metric("two_catches_in_one_frame_db", stack)
	between(stack, 2.5, 4.5, "two catches in one frame peak +3.5 dB over one (the second 6 dB down), not +6 (%+.2f dB)" % stack)
	metric("cue_peaks_dbfs", got)
	cues.clear()
	Events.player_tier_changed.emit(4, 3)
	check(not (&"fanfare" in cues), "losing a tier is not celebrated")
	# NPC-on-NPC catch in earshot: a 3D crunch through the voice pool.
	var hawk := fx.add_npc(&"hawk", Vector3(5, 100, 0))
	var fx_before: int = fx.director.voices.stats["fx"]
	Events.bird_caught.emit(hawk, prey)
	eq(fx.director.voices.stats["fx"], fx_before + 1, "an NPC catch nearby is heard in 3D")


## A-weighted power per STFT frame (1024 points, hop 512), RMS-referenced.
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


## One take of a cue over the wind: `fire` is called 0.22 s into a 0.62 s
## recording of the SFX and Wind buses, analysed in 23 ms A-weighted STFT
## frames (hop 11.6 ms). Returns {} when the cue is not heard, else:
##  before   the wind before the cue (every frame before the onset's and
##           before the cue was fired), dB A;
##  during   the wind under the duck, 0.2 s from two hops after the onset
##           (the cue's first frame straddles its onset and the duck, so
##           the window starts where every frame is post-duck);
##  cue_aw, wind_aw, clear: the loudest 0.2 s of (SFX - Wind) from there on,
##           the wind in that same window, and the difference;
##  calls_before / calls_at, amb_before / amb_at: the Calls and Ambience
##           faders just before the cue and as its signal is emitted (once
##           its duck is in place).
func _cue_take(sfx: AudioEffectCapture, wind: AudioEffectCapture, cue_name: StringName, fire: Callable) -> Dictionary:
	var calls := AudioBuses.index(AudioBuses.CALLS)
	var amb := AudioBuses.index(AudioBuses.AMBIENCE)
	var buses := {}
	var on_cue := func(n: StringName, _i: Dictionary) -> void:
		if n == cue_name and not buses.has("calls_at"):
			buses["calls_at"] = AudioServer.get_bus_volume_db(calls)
			buses["amb_at"] = AudioServer.get_bus_volume_db(amb)
	fx.director.cue.connect(on_cue)
	get_tree().create_timer(0.22, true, false, true).timeout.connect(func() -> void:
		buses["calls_before"] = AudioServer.get_bus_volume_db(calls)
		buses["amb_before"] = AudioServer.get_bus_volume_db(amb)
		fire.call())
	var pair := await fx.record2(get_tree(), sfx, wind, 0.62)
	fx.director.cue.disconnect(on_cue)
	var rate: float = pair[0]["rate"]
	var hop := 512.0 / rate
	var fs := _aw_frames(pair[0]["mono"], rate)
	var fw := _aw_frames(pair[1]["mono"], rate)
	# The cue's onset: where the SFX bus first rises well over the wind.
	var onset := -1
	for k in mini(fs.size(), fw.size()):
		if fs[k] - fw[k] > 4.0 * fw[k]:
			onset = k
			break
	if onset <= 0:
		return {}
	var per := int(round(0.2 / hop))
	# The wind before: every frame before the onset's and before the cue
	# was fired (0.22 s in; frames up to 0.2 s). A cue whose first sound is
	# low (the stinger's boom, which A-weighting discounts) is detected a
	# few frames late, and those frames are already ducked.
	var before := 0.0
	var n_before := mini(onset - 1, int(0.2 / hop))
	for k in n_before:
		before += fw[k]
	before = _pdb(before / maxf(1.0, n_before))
	var during := 0.0
	for k in range(onset + 2, onset + 2 + per):
		during += fw[k]
	during = _pdb(during / per)
	var best := 0.0
	var wind_then := 1e-30
	for k in range(onset + 2, mini(fs.size(), fw.size()) - per):
		var sc := 0.0
		var sw := 0.0
		for j in per:
			sc += maxf(0.0, fs[k + j] - fw[k + j])
			sw += fw[k + j]
		if sc > best:
			best = sc
			wind_then = sw
	var out := {"before": before, "during": during, "cue_aw": _pdb(best / per), "wind_aw": _pdb(wind_then / per),
		"clear": _pdb(best / per) - _pdb(wind_then / per), "rate": rate}
	out.merge(buses)
	return out


## Reward and failure cues cut through the wind, the loudest continuous
## sound, by ducking it (and the rest of the world) at once, never by
## getting louder than the mix can hold:
##  * the catch: 5 dB in ordinary flight, deeper in a fast dive
##    (FlightSoundMap.catch_duck_db; round 3: a tucked dive left the crunch
##    1-3 dB over a 5 dB-ducked wind). At 1.2x cruise and in a tucked 2.6x
##    dive the wind drops by the designed depth (within 1.5 dB), the crunch
##    and puff stand >= 6 dB A over the wind in the same 0.2 s (designed
##    11), and the wind comes back once the crunch is over;
##  * the caught stinger and the tier-up fanfare, in a tucked 2.6x dive (the
##    worst case: at cruise both clear the wind by 30 dB): each ducks the
##    wind by its design, literal here (caught 10 dB, fanfare 6 dB, within
##    1.5) and stands >= 6 dB A over it. Round 4: nothing pinned them
##    against an absolute bar (the stinger at -40 dB, or no caught duck,
##    passed the suite). A fresh director for the fanfare: the caught duck
##    lasts 2.5 s;
##  * the Calls and Ambience buses drop by the same duck at every cue's
##    onset (and come back after the catch);
##  * the calls' dive duck: the Calls bus is 6 dB down at 2.6x, untouched at
##    1.2x.
func test_reward_and_failure_cues_cut_through_the_wind() -> void:
	Game.set_state(Game.State.PLAYING)
	var sfx := fx.tap(AudioBuses.SFX)
	var wind := fx.tap(AudioBuses.WIND)
	var cruise := FlightSoundMap.cruise(fx.player.mass)
	var calls := AudioBuses.index(AudioBuses.CALLS)
	var amb := AudioBuses.index(AudioBuses.AMBIENCE)
	var out := {}
	for c in [["1.2x", 1.2, false], ["2.6x_tucked", 2.6, true]]:
		await Fixture.past_hitch(get_tree())  # (after the last take's analysis)
		fx.set_tel({"airspeed": cruise * c[1], "tucked": c[2], "wing_extension": 0.1 if c[2] else 1.0})
		# (The wind's attack is 0.06 s and its filters' 0.08 s; the take
		# listens to 0.22 s more of it before the catch.)
		await Fixture.wait(get_tree(), 0.25)
		# The prey is out of earshot: it must not call during the take.
		var prey := fx.add_npc(&"wren", Vector3(5000, 100, 0))
		var want: float = FlightSoundMap.catch_duck_db(fx.director.flight_params()["body_db"])
		var r := await _cue_take(sfx, wind, &"catch", func() -> void: Events.bird_caught.emit(fx.player, prey))
		check(not r.is_empty(), "%s: the catch is heard on the SFX bus" % c[0])
		if r.is_empty():
			continue
		out[c[0]] = {"designed_duck_db": want, "wind_before_db": r["before"], "wind_during_db": r["during"], "crunch_aw_db": r["cue_aw"],
			"wind_aw_db": r["wind_aw"], "crunch_over_wind_db": r["clear"], "calls_bus_db": AudioServer.get_bus_volume_db(calls), "buses_at_catch": r.duplicate()}
		near(float(r.get("calls_at", 0.0)) - float(r.get("calls_before", 0.0)), want, 0.1,
			"%s: the calls step back with the flight layers at the catch's onset" % c[0])
		near(float(r.get("amb_at", 0.0)) - float(r.get("amb_before", 0.0)), want, 0.1,
			"%s: and so does the ambience" % c[0])
		near(r["during"] - r["before"], want, 1.5, "%s: a catch ducks the wind %.1f dB at once, to the ear (%.1f)" % [c[0], want, r["during"] - r["before"]])
		gt(r["clear"], 6.0, "%s: the crunch stands clear of the wind it lands in, to the ear (%+.1f dB A)" % [c[0], r["clear"]])
		if c[0] == "1.2x":
			near(float(r["calls_before"]), FlightSoundMap.calls_duck_db(1.2), 0.05, "1.2x: no dive duck on the calls")
		if c[0] == "2.6x_tucked":
			lt(want, -10.0, "in a tucked 2.6x dive the duck is deeper than the 5 dB of ordinary flight (%.1f)" % want)
		fx.npcs.erase(prey)
		prey.queue_free()
	# The caught stinger, in the same tucked dive once the catch duck is
	# over (0.35 s and its release: the take starts 0.65 s after the catch,
	# so its 0.22 s before the stinger is also where the wind, the calls and
	# the ambience must be back), then the fanfare under a fresh director.
	for c in [[&"caught", -10.0], [&"fanfare", -6.0]]:
		if c[0] == &"caught":
			# (Past the analysis frame first: a timer counts that frame's
			# whole delta, the director only 0.1 s of it.)
			await Fixture.past_hitch(get_tree())
			await Fixture.wait(get_tree(), 0.25)
		if c[0] == &"fanfare":
			fx.teardown()
			Game.set_state(Game.State.PLAYING)
			fx = Fixture.new()
			fx.build(self)
			await wait_frames(2)
			sfx = fx.tap(AudioBuses.SFX)
			wind = fx.tap(AudioBuses.WIND)
			fx.set_tel({"airspeed": cruise * 2.6, "tucked": true, "wing_extension": 0.1})
			# (The wind's attack is 0.06 s and its filter's 0.08 s; the take
			# listens to 0.22 s more of it before the cue.)
			await Fixture.wait(get_tree(), 0.25)
		await Fixture.past_hitch(get_tree())
		var fire := func() -> void: Events.player_caught.emit(null)
		if c[0] == &"fanfare":
			fire = func() -> void: Events.player_tier_changed.emit(3, 4)
		var r := await _cue_take(sfx, wind, c[0], fire)
		check(not r.is_empty(), "%s: heard on the SFX bus in a tucked 2.6x dive" % c[0])
		if r.is_empty():
			continue
		var duck: float = c[1]
		out[String(c[0])] = {"wind_before_db": r["before"], "wind_during_db": r["during"], "cue_aw_db": r["cue_aw"],
			"wind_aw_db": r["wind_aw"], "cue_over_wind_db": r["clear"], "buses": r.duplicate()}
		near(r["during"] - r["before"], duck, 1.5, "%s: ducks the dive wind %.0f dB at once (%.1f)" % [c[0], duck, r["during"] - r["before"]])
		gt(r["clear"], 6.0, "%s: stands clear of the dive wind it lands in, to the ear (%+.1f dB A)" % [c[0], r["clear"]])
		near(float(r.get("calls_at", 0.0)) - float(r.get("calls_before", 0.0)), duck, 0.1, "%s: the calls step back by the same duck" % c[0])
		near(float(r.get("amb_at", 0.0)) - float(r.get("amb_before", 0.0)), duck, 0.1, "%s: and so does the ambience" % c[0])
		if c[0] == &"caught" and out.has("2.6x_tucked"):
			var dive: Dictionary = out["2.6x_tucked"]
			var before_catch: Dictionary = dive["buses_at_catch"]
			dive["wind_after_db"] = r["before"]
			near(r["before"], float(dive["wind_before_db"]), 1.0, "after the catch in the dive the wind comes back (%.1f -> %.1f dB A)" % [dive["wind_before_db"], r["before"]])
			near(float(r["amb_before"]), float(before_catch["amb_before"]), 0.05, "the ambience comes back too")
			# Literal: the calls dip about 6 dB in a full dive (the design's
			# CALLS_DUCK_MAX_DB, not read from the code under test).
			between(float(r["calls_before"]), -6.5, -5.0, "and the calls come back, to their dive duck of about 6 dB (%.1f dB)" % r["calls_before"])
	metric("cues_over_wind", out)
	Fixture.save_measure("catch_over_wind", out)


## Every game state lands on its own STATE_MIX: the SFX and Ambience ducks
## and the pause muffle, and the UI bus is never touched. Includes the
## transitions that keep the SFX duck but change the ambience (PLAYING <->
## CAUGHT, MENU <-> PAUSED). Flying fast all along: the flight speed ducks
## of the ambience and the calls hold only in play (paused or in a menu the
## state mix alone rules), and no new call starts outside play: a bird
## whose call is due stays silent while paused and calls once play resumes.
func test_every_state_lands_on_its_mix() -> void:
	var cruise := FlightSoundMap.cruise(fx.player.mass)
	fx.set_tel({"airspeed": cruise * 2.0})
	var voices := fx.director.voices
	var caller := fx.add_npc(&"sparrow", Vector3(0, 100, -5))
	var sfx := AudioBuses.index(AudioBuses.SFX)
	var amb := AudioBuses.index(AudioBuses.AMBIENCE)
	var ui := AudioBuses.index(AudioBuses.UI)
	var sfx_base := AudioBuses.volume_to_db(AudioBuses.setting_value(AudioBuses.SFX, fx.settings))
	var amb_base := AudioBuses.volume_to_db(AudioBuses.setting_value(AudioBuses.AMBIENCE, fx.settings))
	var ui_base := AudioBuses.volume_to_db(AudioBuses.setting_value(AudioBuses.UI, fx.settings))
	var got := {}
	var prev: Dictionary = AudioDirector.STATE_MIX[Game.state]
	for st in [Game.State.PLAYING, Game.State.CAUGHT, Game.State.PLAYING, Game.State.PAUSED, Game.State.MENU,
			Game.State.PAUSED, Game.State.ENDED, Game.State.PLAYING]:
		Game.set_state(st)
		# The caller's call is due now (in play the scheduler visits it
		# within a frame or two).
		voices.stop_all()
		voices._next[caller.get_instance_id()] = 0.0
		var started: int = voices.stats["started"]
		var mix: Dictionary = AudioDirector.STATE_MIX[st]
		# The ducks ramp at DUCK_DB_PER_S (20 dB in a third of a second).
		var move := maxf(absf(mix["sfx"] - prev["sfx"]), absf(mix["amb"] - prev["amb"]))
		await Fixture.wait(get_tree(), move / AudioDirector.DUCK_DB_PER_S + 0.06)
		prev = mix
		var nm := Game.state_name(st)
		var have := [AudioServer.get_bus_volume_db(sfx) - sfx_base, AudioServer.get_bus_volume_db(amb) - amb_base]
		got["%d_%s" % [got.size(), nm]] = have
		near(have[0], mix["sfx"], 0.05, "%s: SFX duck" % nm)
		near(have[1], mix["amb"], 0.05, "%s: Ambience duck" % nm)
		near(AudioServer.get_bus_volume_db(ui), ui_base, 0.01, "%s: UI bus untouched" % nm)
		var mi := AudioBuses.effect_index(AudioBuses.SFX, "AudioEffectLowPassFilter")
		eq(AudioServer.is_bus_effect_enabled(sfx, mi), mix["muffle"], "%s: muffle %s" % [nm, "on" if mix["muffle"] else "off"])
		var play: bool = st == Game.State.PLAYING or st == Game.State.CAUGHT
		near(fx.director.ambience.duck_target_db, FlightSoundMap.ambience_duck_db(2.0) if play else 0.0, 0.01,
			"%s: the ambience speed duck %s" % [nm, "holds in play" if play else "is released"])
		near(voices.speed_duck_target_db, FlightSoundMap.calls_duck_db(2.0) if play else 0.0, 0.01,
			"%s: the calls speed duck %s" % [nm, "holds in play" if play else "is released"])
		eq(fx.director.ambience.scheduling, play, "%s: the bell may start a toll only in play" % nm)
		if play:
			gt(voices.stats["started"] - started, 0.0, "%s: the bird whose call was due calls" % nm)
		else:
			eq(voices.stats["started"] - started, 0, "%s: no new call starts" % nm)
	metric("ducks_db", got)


# ----------------------------------------------------------- ambience ---

func test_ambience_zones_follow_landmarks_and_altitude() -> void:
	var marks: Array[Dictionary] = [
		{"name": "wood", "kind": "forest", "position": Vector3(0, 0, 0), "radius": 100.0},
		{"name": "lake", "kind": "lake", "position": Vector3(400, 0, 0), "radius": 100.0},
		{"name": "village", "kind": "town", "position": Vector3(0, 0, 400), "radius": 120.0},
		{"name": "church_spire", "kind": "landmark", "position": Vector3(10, 20, 400), "radius": 4.0},
		{"name": "meadow", "kind": "meadow", "position": Vector3(-400, 0, 0), "radius": 150.0},
	]
	fx.add_world(marks)
	await wait_frames(2)
	var amb := fx.director.ambience
	amb.set_world(fx.world)
	var at := func(p: Vector3, agl: float) -> Dictionary: return amb.compute_weights(p, agl)
	var forest: Dictionary = at.call(Vector3(0, 3, 0), 3.0)
	var lake: Dictionary = at.call(Vector3(400, 2, 0), 2.0)
	var town: Dictionary = at.call(Vector3(0, 5, 400), 5.0)
	var meadow: Dictionary = at.call(Vector3(-400, 2, 0), 2.0)
	var high: Dictionary = at.call(Vector3(0, 150, 0), 150.0)
	var nowhere: Dictionary = at.call(Vector3(-200, 2, -500), 2.0)
	near(forest[&"trees"], 1.0, 0.01, "in the forest: trees bed full")
	lt(forest[&"water"] + forest[&"village"], 0.01, "in the forest: no water or village")
	near(lake[&"water"], 1.0, 0.01, "at the lake: water bed full")
	near(town[&"village"], 1.0, 0.01, "in the village: village bed full")
	near(meadow[&"meadow"], 1.0, 0.01, "in the meadow: meadow bed full")
	var hsum := 0.0
	for z in high:
		hsum += high[z]
	lt(hsum, 0.01, "150 m up: every bed has faded out (only wind)")
	near(nowhere[&"open"], AmbienceZones.FLOOR_WEIGHT, 0.01, "open country: the quiet open-air floor")
	lt(nowhere[&"meadow"], 0.01, "open country: no crickets away from meadows")
	# Crossfade is monotonic walking out of the forest towards the lake.
	var prev_t := 2.0
	var prev_w := -1.0
	var mono := true
	for i in 21:
		var p := Vector3(20.0 * i, 3, 0)
		var w: Dictionary = at.call(p, 3.0)
		if w[&"trees"] > prev_t + 1e-6 or w[&"water"] < prev_w - 1e-6:
			mono = false
		prev_t = w[&"trees"]
		prev_w = w[&"water"]
	check(mono, "forest -> lake: trees fades out and water fades in monotonically")
	# Up to 12 m above the ground every bed is at full weight (low flight is
	# where the zones are heard).
	var forest12: Dictionary = at.call(Vector3(0, 12, 0), 12.0)
	near(forest12[&"trees"], 1.0, 0.01, "12 m up in the forest: trees bed still full")
	# The beds follow in the mixer: park the listener (still, airspeed 0) in
	# the forest. The crossfade has a 1.2 s time constant and the zone
	# targets update 4 times a second: 0.7 s in, the bed has come 31-44% of
	# its gain up (-10 to -7 dB): neither a jump nor stuck.
	fx.set_tel({"airspeed": 0.0, "perched": true})
	fx.listener.global_position = Vector3(0, 3, 0)
	await Fixture.wait(get_tree(), 0.7)
	var bed: AudioStreamPlayer = amb.get_node("Bed_amb_leaves")
	var water_bed: AudioStreamPlayer = amb.get_node("Bed_amb_water")
	var full: float = AmbienceZones.BEDS[&"trees"][0][1]
	check(bed.playing and not bed.stream_paused, "the leaves bed is playing in the forest")
	between(bed.volume_db, full - 11.0, full - 6.0, "leaves bed crossfading up on its 1.2 s time constant (%.1f dB, full %.1f)" % [bed.volume_db, full])
	check(water_bed.stream_paused or not water_bed.playing or water_bed.volume_db < -60.0, "the water bed is silent in the forest")
	amb.settle(fx.listener.global_position)
	near(bed.volume_db, full, 0.05, "and lands on it (settled, no speed duck at rest)")


## Per-ear mean power spectrum of a stereo recording or clip (each ear hears
## its own channel: a mono sum would under-count decorrelated beds). At most
## `frames` frames per channel, spread evenly over the buffer (a long loop's
## mean needs its whole length, not every frame of it).
static func _ear_power(d: Dictionary, n: int = 2048, frames: int = 32) -> PackedFloat32Array:
	var l: PackedFloat32Array = d["l"]
	var hop := maxi(n, l.size() / frames)
	var pl := AudioAnalysis.mean_power(l, n, hop, -90.0)
	if d["r"] == l:
		return pl  # mono
	var pr := AudioAnalysis.mean_power(d["r"], n, hop, -90.0)
	for i in pl.size():
		pl[i] = 0.5 * (pl[i] + pr[i])
	return pl


const OCTAVES: Array[float] = [125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0]


## `secs` of a looping clip {l, r, rate} from `from_s`, wrapping at its end.
static func _loop_segment(d: Dictionary, from_s: float, secs: float) -> Dictionary:
	var out := {"rate": d["rate"]}
	for ch in ["l", "r"]:
		var src: PackedFloat32Array = d[ch]
		var n := int(secs * float(d["rate"]))
		var o := PackedFloat32Array()
		o.resize(n)
		var at := int(from_s * float(d["rate"]))
		for i in n:
			o[i] = src[(at + i) % src.size()]
		out[ch] = o
	return out


static func _octaves(p: PackedFloat32Array, rate: float, gain_db: float = 0.0) -> PackedFloat32Array:
	var o := PackedFloat32Array()
	for fc in OCTAVES:
		o.append(AudioAnalysis.band_db(p, rate, fc / sqrt(2.0), fc * sqrt(2.0)) + gain_db)
	return o


static func _pow_sum_db(a: float, b: float) -> float:
	return 10.0 * log(pow(10.0, a / 10.0) + pow(10.0, b / 10.0)) / log(10.0)


## The wind is the main speed cue: flying low at cruise, it must stand above
## the ambience in every zone, both to the ear (A-weighted) and in each
## octave band where the wind carries its sound (within 6 dB of its loudest
## band, A-weighted: 250 Hz-2 kHz for a sparrow, 250 Hz-1 kHz for the darker
## eagle wind), or the bed masks it. The wind is measured on the mixer at
## cruise; each bed is its whole loop's per-ear spectrum at the gain the
## director actually gives it there (read from its player, speed duck
## included); one zone's Ambience bus is recorded too, to prove the chain.
func test_wind_stands_above_the_ambience_at_cruise() -> void:
	Game.set_state(Game.State.PLAYING)
	var marks: Array[Dictionary] = [
		{"name": "wood", "kind": "forest", "position": Vector3(0, 0, 0), "radius": 150.0},
		{"name": "lake", "kind": "lake", "position": Vector3(1000, 0, 0), "radius": 150.0},
		{"name": "village", "kind": "town", "position": Vector3(0, 0, 1000), "radius": 150.0},
		{"name": "meadow", "kind": "meadow", "position": Vector3(-1000, 0, 0), "radius": 150.0},
		{"name": "cliffs", "kind": "canyon", "position": Vector3(0, 0, -1000), "radius": 150.0},
	]
	fx.add_world(marks)
	var amb := fx.director.ambience
	amb.set_world(fx.world)
	var bank := fx.director.bank
	# Each bed's whole loop, per ear (a 1.5 s window would measure a gust),
	# on the worker pool.
	var keys: Array[StringName] = []
	for z in AmbienceZones.BEDS:
		for spec in AmbienceZones.BEDS[z]:
			keys.append(spec[0])
	var got := []
	got.resize(keys.size())
	var mutex := Mutex.new()
	var task := WorkerThreadPool.add_group_task(func(i: int) -> void:
		var d := AudioAnalysis.clip_pcm(bank.get_stream(keys[i]))
		var p := _ear_power(d, 1024, 48)
		var r := {"a": AudioAnalysis.a_level_db(p, d["rate"]), "oct": _octaves(p, d["rate"])}
		mutex.lock()
		got[i] = r
		mutex.unlock(), keys.size(), -1, true, "audio bed spectra")
	WorkerThreadPool.wait_for_group_task_completion(task)
	var bed_spec := {}
	for i in keys.size():
		bed_spec[keys[i]] = got[i]
	var wind := fx.tap(AudioBuses.WIND)
	var amb_cap := fx.tap(AudioBuses.AMBIENCE)
	var res := {}
	var worst_a := INF
	var worst_band := INF
	for size in [[&"sparrow", 0.03], [&"eagle", 3.0]]:
		fx.player.mass = size[1]
		var cruise := FlightSoundMap.cruise(size[1])
		fx.set_tel({"airspeed": cruise, "tucked": false, "wing_extension": 1.0})
		var lake := Vector3(1000, 4, 0)
		fx.listener.global_position = lake
		fx.player.global_position = lake
		await Fixture.wait(get_tree(), 0.2)
		amb.settle(lake)
		var water: AudioStreamPlayer = amb.get_node("Bed_amb_water")
		var water_at := water.get_playback_position()
		var pair := await fx.record2(get_tree(), wind, amb_cap, 0.45)
		var rate: float = pair[0]["rate"]
		var pw := _ear_power(pair[0])
		var w_a := AudioAnalysis.a_level_db(pw, rate)
		var w_oct := _octaves(pw, rate)
		# The wind's own bands: A-weighted band level within 6 dB of its top.
		var aw := PackedFloat32Array([-16.1, -8.6, -3.2, 0.0, 1.2, 1.0])
		var top := -INF
		for i in OCTAVES.size():
			top = maxf(top, w_oct[i] + aw[i])
		var own: Array[int] = []
		for i in OCTAVES.size():
			if OCTAVES[i] >= 250.0 and w_oct[i] + aw[i] >= top - 6.0:
				own.append(i)
		if size[0] == &"sparrow":
			# The chain: the lake bed as recorded on the Ambience bus matches
			# the same stretch of its clip at the gain its player has (so the
			# spectra and gains the zones are judged on below are what plays).
			var clip := AudioAnalysis.clip_pcm(water.stream)
			var seg := _loop_segment(clip, water_at, 0.45)
			var want := AudioAnalysis.a_level_db(_ear_power(seg), clip["rate"]) + water.volume_db
			var got_a := AudioAnalysis.a_level_db(_ear_power(pair[1]), rate)
			metric("lake_bed_chain_db", [got_a, want])
			near(got_a, want, 1.5, "the lake bed on the mixer matches its clip at the gain the director gives it")
		var row := {"wind_a": w_a, "own_bands_hz": own.map(func(i: int) -> float: return OCTAVES[i]), "wind_oct": Array(w_oct),
			"octaves_hz": Array(OCTAVES)}
		for zone in [["forest", Vector3(0, 4, 0), &"trees"], ["lake", lake, &"water"], ["village", Vector3(0, 4, 1000), &"village"],
				["meadow", Vector3(-1000, 4, 0), &"meadow"], ["cliffs", Vector3(0, 4, -1000), &"open"]]:
			fx.listener.global_position = zone[1]
			fx.player.global_position = zone[1]
			amb.settle(zone[1])
			# Sum of this spot's playing beds at the gains the director set.
			var b_a := -INF
			var b_oct := PackedFloat32Array([-INF, -INF, -INF, -INF, -INF, -INF])
			for z2 in AmbienceZones.BEDS:
				for spec in AmbienceZones.BEDS[z2]:
					var pl: AudioStreamPlayer = amb.get_node("Bed_" + String(spec[0]))
					if not pl.playing or pl.stream_paused or pl.volume_db < -70.0:
						continue
					b_a = _pow_sum_db(b_a, float(bed_spec[spec[0]]["a"]) + pl.volume_db)
					var o: PackedFloat32Array = bed_spec[spec[0]]["oct"]
					for i in OCTAVES.size():
						b_oct[i] = _pow_sum_db(b_oct[i], o[i] + pl.volume_db)
			var margin_a := w_a - b_a
			var band_margin := INF
			var margins := {}
			for i in own:
				margins["%d" % int(OCTAVES[i])] = snappedf(w_oct[i] - b_oct[i], 0.1)
				band_margin = minf(band_margin, w_oct[i] - b_oct[i])
			row[zone[0]] = {"bed_a": b_a, "margin_a": margin_a, "band_margins": margins, "duck_db": amb.duck_db, "bed_oct": Array(b_oct)}
			worst_a = minf(worst_a, margin_a)
			worst_band = minf(worst_band, band_margin)
			gt(margin_a, 6.0, "%s at cruise, 4 m up in the %s: the wind %.1f dB over the bed to the ear (A-weighted)" % [size[0], zone[0], margin_a])
			gt(band_margin, 2.0, "%s at cruise in the %s: the wind over the bed in each of its bands %s (worst %.1f dB)" % [size[0], zone[0], margins.keys(), band_margin])
		res[String(size[0])] = row
	metric("wind_over_ambience_worst_a_db", worst_a)
	metric("wind_over_ambience_worst_band_db", worst_band)
	metric("detail", res)
	# Perched, the zone is heard in full: no duck at rest.
	fx.set_tel({"airspeed": 0.0, "perched": true})
	await wait_frames(2)
	near(fx.director.ambience.duck_target_db, 0.0, 0.01, "perched: no speed duck")
	Fixture.save_measure("wind_over_ambience", res)


## The church bell: at the belfry it is ambience, not a gameplay cue: a
## stroke at the tower peaks under -8 dBFS on the Ambience bus (Godot's
## default max_db of +3 dB made it the loudest sound in the game); beyond
## 20 m it falls 6 dB per doubling of the distance in world metres,
## whatever the player's size (as the calls since round 5: a sparrow-sized
## player sees a giant bell far away, and a giant bell carries as far as it
## is big; round 2's perceived-distance law made it 18.5 dB quieter 30 m
## from the tower for a sparrow), and the flight speed duck quiets it too.
func test_church_bell_is_ambience() -> void:
	Game.set_state(Game.State.PLAYING)
	var marks: Array[Dictionary] = [
		{"name": "village", "kind": "town", "position": Vector3(0, 0, 0), "radius": 130.0},
		{"name": "church_spire", "kind": "landmark", "position": Vector3(0, 25, 0), "radius": 4.0},
	]
	fx.add_world(marks)
	var amb := fx.director.ambience
	amb.set_world(fx.world)
	var cap := fx.tap(AudioBuses.AMBIENCE)
	var bell: AudioStreamPlayer3D = amb.get_node("Bell")
	var at_tower := Vector3(8, 25, 0)
	fx.listener.global_position = at_tower
	fx.player.global_position = at_tower
	await wait_frames(2)
	amb.settle(at_tower)
	check(amb.toll(), "the bell tolls on request")
	var rec := await fx.record(get_tree(), cap, 0.5)
	var pk := AudioAnalysis.db(maxf(AudioAnalysis.peak(rec["l"]), AudioAnalysis.peak(rec["r"])))
	var g_tower := _voice_gain_db(bell, at_tower)
	lt(pk, -8.0, "a stroke 8 m from the belfry peaks under -8 dBFS on the Ambience bus (%.1f)" % pk)
	gt(pk, -16.0, "and is clearly there (%.1f dBFS)" % pk)
	# 30 m away at world_scale 1 and as a sparrow-sized player (0.141).
	var p30 := Vector3(30, 25, 0)
	fx.listener.global_position = p30
	fx.set_tel({"world_scale": 1.0})
	await wait_frames(2)
	var g30 := _voice_gain_db(bell, p30)
	fx.set_tel({"world_scale": 0.24 / 1.7})
	await wait_frames(2)
	var g30_small := _voice_gain_db(bell, p30)
	# Flying past it at cruise: the speed duck takes the bell down with the beds.
	fx.set_tel({"world_scale": 1.0, "airspeed": FlightSoundMap.cruise(0.03)})
	await Fixture.wait(get_tree(), 0.45)  # the duck follows a speed-up in 0.25 s
	var g30_cruise := _voice_gain_db(bell, p30)
	metric("bell", {"stroke_peak_at_8m_dbfs": pk, "gain_8m_db": g_tower, "gain_30m_db": g30, "gain_30m_sparrow_db": g30_small,
		"gain_30m_cruise_db": g30_cruise})
	var clip_pk := AudioAnalysis.db(AudioAnalysis.peak(AudioAnalysis.clip_pcm(bell.stream)["mono"]))
	Fixture.save_measure("bell_measured", {"stroke_peak_at_8m_dbfs": pk, "clip_peak_dbfs": clip_pk})
	lt(g_tower, AmbienceZones.BELL_DB + 0.01, "the bell never plays above its %.0f dB, however close" % AmbienceZones.BELL_DB)
	# Literal: 20 -> 30 m is 20 log10(20 / 30) = -3.5 dB (and the linear
	# fade to its 1200 m reach takes 0.2 dB more).
	between(g30 - g_tower, -4.5, -3.0, "from the tower's 20 m out to 30 m the bell falls 6 dB per doubling (%.1f dB)" % (g30 - g_tower))
	near(g30_small, g30, 0.1, "a sparrow-sized player 30 m away hears it as a person does (world metres: %.1f vs %.1f dB)" % [g30_small, g30])
	lt(g30_cruise - g30, -10.0, "at cruise the bell recedes with the other ambience (%.1f dB)" % (g30_cruise - g30))
