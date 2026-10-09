extends "res://tests/unit/game/game_fixture.gd"
## G7 — best score / tier persisted in user:// across sessions: round trip,
## records only improve, missing/corrupt files, and the loop saving on every
## run end (and on abandoning a run).

## Per process: concurrent sandboxes share one user:// directory.
var PATH := "user://gameloop_test_records_g7_%d.json" % OS.get_process_id()


func before_each() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))


func after_each() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	await cleanup()


func _summary(score: int, tier: int, mass: float, catches: int, apex_at: float = -1.0,
		victory: bool = false, duration: float = 600.0, streak: int = 2) -> Dictionary:
	return {"score": score, "peak_tier": tier, "peak_mass": mass, "catches": catches,
		"best_streak": streak, "victory": victory, "duration_s": duration,
		"apex": {"reached_at": apex_at}}


func test_round_trip() -> void:
	var r := RunRecords.new(PATH)
	r.load_records()
	eq(r.best_score, 0, "fresh: no score")
	eq(r.best_tier, -1, "fresh: no tier")
	var flags := r.submit(_summary(1234, 5, 0.41, 12, -1.0, false, 700.0, 4))
	check(flags["score"] and flags["tier"] and flags["mass"] and flags["catches"] and flags["streak"], "first run breaks every record it has")
	check(not flags["apex_time"] and not flags["victory_time"], "no apex/victory records without apex/victory")
	check(FileAccess.file_exists(PATH), "saved immediately on submit")
	var r2 := RunRecords.new(PATH)
	r2.load_records()
	eq(r2.best_score, 1234, "score persisted")
	eq(r2.best_tier, 5, "tier persisted")
	near(r2.best_mass, 0.41, 1e-9, "mass persisted")
	eq(r2.most_catches, 12, "catches persisted")
	eq(r2.best_streak, 4, "streak persisted")
	eq(r2.runs, 1, "run count persisted")
	eq(r2.to_dict()["best_species"], &"pigeon", "best species derived from tier")


func test_records_only_improve() -> void:
	var r := RunRecords.new(PATH)
	r.submit(_summary(5000, 9, 4.8, 30, 1500.0, true, 1900.0, 7))
	var f := r.submit(_summary(3000, 6, 0.7, 10, -1.0, false, 400.0, 2))
	check(not f.values().has(true), "a worse run breaks nothing")
	eq(r.best_score, 5000, "score kept")
	eq(r.best_tier, 9, "tier kept")
	near(r.fastest_apex_s, 1500.0, 1e-9, "apex time kept")
	near(r.fastest_victory_s, 1900.0, 1e-9, "victory time kept")
	var f2 := r.submit(_summary(4000, 9, 4.6, 20, 1300.0, true, 1800.0, 3))
	check(f2["apex_time"] and f2["victory_time"], "faster apex and victory are records")
	check(not f2["score"] and not f2["tier"], "but not score/tier")
	eq(r.runs, 3, "three runs")
	eq(r.victories, 2, "two victories")
	var r2 := RunRecords.new(PATH)
	r2.load_records()
	eq(r2.to_dict(), r.to_dict(), "disk matches memory")


func test_missing_and_corrupt_files() -> void:
	var r := RunRecords.new("user://gameloop_no_such_dir/never.json")
	r.load_records()
	eq(r.best_score, 0, "missing file: defaults")
	for garbage in ["this is [not json \n garbage = = = [[[", "", "[1, 2, 3]", "{\"best_score\": \"lots\"}"]:
		var fa := FileAccess.open(PATH, FileAccess.WRITE)
		fa.store_string(garbage)
		fa.close()
		var r2 := RunRecords.new(PATH)
		r2.load_records()
		eq(r2.best_score, 0, "corrupt file %s: defaults, no crash" % JSON.stringify(garbage))
		eq(r2.best_tier, -1, "corrupt file: no tier")
	# Out-of-range values from a hand-edited file are clamped.
	var fb := FileAccess.open(PATH, FileAccess.WRITE)
	fb.store_string(JSON.stringify({"best_tier": 99, "best_score": -50, "runs": 2, "victories": 5,
		"best_mass": -1.0, "fastest_apex_s": -7.0}))
	fb.close()
	var r3 := RunRecords.new(PATH)
	r3.load_records()
	eq(r3.best_tier, SizeRules.SPECIES.size() - 1, "tier clamped to the ladder")
	eq(r3.best_score, 0, "negative score clamped")
	eq(r3.victories, 2, "victories never exceed runs")
	near(r3.best_mass, 0.0, 1e-9, "negative mass clamped")
	near(r3.fastest_apex_s, -1.0, 1e-9, "a negative time means never")
	# And it still saves over the damaged file (atomically: no temp file left).
	r3.submit(_summary(10, 2, 0.03, 1))
	check(not FileAccess.file_exists(PATH + ".tmp"), "no temporary file left behind")
	var r4 := RunRecords.new(PATH)
	r4.load_records()
	eq(r4.runs, 3, "recovered file is usable")


