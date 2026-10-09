extends "res://tests/unit/ai/ai_sim.gd"
## Perch landings and take-offs as a viewer sees them (VR, a bird landing
## next to the player): the body must never point its beak at the ground,
## never flip in one frame, and settle onto the perch's facing; the engine
## must not warn about anything on the way (the last metre onto a perch is a
## vertical drop - it used to feed Basis.looking_at a target colinear with
## UP: a beak-down dart, a 100-170 deg snap on touchdown and a warning every
## tick).
##
## For each species/perch kind, three approach directions: tired bird ->
## lands -> sits 1.5 s -> a hawk hunts it from the direction it faces ->
## it takes off away from the hawk (a take-off against its facing).

const WarningLog := preload("res://tests/unit/ai/warning_log.gd")
## (species, perch kind, start centre) - starts are offset around the perch.
const CASES := [
	[&"sparrow", Perch.Kind.WIRE],
	[&"starling", Perch.Kind.WIRE],
	[&"wren", Perch.Kind.BRANCH],
	[&"pigeon", Perch.Kind.ROOF],
	[&"hawk", Perch.Kind.POLE_TOP],
	[&"gull", Perch.Kind.ROCK],
]
## Largest body rotation between two consecutive physics ticks, degrees.
const MAX_STEP_DEG := 15.0
## Steepest nose-down attitude allowed during a landing flare, degrees.
const MAX_NOSE_DOWN_DEG := 45.0


func before_all() -> void:
	await make_world(false, 1)


func after_all() -> void:
	await clear_sim()


func _perch_of(kind: Perch.Kind, span: float) -> Perch:
	for p in world.get_perches():
		if p.kind == kind and p.is_free() and p.fits(span) and not Habitat.for_world(world).is_enclosed(p):
			return p
	return null


static func _angle_deg(a: Quaternion, b: Quaternion) -> float:
	return rad_to_deg(a.angle_to(b))


