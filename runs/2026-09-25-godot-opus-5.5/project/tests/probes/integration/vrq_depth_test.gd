extends TestCase
## VERIFIER PROBE (integration verify round 1, Quest-readiness lens). Not
## part of any area suite. Depth-buffer headroom of the shipped game on a
## Quest: Godot's Mobile renderer prefers a D24_UNORM_S8 depth buffer
## (RenderSceneBuffersRD::get_depth_format, non-storage path) which Adreno
## supports, while this Mac (MoltenVK on Apple silicon) has no D24 and falls
## back to D32_SFLOAT, so neither the desktop nor the simulator shows D24's
## precision. With reverse-Z in a 24-bit UNORM buffer one depth step at view
## depth z is about z^2 / (near * 2^24). The game's near plane is
## 0.03 x world_scale (0.0043 m for a sparrow).
##
## From real viewpoints of the composed valley (head camera, 90 deg view),
## rays are cast through the collision geometry (terrain, water, buildings,
## rocks: what has colliders); for each pixel ray the first surface and the
## next surface behind it along the same ray are found, and the pixel is
## counted as a z-fight risk when their view-depth gap is under 2 depth
## steps at the sparrow's near plane (and, for comparison, an eagle's and a
## 0.10 x world_scale near plane). Visual-only details (trims, frames,
## decals) have no colliders and are not counted, so this is a lower bound.
##
##   tools/gd.sh vrq --headless --fixed-fps 72 res://tests/runner.tscn -- --dir=res://tests/probes/integration --suite=vrq_depth --fresh-settings

const Kit := preload("res://tests/unit/integration/game_kit.gd")
const STEPS := 16777216.0

var kit: Kit
var booted := false


func before_all() -> void:
	kit = Kit.new()
	booted = await kit.boot(self)


func after_all() -> void:
	if kit:
		await kit.teardown()
	await wait_frames(5)


func _scan(eye: Vector3, yaw: float, pitch: float, nears: Dictionary, w := 160, h := 120) -> Dictionary:
	var space := kit.main.get_world_3d().direct_space_state
	var basis := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch)
	var fwd := -basis.z
	var tan_h := tan(deg_to_rad(45.0))
	var tan_v := tan_h * float(h) / float(w)
	var out := {}
	for k in nears:
		out[k] = {"risk_px": 0, "by_band": {}}
	var hits := 0
	var gaps := []
	for j in h:
		for i in w:
			var u := ((i + 0.5) / w * 2.0 - 1.0) * tan_h
			var v := (1.0 - (j + 0.5) / h * 2.0) * tan_v
			var dir := (basis * Vector3(u, v, -1.0)).normalized()
			var q := PhysicsRayQueryParameters3D.create(eye, eye + dir * 2500.0, 1)
			var r := space.intersect_ray(q)
			if r.is_empty():
				continue
			hits += 1
			var p1: Vector3 = r["position"]
			var z1 := (p1 - eye).dot(fwd)
			var q2 := PhysicsRayQueryParameters3D.create(p1 + dir * 0.002, p1 + dir * 400.0, 1)
			q2.hit_back_faces = false
			q2.exclude = []
			var r2 := space.intersect_ray(q2)
			if r2.is_empty():
				continue
			var p2: Vector3 = r2["position"]
			var z2 := (p2 - eye).dot(fwd)
			var gap := z2 - z1
			for k in nears:
				var n: float = nears[k]
				var step := z1 * z1 / (n * STEPS)
				if gap < 2.0 * step:
					out[k]["risk_px"] += 1
					if z1 < 400.0 and String(k) == "sparrow_near_0.03ws":
						var pair := "%s | %s" % [_owner(r), _owner(r2)]
						if not out.has("pairs_under_400m"):
							out["pairs_under_400m"] = {}
						out["pairs_under_400m"][pair] = int(out["pairs_under_400m"].get(pair, 0)) + 1
					var band := "%d-%d m" % [int(z1 / 100.0) * 100, int(z1 / 100.0) * 100 + 100]
					out[k]["by_band"][band] = int(out[k]["by_band"].get(band, 0)) + 1
	for k in nears:
		out[k]["risk_frac"] = float(out[k]["risk_px"]) / maxf(hits, 1.0)
	out["hit_px"] = hits
	return out


static func _owner(r: Dictionary) -> String:
	var c: Object = r.get("collider")
	if c == null or not (c is Node):
		return "?"
	var n := c as Node
	var p := n.get_parent()
	return "%s/%s" % [p.name if p else "", n.name]


func test_depth_headroom_on_a_quest() -> void:
	if not check(booted, "the game loaded"):
		return
	var m := kit.main
	var arm := 1.5
	var ws_sparrow := WorldScaleDriver.target_scale(0.03, arm)
	var ws_eagle := WorldScaleDriver.target_scale(3.0, arm)
	var nears := {"sparrow_near_0.03ws": WorldScaleDriver.NEAR_K * ws_sparrow, "eagle_near_0.03ws": WorldScaleDriver.NEAR_K * ws_eagle,
		"sparrow_near_0.10ws": 0.10 * ws_sparrow}
	var spawn := m.world.get_player_spawn()
	var eye0 := m.player.camera.global_position
	var f := -spawn.basis.z
	var yaw0 := atan2(-f.x, -f.z)
	var views := {
		"spawn_menu_view": [eye0, yaw0, deg_to_rad(-8.0)],
		"spawn_+60deg": [eye0, yaw0 + deg_to_rad(60.0), deg_to_rad(-8.0)],
		"spawn_-60deg": [eye0, yaw0 - deg_to_rad(60.0), deg_to_rad(-8.0)],
		"30m_up_down15": [eye0 + Vector3(0, 30, 0), yaw0, deg_to_rad(-15.0)],
		"60m_up_down25": [eye0 + Vector3(0, 60, 0), yaw0 + deg_to_rad(120.0), deg_to_rad(-25.0)],
	}
	var res := {"nears": nears, "views": {}}
	for name: String in views:
		var v: Array = views[name]
		res["views"][name] = _scan(v[0], v[1], v[2], nears)
	metric("depth", res)
	print("[integration-verify] depth ", JSON.stringify(res))
	check(true, "measured")
