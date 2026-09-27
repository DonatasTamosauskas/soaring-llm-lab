extends TestCase
## LAB (integration hygiene): how close does the kit's staged pass - the one
## game_flow_test flies - bring the player to hovering prey? The prey is
## protected (no catch ends the pass), so every pass flies through and its
## closest approach (swept between ticks) is recorded; the catch rule's
## contact distance at the real assist is printed beside it. Seeds are the
## lab's own (100+), never game_flow's (21, 30-35).
##
##   tools/gd.sh ih_lab --headless --fixed-fps 72 res://tests/runner.tscn -- --dir=res://tests/shots --suite=integration_catchpass_lab --fresh-settings [--passes=24] [--species=moth,wren]

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var kit: Kit


func before_all() -> void:
	kit = Kit.new()
	check(await kit.boot(self), "the game loaded")


func after_all() -> void:
	if kit:
		await kit.teardown()
	await wait_frames(5)


## Closest distance between a point moving linearly from p0 to p1 and a
## point moving from q0 to q1 over one tick.
static func _swept_min(p0: Vector3, p1: Vector3, q0: Vector3, q1: Vector3) -> float:
	var r0 := q0 - p0
	var dr := (q1 - q0) - (p1 - p0)
	var t := 0.0
	var dd := dr.length_squared()
	if dd > 1e-12:
		t = clampf(-r0.dot(dr) / dd, 0.0, 1.0)
	return (r0 + dr * t).length()


func _pass(species: StringName, ahead: float, beside: float) -> Dictionary:
	var m := kit.main
	kit.fly_straight()
	await kit.advance(1.5)
	await kit.wait_until(func() -> bool:
		return m.player.mode_name() == "flying" and absf(m.player.model.position.y - kit.pilot.h_target) < 1.0 \
			and absf(m.player.velocity.y) < 1.0, 8.0)
	var prey := kit.stage_prey(species, ahead, beside)
	m.game_loop.set_protection(prey, 1e6)
	var st := {"min": INF, "rel": Vector3.ZERO, "pp": m.player.get_body_position(), "qp": prey.global_position}
	var track := func() -> void:
		if not is_instance_valid(prey):
			return
		var p1 := m.player.get_body_position()
		var q1 := prey.global_position
		var d := _swept_min(st["pp"], p1, st["qp"], q1)
		if d < st["min"]:
			st["min"] = d
			st["rel"] = q1 - p1
		st["pp"] = p1
		st["qp"] = q1
	m.get_tree().physics_frame.connect(track)
	var passed := false
	for i in 40:
		await kit.advance(0.2)
		if not is_instance_valid(prey):
			break
		var rel := prey.global_position - m.player.get_body_position()
		if rel.dot(m.player.velocity) < 0.0 and rel.length() > 1.5:
			passed = true
			break
	m.get_tree().physics_frame.disconnect(track)
	var contact := m.game_loop.rule.contact_distance(m.player.get_body_radius(), m.player.get_wingspan(), true,
		prey.get_body_radius() if is_instance_valid(prey) else 0.0)
	if is_instance_valid(prey):
		kit.release(prey)
	kit.cruise()
	return {"closest": st["min"], "rel": st["rel"], "passed": passed, "contact": contact, "assist": m.game_loop.rule.player_assist}


func test_passes() -> void:
	var m := kit.main
	check(await kit.click(&"main", &"play"), "Play")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	m.ui.onboarding.skip()
	# The assist a player who just caught something has (none): the lab
	# never catches, and the automatic assist would grow pass by pass.
	m.game_loop.assist_override = float(Paths.arg("assist", "0"))
	var beside_spans := float(Paths.arg("beside_spans", "0"))
	var n := int(Paths.arg("passes", "24"))
	var out := {}
	for sp: String in Paths.arg("species", "moth,wren").split(","):
		var rows := []
		for k in n:
			if k % 6 == 0:
				kit.fly_bot(100 + rows.size() + (0 if sp == "moth" else 50))
				kit.set_mode(&"climb")
				await kit.advance(2.0)
				kit.set_mode(&"cruise")
			m.game_loop.set_protection(m.player, 1e6)
			var r := await _pass(StringName(sp), 30.0, beside_spans * m.player.get_wingspan())
			rows.append(r)
			print("[integration] lab %s pass %d: closest %.3f m (rel %s), contact %.3f m at assist %.2f, %s" % [
				sp, k, r["closest"], r["rel"], r["contact"], r["assist"], "passed" if r["passed"] else "timeout"])
		var cl: Array = rows.map(func(r: Dictionary) -> float: return r["closest"])
		cl.sort()
		var c0: float = rows[0]["contact"]
		var within := func(c: float) -> int: return cl.filter(func(x: float) -> bool: return x <= c).size()
		print("[integration] lab %s (aim %.2f spans beside): %d passes; closest approach p10 %.3f p50 %.3f p90 %.3f max %.3f m; contact %.3f m: %d within it, %d within half of it, %d within 0.75 of it" % [
			sp, beside_spans, cl.size(), cl[int(cl.size() * 0.1)], cl[int(cl.size() * 0.5)], cl[int(cl.size() * 0.9)], cl[-1], c0,
			within.call(c0), within.call(c0 * 0.5), within.call(c0 * 0.75)])
		out[sp] = {"closest": cl, "contact": c0}
	var f := FileAccess.open(Paths.artifacts("integration").path_join("catchpass_lab%s.json" % Paths.arg("tag", "")), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(out, "  "))
	check(true, "ran")
