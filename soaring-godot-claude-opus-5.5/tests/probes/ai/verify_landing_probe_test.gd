extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (ai, round 1) - not part of the area suite.
## The last leg of a perch landing drops the bird straight down onto the
## perch (npc_bird.gd _flare -> Basis.looking_at(dir, UP) with a vertical
## dir). Measures what the body does meanwhile: nose-down pitch during the
## flare and the orientation snap on the tick it becomes perched. A good
## landing keeps the body roughly level and never snaps.
##
##   tools/gd.sh ai_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/ai --suite=landing


func test_probe_landing_leg_keeps_body_level_and_does_not_snap() -> void:
	await make_world(false, 1)
	var wires: Array[Perch] = []
	for p in world.get_perches():
		if p.kind == Perch.Kind.WIRE and p.is_free():
			wires.append(p)
	var wire: Perch = wires[10]
	var out := {}
	for sp: StringName in [&"sparrow", &"starling", &"hawk"]:
		var b := spawn(sp, wire.position + Vector3(40, 12, 30), Vector3(-8, 0, -6))
		b.energy = 0.15
		b.hunger = 0.0
		b.can_hunt = false
		var m := {"max_pitch": 0.0, "steep_ticks": 0, "snap": -1.0, "prev": b.global_basis.orthonormalized(), "landed": false, "t": -1.0}
		run(40.0, func(i: int) -> bool:
			var bs := b.global_basis.orthonormalized()
			var fwd := -bs.z
			if b.is_flaring():
				# Nose-down pitch in degrees (positive = beak below the horizon).
				var pitch := rad_to_deg(asin(clampf(-fwd.y, -1.0, 1.0)))
				m["max_pitch"] = maxf(m["max_pitch"], pitch)
				if pitch > 60.0:
					m["steep_ticks"] += 1
			if b.perched and not m["landed"]:
				m["landed"] = true
				m["t"] = i * DT
				var prev: Basis = m["prev"]
				m["snap"] = rad_to_deg(prev.get_rotation_quaternion().angle_to(bs.get_rotation_quaternion()))
			m["prev"] = bs
			return m["landed"])
		out[String(sp)] = {"landed_at_s": snappedf(m["t"], 0.01), "max_nose_down_deg": snappedf(m["max_pitch"], 0.1),
			"ticks_nose_down_over_60deg": m["steep_ticks"], "snap_on_touchdown_deg": snappedf(m["snap"], 0.1)}
		check(m["landed"], "%s landed" % sp)
		lt(m["max_pitch"], 60.0, "%s body pitch during the landing flare stays under 60 deg nose-down" % sp)
		lt(m["snap"], 30.0, "%s orientation does not snap on touchdown (deg in one tick)" % sp)
		despawn(b)
		await wait_frames(1)
	metric("landing", out)
	print("[ai-verify] landing orientation: ", out)
	await clear_sim()
