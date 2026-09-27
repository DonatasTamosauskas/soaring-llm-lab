extends TestCase
## Verifier probes (round 1, flight): F10 continuous collision against the
## shape types the real World uses (CapsuleShape3D wires/twigs from MeshKit,
## ConcavePolygonShape3D trimesh walls) plus cylinders and thin boxes, at
## V_max, for sparrow / pigeon / eagle, straight, diagonal and grazing, with
## random offsets, and with a 50 ms physics hitch.

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const DEG := PI / 180.0
const DT := 1.0 / 72.0

var fx: FX
var _lines := PackedStringArray()


func after_each() -> void:
	if fx != null:
		fx.teardown()
		fx = null
	await get_tree().process_frame


func after_all() -> void:
	var path := Paths.artifacts("flight").path_join("verify").path_join("collision_probe.txt")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(_lines))


static func _capsule_body(parent: Node, a: Vector3, b: Vector3, r: float) -> StaticBody3D:
	# Exactly how MeshKit.add_capsule builds world wires and twigs.
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var d := b - a
	var l := d.length()
	var cap := CapsuleShape3D.new()
	cap.radius = r
	cap.height = l + 2.0 * r
	var yv := d / l
	var ref := Vector3.RIGHT if absf(yv.x) < 0.9 else Vector3.FORWARD
	var xv := yv.cross(ref).normalized()
	var zv := xv.cross(yv)
	var o := body.create_shape_owner(body)
	body.shape_owner_add_shape(o, cap)
	body.shape_owner_set_transform(o, Transform3D(Basis(xv, yv, zv), (a + b) * 0.5))
	parent.add_child(body)
	return body


static func _trimesh_panel(parent: Node, center: Vector3, size: Vector3) -> StaticBody3D:
	# A closed thin box as a trimesh (ConcavePolygonShape3D), like MeshKit's
	# building colliders.
	var bm := BoxMesh.new()
	bm.size = size
	var faces := bm.get_faces()
	for i in faces.size():
		faces[i] += center
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var sh := ConcavePolygonShape3D.new()
	sh.set_faces(faces)
	var o := body.create_shape_owner(body)
	body.shape_owner_add_shape(o, sh)
	parent.add_child(body)
	return body


