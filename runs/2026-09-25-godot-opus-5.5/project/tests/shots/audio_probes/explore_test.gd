extends TestCase
## Builder exploration (fix round 3): measurements used to calibrate the
## catch duck and the programme loudness. Not part of the suite.
##
##   tools/gd.sh audio --headless res://tests/runner.tscn -- --dir=res://tests/shots/audio_probes --suite=explore

const Fixture := preload("res://tests/unit/audio/audio_fixture.gd")

var fx: Fixture


func before_each() -> void:
	# (The fixture's directors read in-memory settings at the defaults.)
	fx = Fixture.new()
	fx.build(self)
	await wait_frames(2)


func after_each() -> void:
	fx.teardown()
	await Fixture.wait(get_tree(), 0.1)


func after_all() -> void:
	await Fixture.wait(get_tree(), 0.3)


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


func test_catch_over_wind() -> void:
	Game.set_state(Game.State.PLAYING)
	var sfx := fx.tap(AudioBuses.SFX)
	var wind := fx.tap(AudioBuses.WIND)
	var cruise := FlightSoundMap.cruise(0.03)
	for c in [["cruise", 1.0, false], ["1.5x", 1.5, false], ["2.0x", 2.0, false], ["2.0x_t", 2.0, true], ["2.4x_t", 2.4, true],
			["2.6x", 2.6, false], ["2.6x_t", 2.6, true]]:
		fx.set_tel({"airspeed": cruise * c[1], "tucked": c[2], "wing_extension": 0.1 if c[2] else 1.0, "perched": false})
		await Fixture.wait(get_tree(), 0.8)
		var prey := fx.add_npc(&"wren", Vector3(5000, 100, 0))
		get_tree().create_timer(0.3, true, false, true).timeout.connect(func() -> void: Events.bird_caught.emit(fx.player, prey))
		var pair := await fx.record2(get_tree(), sfx, wind, 1.0)
		var rate: float = pair[0]["rate"]
		var fs := _aw_frames(pair[0]["mono"], rate)
		var fw := _aw_frames(pair[1]["mono"], rate)
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
		var before := 0.0
		for k in range(0, int(0.25 / (512.0 / rate))):
			before += fw[k]
		before /= int(0.25 / (512.0 / rate))
		print("[audio] catch %s: body %.1f dB; wind before %.1f dB A, crunch %.1f, wind then %.1f -> %+.1f" % [c[0],
			FlightSoundMap.body_db(c[1], 1.0 if c[2] else 0.0), _pdb(before), _pdb(best_cue / per), _pdb(wind_then / per),
			_pdb(best_cue / per) - _pdb(wind_then / per)])
		fx.npcs.erase(prey)
		prey.queue_free()
		await Fixture.wait(get_tree(), 0.4)
	check(true, "measured")