func test_loop_persists_every_run() -> void:
	make_loop()
	loop.records_path = PATH
	loop.records = RunRecords.new(PATH)
	var p := make_bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 0.0)
	for i in 3:
		make_bird(p.mass / SizeRules.EAT_RATIO * 0.99, p.get_body_position() + Vector3(0, 0, -0.05))
		loop.step(1.0 / 72.0)
		loop.step(GameLoop.SWALLOW_MAX_S + 0.05)
	var peak_tier := SizeRules.tier_for_mass(p.mass)
	start_logging()
	loop.end_run(&"quit")
	var s: Dictionary = events("run_ended")[0][1]
	check(s["new_records"]["score"] and s["new_records"]["tier"], "summary reports new records")
	eq(s["records"]["best_tier"], peak_tier, "summary carries the persisted bests")
	# A new session: a fresh GameLoop entering the tree with nothing but the
	# path set loads the bests by itself (in _ready).
	await cleanup()
	loop = GameLoop.new()
	loop.auto_step = false
	loop.verbose = false
	loop.records_path = PATH
	add_child(loop)
	var st := loop.get_run_stats()
	eq(st["best_tier"], peak_tier, "next session: best tier")
	eq(st["best_score"], s["score"], "next session: best score")
	eq(loop.records.runs, 1, "next session: one run so far")
	# Abandoning a run to the menu still counts toward the records.
	make_bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	loop.to_menu()
	var r := RunRecords.new(PATH)
	r.load_records()
	eq(r.runs, 2, "abandoned run recorded")
	# The loop's default file is a separate, real user:// path.
	eq(RunRecords.DEFAULT_PATH, "user://gameloop_records.json", "default records path")


