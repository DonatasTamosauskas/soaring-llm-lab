extends "res://tests/unit/ai/ai_sim.gd"
## Calm birds' full ticks are spread over the ticks (integration round 1; the
## Quest verifier's finding: a whole sky spawned in one tick integrated in
## lockstep - even ticks cost 0.84 ms, odd ones 0.50 - and a headset drops a
## frame on the worst tick, not the average one).
##
## 60 NPCs round a mock player in the AI arena, spawned together in one
## step (as at a new run). Over 72 ticks the number of birds doing a full
## integration each tick (NpcBird.age advances only on those) is counted:
## the worst tick may carry at most MAX_PEAK x the mean.

const MockPlayer2 := preload("res://tests/unit/ai/mock_player.gd")
const MAX_PEAK := 1.3


func before_all() -> void:
	await make_world(false, 1)


func after_all() -> void:
	await clear_sim()


func test_full_ticks_are_spread_over_the_ticks() -> void:
	var player := MockPlayer2.new()
	player.mass = 0.03
	add_child(player)
	player.global_position = Vector3(0, 30, 0)
	var e := make_eco(60, 5)
	e.focus = player
	e.step(DT)
	await wait_frames(1)
	# Let the spawns settle into calm flight away from the player (they stay
	# where the mock player is: it hovers).
	run(3.0)
	var ages := {}
	for b in e.get_npcs():
		ages[b.get_instance_id()] = b.age
	var per_tick: Array[int] = []
	var hist := {}
	for i in 72:
		run(DT)
		var n := 0
		for b in e.get_npcs():
			var id := b.get_instance_id()
			if ages.has(id) and b.age > float(ages[id]):
				n += 1
				if hist.size() < 400:
					var k := "%s#%d" % [b.species, id % 1000]
					hist[k] = str(hist.get(k, "")) + "%d," % i
			ages[id] = b.age
		per_tick.append(n)
	if Paths.arg("phase_debug", "") != "":
		var shown := 0
		for k in hist:
			if shown < 12:
				print("[ai] %s full at %s" % [k, str(hist[k]).substr(0, 60)])
				shown += 1
	if Paths.arg("phase_debug", "") != "":
		var rows := []
		for b in e.get_npcs():
			rows.append("%s st%d nearg%s eng%s lod%d" % [b.species, b.get("_stagger"), b.near_geometry, b.is_engaged(), b.lod])
		print("[ai] birds: ", rows)
	var mean := 0.0
	var peak := 0
	for n in per_tick:
		mean += n
		peak = maxi(peak, n)
	mean /= per_tick.size()
	print("[ai] full ticks per tick: mean %.1f, peak %d of %d birds; %s" % [mean, peak, e.count(), per_tick.slice(0, 24)])
	metric("full_ticks_per_tick", {"mean": mean, "peak": peak, "series": per_tick})
	gt(mean, 1.0, "(setup) birds integrate")
	lt(float(peak), mean * MAX_PEAK, "the busiest tick carries %d full ticks, %.2fx the mean %.1f (lockstep: ~2x)" % [peak, peak / maxf(mean, 1e-6), mean])
	player.queue_free()