func test_landings_and_take_offs_never_snap_or_dive_beak_first() -> void:
	var log: Logger = WarningLog.install()
	var table := {}
	var worst := {"step": 0.0, "nose": 0.0, "touch": 0.0, "settle": 0.0, "takeoff": 0.0}
	var landed := 0
	var n := 0
	for cs in CASES:
		var sp: StringName = cs[0]
		var span := SizeRules.wingspan_for_mass(SizeRules.species_data(sp)["mass"])
		var target := _perch_of(cs[1], span)
		check(target != null, "test world has a free %s perch for a %s" % [Perch.Kind.keys()[cs[1]], sp])
		if target == null:
			continue
		# Three approach directions, each twice: as a loose bird and with a
		# tick phase the Ecosystem gives the birds it spawns
		# (NpcBird.set_tick_phase; integration round 1: with one, a sparrow
		# came down steeply onto a low perch and entered its flare 45 deg
		# nose-down).
		for k in 6:
			n += 1
			var a := TAU * (k % 3) / 3.0 + 0.4
			var start := target.position + Vector3(cos(a) * 45.0, 12.0, sin(a) * 45.0)
			start.y = maxf(start.y, world.ground_height(start.x, start.z) + 10.0)
			var to := target.position - start
			to.y = 0.0
			var b := spawn(sp, start, to.normalized() * SizeRules.performance(SizeRules.species_data(sp)["mass"])["cruise"])
			if k >= 3:
				b.set_tick_phase(k)
			b.energy = 0.12
			b.hunger = 0.0
			b.can_hunt = false
			b.can_flee = false
			var m := {"q": b.global_basis.get_rotation_quaternion(), "step": 0.0, "nose": 0.0, "touch": -1.0,
				"t_land": -1.0, "settle": 180.0, "flared": false}
			var trace := OS.get_environment("AI_TRACE") != ""
			var hist: Array[String] = []
			run(45.0, func(i: int) -> bool:
				if trace and i % 6 == 0:
					hist.append("t=%.2f p=%s v=%s st=%s ph=%d fl=%s want=%s ws=%.1f brake=%.0f slots=%d ahead=%.1f near=%s geo=%d perch=%s" % [i * DT,
						b.global_position.snapped(Vector3.ONE * 0.01), b.velocity.snapped(Vector3.ONE * 0.1), b.state_name(), b.brain._perch_phase,
						b.is_flaring(), b.want_dir.snapped(Vector3.ONE * 0.01), b.want_speed, b.want_brake, b.brain._ob_p.size(),
						b.brain._ahead_d, b.near_geometry, b.geo_hits, (b.perch_spot.position.snapped(Vector3.ONE * 0.01) if b.perch_spot else Vector3.ZERO)])
				var q := b.global_basis.get_rotation_quaternion()
				var step := _angle_deg(m["q"], q)
				m["step"] = maxf(m["step"], step)
				m["q"] = q
				if b.is_flaring():
					m["flared"] = true
					var fwd := -b.global_basis.z
					m["nose"] = maxf(m["nose"], rad_to_deg(asin(clampf(-fwd.y, -1.0, 1.0))))
				if b.perched and m["t_land"] < 0.0:
					m["t_land"] = i * DT
					m["touch"] = step
				if m["t_land"] >= 0.0 and i * DT > m["t_land"] + 1.5:
					var f := -b.global_basis.z
					m["settle"] = rad_to_deg(Vector3(f.x, 0.0, f.z).normalized().angle_to(b.perch_spot.facing))
					return true
				return false)
			var ok: bool = m["t_land"] >= 0.0
			landed += 1 if ok else 0
			if trace and (not ok or m["nose"] > MAX_NOSE_DOWN_DEG):
				print("[ai-trace] %s approach %d: landed %s nose %.1f target %s" % [sp, k, ok, m["nose"], target.position])
				for line in hist.slice(0, 400):
					print("[ai-trace]   ", line)
			var row := {"landed_s": snappedf(m["t_land"], 0.01), "max_step_deg": snappedf(m["step"], 0.1),
				"max_nose_down_deg": snappedf(m["nose"], 0.1), "touchdown_deg": snappedf(m["touch"], 0.1),
				"facing_err_deg": snappedf(m["settle"], 0.1)}
			if ok:
				worst["step"] = maxf(worst["step"], m["step"])
				worst["nose"] = maxf(worst["nose"], m["nose"])
				worst["touch"] = maxf(worst["touch"], m["touch"])
				worst["settle"] = maxf(worst["settle"], m["settle"])
				# Take-off against its facing: a hawk comes at it from the front
				# - or from as near the front as has a clear line to the bird
				# (a wren may sit under a canopy: a hawk that cannot get at it
				# is rightly ignored, and would test nothing).
				var face := b.perch_spot.facing
				var hawk_sp := &"eagle" if sp == &"hawk" or sp == &"gull" else &"hawk"
				var from := face * 30.0 + Vector3.UP * 6.0
				var hab := Habitat.for_world(world)
				for j in 16:
					var dir := face.rotated(Vector3.UP, (0.5 * float((j + 1) / 2)) * (1.0 if j % 2 == 1 else -1.0))
					var cand := dir * 30.0 + Vector3.UP * (6.0 if j < 8 else 14.0)
					if hab.ray(b.global_position + Vector3.UP * 0.3, b.global_position + cand).is_empty():
						from = cand
						break
				var hawk := spawn(hawk_sp, b.global_position + from, -from.normalized() * 15.0)
				hawk.can_flee = false
				hawk.hunger = 1.0
				hawk.brain._pending_prey = b
				hawk.brain._enter(NpcBird.State.HUNT)
				b.can_flee = true
				var t := {"q": b.global_basis.get_rotation_quaternion(), "step": 0.0, "off": false}
				run(2.0, func(_i: int) -> bool:
					var q := b.global_basis.get_rotation_quaternion()
					if not b.perched:
						t["off"] = true
					if t["off"]:
						t["step"] = maxf(t["step"], _angle_deg(t["q"], q))
					t["q"] = q
					return not b.alive)
				check(t["off"], "%s took off from the approaching %s" % [sp, hawk_sp])
				row["takeoff_max_step_deg"] = snappedf(t["step"], 0.1)
				worst["takeoff"] = maxf(worst["takeoff"], t["step"])
				despawn(hawk)
			table["%s_%d" % [sp, k]] = row
			check(ok, "%s landed on a %s (approach %d)" % [sp, Perch.Kind.keys()[cs[1]], k])
			despawn(b)
		await wait_frames(1)
	log.uninstall()
	metric("landings", table)
	metric("worst", worst)
	print("[ai] landing worst: %s" % worst)
	gt(landed, n - 1, "every approach ended on the perch")
	lt(worst["nose"], MAX_NOSE_DOWN_DEG, "beak never points steeply at the ground in a landing flare (deg)")
	lt(worst["step"], MAX_STEP_DEG, "no body rotation over %.0f deg between two ticks, approach to perched (deg)" % MAX_STEP_DEG)
	lt(worst["touch"], MAX_STEP_DEG, "no snap on the touchdown tick (deg)")
	lt(worst["settle"], 5.0, "settled onto the perch's facing 1.5 s after landing (deg)")
	lt(worst["takeoff"], MAX_STEP_DEG, "no snap when taking off against its facing (deg)")
	eq(log.warnings + log.errors, 0, "no engine warnings or errors during landings and take-offs %s" % str(log.samples))
