extends TestCase
## DIAGNOSTIC (integration round 1, not in the unit suites): where the NPCs
## are relative to a cruising player's view (the experience verifier's
## "empty sky" finding). Every second: each NPC's range, bearing from the
## flight direction, elevation from the head's level, state and role; the
## count inside a 106 x 90 deg view straight ahead and how many of those
## span >= 0.37 deg (4 px at 1280x960 / 90 deg).
##
##   tools/gd.sh fx_diag --headless --fixed-fps 72 res://tests/runner.tscn -- --dir=res://tests/shots --suite=integration_diag_sky --fresh-settings [--quality=quest] [--nav=orbit|heading]

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var kit: Kit


func before_all() -> void:
	kit = Kit.new()
	check(await kit.boot(self), "the game loaded")


func after_all() -> void:
	if kit:
		await kit.teardown()
	await wait_frames(5)


func test_sky_census() -> void:
	var m := kit.main
	check(await kit.click(&"main", &"play"), "Play")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	m.ui.onboarding.skip()
	m.game_loop.set_protection(m.player, 1e6)
	kit.fly_bot(9)
	kit.set_mode(&"climb")
	await kit.advance(3.0)
	kit.set_mode(&"cruise")
	kit.orbit_radius = 90.0
	kit.pilot.set(&"agl", 25.0)
	if Paths.arg("nav", "orbit") == "heading":
		kit.fly_straight()
	await kit.advance(30.0)
	var tan_h := tan(deg_to_rad(53.0))
	var tan_v := tan(deg_to_rad(45.0))
	var sums := {"in_view": 0.0, "vis": 0.0, "front": 0.0, "within60": 0.0, "n": 0.0}
	var states := {}
	var roles := {}
	var bearings := []
	var vis_by := {}
	var show_rows := []
	for i in 30:
		await kit.advance(1.0)
		var cam := m.player.camera.global_transform
		var eye := cam.origin
		var v := m.player.velocity
		var fdir := Vector3(v.x, 0.0, v.z).normalized()
		# The head straight ahead along the flight direction, 5 deg down.
		var basis := Basis.looking_at(fdir, Vector3.UP) * Basis(Vector3.RIGHT, deg_to_rad(-5.0))
		for b in m.ecosystem.get_npcs():
			if not is_instance_valid(b) or not b.alive:
				continue
			var rel := b.global_position - eye
			var d := rel.length()
			var loc := basis.inverse() * rel
			var brg := rad_to_deg(atan2(rel.x * -fdir.z + rel.z * fdir.x, rel.dot(fdir)))
			sums["n"] += 1.0
			if loc.z < 0.0:
				sums["front"] += 1.0
			if d < 60.0:
				sums["within60"] += 1.0
			var st: String = b.state_name() + ("/hidden" if b.hidden else "")
			states[st] = int(states.get(st, 0)) + 1
			var role := String(m.ecosystem._role_of(m.ecosystem._npc_key.get(b.get_instance_id(), b.species)))
			roles[role] = int(roles.get(role, 0)) + 1
			if i % 10 == 0:
				bearings.append([snappedf(d, 1.0), snappedf(brg, 1.0), snappedf(rad_to_deg(atan2(rel.y, Vector2(rel.x, rel.z).length())), 1.0), st, role, String(b.species)])
			if b.hidden or loc.z >= -0.1:
				continue
			if absf(loc.x / -loc.z) > tan_h or absf(loc.y / -loc.z) > tan_v:
				continue
			sums["in_view"] += 1.0
			if b.get_wingspan() / maxf(d, 0.01) >= deg_to_rad(0.37):
				sums["vis"] += 1.0
				var shown := m.ecosystem._show_solos.has(b) or (b.flock != null and m.ecosystem._show_flocks.has(b.flock))
				var vk := "%s/%s%s" % [b.species, role, "/show" if shown else ""]
				vis_by[vk] = int(vis_by.get(vk, 0)) + 1
	for k in ["in_view", "vis", "front", "within60"]:
		sums[k] = snappedf(sums[k] / 30.0, 0.01)
	print("[integration] sky census (per second): %s" % sums)
	print("[integration] visible by species/role: %s" % vis_by)
	print("[integration] show: %s" % m.ecosystem.show_info())
	for b in m.ecosystem._show_solos:
		print("[integration]   show solo %s %s d %.0f state %s" % [b.species, m.ecosystem._role_of(m.ecosystem._npc_key.get(b.get_instance_id(), b.species)), b.global_position.distance_to(m.player.global_position), b.state_name()])
	for fl in m.ecosystem._show_flocks:
		print("[integration]   show flock %s x%d d %.0f mood %d" % [fl.species, fl.size(), fl.centroid().distance_to(m.player.global_position), fl.mood])
	print("[integration] states: %s" % states)
	print("[integration] roles: %s" % roles)
	print("[integration] focus %s sky %.0f travelling %s area_r %.0f player %s" % [m.ecosystem.focus_point(), m.ecosystem.sky_radius(),
		m.ecosystem.travelling(), m.ecosystem._area_r, m.player.global_position])
	bearings.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	for row in bearings.slice(0, 60):
		print("[integration]   d %s brg %s elev %s %s %s %s" % row)