func test_programme_loudness() -> void:
	var marks: Array[Dictionary] = [
		{"name": "meadow", "kind": "meadow", "position": Vector3(0, 0, 0), "radius": 300.0},
		{"name": "wood", "kind": "forest", "position": Vector3(800, 0, 0), "radius": 200.0},
	]
	fx.add_world(marks)
	fx.director.ambience.set_world(fx.world)
	var master := fx.tap(AudioBuses.MASTER)
	var master_fader := AudioServer.get_bus_volume_db(AudioServer.get_bus_index(AudioBuses.MASTER))
	var cruise := FlightSoundMap.cruise(0.03)
	var callers: Array[Bird] = []
	var scenes := [
		["menu", Game.State.MENU, Vector3(0, 2, 0), {"airspeed": 0.0, "perched": true}, false, false],
		["perched_forest_birds", Game.State.PLAYING, Vector3(800, 3, 0), {"airspeed": 0.0, "perched": true}, false, true],
		["glide_cruise_20m", Game.State.PLAYING, Vector3(0, 20, 0), {"airspeed": cruise, "perched": false}, false, false],
		["glide_cruise_5m", Game.State.PLAYING, Vector3(0, 5, 0), {"airspeed": cruise, "perched": false}, false, false],
		["flapping_cruise_5m", Game.State.PLAYING, Vector3(0, 5, 0), {"airspeed": cruise, "perched": false}, true, true],
		["slow_glide_0.6x_5m", Game.State.PLAYING, Vector3(0, 5, 0), {"airspeed": cruise * 0.6, "perched": false}, false, false],
		["dive_2.4x_tucked", Game.State.PLAYING, Vector3(0, 30, 0), {"airspeed": cruise * 2.4, "perched": false, "tucked": true, "wing_extension": 0.1}, false, false],
		["menu_again", Game.State.MENU, Vector3(0, 2, 0), {"airspeed": 0.0, "perched": true}, false, false],
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
		await Fixture.wait(get_tree(), 1.8 if not String(sc[0]).begins_with("menu") else 2.2)
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
		var l := AudioAnalysis.lufs(rec["l"], rec["r"], rec["rate"], master_fader)
		print("[audio] %s: %.1f LUFS" % [sc[0], l])
	check(true, "measured")


func test_music_profile() -> void:
	var st := fx.director.bank.get_stream(&"music_menu")
	var d := AudioAnalysis.clip_pcm(st)
	var rate: float = d["rate"]
	var l: PackedFloat32Array = d["l"]
	var r: PackedFloat32Array = d["r"]
	print("[audio] music %.1f s at %d Hz, whole loop %.2f LUFS (clip, 0 dB), RMS %.2f dBFS" % [l.size() / rate, int(rate),
		AudioAnalysis.lufs(l, r, rate), AudioAnalysis.db(AudioAnalysis.rms(d["mono"]))])
	var win := int(2.0 * rate)
	var line := PackedStringArray()
	for k in range(0, l.size() - win, win):
		line.append("%.1f" % AudioAnalysis.lufs(l.slice(k, k + win), r.slice(k, k + win), rate))
	print("[audio] music 2 s windows (LUFS): %s" % ", ".join(line))
	var i1 := int(1.5 * rate)
	print("[audio] music first 1.5 s: %.2f LUFS, RMS %.2f" % [AudioAnalysis.lufs(l.slice(0, i1), r.slice(0, i1), rate), AudioAnalysis.db(AudioAnalysis.rms(d["mono"].slice(0, i1)))])
	check(true, "measured")


func test_catch_cluster_peaks() -> void:
	Game.set_state(Game.State.PLAYING)
	var sfx := fx.tap(AudioBuses.SFX)
	var body := fx.tap(AudioBuses.BODY)
	await Fixture.wait(get_tree(), 0.4)
	var pk := PackedFloat32Array()
	for trial in 8:
		var a := fx.add_npc(&"moth", Vector3(0, 100, -1))
		var b := fx.add_npc(&"wren", Vector3(0, 100, -1.5))
		get_tree().create_timer(0.05, true, false, true).timeout.connect(func() -> void:
			Events.bird_caught.emit(fx.player, a)
			get_tree().create_timer(0.05, true, false, true).timeout.connect(func() -> void: Events.bird_caught.emit(fx.player, b)))
		var rec := await fx.record(get_tree(), sfx, 0.6)
		pk.append(AudioAnalysis.db(maxf(AudioAnalysis.peak(rec["l"]), AudioAnalysis.peak(rec["r"]))))
		fx.npcs.erase(a)
		fx.npcs.erase(b)
		a.queue_free()
		b.queue_free()
		await Fixture.wait(get_tree(), 0.3)
	print("[audio] two catches 50 ms apart, SFX peak dBFS: %s" % [pk])
	var fl := PackedFloat32Array()
	for trial in 6:
		Events.player_flapped.emit(0, 1.0)
		var rec := await fx.record(get_tree(), body, 0.35)
		fl.append(AudioAnalysis.db(maxf(AudioAnalysis.peak(rec["l"]), AudioAnalysis.peak(rec["r"]))))
	print("[audio] both-wings full flap, Body peak dBFS: %s" % [fl])
	check(true, "measured")