func test_a_continued_victory_counts_once() -> void:
	# Win, keep flying (continue_after_victory), then the run ends again -
	# by being caught out or by quitting: still one run and one victory.
	for ending in [&"caught", &"quit", &"menu"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
		make_loop()
		loop.records_path = PATH
		loop.records = RunRecords.new(PATH)
		var eagle: float = SizeRules.species_data(&"eagle")["mass"]
		var p := make_bird(eagle * 0.97, Vector3.ZERO, Vector3.FORWARD, true)
		loop.start_run()
		loop.set_protection(p, 0.0)
		p.mass = eagle * 0.97
		loop.step(1.0 / 72.0)
		for i in GameLoop.APEX_CATCHES + 1:
			make_bird(p.mass * 0.3, p.get_body_position() + p.get_forward() * 0.3)
			loop.step(1.0 / 72.0)
			loop.step(GameLoop.SWALLOW_MAX_S + 0.05)
		check(loop.stats.victory and Game.state == Game.State.ENDED, "(setup) won")
		eq(loop.records.runs, 1, "one run after the victory")
		eq(loop.records.victories, 1, "one victory")
		loop.continue_after_victory()
		match ending:
			&"caught":
				loop.lives = 1
				var hunter := make_bird(p.mass * 2.0, p.get_body_position() + Vector3(0, 0, 0.6), Vector3.FORWARD)
				hunter.set_heading(Vector3.FORWARD)
				loop.set_protection(p, 0.0)
				loop.step(1.0 / 72.0)
				for i in int((GameLoop.CAUGHT_BEAT_S + 0.5) / 0.1):
					loop.step(0.1)
				eq(loop.phase, GameLoop.Phase.ENDED, "continued run ended by being caught")
			&"quit":
				loop.end_run(&"quit")
			&"menu":
				loop.to_menu()
		var r := RunRecords.new(PATH)
		r.load_records()
		eq(r.runs, 1, "%s after a continued victory: still one run" % ending)
		eq(r.victories, 1, "%s after a continued victory: still one victory" % ending)
		gt(float(r.most_catches), float(GameLoop.APEX_CATCHES), "the continued part's bests still count")
		await cleanup()


func test_bests_survive_the_app_closing_mid_run() -> void:
	# On Quest a session often ends from the system menu or by taking the
	# headset off - no run end. A new peak tier is saved at once, and the
	# run's progress again on pause and when the app is paused, loses focus
	# or is closed; none of that counts as a run until the run ends. The
	# summary still celebrates records against the bests at the run's start.
	make_loop()
	loop.records_path = PATH
	loop.records = RunRecords.new(PATH)
	var p := make_bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 0.0)
	var tier0 := SizeRules.tier_for_mass(p.mass)
	while SizeRules.tier_for_mass(p.mass) == tier0:
		make_bird(p.mass / SizeRules.EAT_RATIO * 0.99, p.get_body_position() + Vector3(0, 0, -0.05))
		loop.step(1.0 / 72.0)
		loop.step(GameLoop.SWALLOW_MAX_S + 0.05)
	var peak := SizeRules.tier_for_mass(p.mass)
	var r := RunRecords.new(PATH)
	r.load_records()
	eq(r.best_tier, peak, "a new peak tier is on disk at once, mid-run")
	eq(r.runs, 0, "...without counting the run yet")
	gt(float(r.best_score), 0.0, "the run's score so far is kept too")
	# More progress that reaches no new tier (so nothing saved it yet), then
	# the app is backgrounded (headset off / system menu).
	var tier_now := SizeRules.tier_for_mass(p.mass)
	make_bird(p.mass * 0.2, p.get_body_position() + Vector3(0, 0, -0.05))
	loop.step(1.0 / 72.0)
	eq(SizeRules.tier_for_mass(p.mass), tier_now, "(setup) a small meal, no new tier")
	var catches := loop.stats.catches
	r.load_records()
	lt(float(r.most_catches), float(catches), "(setup) that catch is not on disk yet")
	loop.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	r.load_records()
	eq(r.most_catches, catches, "progress saved when the app is paused")
	eq(r.runs, 0, "still not counted as a run")
	loop.step(0.3)
	make_bird(p.mass * 0.05, p.get_body_position() + Vector3(0, 0, -0.05))
	loop.step(1.0 / 72.0)
	eq(SizeRules.tier_for_mass(p.mass), tier_now, "(setup) again no new tier")
	loop.pause()
	r.load_records()
	eq(r.most_catches, loop.stats.catches, "progress saved on pause")
	loop.resume()
	# The run ends: counted once; the summary's flags are against the bests
	# before the run, although the file already has this run's progress.
	start_logging()
	loop.end_run(&"quit")
	var s: Dictionary = events("run_ended")[0][1]
	check(s["new_records"]["tier"] and s["new_records"]["score"], "the summary still says: new best tier and score")
	r.load_records()
	eq(r.runs, 1, "one run once it ended")
	# Closing the window mid-run (desktop) saves too.
	await cleanup()
	make_loop()
	loop.records_path = PATH
	loop.records = RunRecords.new(PATH)
	loop.records.load_records()
	var p2 := make_bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p2, 0.0)
	# (Two big meals, each species settling in before the next - fix round
	# 1's growth made three back to back stop at the next species' settle
	# cap, where a small meal adds nothing - to a better score than the run
	# above.)
	for i in 2:
		make_bird(p2.mass / SizeRules.EAT_RATIO * 0.99, p2.get_body_position() + Vector3(0, 0, -0.05))
		loop.step(1.0 / 72.0)
		loop.step(GameLoop.SWALLOW_MAX_S + 0.05)
		loop.step(GameLoop.TIER_SETTLE_S)
	# (and a last small, worthwhile catch that no new tier has saved)
	var tier2 := SizeRules.tier_for_mass(p2.mass)
	loop.step(0.3)
	make_bird(p2.mass * 0.1, p2.get_body_position() + Vector3(0, 0, -0.05))
	loop.step(1.0 / 72.0)
	eq(SizeRules.tier_for_mass(p2.mass), tier2, "(setup) no new tier")
	var score := loop.stats.score()
	r.load_records()
	lt(float(r.best_score), float(score), "(setup) the run's score so far is not on disk yet")
	loop.notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	r.load_records()
	eq(r.best_score, score, "progress saved when the window is closed")
	# The loop leaving the tree mid-run (the scene is changed or torn down
	# without a run end) saves too.
	loop.step(0.3)
	make_bird(p2.mass * 0.1, p2.get_body_position() + Vector3(0, 0, -0.05))
	loop.step(1.0 / 72.0)
	var score2 := loop.stats.score()
	r.load_records()
	lt(float(r.best_score), float(score2), "(setup) the newest score is not on disk yet")
	remove_child(loop)
	r.load_records()
	eq(r.best_score, score2, "progress saved when the loop leaves the tree")
	eq(r.runs, 1, "...still without counting a run")
	add_child(loop)
