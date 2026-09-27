extends TestCase
## Depth-buffer headroom of the shipped valley on a Quest (integration round
## 1; the Quest verifier's finding, its probe tests/probes/integration/
## vrq_depth_test.gd made a regression test).
##
## Godot 4.7's Mobile renderer draws into a D24_UNORM_S8 depth buffer on the
## Quest (Adreno has D24; this Mac's MoltenVK does not and silently uses
## D32F, so no screenshot here can show it). With reverse-Z in a 24-bit
## fixed-point buffer one depth step at view depth z is z^2 / (near * 2^24).
## From real viewpoints of the composed valley at a sparrow's size (the
## smallest near plane the game uses), rays are cast through the collision
## geometry (for the valley's merged meshes it is the drawn geometry: MeshKit
## builds both from the same triangles; trees and a few props collide with
## simpler shapes); for each pixel the first surface and the next one behind
## it along the ray are found, and the pixel is at risk when their view-depth
## gap is under 2 depth steps.
##
## Two kinds of risk, told apart by the angle between the two surfaces:
##  * PARALLEL surfaces (within PARALLEL_DEG) a few centimetres apart - a
##    paving slab over the grass, a strip on a deck - fight over their whole
##    area: a flickering patch. None may do so between different bodies
##    under 300 m.
##  * surfaces that CROSS (a bank dipping under the water, a wall into the
##    ground, a ramp onto the street) only blur their crossing line, over a
##    band ~2 steps / tan(angle) wide - as in every renderer. The shallower
##    the crossing, the wider the band: the lake's and the river's banks
##    used to cross the water at ~6 deg. Their share of the view is bounded.
##
## Ten views: the verifier's five from the spawn, the street from 12 m up
## both ways and along its whole length from 30 and 45 m up (a grazing
## view: the paving at 0.1 m over the grass fought over 77 px there), and
## the lake from 25 m up on its shore.
##
## Pinned (at the sparrow's near plane, WorldScaleDriver.NEAR_K x its
## world_scale): the near plane is at least twice round 0's (0.03); no
## parallel pair of distinct bodies fights under 300 m in any view; the risk
## between distinct bodies under 300 m is under MAX_DISTINCT_300 of the view
## in every view (round 0's valley and near plane: 1.8 % in the view from
## 60 m up, mostly the street slab and the shores); water and bank never
## cross at under MIN_SHORE_DEG where they are at risk.
## Printed for the record: risk within one body (the crossing lines of its
## own parts - a tree's collider capsules, rails on posts), and round 0's
## near plane on today's valley.

const Kit := preload("res://tests/unit/integration/game_kit.gd")
const STEPS := 16777216.0
## Round 0's near plane factor (the verifier's measurement).
const OLD_NEAR_K := 0.03
## Surfaces whose normals are within this angle count as parallel.
const PARALLEL_DEG := 5.0
## Pixels (of those that hit geometry) at risk between distinct bodies under
## 300 m, per view.
const MAX_DISTINCT_300 := 0.005
## The shallowest water-bank crossing allowed where the two are at risk
## (deg): the banks now cross the water line at ~14-20 deg (a ~0.25-0.35
## slope; round 0's ~0.1 gave 10-12 deg crossings with ~2.5x wider bands).
const MIN_SHORE_DEG := 12.5

var kit: Kit
var booted := false


func before_all() -> void:
	kit = Kit.new()
	booted = await kit.boot(self)


func after_all() -> void:
	if kit:
		await kit.teardown()
	await wait_frames(5)


static func _owner(r: Dictionary) -> String:
	var c: Object = r.get("collider")
	if c == null or not (c is Node):
		return "?"
	var n := c as Node
	var p := n.get_parent()
	return "%s/%s" % [p.name if p else "", n.name]


