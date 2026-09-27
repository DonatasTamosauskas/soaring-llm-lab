extends TestCase
## Builder's headroom probe (not part of the suite; moved here from
## tests/probes/audio/, the verifiers' folder, in fix round 3): the suite's
## heavy-play scenarios (a tucked dive by the forest, slow flight by the
## tolling belfry; both with a hawk at threat 0.8, hard flapping, calls and
## two catches 50 ms apart) repeated five times each with the event timing
## shifted, every bus tapped, and what sits under each pre-limiter peak
## printed. Evidence for the headroom figures in docs/areas/AUDIO.md.
## Round 5 added a spread 2.6x dive (the drone's fast-flight make-up at its
## full 6 dB, the threatening hawk's edge lift at 1.2 dB); the tucked dive
## has the hawk's full 4 dB edge lift.
##   tools/gd.sh audio --headless res://tests/runner.tscn -- --dir=res://tests/shots/audio_probes --suite=peaks

const Fixture := preload("res://tests/unit/audio/audio_fixture.gd")
const BUSES: Array[StringName] = [&"Wind", &"Body", &"Calls", &"Danger", &"Ambience", &"SFX", &"Master"]

var fx: Fixture


func before_each() -> void:
	# (The fixture's directors read in-memory settings at the defaults.)
	fx = Fixture.new()
	fx.build(self)
	await wait_frames(2)


func after_each() -> void:
	fx.teardown()
	await Fixture.wait(get_tree(), 0.1)


func test_peaks() -> void:
	Game.set_state(Game.State.PLAYING)
	var marks: Array[Dictionary] = [
		{"name": "f", "kind": "forest", "position": Vector3(0, 0, 0), "radius": 200.0},
		{"name": "l", "kind": "lake", "position": Vector3(60, 0, 0), "radius": 100.0},
		{"name": "v", "kind": "town", "position": Vector3(0, 0, 600), "radius": 130.0},
		{"name": "church_spire", "kind": "landmark", "position": Vector3(0, 20, 600), "radius": 4.0},
	]
	fx.add_world(marks)
	fx.director.ambience.set_world(fx.world)
	var pre := fx.tap(AudioBuses.MASTER, 0)
	var taps := {}
	for b in BUSES:
		taps[b] = fx.tap(b)
	var worst := {}
	for scene in ["belfry", "dive", "spread"]:
		for trial in 5:
			var at := Vector3(10, 20, 600) if scene == "belfry" else Vector3(0, 6, 0)
			fx.listener.global_position = at
			fx.player.global_position = at
			if scene == "dive":
				fx.set_tel({"airspeed": 23.0, "tucked": true, "wing_extension": 0.1, "in_updraft": 2.0})
			elif scene == "spread":
				fx.set_tel({"airspeed": 23.5, "tucked": false, "wing_extension": 1.0, "in_updraft": 2.0})
			else:
				fx.set_tel({"airspeed": FlightSoundMap.cruise(0.03) * 0.35, "tucked": false, "wing_extension": 1.0, "in_updraft": 0.0})
			var callers := [fx.add_npc(&"crow", at + Vector3(10, 2, -5)), fx.add_npc(&"sparrow", at + Vector3(-12, -1, 8)), fx.add_npc(&"gull", at + Vector3(5, 14, 20))]
			var prey := [fx.add_npc(&"moth", at + Vector3(0, 0, -1)), fx.add_npc(&"wren", at + Vector3(0, 0, -1.5))]
			var hawk := fx.add_npc(&"hawk", at + Vector3(0, 6, 15))
			Events.threat_changed.emit(0.8, hawk)
			await Fixture.wait(get_tree(), 0.6)
			fx.director.ambience.settle(at)
			if scene == "belfry":
				fx.director.ambience.toll()
			var driver := Timer.new()
			driver.wait_time = 0.35 + trial * 0.013
			fx.root.add_child(driver)
			var n := [0]
			driver.timeout.connect(func() -> void:
				n[0] += 1
				Events.player_flapped.emit(0, 1.0)
				fx.director.voices.request_call(callers[n[0] % 3], 20.0)
				if n[0] == 3:
					Events.bird_caught.emit(fx.player, prey[0])
					get_tree().create_timer(0.05, true, false, true).timeout.connect(func() -> void:
						Events.bird_caught.emit(fx.player, prey[1])))
			driver.start()
			# Record everything together.
			for c in [pre] + taps.values():
				(c as AudioEffectCapture).clear_buffer()
			var need := int(1.6 * AudioServer.get_mix_rate())
			var bufs := {}
			var main := PackedVector2Array()
			for b in BUSES:
				bufs[b] = PackedVector2Array()
			while main.size() < need:
				await get_tree().process_frame
				var k := pre.get_frames_available()
				if k > 0:
					main.append_array(pre.get_buffer(k))
				for b in BUSES:
					var cc: AudioEffectCapture = taps[b]
					var kk := cc.get_frames_available()
					if kk > 0:
						var arr: PackedVector2Array = bufs[b]
						arr.append_array(cc.get_buffer(kk))
						bufs[b] = arr
			bufs["pre"] = main
			driver.stop()
			driver.queue_free()
			var p: PackedVector2Array = bufs["pre"]
			var pk := 0.0
			var at_i := 0
			for i in p.size():
				var v := maxf(absf(p[i].x), absf(p[i].y))
				if v > pk:
					pk = v
					at_i = i
			var parts := {}
			for b in BUSES:
				var bb: PackedVector2Array = bufs[b]
				if at_i < bb.size():
					var bus_pk := 0.0
					for j in range(maxi(0, at_i - 600), mini(bb.size(), at_i + 600)):
						bus_pk = maxf(bus_pk, maxf(absf(bb[j].x), absf(bb[j].y)))
					parts[b] = snappedf(AudioAnalysis.db(bus_pk), 0.1)
			print("[audio] %s trial %d: pre-limiter peak %.2f dBFS at %.3f s; bus peaks near it (bus taps, pre-fader): %s" % [scene, trial, AudioAnalysis.db(pk), at_i / AudioServer.get_mix_rate(), parts])
			worst[scene] = maxf(float(worst.get(scene, -INF)), AudioAnalysis.db(pk))
			lt(AudioAnalysis.db(pk), AudioBuses.CEILING_DB, "%s trial %d: under the limiter ceiling" % [scene, trial])
			Events.threat_changed.emit(0.0, null)
			for b in callers + prey + [hawk]:
				if is_instance_valid(b):
					fx.npcs.erase(b)
					b.queue_free()
			await Fixture.wait(get_tree(), 0.5)
	metric("worst_pre_limiter_peak_dbfs", worst)
