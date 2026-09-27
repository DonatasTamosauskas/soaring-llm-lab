extends TestCase
## Verifier probes for the audio area (round 1, engineering lens). Not part
## of the area's suite; run with
##   tools/gd.sh audio_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/audio
## Each probe pins a claim or a suspected defect; failures here are findings.

const Fixture := preload("res://tests/unit/audio/audio_fixture.gd")

var fx: Fixture


func after_each() -> void:
	if fx != null:
		fx.teardown()
		fx = null
	await Fixture.wait(get_tree(), 0.1)


## (Retired in audio fix round 2, as the round-2 engineering verifier asked:
## test_cache_matches_fresh_synthesis read the round-1 ".res" cache through
## AudioBank.cache_path, both gone. The suite's
## audio_bank_test.test_first_launch_is_off_the_main_thread_and_matches_the_cache
## now checks clips from every design family bit-identical to a fresh
## synthesis, in the cache's current format.)


## STATE_MIX says CAUGHT ducks the Ambience bus by 4 dB. Is it applied?
func test_caught_state_ducks_ambience_as_configured() -> void:
	fx = Fixture.new()
	fx.build(self)
	await wait_frames(2)
	Game.set_state(Game.State.PLAYING)
	await Fixture.wait(get_tree(), 0.6)
	var amb := AudioBuses.index(AudioBuses.AMBIENCE)
	var base := AudioBuses.volume_to_db(AudioBuses.setting_value(AudioBuses.AMBIENCE))
	var playing_db := AudioServer.get_bus_volume_db(amb)
	Game.set_state(Game.State.CAUGHT)
	await Fixture.wait(get_tree(), 0.6)
	var caught_db := AudioServer.get_bus_volume_db(amb)
	var want: float = base + float(AudioDirector.STATE_MIX[Game.State.CAUGHT]["amb"])
	metric("playing_amb_db", playing_db)
	metric("caught_amb_db", caught_db)
	metric("caught_amb_want_db", want)
	print("[audio-verify] ambience bus: playing %.2f dB, caught %.2f dB, STATE_MIX wants %.2f dB" % [playing_db, caught_db, want])
	near(caught_db, want, 0.1, "CAUGHT applies STATE_MIX's ambience duck")


## Crowd normalisation writes the Calls bus volume when it "changes". After a
## burst releases, how many frames in the next 4 s still write it?
func test_crowd_gain_settles_without_per_frame_writes() -> void:
	fx = Fixture.new()
	fx.build(self)
	await wait_frames(2)
	Game.set_state(Game.State.PLAYING)
	var voices := fx.director.voices
	for i in CallVoices.MAX_VOICES:
		var a := TAU * i / CallVoices.MAX_VOICES
		voices.request_call(fx.add_npc(&"sparrow", Vector3(cos(a) * 5.0, 100.0, sin(a) * 5.0)))
	await Fixture.wait(get_tree(), 4.0)  # calls end, crowd gain releases
	var writes := 0
	var frames := 0
	var t_end := Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < t_end:
		var before := voices.crowd_db
		await get_tree().process_frame
		frames += 1
		var target := -10.0 * log(maxf(1.0, voices.active_count() / CallVoices.CROWD_FREE)) / log(10.0)
		# The same condition CallVoices.tick uses to decide a bus write.
		if absf(voices.crowd_db - before) > 0.02 or absf(voices.crowd_db - target) < 0.02 and before != target:
			writes += 1
	metric("frames", frames)
	metric("bus_writes", writes)
	metric("crowd_db_after", voices.crowd_db)
	print("[audio-verify] crowd gain: %d bus writes in %d frames after release (crowd_db %s)" % [writes, frames, str(voices.crowd_db)])
	lt(writes, frames * 0.1, "the Calls bus is not rewritten every frame once the crowd gain has settled")


## Ecosystem._remove() does remove_child(npc) then queue_free(): for the rest
## of that frame the NPC is valid but outside the tree. A voice following it
## reads get_body_position() (global_position). Watch the log for
## "!is_inside_tree()" errors after this probe.
func test_voice_following_npc_removed_from_tree() -> void:
	fx = Fixture.new()
	fx.build(self)
	await wait_frames(2)
	Game.set_state(Game.State.PLAYING)
	var voices := fx.director.voices
	var hawk := fx.add_npc(&"hawk", Vector3(0, 100, 20))
	check(voices.request_call(hawk), "the hawk calls")
	await wait_frames(2)
	print("[audio-verify] removing the calling hawk from the tree (as Ecosystem._remove does), freeing next frame")
	fx.npcs.erase(hawk)
	hawk.alive = false
	hawk.get_parent().remove_child(hawk)
	hawk.queue_free()
	await wait_frames(3)
	check(true, "survived")


## A steal queues the new call on a fading voice for 50 ms. If the new
## caller is freed inside that window (despawned / eaten), _start() runs on
## a freed Bird. Watch the log for SCRIPT ERROR after this probe.
func test_pending_steal_survives_freed_caller() -> void:
	fx = Fixture.new()
	fx.build(self)
	await wait_frames(2)
	Game.set_state(Game.State.PLAYING)
	var voices := fx.director.voices
	var far: Array[Bird] = []
	for i in CallVoices.MAX_VOICES:
		var a := TAU * i / CallVoices.MAX_VOICES
		far.append(fx.add_npc(&"sparrow", Vector3(cos(a) * 60.0, 100.0, sin(a) * 60.0)))
	for b in far:
		voices.request_call(b)
	await wait_frames(1)
	var near := fx.add_npc(&"crow", Vector3(0, 100, -3))
	var stolen_before: int = voices.stats["stolen"]
	var ok := voices.request_call(near)
	check(ok and voices.stats["stolen"] == stolen_before + 1, "the near crow steals a voice (queued on a fading one)")
	print("[audio-verify] freeing the queued caller inside the 50 ms fade window")
	fx.npcs.erase(near)
	near.free()
	await Fixture.wait(get_tree(), 0.2)
	var bad := 0
	for v in voices.voices:
		if v.bird != null and not is_instance_valid(v.bird):
			bad += 1
	metric("voices_on_freed_birds", bad)
	eq(bad, 0, "no voice is left following a freed bird")
