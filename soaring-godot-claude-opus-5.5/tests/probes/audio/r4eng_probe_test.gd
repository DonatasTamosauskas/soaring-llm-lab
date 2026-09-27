extends TestCase
## Round-4 engineering verifier probes (not part of the audio suite).
##
## Run: tools/gd.sh audio_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/audio --suite=r4eng
##
##  1. The tier-up fanfare and the caught stinger stand over the player's own
##     wind (the suite pins only the catch crunch against the wind; the
##     fanfare/stinger are checked only against their own LEVEL entries).
##  2. A both-wings flap (side 0) is a centred transient.
##  3. A director built asynchronously and freed at once raises no errors.
##  4. A director with no player, no camera and no world handles every event
##     without errors.
## Numbers go to artifacts/audio/verify/r4eng/probe.json.

const Fixture := preload("res://tests/unit/audio/audio_fixture.gd")
const ErrorLog := preload("res://tests/unit/audio/audio_error_log.gd")

var out := {}


func after_all() -> void:
	Fixture.restore_default_settings()
	var f := FileAccess.open(Paths.artifacts("audio/verify/r4eng").path_join("probe.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "  ", true))
	await Fixture.wait(get_tree(), 0.2)


static func _aw_frames(buf: PackedFloat32Array, rate: float) -> PackedFloat32Array:
	var w := AudioAnalysis.a_weights(1024, rate)
	var o := PackedFloat32Array()
	for fr in AudioAnalysis.stft(buf, 1024, 512):
		var s := 0.0
		for i in fr.size():
			s += fr[i] * fr[i] * w[i]
		o.append(s / AudioAnalysis.BIN_POWER_PER_MS)
	return o


static func _pdb(p: float) -> float:
	return 10.0 * log(maxf(p, 1e-30)) / log(10.0)


## Loudest 0.4 s of (SFX - Wind) A-weighted, against the wind in the same
## window; plus the wind before the cue.
static func _cue_over_wind(sfx: Dictionary, wind: Dictionary, pre_s: float) -> Dictionary:
	var rate: float = sfx["rate"]
	var fs := _aw_frames(sfx["mono"], rate)
	var fw := _aw_frames(wind["mono"], rate)
	var n := mini(fs.size(), fw.size())
	var hop := 512.0 / rate
	var per := int(round(0.4 / hop))
	var pre := int(pre_s / hop) - 1
	var before := 0.0
	for k in pre:
		before += fw[k]
	before = _pdb(before / maxf(1.0, pre))
	var best := 0.0
	var wind_then := 1e-30
	for k in range(pre, n - per):
		var sc := 0.0
		var sw := 0.0
		for j in per:
			sc += maxf(0.0, fs[k + j] - fw[k + j])
			sw += fw[k + j]
		if sc > best:
			best = sc
			wind_then = sw
	return {"cue_aw": _pdb(best / per), "wind_aw_then": _pdb(wind_then / per), "wind_aw_before": before,
		"cue_over_wind_db": _pdb(best / per) - _pdb(wind_then / per), "cue_over_unducked_wind_db": _pdb(best / per) - before}


func test_fanfare_and_stinger_stand_over_the_wind() -> void:
	Fixture.restore_default_settings()
	Game.set_state(Game.State.PLAYING)
	var fx := Fixture.new()
	fx.build(self)
	await wait_frames(2)
	var sfx := fx.tap(AudioBuses.SFX)
	var wind := fx.tap(AudioBuses.WIND)
	var cruise := FlightSoundMap.cruise(fx.player.mass)
	var predator := fx.add_npc(&"hawk", Vector3(0, 100, 3000))
	var res := {}
	for c in [["cruise", 1.0, false], ["dive_2.6x_tucked", 2.6, true]]:
		for cue in ["fanfare", "caught"]:
			fx.set_tel({"airspeed": cruise * c[1], "tucked": c[2], "wing_extension": 0.1 if c[2] else 1.0})
			# Any earlier cue duck (2.5 s at most) is over and the wind settled.
			await Fixture.wait(get_tree(), 2.9)
			await Fixture.past_hitch(get_tree())
			get_tree().create_timer(0.3, true, false, true).timeout.connect(func() -> void:
				if cue == "fanfare":
					Events.player_tier_changed.emit(3, 4)
				else:
					Events.player_caught.emit(predator))
			var pair := await fx.record2(get_tree(), sfx, wind, 1.3)
			var m := _cue_over_wind(pair[0], pair[1], 0.3)
			res["%s_%s" % [c[0], cue]] = m
			gt(m["cue_over_wind_db"], 6.0, "%s: the %s stands >= 6 dB A over the wind it lands in (%+.1f)" % [c[0], cue, m["cue_over_wind_db"]])
	out["cues_over_wind"] = res
	metric("cues_over_wind", res)
	fx.teardown()
	await Fixture.wait(get_tree(), 0.05)


func test_both_wings_flap_is_centred_transient() -> void:
	Fixture.restore_default_settings()
	Game.set_state(Game.State.PLAYING)
	var fx := Fixture.new()
	fx.build(self)
	await wait_frames(2)
	var cap := fx.tap(AudioBuses.BODY)
	await Fixture.wait(get_tree(), 0.1)
	var res := {}
	for side in [0, -1]:
		cap.clear_buffer()
		Events.player_flapped.emit(side, 1.0)
		var rec := await fx.record(get_tree(), cap, 0.4)
		var l := AudioAnalysis.db(AudioAnalysis.rms(rec["l"]))
		var r := AudioAnalysis.db(AudioAnalysis.rms(rec["r"]))
		var env := AudioAnalysis.envelope(rec["mono"], rec["rate"], 0.005)
		var pk := 0.0
		for e in env:
			pk = maxf(pk, e)
		var on := 0
		while on < env.size() and env[on] < pk * 0.1:
			on += 1
		var last := on
		for i in range(on, env.size()):
			if env[i] >= pk * 0.1:
				last = i
		res[str(side)] = {"l": l, "r": r, "decay_s": (last - on + 1) * 0.005,
			"power_db": 10.0 * log(pow(10.0, l / 10.0) + pow(10.0, r / 10.0)) / log(10.0)}
		await Fixture.wait(get_tree(), 0.1)
	out["both_wings_flap"] = res
	metric("both_wings_flap", res)
	lt(absf(float(res["0"]["l"]) - float(res["0"]["r"])), 2.0, "a both-wings flap is centred (L %.1f, R %.1f)" % [res["0"]["l"], res["0"]["r"]])
	lt(float(res["0"]["decay_s"]), 0.3, "and a transient (%.2f s)" % res["0"]["decay_s"])
	# Two whooshes at -3 dB each: about as loud in total as one full flap.
	near(float(res["0"]["power_db"]), float(res["-1"]["power_db"]), 3.0, "and about as loud in total as a one-wing flap")
	fx.teardown()
	await Fixture.wait(get_tree(), 0.05)


func test_async_director_freed_at_once_is_clean() -> void:
	var log := ErrorLog.install()
	for i in 3:
		var d := (load(Fixture.DIRECTOR) as PackedScene).instantiate() as AudioDirector
		d.async_build = true
		add_child(d)
		await wait_frames(1 + i)
		Events.player_flapped.emit(-1, 1.0)
		Events.threat_changed.emit(0.7, null)
		remove_child(d)
		d.free()
		await wait_frames(2)
	await Fixture.wait(get_tree(), 0.3)
	log.uninstall()
	out["async_free_errors"] = [log.errors, log.samples]
	eq(log.errors, 0, "async-built directors freed at once: no errors (%s)" % [log.samples])


func test_bare_director_handles_every_event() -> void:
	var log := ErrorLog.install()
	Game.set_state(Game.State.PLAYING)
	var d := (load(Fixture.DIRECTOR) as PackedScene).instantiate() as AudioDirector
	d.async_build = false
	add_child(d)
	await wait_frames(2)
	var npc := Bird.new()
	npc.species = &"crow"
	add_child(npc)
	Events.player_flapped.emit(0, 1.0)
	Events.player_flapped.emit(1, 0.5)
	Events.bird_caught.emit(npc, npc)
	Events.player_caught.emit(null)
	Events.player_caught.emit(npc)
	Events.player_tier_changed.emit(1, 2)
	Events.player_collided.emit(4.0, Vector3.UP)
	Events.player_collided.emit(0.0, Vector3.UP)
	Events.player_perched.emit(Vector3.ZERO)
	Events.threat_changed.emit(0.9, npc)
	Events.threat_changed.emit(0.2, null)
	Events.target_changed.emit(npc)
	Events.settings_changed.emit("sfx_volume", 1.0)
	for st in [Game.State.PAUSED, Game.State.MENU, Game.State.ENDED, Game.State.CAUGHT, Game.State.PLAYING]:
		Game.set_state(st)
		await wait_frames(3)
	d.play_ui(&"click")
	d.play_ui(&"nonexistent")
	await Fixture.wait(get_tree(), 0.3)
	npc.queue_free()
	await wait_frames(3)
	var snap := d.debug_snapshot()
	await d.shutdown()
	remove_child(d)
	d.free()
	await Fixture.wait(get_tree(), 0.1)
	log.uninstall()
	out["bare_director"] = {"errors": log.errors, "warnings": log.warnings, "samples": log.samples, "snapshot_keys": snap.keys()}
	eq(log.errors, 0, "a director with no player, camera or world: no errors (%s)" % [log.samples])
	eq(log.warnings, 0, "and no warnings (%s)" % [log.samples])
	Game.set_state(Game.State.BOOT)
