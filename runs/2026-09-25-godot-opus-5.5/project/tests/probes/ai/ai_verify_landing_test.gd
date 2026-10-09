extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (visual/VR quality of perching): the landing flare's last
## leg drops straight down onto the perch. _flare() builds
## Basis.looking_at(dir, UP) with a vertical dir (colinear with UP), which
## logs a warning every tick and yields a degenerate "beak straight down"
## basis; land_on() then snaps the body level. Measure it: the per-tick
## body rotation (deg) through the landing and at the land_on tick, and the
## lowest beak direction (forward.y) during the flare.

func test_landing_has_no_nose_dive_or_snap() -> void:
	await make_world(false, 1)
	var h := Habitat.for_world(world)
	var rows := []
	var worst_step := 0.0
	var worst_land := 0.0
	var min_fy := 1.0
	var landed := 0
	var tried := 0
	for sp in [&"sparrow", &"starling", &"swallow", &"wren", &"hawk"]:
		for trial in 3:
			var span := SizeRules.species_data(sp)["span"] as float
			var kinds: Array = SpeciesProfile.of(sp)["perch_kinds"]
			var list := h.find_perches(Vector3.ZERO, 900.0, span, kinds)
			if list.is_empty():
				continue
			var p: Perch = list[(trial * 7 + sp.length()) % list.size()]
			var start := p.position + Vector3(18.0, 4.0, 10.0)
			start.y = maxf(start.y, h.ground(start.x, start.z) + 3.0)
			var b := spawn(sp, start, (p.position - start).normalized() * 8.0)
			b.energy = 0.05
			b.can_hunt = false
			b.can_flee = false
			tried += 1
			b.brain._enter(NpcBird.State.PERCH)
			var prev := b.global_basis.orthonormalized().get_rotation_quaternion()
			var m := {"step": 0.0, "land": 0.0, "fy": 1.0, "up": 1.0, "was": false}
			run(40.0, func(_i: int) -> bool:
				var q := b.global_basis.orthonormalized().get_rotation_quaternion()
				var ang := rad_to_deg(prev.angle_to(q))
				prev = q
				if b.perched and not m["was"]:
					m["land"] = ang
					m["was"] = true
					return true
				if b.is_flaring():
					m["step"] = maxf(m["step"], ang)
					m["fy"] = minf(m["fy"], b.get_forward().y)
					m["up"] = minf(m["up"], b.global_basis.y.normalized().y)
				return false)
			if m["was"]:
				landed += 1
				worst_step = maxf(worst_step, m["step"])
				worst_land = maxf(worst_land, m["land"])
				min_fy = minf(min_fy, m["fy"])
			rows.append("%s on %s: landed=%s max step %.1f deg, land snap %.1f deg, min beak y %.2f, min up.y %.2f" % [sp, Perch.Kind.keys()[p.kind], m["was"], m["step"], m["land"], m["fy"], m["up"]])
			despawn(b)
			await wait_frames(1)
	for r in rows:
		print("[ai-verify] ", r)
	metric("landing", {"tried": tried, "landed": landed, "worst_step_deg": worst_step, "worst_land_snap_deg": worst_land, "min_beak_y": min_fy})
	gt(landed, tried * 0.6, "most birds landed")
	lt(worst_land, 25.0, "no visible snap (>25 deg in one tick) when the bird settles on the perch")
	gt(min_fy, -0.7, "the beak never points more than ~45 deg down during a gentle landing flare")
	await clear_sim()