## Fly the real PlayerBird at `vel` from `start` for `secs`; `inside` returns the
## penetration depth of the body sphere (> 0 = inside / through) for a position.
func _shot(sp: StringName, build: Callable, start: Vector3, vel: Vector3, secs: float, inside: Callable,
		hitch_at := -1) -> Dictionary:
	fx = FX.new(self)
	await fx.setup(sp, func(w: Variant) -> void:
		w.with_ground = false
		build.call(w))
	var p := fx.player
	var yaw := FlightMath.yaw_of(vel) if Vector2(vel.x, vel.z).length() > 0.1 else 0.0
	p.start_flying(start, yaw, 0.0)
	p.model.reset(start, vel, yaw)
	p.model.theta = clampf(atan2(vel.y, Vector2(vel.x, vel.z).length()), -PI / 2, PI / 2)
	fx.driver = func(_tick: int, _t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		b.synth(-1.0, 0.0, 0.0, p.wing_input.calibration)
	var out := {"worst": -INF, "stunned": false, "stun_s": 0.0, "slid": false, "contacts": {}}
	var n := int(round(secs / DT))
	for i in n:
		var dt := 0.05 if i == hitch_at else DT
		p.tick(dt)
		var d: float = inside.call(p.model.position, p.model.params.r_body)
		out["worst"] = maxf(out["worst"], d)
		if p.mode == PlayerBird.Mode.STUNNED:
			out["stunned"] = true
			out["stun_s"] += dt
		if p.last_contact == PlayerBird.Contact.SLIDE:
			out["slid"] = true
	out["contacts"] = p.contacts.duplicate()
	out["v_max"] = p.model.params.v_max
	fx.teardown()
	fx = null
	return out


static func _rod_depth(a: Vector3, u: Vector3, r_rod: float) -> Callable:
	return func(pos: Vector3, r_body: float) -> float:
		var d := pos - a
		var perp := (d - u * d.dot(u)).length()
		return (r_body + r_rod) - perp


func test_f10_thin_rods_all_sizes_vmax() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 2024
	var shapes := [["capsule twig r1cm", 0.01, true], ["capsule wire r6mm", 0.006, true], ["capsule wire r3mm", 0.003, true],
		["cylinder r3mm", 0.003, false]]
	var fails := 0
	var runs := 0
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		for shp in shapes:
			for k in 6:
				var r_rod: float = shp[1]
				var a := Vector3(-3, 100, 0)
				var b := Vector3(3, 100, 0)
				var r_body := SizeRules.body_radius_for_mass(FlightParams.species_mass(sp))
				var v_max: float = FlightModel.new(FlightParams.species_mass(sp)).params.v_max
				# Direction: vertical dive, horizontal, 45 deg; offset across the rod.
				var dir: Vector3
				match k % 3:
					0:
						dir = Vector3.DOWN
					1:
						dir = Vector3(0, 0, -1)
					_:
						dir = Vector3(0, -1, -1).normalized()
				var off := rng.randf_range(-0.9, 0.9) * (r_body + r_rod)
				var across := dir.cross(Vector3.RIGHT).normalized()
				# 0.12 s lead; the zero-lift bird falls 0.5 g t^2 on the way in, so
				# aim that much high (a vertical dive needs no correction).
				var lead := 0.12
				# Gravity's sideways share over the lead (its along-path share only
				# shifts the arrival time).
				var sag := (Vector3.UP - dir * dir.y) * (0.5 * 9.81 * lead * lead)
				var start := Vector3(rng.randf_range(-1, 1), 100, 0) + sag - dir * (v_max * lead) + across * off
				var build := func(w: Variant) -> void:
					if shp[2]:
						_capsule_body(w, a, b, r_rod)
					else:
						w.add_rod(a, b, r_rod)
				# The hitch (a 50 ms physics step) lands on the crossing tick.
				var hitch := int(lead / DT) - 1 if k >= 3 else -1
				var res: Dictionary = await _shot(sp, build, start, dir * v_max, 1.0, _rod_depth(a, Vector3.RIGHT, r_rod), hitch)
				runs += 1
				var ok: bool = res["worst"] < 0.001
				if not ok:
					fails += 1
				_lines.append("%s %s dir %s off %.3f hitch %s: worst penetration %.4f m, stunned %s (%.2f s), slid %s, contacts %s" % [
					sp, shp[0], str(dir.snapped(Vector3.ONE * 0.01)), off, str(hitch >= 0), res["worst"], str(res["stunned"]), res["stun_s"],
					str(res["slid"]), str(res["contacts"])])
				lt(res["worst"], 0.001, "%s %s at V_max (dir %s, offset %.3f, hitch %s): never inside the rod" % [sp, shp[0], str(dir.snapped(Vector3.ONE * 0.01)), off, str(hitch >= 0)])
				var touched: int = res["contacts"]["stun"] + res["contacts"]["slide"] + res["contacts"]["silent"]
				check(touched > 0, "%s %s (dir %s, offset %.3f): the shot does reach the rod" % [sp, shp[0], str(dir.snapped(Vector3.ONE * 0.01)), off])
				if absf(off) < 0.3 * (r_body + r_rod):
					check(res["stunned"], "%s %s near head-on at V_max: stunned" % [sp, shp[0]])
					between(res["stun_s"], 0.6 - DT, 1.4 + 0.05, "%s %s: stun is brief (s)" % [sp, shp[0]])
	metric("rod_runs", runs)
	metric("rod_fails", fails)


static func _plane_depth(z_face: float) -> Callable:
	# Near side is z > z_face (the bird comes from +z).
	return func(pos: Vector3, r_body: float) -> float:
		return r_body - (pos.z - z_face)


func test_f10_trimesh_and_thin_box_walls_vmax() -> void:
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		var v_max: float = FlightModel.new(FlightParams.species_mass(sp)).params.v_max
		for kind: String in ["trimesh 2 cm", "box 1 cm"]:
			for ang_deg: float in [0.0, 45.0, 75.0]:
				var thick := 0.02 if kind.begins_with("trimesh") else 0.01
				# Wall centred at z = -thick/2: its front face is the plane z = 0.
				var ang := ang_deg * DEG
				var dir := Vector3(sin(ang), 0, -cos(ang))
				var start := Vector3(0, 100, 0) - dir * v_max * 0.3
				var build := func(w: Variant) -> void:
					if kind.begins_with("trimesh"):
						_trimesh_panel(w, Vector3(0, 100, -thick * 0.5), Vector3(80, 40, thick))
					else:
						w.add_wall(Vector3(0, 100, -thick * 0.5), Vector3(80, 40, thick))
				var res: Dictionary = await _shot(sp, build, start, dir * v_max, 1.0, _plane_depth(0.0))
				_lines.append("%s %s at %d deg from the normal, V_max %.1f: worst penetration %.4f m, stunned %s (%.2f s), slid %s, contacts %s" % [
					sp, kind, int(ang_deg), v_max, res["worst"], str(res["stunned"]), res["stun_s"], str(res["slid"]), str(res["contacts"])])
				lt(res["worst"], 0.001, "%s %s at %d deg, V_max: never through / inside the wall" % [sp, kind, int(ang_deg)])
				if ang_deg == 0.0:
					check(res["stunned"], "%s %s head-on at V_max: stunned (not killed)" % [sp, kind])
				if ang_deg == 75.0:
					check(not res["stunned"], "%s %s grazing (15 deg incidence) at V_max: slides, no stun" % [sp, kind])