func _scan(eye: Vector3, yaw: float, pitch: float, nears: Dictionary, w := 160, h := 120) -> Dictionary:
	var space := kit.main.get_world_3d().direct_space_state
	var basis := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch)
	var fwd := -basis.z
	var tan_h := tan(deg_to_rad(45.0))
	var tan_v := tan_h * float(h) / float(w)
	var out := {"hit_px": 0, "pairs_300": {}, "parallel_distinct_300": {}, "shore_min_deg": 90.0, "where": {}}
	for k in nears:
		out[k] = {"risk_px": 0, "risk_300_px": 0, "risk_300_distinct_px": 0, "parallel_300_px": 0,
			"parallel_300_distinct_px": 0}
	for j in h:
		for i in w:
			var u := ((i + 0.5) / w * 2.0 - 1.0) * tan_h
			var v := (1.0 - (j + 0.5) / h * 2.0) * tan_v
			var dir := (basis * Vector3(u, v, -1.0)).normalized()
			var r := space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, eye + dir * 2500.0, 1))
			if r.is_empty():
				continue
			out["hit_px"] += 1
			var p1: Vector3 = r["position"]
			var z1 := (p1 - eye).dot(fwd)
			var q2 := PhysicsRayQueryParameters3D.create(p1 + dir * 0.002, p1 + dir * 400.0, 1)
			q2.hit_back_faces = false
			var r2 := space.intersect_ray(q2)
			if r2.is_empty():
				continue
			var gap := ((r2["position"] as Vector3) - eye).dot(fwd) - z1
			var o1 := _owner(r)
			var o2 := _owner(r2)
			var distinct := o1 != o2
			var ang := rad_to_deg((r["normal"] as Vector3).angle_to(r2["normal"] as Vector3))
			var parallel := ang < PARALLEL_DEG
			var shore := (o1.contains("water_body") and o2.contains("terrain")) or (o2.contains("water_body") and o1.contains("terrain"))
			for k in nears:
				var step := z1 * z1 / (float(nears[k]) * STEPS)
				if gap >= 2.0 * step:
					continue
				out[k]["risk_px"] += 1
				if z1 >= 300.0:
					continue
				out[k]["risk_300_px"] += 1
				if distinct:
					out[k]["risk_300_distinct_px"] += 1
				if parallel:
					out[k]["parallel_300_px"] += 1
					if distinct:
						out[k]["parallel_300_distinct_px"] += 1
				if k != "game":
					continue
				var pair := "%s | %s" % [o1, o2]
				out["pairs_300"][pair] = int(out["pairs_300"].get(pair, 0)) + 1
				if parallel and distinct:
					out["parallel_distinct_300"][pair] = int(out["parallel_distinct_300"].get(pair, 0)) + 1
				if shore:
					out["shore_min_deg"] = minf(float(out["shore_min_deg"]), ang)
				var wl: Array = out["where"].get(pair, [])
				if wl.size() < 3:
					wl.append("p=(%.1f,%.2f,%.1f) z=%.0f gap=%.3f m (%.1f steps) angle %.0f deg" % [p1.x, p1.y, p1.z, z1, gap, gap / step, ang])
					out["where"][pair] = wl
	for k in nears:
		for key in ["risk_px", "risk_300_px", "risk_300_distinct_px", "parallel_300_px", "parallel_300_distinct_px"]:
			out[k][key.replace("_px", "_frac")] = float(out[k][key]) / maxf(out["hit_px"], 1.0)
	return out


## Integration hygiene (2026-09-27): the depth buffer's precision at every
## size the player flies, for the record (docs/INTEGRATION.md). One D24 step
## at view depth z is z^2 / (near x 2^24); two surfaces closer than two
## steps may fight. Per species (default arm span): world_scale, the near
## plane, the step at 10 / 30 / 100 / 300 / 1000 m, and the depth from which
## a gap of 1 mm / 1 cm / 5 cm / 20 cm / 1 m is within two steps.
func test_depth_precision_table() -> void:
	var rows := []
	for sp: StringName in [&"sparrow", &"swallow", &"starling", &"pigeon", &"crow", &"gull", &"hawk", &"eagle"]:
		var ws := WorldScaleDriver.target_scale(SizeRules.species_data(sp)["mass"], 1.5)
		var near := WorldScaleDriver.near_for(ws)
		var steps := []
		for z: float in [10.0, 30.0, 100.0, 300.0, 1000.0]:
			steps.append(snappedf(z * z / (near * STEPS) * 1000.0, 0.01))
		var fights := []
		for g: float in [0.001, 0.01, 0.05, 0.2, 1.0]:
			fights.append(roundi(sqrt(g * near * STEPS / 2.0)))
		rows.append({"species": sp, "world_scale": snappedf(ws, 0.001), "near_mm": snappedf(near * 1000.0, 0.1),
			"step_mm_at_10_30_100_300_1000m": steps, "fights_from_m_gap_1mm_1cm_5cm_20cm_1m": fights})
		print("[integration] depth table %-8s ws %.3f near %5.1f mm | step (mm) at 10/30/100/300/1000 m %s | a gap of 1 mm/1 cm/5 cm/20 cm/1 m fights from %s m" % [
			sp, ws, near * 1000.0, steps, fights])
	metric("depth_table", rows)
	# The table's premise: the near plane grows with the bird (so does the
	# precision), and the sparrow's is the worst.
	gt(float(rows[-1]["near_mm"]), float(rows[0]["near_mm"]) * 8.0, "an eagle's near plane is ~9x a sparrow's")


