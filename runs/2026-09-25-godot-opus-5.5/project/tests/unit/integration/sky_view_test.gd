extends TestCase
## What the player sees of the living sky (integration round 1; the
## experience verifier's major finding: "from the player's eyes the sky
## looks empty, and worst on the Quest tier that ships" - straight ahead a
## cruising sparrow had on average 0.15 NPCs in view, 0.05 big enough to
## see, and 0.0 at the Quest tier).
##
## The real game (main.tscn), a sparrow flown by the bot through the real
## WingInput at ~25 m over the valley, the head straight along the flight
## direction (5 deg down, the Quest Pro's ~106 x 90 deg view). Every second
## of game time: the NPCs in that view (not hidden in cover) whose wingspan
## spans at least SEEN_DEG (4 px at 1280 x 960 over 90 deg; ~7 px in a
## Quest Pro) - birds a player notices. Two flights, each at both tiers:
## lapping (the verifier's orbit round the spawn) and travelling (straight
## legs across the valley, a 45-75 deg turn every LEG_S). The Ecosystem's show
## (Ecosystem.SHOW_AHEAD: ambient flocks, the murmuration and big birds
## that are not the player's prey or threats, homed ahead of its flight) is
## what fills it.
##
## Pinned for every flight: a mean of at least MIN_MEAN such birds in view
## and at least one in MIN_SHARE of the seconds - per tier. The full game's
## 60 NPCs measured 2.0-4.2 on a lap and 4.6-7.9 travelling, one in 60-99 %
## of the seconds (four realizations of the sky); the Quest tier's 28 leave
## the show a murmuration and a few big birds: 1.4-4.5 on a lap, 0.9-2.6
## travelling, one in 41-88 % of the seconds. The verifier measured 0.05
## (full) and 0.0 (Quest) straight ahead on a lap.

const Kit := preload("res://tests/unit/integration/game_kit.gd")
const SEEN_DEG := 0.37
const HALF_H_DEG := 53.0
const HALF_V_DEG := 45.0
const SETTLE_S := 25.0
const SAMPLE_S := 90
const LEG_S := 25.0
const MIN_MEAN := {&"full": 1.5, &"quest": 0.75}
const MIN_SHARE := {&"full": 0.55, &"quest": 0.35}

var kit: Kit
var booted := false


func before_all() -> void:
	kit = Kit.new()
	booted = await kit.boot(self)


func after_all() -> void:
	if kit:
		await kit.teardown()
	await wait_frames(5)


## Birds a player notices straight ahead right now.
func _seen() -> int:
	var m := kit.main
	var eye := m.player.camera.global_position
	var v := m.player.velocity
	var fdir := Vector3(v.x, 0.0, v.z)
	if fdir.length() < 0.5:
		fdir = -m.player.global_basis.z
	fdir = Vector3(fdir.x, 0.0, fdir.z).normalized()
	var inv := (Basis.looking_at(fdir, Vector3.UP) * Basis(Vector3.RIGHT, deg_to_rad(-5.0))).inverse()
	var th := tan(deg_to_rad(HALF_H_DEG))
	var tv := tan(deg_to_rad(HALF_V_DEG))
	var n := 0
	for b in m.ecosystem.get_npcs():
		if not is_instance_valid(b) or not b.alive or b.hidden:
			continue
		var rel := b.global_position - eye
		var loc := inv * rel
		if loc.z > -0.1 or absf(loc.x / -loc.z) > th or absf(loc.y / -loc.z) > tv:
			continue
		if b.get_wingspan() / maxf(rel.length(), 0.01) >= deg_to_rad(SEEN_DEG):
			n += 1
	return n


func _fly(tier: StringName, flight: StringName) -> Dictionary:
	var m := kit.main
	var q := QualityTier.new()
	if tier == &"quest":
		q.set_quest()
	q.apply_ecosystem(m.ecosystem)
	# A new run: the sky rebuilt for this budget round the spawn.
	if Game.state != Game.State.PLAYING:
		# (Play through the bridge: a pointer click takes a wall-clock number
		# of ticks, and a seed would not be one run; game_catch_test.gd.)
		m.ui.bridge.start_run()
		await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	m.game_loop.restart_run()
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	if m.ui.onboarding.has_method(&"skip"):
		m.ui.onboarding.skip()
	m.game_loop.set_protection(m.player, 1e6)
	kit.fly_bot(int(Paths.arg("sky_seed", "9")))
	kit.set_mode(&"climb")
	await kit.advance(3.0)
	kit.set_mode(&"cruise")
	kit.pilot.set(&"agl", 25.0)
	kit.orbit_radius = 90.0
	kit.cruise()
	if flight == &"travel":
		kit.fly_straight()
	await kit.advance(SETTLE_S)
	var counts: Array[int] = []
	var legs := 0
	for i in SAMPLE_S:
		if flight == &"travel" and i > 0 and fmod(float(i), LEG_S) == 0.0:
			# A new leg: 45-75 deg off, back towards the valley's middle
			# when far out.
			legs += 1
			var p := m.player.global_position
			var home := atan2(p.x, p.z)
			var h := float(kit.pilot.get(&"heading"))
			var turn := deg_to_rad(45.0 + 15.0 * (legs % 3))
			h = home if Vector2(p.x, p.z).length() > 380.0 else h + turn * (1.0 if legs % 2 == 0 else -1.0)
			kit.pilot.set(&"heading", h)
		await kit.advance(1.0)
		counts.append(_seen())
	var mean := 0.0
	var any := 0
	for c in counts:
		mean += c
		any += 1 if c > 0 else 0
	mean /= counts.size()
	var share := float(any) / counts.size()
	var show: Dictionary = m.ecosystem.show_info()
	var fl_rows := []
	for fl in m.ecosystem.get_flocks():
		fl_rows.append("%s %s x%d mood %d mood_t %.0f d %.0f" % [fl.kind, fl.species, fl.size(), fl.mood, fl.mood_time,
			fl.centroid().distance_to(m.player.global_position)])
	print("[integration] sky view %s %s flocks: %s" % [tier, flight, fl_rows])
	print("[integration] sky view %s %s: seen mean %.2f, >=1 in %.0f%% of %d s; npcs %d; show %s; counts %s" % [
		tier, flight, mean, share * 100.0, counts.size(), m.ecosystem.count(), show, counts])
	return {"mean": mean, "share": share, "counts": counts, "npcs": m.ecosystem.count(), "show": {"flocks": show["flocks"],
		"flock_birds": show["flock_birds"], "solos": show["solos"]}}


func test_birds_in_view_at_both_tiers() -> void:
	if not check(booted, "the game loaded"):
		return
	var res := {}
	for tier: StringName in [&"quest", &"full"]:
		for flight: StringName in [&"lap", &"travel"]:
			var r := await _fly(tier, flight)
			res["%s_%s" % [tier, flight]] = r
			gt(float(r["mean"]), float(MIN_MEAN[tier]), "%s tier, %s: %.2f birds a player notices in view on average (verifier: 0.05 full, 0.0 Quest)" % [
				tier, flight, r["mean"]])
			gt(float(r["share"]), float(MIN_SHARE[tier]), "%s tier, %s: at least one in %.0f%% of the seconds" % [tier, flight, float(r["share"]) * 100.0])
	metric("sky_view", res)
	# Back to the full game for any suite that runs after.
	QualityTier.new().apply_ecosystem(kit.main.ecosystem)
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())
