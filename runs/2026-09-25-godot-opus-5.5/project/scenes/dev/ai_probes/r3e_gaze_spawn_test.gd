extends "res://tests/unit/ai/ai_sim.gd"
## COPY of the verifier probe tests/probes/ai/r3e_gaze_spawn_test.gd (round 3), run by the ai
## builder with its output redirected to artifacts/ai/fix_r3/verifier_probes/, so
## the verifier's own files are never overwritten. Logic unchanged.
## VERIFIER PROBE (round 3, engineering lens): A6 "spawns never inside the
## player's view cone" when the player's GAZE differs from its heading.
## In VR the head turns freely (looking over a shoulder at a threat, down at
## prey); every suite test uses MockPlayer, whose get_view_direction() is
## always its direction of flight, so an Ecosystem that ignored the gaze
## (used the body forward) would pass the whole suite. This probe keeps the
## gaze 90 deg left of the heading (and, second case, straight behind a
## travelling player) and counts spawns inside a 75-deg cone round the gaze
## or within the bird's near distance. It also counts spawns inside the
## heading cone, to show the two cones differ in these runs.
##   tools/gd.sh ai_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/ai --suite=r3e_gaze
## Report: artifacts/ai/verify/r3e/gaze_spawn.json

const VIEW_HALF_DEG := 75.0
const RUN_S := 70.0


func before_all() -> void:
	await make_world(false, 1)


func after_all() -> void:
	await clear_sim()


func _case(tag: String, pm: float, travel: bool, gaze_turn: float, seed_v: int) -> Dictionary:
	var p := MockPlayer.new()
	p.mass = pm
	p.path_center = Vector3(-20, 0, 10)
	p.path_radius = 90.0
	p.path_height = 26.0
	p.speed = minf(SizeRules.cruise_speed(pm), 14.0)
	if travel:
		p.travel = true
		p.speed = 12.0
	add_child(p)
	p.step(0.0)
	p.view_dir = p.view_dir.rotated(Vector3.UP, gaze_turn)
	var e := make_eco(60, seed_v)
	e.focus = p
	var cos_v := cos(deg_to_rad(VIEW_HALF_DEG))
	var m := {"spawns": 0, "in_gaze": 0, "near": 0, "in_heading": 0}
	e.npc_spawned.connect(func(n: NpcBird) -> void:
		m["spawns"] += 1
		var rel := n.global_position - p.get_body_position()
		var d := rel.length()
		if d < e.spawn_distance(n.get_wingspan()):
			m["near"] += 1
		elif p.get_view_direction().dot(rel / d) > cos_v:
			m["in_gaze"] += 1
		if p.get_forward().dot(rel / d) > cos_v:
			m["in_heading"] += 1)
	for i in int(RUN_S / DT):
		p.step(DT)
		# MockPlayer.step() resets the gaze to the heading: turn the head again.
		p.view_dir = p.view_dir.rotated(Vector3.UP, gaze_turn)
		e.step(DT)
	var row := {"tag": tag, "player_mass": pm, "travel": travel, "gaze_turn_deg": rad_to_deg(gaze_turn),
		"spawns": m["spawns"], "spawns_in_gaze_cone": m["in_gaze"], "spawns_within_near_distance": m["near"],
		"spawns_in_heading_cone": m["in_heading"]}
	print("[ai] r3e gaze %s: %s" % [tag, JSON.stringify(row)])
	e.queue_free()
	eco = null
	remove_child(p)
	p.queue_free()
	await wait_frames(2)
	return row


func test_spawns_stay_out_of_the_gaze_not_just_the_heading() -> void:
	var rows := {}
	rows["lap_look_left"] = await _case("lap_look_left", 0.3, false, PI * 0.5, 21)
	rows["travel_look_left"] = await _case("travel_look_left", 0.03, true, PI * 0.5, 22)
	rows["travel_look_back"] = await _case("travel_look_back", 0.1, true, PI, 23)
	for k in rows:
		var r: Dictionary = rows[k]
		gt(r["spawns"], 20, "%s: (setup) the population spawned" % k)
		eq(r["spawns_in_gaze_cone"], 0, "%s: no spawn inside the 75-deg cone round the gaze" % k)
		eq(r["spawns_within_near_distance"], 0, "%s: no spawn within the near distance" % k)
	metric("gaze_spawn", rows)
	var dir := Paths.artifacts("ai/fix_r3/verifier_probes")
	var f := FileAccess.open(dir.path_join("gaze_spawn.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(rows, "  "))
	f.close()