func test_depth_headroom_at_a_sparrows_near_plane() -> void:
	if not check(booted, "the game loaded"):
		return
	var m := kit.main
	var ws := WorldScaleDriver.target_scale(SizeRules.species_data(&"sparrow")["mass"], 1.6)
	var nears := {"game": WorldScaleDriver.near_for(ws), "old": OLD_NEAR_K * ws}
	gt(WorldScaleDriver.NEAR_K, 1.99 * OLD_NEAR_K, "the near plane is at least twice round 0's (%.3f x world_scale)" % WorldScaleDriver.NEAR_K)
	var spawn := m.world.get_player_spawn()
	var eye0 := m.player.camera.global_position
	var f := -spawn.basis.z
	var yaw0 := atan2(-f.x, -f.z)
	# The verifier's five views, the village street at a sparrow's cruising
	# height, and the lake from its western shore.
	var street := Vector3(-90.0, m.world.ground_height(-90.0, WorldLayout.STREET_Z) + 12.0, WorldLayout.STREET_Z)
	var lake := Vector3(WorldLayout.LAKE.x - 170.0, 25.0, WorldLayout.LAKE.y - 40.0)
	var to_lake := Vector3(WorldLayout.LAKE.x, 0.0, WorldLayout.LAKE.y) - Vector3(lake.x, 0.0, lake.z)
	var views := {
		"spawn_menu_view": [eye0, yaw0, deg_to_rad(-8.0)],
		"spawn_+60deg": [eye0, yaw0 + deg_to_rad(60.0), deg_to_rad(-8.0)],
		"spawn_-60deg": [eye0, yaw0 - deg_to_rad(60.0), deg_to_rad(-8.0)],
		"30m_up_down15": [eye0 + Vector3(0, 30, 0), yaw0, deg_to_rad(-15.0)],
		"60m_up_down25": [eye0 + Vector3(0, 60, 0), yaw0 + deg_to_rad(120.0), deg_to_rad(-25.0)],
		"street_12m_east": [street, deg_to_rad(-90.0), deg_to_rad(-12.0)],
		"street_12m_west": [street + Vector3(40, 0, 0), deg_to_rad(90.0), deg_to_rad(-12.0)],
		"lake_25m": [lake, atan2(-to_lake.x, -to_lake.z), deg_to_rad(-10.0)],
		# Along the whole street from 30 m over its west end: the paving seen
		# at a grazing angle out to ~240 m (0.1 m of paving fought here).
		"street_30m_along": [Vector3(WorldLayout.STREET_X0, m.world.ground_height(WorldLayout.STREET_X0, WorldLayout.STREET_Z) + 30.0,
			WorldLayout.STREET_Z), deg_to_rad(-90.0), deg_to_rad(-9.0)],
		"street_45m_along": [Vector3(WorldLayout.STREET_X0 - 20.0, m.world.ground_height(WorldLayout.STREET_X0, WorldLayout.STREET_Z) + 45.0,
			WorldLayout.STREET_Z), deg_to_rad(-90.0), deg_to_rad(-12.0)],
	}
	var res := {"nears": nears, "views": {}}
	var shore_min := 90.0
	for name: String in views:
		var v: Array = views[name]
		var r := _scan(v[0], v[1], v[2], nears)
		var g: Dictionary = r["game"]
		var o: Dictionary = r["old"]
		res["views"][name] = {"game": g, "old": o, "hit_px": r["hit_px"], "parallel_distinct_300": r["parallel_distinct_300"],
			"shore_min_deg": r["shore_min_deg"]}
		shore_min = minf(shore_min, float(r["shore_min_deg"]))
		print("[integration] depth %-16s under 300 m: distinct bodies %.4f (round 0's near %.4f), parallel distinct %d px, within one body %.4f; all pairs, all distances %.4f; shore crossings >= %.0f deg" % [
			name, g["risk_300_distinct_frac"], o["risk_300_distinct_frac"], g["parallel_300_distinct_px"],
			float(g["risk_300_frac"]) - float(g["risk_300_distinct_frac"]), g["risk_frac"], r["shore_min_deg"]])
		if Paths.arg("depth_where", "") != "":
			for pw: String in r["where"]:
				if not pw.begins_with("tree_bodies"):
					print("[integration]   %s: %s" % [pw, r["where"][pw]])
		eq(int(g["parallel_300_distinct_px"]), 0, "%s: no parallel surfaces of distinct bodies fight under 300 m (%s)" % [
			name, r["parallel_distinct_300"]])
		lt(float(g["risk_300_distinct_frac"]), MAX_DISTINCT_300, "%s: risk between distinct bodies under 300 m %.4f of the view (round 0's near plane: %.4f)" % [
			name, g["risk_300_distinct_frac"], o["risk_300_distinct_frac"]])
	gt(shore_min, MIN_SHORE_DEG, "the banks cross the water at %.1f deg or more where they are at risk" % shore_min)
	metric("depth", res)
	metric("shore_min_deg", shore_min)
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())
