class_name VillageBuilder
extends RefCounted
## The village: a cobbled street of houses (many with open windows front and
## back and a furnished room between them to fly through), a church with an
## open belfry, a square with a well, and a humpbacked stone bridge over the
## river. Chimneys, roof ridges, gutters and sills are perches.

## House vent widths (m), cycled along the street: pigeon, crow, gull holes.
const VENTS: Array[float] = [0.3, 0.4, 0.52]
const WALL := 0.26
const WALL_COLS := [&"wall_white", &"wall_cream", &"wall_ochre", &"wall_pink", &"wall_blue", &"wall_sage"]
const ROOF_COLS := [&"roof_red", &"roof_terracotta", &"roof_slate", &"roof_brown", &"roof_red"]
const SHUTTER_COLS := [&"shutter_green", &"shutter_blue", &"wood", &"shutter_green"]


static func build(ctx: WorldBuild) -> void:
	var rng := ctx.sub_rng("village")
	var y0 := ctx.terrain.village_y
	_street(ctx, y0)
	var through := 0
	for idx in WorldLayout.HOUSES.size():
		var slot: Array = WorldLayout.HOUSES[idx]
		var x: float = slot[0]
		var side: int = slot[1]
		var W := rng.randf_range(7.4, 9.4)
		var D := rng.randf_range(5.8, 7.0)
		var storeys := 2 if rng.randf() < 0.45 else 1
		var z := WorldLayout.STREET_Z + side * (5.6 + D * 0.5)
		# Most houses are fly-through; a couple stay shut for variety.
		var open_through := idx % 5 != 3
		if open_through:
			through += 1
		var kit := ctx.kit("village_w" if x < -100.0 else "village_e")
		house(ctx, kit, rng, {
			"name": "house_%d" % idx, "center": Vector2(x, z), "yaw": 0.0 if side < 0 else PI,
			"W": W, "D": D, "storeys": storeys, "through": open_through,
			"wall": WALL_COLS[rng.randi() % WALL_COLS.size()],
			"roof": ROOF_COLS[rng.randi() % ROOF_COLS.size()],
			"shutter": SHUTTER_COLS[rng.randi() % SHUTTER_COLS.size()],
			"pitch": deg_to_rad(rng.randf_range(34.0, 44.0)),
			"aerial": rng.randf() < 0.35, "district": &"village",
			# Vents in three sizes, so the pigeon, the crow and the gull each have
			# holes the next size up cannot follow them into.
			"vent": VENTS[idx % VENTS.size()],
		})
	_church(ctx, y0)
	_square(ctx, y0, rng)
	_bridge(ctx, y0)
	ctx.add_landmark("village", "town", Vector3(WorldLayout.VILLAGE.x, y0, WorldLayout.VILLAGE.y), 130.0,
		{"through_houses": through})
	# Spawn: the ridge of the house beside the square, looking down the
	# street toward the bridge and the lake.
	ctx.set_meta(&"spawn_hint", Vector3(-52.0, y0, 18.0))


# --- houses ------------------------------------------------------------

## Builds one house into kit. p: name, center (Vector2), yaw, W, D, storeys,
## through (open windows front+back), wall, roof, shutter, pitch, aerial,
## district. Returns {"xf": Transform3D, "ridge_y": float}.
static func house(ctx: WorldBuild, kit: MeshKit, rng: RandomNumberGenerator, p: Dictionary) -> Dictionary:
	var W: float = p["W"]
	var D: float = p["D"]
	var c: Vector2 = p["center"]
	var yaw: float = p["yaw"]
	var district: StringName = p.get("district", &"village")
	var nm: String = p["name"]
	var foot := WorldBuild.rect_points(c, Vector2(W * 0.5 + 0.1, D * 0.5 + 0.1), yaw)
	var gmin := ctx.ground_min(foot)
	var gmax := ctx.ground_max(foot)
	var y0 := gmax + 0.3
	var xf := Transform3D(Basis(Vector3.UP, yaw), Vector3(c.x, y0, c.y))
	var prev := kit.xf
	kit.xf = xf
	var wall_c := Palette.c(p["wall"])
	var in_c := Palette.c(&"interior_wall")
	var trim := Palette.c(&"trim")
	var storeys: int = p["storeys"]
	var Hw := 3.3 if storeys == 1 else 6.0
	var pitch: float = p["pitch"]
	var rh := D * 0.5 * tan(pitch)
	# Plinth down into the ground; its top is the room floor.
	kit.box_between(Vector3(-W * 0.5 - 0.08, gmin - 0.6 - y0, -D * 0.5 - 0.08), Vector3(W * 0.5 + 0.08, 0.0, D * 0.5 + 0.08),
		Palette.c(&"plinth"), Palette.c(&"interior_floor"))
	ctx.add_footprint(nm, foot, gmin - 0.6, 3.5, 2.5, -1.0, kit.name)
	ctx.add_feature(c.x, c.y, maxf(W, D) * 0.5, "house")

	# Ground-floor layout (u along the front wall, 0..W).
	var ww := rng.randf_range(0.62, 1.05)
	var wh := rng.randf_range(1.05, 1.3)
	var sill := 0.95
	var u_l := W * 0.22
	var u_r := W * 0.78
	var u_d := W * 0.5
	var front_holes := [
		{"rect": Rect2(u_l - ww * 0.5, sill, ww, wh)},
		{"rect": Rect2(u_d - 0.5, 0.0, 1.0, 2.1)},
		{"rect": Rect2(u_r - ww * 0.5, sill, ww, wh)},
	]
	var back_holes := [
		{"rect": Rect2(u_l - ww * 0.5, sill, ww, wh)},
		{"rect": Rect2(u_r - ww * 0.5, sill, ww, wh)},
	]
	var up_sill := 3.75
	if storeys == 2:
		for u: float in [u_l, u_d, u_r]:
			front_holes.append({"rect": Rect2(u - ww * 0.5, up_sill, ww, wh)})
		for u: float in [u_l, u_r]:
			back_holes.append({"rect": Rect2(u - ww * 0.5, up_sill, ww, wh)})
	var through: bool = p["through"]
	# Front-left window lines up with back-right (back u runs along -X).
	var open_front := {0: true} if through else {}
	var open_back := {1: true} if through else {}
	var t_front := Transform3D(Basis.IDENTITY, Vector3(-W * 0.5, 0.0, D * 0.5 - WALL * 0.5))
	var t_back := Transform3D(Basis(Vector3.UP, PI), Vector3(W * 0.5, 0.0, -D * 0.5 + WALL * 0.5))
	var t_left := Transform3D(Basis(Vector3.UP, -PI * 0.5), Vector3(-W * 0.5 + WALL * 0.5, 0.0, -D * 0.5 + WALL))
	var t_right := Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(W * 0.5 - WALL * 0.5, 0.0, D * 0.5 - WALL))
	var reveal := Palette.vary(wall_c, -0.08)
	kit.wall(t_front, W, Hw, WALL, front_holes, wall_c, in_c, reveal, 1 | 2 | 4)
	kit.wall(t_back, W, Hw, WALL, back_holes, wall_c, in_c, reveal, 1 | 2 | 4)
	var side_holes := []
	if rng.randf() < 0.6:
		side_holes.append({"rect": Rect2((D - 2.0 * WALL) * 0.5 - 0.35, 1.3, 0.7, 0.9)})
	kit.wall(t_left, D - 2.0 * WALL, Hw, WALL, side_holes, wall_c, in_c, reveal, 4)
	# A vent high in the right-hand wall, into the (upper) room: the
	# mid-size birds' way into a house (windows are for anything that
	# fits). Its size says who: 0.30 m a pigeon but not a crow, 0.40 m a
	# crow but not a gull, 0.52 m a gull but not a hawk.
	var vw: float = p.get("vent", 0.4)
	var vent := Rect2((D - 2.0 * WALL) * 0.5 - vw * 0.5, Hw - 0.95, vw, vw)
	kit.wall(t_right, D - 2.0 * WALL, Hw, WALL, [{"rect": vent, "arch": true, "segs": 3}], wall_c, in_c, reveal, 4)
	var vent_c := xf * (t_right * Vector3(vent.get_center().x, vent.get_center().y, WALL * 0.5))
	var vent_n := xf.basis * Vector3.RIGHT
	ctx.add_opening(nm + "_vent", "vent", vent_c, vent_n, vent.size.x, vent.size.y, WorldBuild.span_for_gap(vent.size.x), 1.2, 15)
	kit.box(t_right * Transform3D(Basis.IDENTITY, Vector3(vent.get_center().x, vent.position.y - 0.035, WALL * 0.5 + 0.08)), Vector3(vw + 0.16, 0.07, 0.16), trim)
	ctx.add_perch(xf * (t_right * Vector3(vent.get_center().x + 0.12, vent.position.y, WALL * 0.5 + 0.1)), vent_n, Perch.Kind.LEDGE, 0.66, district)
	if not through:
		# A shut house's room is a refuge only the vent reaches.
		ctx.add_refuge(nm + "_room", vent_c - vent_n * 1.5, 0.8, WorldBuild.span_for_gap(vent.size.x))
	var shutter := Palette.c(p["shutter"])
	# Window dressing: panes in closed windows, sills and shutters on all.
	for wi in front_holes.size():
		var r: Rect2 = front_holes[wi]["rect"]
		if r.position.y == 0.0:
			_door(kit, t_front, r)
			continue
		_window(ctx, kit, xf, t_front, r, open_front.has(wi), shutter, trim, district)
	for wi in back_holes.size():
		var r: Rect2 = back_holes[wi]["rect"]
		_window(ctx, kit, xf, t_back, r, open_back.has(wi), shutter, trim, district)
	for r in side_holes:
		_window(ctx, kit, xf, t_left, r["rect"], false, shutter, trim, district)
	if through:
		var wf: Rect2 = front_holes[0]["rect"]
		var wb: Rect2 = back_holes[1]["rect"]
		var fc := Vector3(-W * 0.5 + wf.get_center().x, sill + wh * 0.5, D * 0.5)
		var bc := Vector3(W * 0.5 - wb.get_center().x, sill + wh * 0.5, -D * 0.5)
		var span := WorldBuild.span_for_gap(minf(ww, wh))
		var depth := D - 2.0 * WALL - 0.2
		ctx.add_opening(nm + "_front_window", "window", xf * fc, xf.basis * Vector3.BACK, ww, wh, span, depth, 15)
		ctx.add_opening(nm + "_back_window", "window", xf * bc, xf.basis * Vector3.FORWARD, ww, wh, span, depth, 15)
		ctx.add_refuge(nm + "_room", xf * Vector3(fc.x, 1.4, 0.0), minf(W, D) * 0.35, span)
		# Contract kind "window": one per fly-through house (AI, tutorial).
		ctx.add_landmark(nm + "_window", "window", xf * fc, maxf(ww, wh) * 0.5, {"exit": xf * bc, "max_span": span})
	# Gables (triangles over the side walls, under the roof).
	var tri := PackedVector2Array([Vector2(-D * 0.5, 0.0), Vector2(D * 0.5, 0.0), Vector2(0.0, rh)])
	var gb := Basis(Vector3(0, 0, -1), Vector3.UP, Vector3(1, 0, 0))
	kit.prism(Transform3D(gb, Vector3(-W * 0.5, Hw, 0.0)), tri, WALL, wall_c)
	kit.prism(Transform3D(gb, Vector3(W * 0.5 - WALL, Hw, 0.0)), tri, WALL, wall_c)
	# Room ceiling (closes the attic).
	kit.box_between(Vector3(-W * 0.5 + WALL, Hw - 0.12, -D * 0.5 + WALL), Vector3(W * 0.5 - WALL, Hw, D * 0.5 - WALL), in_c, Color(0, 0, 0, 0), 4)
	if storeys == 2:
		# Upper floor boards (seen through the lower windows as a ceiling).
		kit.box_between(Vector3(-W * 0.5 + WALL, 3.0, -D * 0.5 + WALL), Vector3(W * 0.5 - WALL, 3.12, D * 0.5 - WALL), in_c)
	_furniture(kit, W, D, through, Hw - 0.12 if storeys == 1 else 3.0)
	if storeys == 2:
		# Beams under the upper room's ceiling too (the vents open into it).
		_beams(kit, W, D, Hw - 0.12)
	var roof := _roof(kit, W, D, Hw, pitch, Palette.c(p["roof"]))
	var ridge_top: float = roof["ridge_top"]
	# Chimney through the back slope.
	var cx := (W * 0.5 - 0.95) * (1.0 if rng.randf() < 0.5 else -1.0)
	var cz := -D * 0.22
	var ctop := Hw + rh + 0.85
	kit.box_between(Vector3(cx - 0.33, Hw, cz - 0.33), Vector3(cx + 0.33, ctop, cz + 0.33), Palette.c(&"stone"))
	kit.box_between(Vector3(cx - 0.42, ctop, cz - 0.42), Vector3(cx + 0.42, ctop + 0.1, cz + 0.42), Palette.c(&"stone_dark"))
	kit.cyl(Vector3(cx - 0.14, ctop + 0.1, cz), Vector3(cx - 0.14, ctop + 0.42, cz), 0.12, 0.1, 6, Palette.c(&"roof_terracotta"))
	ctx.add_perch(xf * Vector3(cx + 0.22, ctop + 0.1, cz), xf.basis * Vector3.BACK, Perch.Kind.ROOF, 1.0, district)
	if p.get("aerial", false):
		var ay := ctop + 0.1
		var was := kit.collide
		kit.collide = false
		kit.cyl(Vector3(cx + 0.2, ay, cz), Vector3(cx + 0.2, ay + 1.7, cz), 0.025, 0.02, 4, Palette.c(&"metal_dark"))
		kit.cyl(Vector3(cx + 0.2 - 0.6, ay + 1.35, cz), Vector3(cx + 0.2 + 0.6, ay + 1.35, cz), 0.018, 0.018, 4, Palette.c(&"metal_dark"))
		kit.collide = was
		kit.add_capsule(Vector3(cx + 0.2, ay, cz), Vector3(cx + 0.2, ay + 1.7, cz), 0.025)
		kit.add_capsule(Vector3(cx + 0.2 - 0.6, ay + 1.35, cz), Vector3(cx + 0.2 + 0.6, ay + 1.35, cz), 0.018)
		ctx.add_perch(xf * Vector3(cx + 0.2 + 0.4, ay + 1.35 + 0.018, cz), xf.basis * Vector3.BACK, Perch.Kind.WIRE, 0.4, district)
	# Ridge and gutter perches.
	for fx: float in [-0.3, 0.3]:
		ctx.add_perch(xf * Vector3(W * fx, ridge_top, 0.0), xf.basis * Vector3.BACK, Perch.Kind.ROOF, 2.1, district)
	var ey: float = roof["gutter_top"]
	var gz: float = roof["gutter_z"]
	for s: float in [1.0, -1.0]:
		for fx: float in [-0.28, 0.28]:
			ctx.add_perch(xf * Vector3(W * fx, ey, s * gz), xf.basis * Vector3(0, 0, s), Perch.Kind.LEDGE, 0.33, district)
	kit.xf = prev
	return {"xf": xf, "ridge_y": y0 + ridge_top}


static func _door(kit: MeshKit, t: Transform3D, r: Rect2) -> void:
	kit.box(t * Transform3D(Basis.IDENTITY, Vector3(r.get_center().x, r.size.y * 0.5, 0.0)), Vector3(r.size.x, r.size.y, 0.08), Palette.c(&"door"))
	# Step.
	kit.box(t * Transform3D(Basis.IDENTITY, Vector3(r.get_center().x, 0.06, WALL * 0.5 + 0.2)), Vector3(r.size.x + 0.4, 0.12, 0.4), Palette.c(&"stone"))


static func _window(ctx: WorldBuild, kit: MeshKit, xf: Transform3D, t: Transform3D, r: Rect2, open: bool, shutter: Color, trim: Color, district: StringName) -> void:
	var cu := r.get_center().x
	var zo := WALL * 0.5
	# Sill: starts exactly at the wall face (no coplanar overlap).
	kit.box(t * Transform3D(Basis.IDENTITY, Vector3(cu, r.position.y - 0.035, zo + 0.08)), Vector3(r.size.x + 0.22, 0.07, 0.16), trim)
	# Shutters beside the opening.
	for s: float in [-1.0, 1.0]:
		var su: float = cu + s * (r.size.x * 0.5 + r.size.x * 0.25 + 0.03)
		kit.box(t * Transform3D(Basis.IDENTITY, Vector3(su, r.get_center().y, zo + 0.025)), Vector3(r.size.x * 0.5, r.size.y, 0.05), shutter)
	if not open:
		kit.box(t * Transform3D(Basis.IDENTITY, Vector3(cu, r.get_center().y, 0.0)), Vector3(r.size.x, r.size.y, 0.05), Palette.c(&"window_dark"))
		kit.box(t * Transform3D(Basis.IDENTITY, Vector3(cu, r.get_center().y, 0.04)), Vector3(0.05, r.size.y, 0.03), trim)
		# The cross bar in two halves either side of the upright: one bar
		# through the other left 5 x 5 cm of two coplanar faces at the
		# crossing, which fight at any distance in the Quest's depth buffer
		# (integration hygiene, 2026-09-27; the facets' shades differ).
		# (The second half takes no facet jitter, so the kit's random stream
		# - which also shapes later pieces - runs exactly as before.)
		var half := (r.size.x - 0.05) * 0.5
		kit.box(t * Transform3D(Basis.IDENTITY, Vector3(cu - 0.025 - half * 0.5, r.get_center().y, 0.04)), Vector3(half, 0.05, 0.03), trim)
		var jit := kit.jitter
		kit.jitter = 0.0
		kit.box(t * Transform3D(Basis.IDENTITY, Vector3(cu + 0.025 + half * 0.5, r.get_center().y, 0.04)), Vector3(half, 0.05, 0.03), trim)
		kit.jitter = jit
	if r.position.y > 0.5:
		ctx.add_perch(xf * (t * Vector3(cu + r.size.x * 0.2, r.position.y, zo + 0.1)), xf.basis * (t.basis * Vector3.BACK), Perch.Kind.LEDGE, 0.45, district)


## Two dark ceiling beams across a room whose ceiling is at y.
static func _beams(kit: MeshKit, W: float, D: float, y: float) -> void:
	for bx: float in [-W * 0.25, W * 0.25]:
		kit.box_between(Vector3(bx - 0.09, y - 0.18, -D * 0.5 + WALL), Vector3(bx + 0.09, y, D * 0.5 - WALL), Palette.c(&"wood_dark"))


## A lived-in room. The fly-through line runs from the front-left window
## to the back-right one (x = -0.28 W, a body between ~1.0 and ~1.9 m up),
## so everything near it stays below 0.95 m (bed, chair, rug) or above
## 2.2 m (shelf, lamp, beams); the table and dresser stand on the right.
static func _furniture(kit: MeshKit, W: float, D: float, through: bool, ceil_y: float) -> void:
	# Table and bench on the right, clear of the window-to-window path (left).
	var tx := W * 0.18
	var tz := -D * 0.08
	var wood := Palette.c(&"wood")
	kit.box(Transform3D(Basis.IDENTITY, Vector3(tx, 0.74, tz)), Vector3(1.3, 0.06, 0.8), wood)
	for lx: float in [-0.58, 0.58]:
		for lz: float in [-0.34, 0.34]:
			kit.box(Transform3D(Basis.IDENTITY, Vector3(tx + lx, 0.355, tz + lz)), Vector3(0.07, 0.71, 0.07), Palette.c(&"wood_dark"))
	kit.box(Transform3D(Basis.IDENTITY, Vector3(tx, 0.44, tz + 0.72)), Vector3(1.2, 0.08, 0.3), wood)
	kit.box(Transform3D(Basis.IDENTITY, Vector3(tx, 0.2, tz + 0.72)), Vector3(1.1, 0.4, 0.06), Palette.c(&"wood_dark"))
	# A rug under the table and a picture on the back wall.
	kit.box(Transform3D(Basis.IDENTITY, Vector3(tx, 0.012, tz + 0.2)), Vector3(2.2, 0.024, 1.6), Palette.c(&"rug"))
	kit.box(Transform3D(Basis.IDENTITY, Vector3(tx, 1.75, -D * 0.5 + WALL + 0.02)), Vector3(0.8, 0.55, 0.04), Palette.c(&"wood_dark"))
	kit.box(Transform3D(Basis.IDENTITY, Vector3(tx, 1.75, -D * 0.5 + WALL + 0.045)), Vector3(0.66, 0.41, 0.02), Palette.c(&"shutter_blue"))
	# Dresser against the right wall.
	kit.box(Transform3D(Basis.IDENTITY, Vector3(W * 0.5 - WALL - 0.26, 0.9, D * 0.12)), Vector3(0.5, 1.8, 1.1), Palette.c(&"wood_dark"))
	# A chair across the table from the bench.
	var cz := tz - 0.62
	kit.box(Transform3D(Basis.IDENTITY, Vector3(tx + 0.25, 0.44, cz)), Vector3(0.42, 0.05, 0.42), wood)
	kit.box(Transform3D(Basis.IDENTITY, Vector3(tx + 0.25, 0.21, cz)), Vector3(0.36, 0.42, 0.36), Palette.c(&"wood_dark"))
	kit.box(Transform3D(Basis.IDENTITY, Vector3(tx + 0.25, 0.68, cz - 0.19)), Vector3(0.42, 0.44, 0.05), wood)
	# Timber panelling round the walls up to 0.85 m (under every sill; the
	# front wall's is broken by the door), 2 cm proud of the plaster.
	var pan := Palette.c(&"wood")
	var wx := W * 0.5 - WALL
	var wz := D * 0.5 - WALL
	# (Side lengths stop 2 cm short of the corners: no coplanar overlap.)
	for seg in [[Vector3(-wx, 0.0, -wz), Vector3(wx, 0.85, -wz + 0.02)], [Vector3(-wx, 0.0, -wz + 0.02), Vector3(-wx + 0.02, 0.85, wz - 0.02)],
			[Vector3(wx - 0.02, 0.0, -wz + 0.02), Vector3(wx, 0.85, wz - 0.02)], [Vector3(-wx, 0.0, wz - 0.02), Vector3(-0.55, 0.85, wz)],
			[Vector3(0.55, 0.0, wz - 0.02), Vector3(wx, 0.85, wz)]]:
		kit.box_between(seg[0], seg[1], pan)
	# A bed in the back-left corner, its head to the back wall, beside the
	# open back window and under its sill: frame, mattress, blanket, pillow.
	var bx0 := -W * 0.5 + WALL + 0.02
	var bz0 := -D * 0.5 + WALL + 0.02
	kit.box_between(Vector3(bx0, 0.0, bz0 + 0.08), Vector3(bx0 + 0.95, 0.36, bz0 + 2.03), Palette.c(&"wood_dark"))
	kit.box_between(Vector3(bx0 + 0.04, 0.36, bz0 + 0.12), Vector3(bx0 + 0.91, 0.5, bz0 + 1.98), Palette.c(&"wall_cream"))
	kit.box_between(Vector3(bx0 + 0.02, 0.5, bz0 + 0.66), Vector3(bx0 + 0.93, 0.56, bz0 + 2.0), Palette.c(&"shutter_blue"))
	kit.box_between(Vector3(bx0 + 0.12, 0.5, bz0 + 0.18), Vector3(bx0 + 0.83, 0.62, bz0 + 0.58), Palette.c(&"trim"))
	kit.box_between(Vector3(bx0, 0.0, bz0), Vector3(bx0 + 0.95, 0.88, bz0 + 0.08), Palette.c(&"wood"))
	# A shelf of jars high on the left wall's back half, on two brackets.
	var sz0 := -D * 0.5 + WALL + 0.45
	var sh_y := 2.3
	var shx := -W * 0.5 + WALL
	kit.box_between(Vector3(shx, sh_y - 0.04, sz0), Vector3(shx + 0.24, sh_y, sz0 + 1.2), wood)
	for bz: float in [sz0 + 0.15, sz0 + 1.05]:
		kit.box_between(Vector3(shx, sh_y - 0.2, bz - 0.02), Vector3(shx + 0.04, sh_y - 0.04, bz + 0.02), Palette.c(&"wood_dark"))
	var jars := [[0.25, 0.1, &"roof_terracotta"], [0.55, 0.075, &"shutter_blue"], [0.85, 0.09, &"wall_cream"]]
	for j in jars:
		var jc := Vector3(shx + 0.12, sh_y, sz0 + float(j[0]))
		kit.cyl(jc, jc + Vector3(0, float(j[1]) * 2.2, 0), float(j[1]), float(j[1]) * 0.8, 6, Palette.c(j[2]), false, true)
	# A lamp hanging over the table.
	kit.rod(Vector3(tx, ceil_y, tz), Vector3(tx, 2.45, tz), 0.012, 0.015, 4, Palette.c(&"metal_dark"))
	kit.cyl(Vector3(tx, 2.2, tz), Vector3(tx, 2.45, tz), 0.26, 0.06, 6, Palette.c(&"wall_ochre"), true, true)
	_beams(kit, W, D, ceil_y)


## Gable roof along X. Returns ridge top (for perches) and gutter data.
static func _roof(kit: MeshKit, W: float, D: float, Hw: float, pitch: float, col: Color) -> Dictionary:
	var rt := 0.16
	var ov := 0.45
	var ovg := 0.35
	var tp := tan(pitch)
	var cp := cos(pitch)
	var sp := sin(pitch)
	var zm := (D * 0.5 + ov) * 0.5
	var ym := Hw - (zm - D * 0.5) * tp
	var L := (D * 0.5 + ov) / cp
	for s: float in [1.0, -1.0]:
		var n := Vector3(0.0, cp, sp * s)
		var zax := Vector3(1, 0, 0).cross(n)
		var centre := Vector3(0.0, ym, zm * s) + n * rt * 0.5
		kit.box(Transform3D(Basis(Vector3(1, 0, 0), n, zax), centre), Vector3(W + 2.0 * ovg, rt, L), col)
	var rh := D * 0.5 * tp
	var ridge_y := Hw + rh + rt / cp
	var cap := 0.22
	kit.box(Transform3D(Basis(Vector3(1, 0, 0), PI * 0.25), Vector3(0.0, ridge_y - 0.03, 0.0)), Vector3(W + 2.0 * ovg + 0.04, cap, cap), Palette.vary(col, -0.15))
	var eave_y := Hw - ov * tp
	# Gutters hang just under the eave, proud of the roof edge.
	var gz := D * 0.5 + ov + 0.085
	for s: float in [1.0, -1.0]:
		kit.box(Transform3D(Basis.IDENTITY, Vector3(0.0, eave_y - 0.06, s * gz)), Vector3(W + 2.0 * ovg - 0.1, 0.12, 0.21), Palette.c(&"metal_dark"))
	return {"ridge_top": ridge_y - 0.03 + cap * 0.7072, "gutter_top": eave_y, "gutter_z": gz + 0.05}


# --- church ------------------------------------------------------------

static func _church(ctx: WorldBuild, vy: float) -> void:
	var kit := ctx.kit("church")
	var c := WorldLayout.CHURCH
	var stone := Palette.c(&"stone")
	var stone_d := Palette.c(&"stone_dark")
	var slate := Palette.c(&"roof_slate")
	var dark := Palette.c(&"interior_dark")
	var y0 := vy + 0.25
	# Nave: 18 x 10 along X, east of the tower.
	var nave_c := Vector3(c.x + 6.0, y0, c.y)
	var nW := 18.0
	var nD := 10.0
	var nH := 8.0
	var th := 0.5
	var foot := WorldBuild.rect_points(Vector2(nave_c.x, nave_c.z), Vector2(nW * 0.5, nD * 0.5), 0.0)
	var gmin := ctx.ground_min(foot)
	kit.box_between(nave_c + Vector3(-nW * 0.5 - 0.1, gmin - 0.8 - y0, -nD * 0.5 - 0.1), nave_c + Vector3(nW * 0.5 + 0.1, 0.0, nD * 0.5 + 0.1), stone_d)
	ctx.add_footprint("church_nave", foot, gmin - 0.8, 3.0, 2.5, -1.0, kit.name)
	var win := []
	for k in 3:
		win.append({"rect": Rect2(3.0 + k * 5.0 - 0.6, 2.2, 1.2, 4.2), "arch": true, "segs": 5})
	var tf := Transform3D(Basis.IDENTITY, nave_c + Vector3(-nW * 0.5, 0.0, nD * 0.5 - th * 0.5))
	var tb := Transform3D(Basis(Vector3.UP, PI), nave_c + Vector3(nW * 0.5, 0.0, -nD * 0.5 + th * 0.5))
	var south := win.duplicate()
	south.append({"rect": Rect2(nW - 3.4, 0.0, 1.6, 3.0), "arch": true, "segs": 4})
	kit.wall(tf, nW, nH, th, south, stone, dark, stone_d, 1 | 2 | 4)
	kit.wall(tb, nW, nH, th, win, stone, dark, stone_d, 1 | 2 | 4)
	var te := Transform3D(Basis(Vector3.UP, PI * 0.5), nave_c + Vector3(nW * 0.5 - th * 0.5, 0.0, nD * 0.5 - th))
	kit.wall(te, nD - 2.0 * th, nH, th, [{"rect": Rect2((nD - 2.0 * th) * 0.5 - 0.9, 4.0, 1.8, 2.6), "arch": true}], stone, dark, stone_d, 4)
	# The west end abuts the tower; close it with a plain wall.
	var tw := Transform3D(Basis(Vector3.UP, -PI * 0.5), nave_c + Vector3(-nW * 0.5 + th * 0.5, 0.0, -nD * 0.5 + th))
	kit.wall(tw, nD - 2.0 * th, nH, th, [], stone, dark, stone_d, 4)
	# Dark glass in every nave window, set at mid-wall.
	for w in win:
		var r: Rect2 = w["rect"]
		for t: Transform3D in [tf, tb]:
			kit.box(t * Transform3D(Basis.IDENTITY, Vector3(r.get_center().x, r.get_center().y, 0.0)), Vector3(r.size.x, r.size.y, 0.06), Palette.c(&"window_dark"))
	kit.box(tf * Transform3D(Basis.IDENTITY, Vector3(nW - 2.6, 1.5, 0.0)), Vector3(1.6, 3.0, 0.1), Palette.c(&"door"))
	kit.box(te * Transform3D(Basis.IDENTITY, Vector3((nD - 2.0 * th) * 0.5, 5.3, 0.0)), Vector3(1.8, 2.6, 0.06), Palette.c(&"window_dark"))
	kit.box_between(nave_c + Vector3(-nW * 0.5 + th, nH - 0.2, -nD * 0.5 + th), nave_c + Vector3(nW * 0.5 - th, nH, nD * 0.5 - th), dark)
	# Nave roof (gable along X) and its gables.
	var prev := kit.xf
	kit.xf = Transform3D(Basis.IDENTITY, nave_c)
	var roof := _roof(kit, nW, nD, nH, deg_to_rad(47.0), slate)
	var rh := nD * 0.5 * tan(deg_to_rad(47.0))
	var tri := PackedVector2Array([Vector2(-nD * 0.5, 0.0), Vector2(nD * 0.5, 0.0), Vector2(0.0, rh)])
	var gb := Basis(Vector3(0, 0, -1), Vector3.UP, Vector3(1, 0, 0))
	kit.prism(Transform3D(gb, Vector3(nW * 0.5 - th, nH, 0.0)), tri, th, stone)
	kit.prism(Transform3D(gb, Vector3(-nW * 0.5, nH, 0.0)), tri, th, stone)
	kit.xf = prev
	for fx: float in [-0.3, 0.0, 0.3]:
		ctx.add_perch(nave_c + Vector3(nW * fx, roof["ridge_top"], 0.0), Vector3.BACK, Perch.Kind.ROOF, 2.1, &"village")
	for s: float in [1.0, -1.0]:
		for fx: float in [-0.25, 0.25]:
			ctx.add_perch(nave_c + Vector3(nW * fx, roof["gutter_top"], s * roof["gutter_z"]), Vector3(0, 0, s), Perch.Kind.LEDGE, 0.33, &"village")

	# Tower: solid shaft, open belfry, cornice, spire, cross.
	var tc := Vector3(c.x - 6.0, y0, c.y)
	var tS := 6.0
	var shaft_h := 17.0
	var tfoot := WorldBuild.rect_points(Vector2(tc.x, tc.z), Vector2(tS * 0.5, tS * 0.5), 0.0)
	var tg := ctx.ground_min(tfoot)
	kit.box_between(tc + Vector3(-tS * 0.5, tg - 0.8 - y0, -tS * 0.5), tc + Vector3(tS * 0.5, shaft_h, tS * 0.5), stone)
	ctx.add_footprint("church_tower", tfoot, tg - 0.8, 3.0, 2.5, -1.0, kit.name)
	ctx.add_feature(tc.x, tc.z, 12.0, "church")
	# Belt course and slit windows on the shaft. The belt is a ring round the
	# shaft's top, not a slab through it: a slab's top lay exactly in the
	# belfry floor (the shaft's top), 36 m2 of two colours fighting at any
	# distance, seen through the arches (integration hygiene, 2026-09-27).
	var bx0 := -tS * 0.5 - 0.12
	var bx1 := tS * 0.5 + 0.12
	var by0 := shaft_h - 0.35
	# (Three of the four take no facet jitter: the kit's random stream runs
	# exactly as it did for the one slab.)
	kit.box_between(tc + Vector3(bx0, by0, tS * 0.5), tc + Vector3(bx1, shaft_h, bx1), stone_d)
	var jit := kit.jitter
	kit.jitter = 0.0
	kit.box_between(tc + Vector3(bx0, by0, bx0), tc + Vector3(bx1, shaft_h, -tS * 0.5), stone_d)
	kit.box_between(tc + Vector3(bx0, by0, -tS * 0.5), tc + Vector3(-tS * 0.5, shaft_h, tS * 0.5), stone_d)
	kit.box_between(tc + Vector3(tS * 0.5, by0, -tS * 0.5), tc + Vector3(bx1, shaft_h, tS * 0.5), stone_d)
	kit.jitter = jit
	for yy: float in [6.0, 11.0]:
		kit.box(Transform3D(Basis.IDENTITY, tc + Vector3(0.0, yy, tS * 0.5 + 0.02)), Vector3(0.35, 1.4, 0.06), Palette.c(&"window_dark"))
	# Clock on the south face.
	kit.cyl(tc + Vector3(0.0, 13.8, tS * 0.5), tc + Vector3(0.0, 13.8, tS * 0.5 + 0.12), 1.1, 1.1, 12, Palette.c(&"trim"))
	kit.box(Transform3D(Basis.IDENTITY, tc + Vector3(0.0, 14.15, tS * 0.5 + 0.15)), Vector3(0.08, 0.75, 0.04), Palette.c(&"interior_dark"))
	kit.box(Transform3D(Basis(Vector3.BACK, 1.1), tc + Vector3(0.22, 13.7, tS * 0.5 + 0.15)), Vector3(0.08, 0.55, 0.04), Palette.c(&"interior_dark"))
	var bh := 6.0
	var by := shaft_h
	var bth := 0.5
	var arch_w := 1.7
	var bt := [
		[Transform3D(Basis.IDENTITY, tc + Vector3(-tS * 0.5, by, tS * 0.5 - bth * 0.5)), tS, 1 | 2 | 4, Vector3.BACK, "s"],
		[Transform3D(Basis(Vector3.UP, PI), tc + Vector3(tS * 0.5, by, -tS * 0.5 + bth * 0.5)), tS, 1 | 2 | 4, Vector3.FORWARD, "n"],
		[Transform3D(Basis(Vector3.UP, -PI * 0.5), tc + Vector3(-tS * 0.5 + bth * 0.5, by, -tS * 0.5 + bth)), tS - 2.0 * bth, 4, Vector3.LEFT, "w"],
		[Transform3D(Basis(Vector3.UP, PI * 0.5), tc + Vector3(tS * 0.5 - bth * 0.5, by, tS * 0.5 - bth)), tS - 2.0 * bth, 4, Vector3.RIGHT, "e"],
	]
	for b in bt:
		var bw: float = b[1]
		var hole := Rect2(bw * 0.5 - arch_w * 0.5, 1.0, arch_w, 4.0)
		kit.wall(b[0], bw, bh, bth, [{"rect": hole, "arch": true, "segs": 6}], stone, dark, stone_d, b[2])
		var centre: Vector3 = (b[0] as Transform3D) * Vector3(bw * 0.5, hole.get_center().y, bth * 0.5)
		# Rated by a measured flight through the whole belfry and out of
		# the opposite arch (SoaringWorld._measure_openings), not by the
		# arch alone: a bird that fits the arch must also clear the bell.
		var op := ctx.add_opening("belfry_" + String(b[4]), "belfry", centre, b[3], arch_w, hole.size.y, WorldBuild.span_for_gap(arch_w), tS + 1.0, 15)
		op["measure"] = true
		# Arch sill ledge (perch) at the opening's foot.
		ctx.add_perch((b[0] as Transform3D) * Vector3(bw * 0.5 + 0.4, 1.0, bth * 0.5 - 0.12), b[3], Perch.Kind.LEDGE, 1.6, &"village")
	# Bell and its beam, hung high enough that a bird flying through at the
	# arches' mid-height passes under the bell.
	var beam_y := by + 5.55
	kit.box_between(tc + Vector3(-tS * 0.5 + bth, beam_y - 0.18, -0.16), tc + Vector3(tS * 0.5 - bth, beam_y + 0.18, 0.16), Palette.c(&"wood_dark"))
	kit.cyl(tc + Vector3(0.0, beam_y - 0.18, 0.0), tc + Vector3(0.0, beam_y - 0.55, 0.0), 0.06, 0.06, 5, Palette.c(&"metal_dark"))
	kit.cyl(tc + Vector3(0.0, beam_y - 1.3, 0.0), tc + Vector3(0.0, beam_y - 0.55, 0.0), 0.62, 0.3, 10, Palette.c(&"bell"))
	kit.cyl(tc + Vector3(0.0, beam_y - 1.4, 0.0), tc + Vector3(0.0, beam_y - 1.25, 0.0), 0.66, 0.66, 10, Palette.vary(Palette.c(&"bell"), -0.15))
	ctx.add_perch(tc + Vector3(1.6, beam_y + 0.18, 0.0), Vector3.BACK, Perch.Kind.LEDGE, 1.3, &"village")
	ctx.add_perch(tc + Vector3(-1.6, beam_y + 0.18, 0.0), Vector3.FORWARD, Perch.Kind.LEDGE, 1.3, &"village")
	ctx.add_landmark("belfry", "roost", tc + Vector3(0.0, by + 2.5, 0.0), 2.5)
	# Its max_span is measured too: the largest body that gets in through
	# an arch and sits here.
	# Under the bell, on the arches' line: straight in from any of them.
	ctx.add_refuge("belfry", tc + Vector3(0.0, by + 2.4, 0.0), 1.0, WorldBuild.span_for_gap(arch_w))
	ctx.refuges[-1]["measure_from"] = ["belfry_s", "belfry_n", "belfry_w", "belfry_e"]
	# Cornice, spire and cross.
	var ctop := by + bh
	kit.box_between(tc + Vector3(-tS * 0.5 - 0.3, ctop, -tS * 0.5 - 0.3), tc + Vector3(tS * 0.5 + 0.3, ctop + 0.45, tS * 0.5 + 0.3), stone_d)
	var sp_top := ctop + 13.0
	kit.cyl(tc + Vector3(0.0, ctop + 0.45, 0.0), tc + Vector3(0.0, sp_top, 0.0), (tS * 0.5 + 0.1) * sqrt(2.0), 0.0, 4, slate, true, false, PI * 0.25)
	var was := kit.collide
	kit.collide = false
	kit.cyl(tc + Vector3(0.0, sp_top - 0.3, 0.0), tc + Vector3(0.0, sp_top + 2.2, 0.0), 0.05, 0.05, 5, Palette.c(&"bell"))
	kit.cyl(tc + Vector3(-0.55, sp_top + 1.5, 0.0), tc + Vector3(0.55, sp_top + 1.5, 0.0), 0.045, 0.045, 5, Palette.c(&"bell"))
	kit.collide = was
	kit.add_capsule(tc + Vector3(0.0, sp_top - 0.3, 0.0), tc + Vector3(0.0, sp_top + 2.2, 0.0), 0.05)
	kit.add_capsule(tc + Vector3(-0.55, sp_top + 1.5, 0.0), tc + Vector3(0.55, sp_top + 1.5, 0.0), 0.045)
	ctx.add_perch(tc + Vector3(0.0, sp_top + 2.25, 0.0), Vector3.BACK, Perch.Kind.POLE_TOP, 1.6, &"village")
	ctx.add_perch(tc + Vector3(0.42, sp_top + 1.545, 0.0), Vector3.BACK, Perch.Kind.POLE_TOP, 0.7, &"village")
	ctx.add_landmark("church_spire", "landmark", tc + Vector3(0.0, sp_top, 0.0), 4.0)


# --- street, square ----------------------------------------------------

## Street and square paving: its top over the ground (m). 0.2 since
## integration round 1 (was 0.1): the Quest's 24-bit depth buffer resolved
## a 10 cm step between the cobbles and the grass under them only to ~70 m
## for a sparrow flying 100 m up (tests/unit/integration/depth_precision_test.gd).
const PAVING_TOP := 0.2


static func _slab(kit: MeshKit, x0: float, x1: float, z0: float, z1: float, top: float, col: Color, edge: Color) -> void:
	kit.box_between(Vector3(x0, top - 0.45, z0), Vector3(x1, top, z1), edge, col)


static func _street(ctx: WorldBuild, vy: float) -> void:
	var kit := ctx.kit("street", false, false)
	var top := vy + PAVING_TOP
	var cob := Palette.c(&"cobble")
	var edge := Palette.c(&"stone_dark")
	var sz := WorldLayout.STREET_Z
	# West street, square, east street: three slabs that do not overlap.
	_slab(kit, WorldLayout.STREET_X0, -115.0, sz - 4.0, sz + 4.0, top, cob, edge)
	_slab(kit, -115.0, -65.0, 11.0, 47.0, top, Palette.vary(cob, 0.06), edge)
	_slab(kit, -65.0, 27.0, sz - 4.0, sz + 4.0, top, cob, edge)
	# Kerb stripes along the street (low, not coplanar with the slab top).
	for s: float in [-1.0, 1.0]:
		for seg in [[WorldLayout.STREET_X0, -115.0], [-65.0, 27.0]]:
			kit.box_between(Vector3(seg[0], top, sz + s * 4.0 - 0.15), Vector3(seg[1], top + 0.08, sz + s * 4.0 + 0.15), Palette.c(&"stone"))


static func _square(ctx: WorldBuild, vy: float, rng: RandomNumberGenerator) -> void:
	var kit := ctx.kit("church")
	var top := vy + PAVING_TOP
	# Well: stone ring, two posts and a little roof.
	var wc := Vector3(-100.0, top, 40.0)
	kit.cyl(wc + Vector3(0, -0.3, 0), wc + Vector3(0, 0.8, 0), 1.0, 1.0, 10, Palette.c(&"stone"), false, true)
	kit.cyl(wc + Vector3(0, 0.8, 0), wc + Vector3(0, 0.83, 0), 0.72, 0.72, 10, Palette.c(&"interior_dark"), false, true)
	for s: float in [-1.0, 1.0]:
		kit.box(Transform3D(Basis.IDENTITY, wc + Vector3(s * 0.85, 1.6, 0)), Vector3(0.14, 1.6, 0.14), Palette.c(&"wood_dark"))
	kit.prism(Transform3D(Basis(Vector3(0, 0, -1), Vector3.UP, Vector3(1, 0, 0)), wc + Vector3(-1.2, 2.35, 0)),
		PackedVector2Array([Vector2(-1.0, 0.0), Vector2(1.0, 0.0), Vector2(0.0, 0.8)]), 2.4, Palette.c(&"roof_red"), Palette.c(&"roof_red"))
	ctx.add_perch(wc + Vector3(0.5, 3.15, 0.0), Vector3.BACK, Perch.Kind.ROOF, 0.7, &"village")
	ctx.add_perch(wc + Vector3(0.0, 0.8, 0.9), Vector3.BACK, Perch.Kind.LEDGE, 0.66, &"village")
	ctx.add_feature(wc.x, wc.z, 2.0, "well")
	# Benches and lamp posts around the square.
	for i in 4:
		var bx := -110.0 + i * 13.0
		var bz := 45.5
		kit.box(Transform3D(Basis.IDENTITY, Vector3(bx, top + 0.45, bz)), Vector3(1.8, 0.08, 0.45), Palette.c(&"wood"))
		for s: float in [-0.8, 0.8]:
			kit.box(Transform3D(Basis.IDENTITY, Vector3(bx + s, top + 0.21, bz)), Vector3(0.08, 0.42, 0.4), Palette.c(&"metal_dark"))
		ctx.add_perch(Vector3(bx + 0.4, top + 0.49, bz), Vector3.BACK, Perch.Kind.LEDGE, 0.66, &"village")
	# Four stand on the square's paving; the two by the street ends stand on
	# the verge beside the street slab, so they are planted in the ground
	# (round 3 based them at the paving's height: 10 cm in the air).
	var lamps := [Vector2(-114, 13), Vector2(-66, 13), Vector2(-114, 46), Vector2(-66, 46), Vector2(-160, 25), Vector2(-20, 35)]
	for li in lamps.size():
		var lp: Vector2 = lamps[li]
		var base := Vector3(lp.x, top, lp.y)
		if li >= 4:
			base.y = ctx.ground(lp.x, lp.y) - 0.15
			ctx.add_footprint("lamp_post_%d" % li, PackedVector2Array([lp]), base.y, 0.3, 0.5, 0.6, kit.name)
		kit.rod(base, base + Vector3(0, 3.6, 0), 0.07, 0.07, 6, Palette.c(&"metal_dark"))
		kit.box(Transform3D(Basis.IDENTITY, base + Vector3(0, 3.75, 0)), Vector3(0.36, 0.3, 0.36), Palette.c(&"window_dark"))
		kit.box(Transform3D(Basis.IDENTITY, base + Vector3(0, 3.95, 0)), Vector3(0.46, 0.1, 0.46), Palette.c(&"metal_dark"))
		ctx.add_perch(base + Vector3(0, 4.0, 0), Vector3.BACK, Perch.Kind.POLE_TOP, 0.95, &"village")


# --- bridge ------------------------------------------------------------

static func _bridge(ctx: WorldBuild, vy: float) -> void:
	var kit := ctx.kit("bridge")
	var stone := Palette.c(&"stone")
	var stone_d := Palette.c(&"stone_dark")
	var b := WorldLayout.BRIDGE
	var width := 6.4
	var length := 38.0
	var deck := vy + 2.6
	var base := WorldLayout.WATER_Y - 3.0
	var h := deck - base
	var x0 := b.x - length * 0.5
	var wy := WorldLayout.WATER_Y
	# Holes in panel space (u from x0 along +X, v from base).
	var main := Rect2(length * 0.5 - 5.5, 0.0, 11.0, (wy + 3.9) - base)
	var side_w := 3.6
	var s1 := Rect2(length * 0.5 - 5.5 - 3.4 - side_w, (vy - 0.6) - base, side_w, 3.4)
	var s2 := Rect2(length * 0.5 + 5.5 + 3.4, (vy - 0.6) - base, side_w, 3.4)
	var holes := [
		{"rect": main, "arch": true, "rise": 2.6, "segs": 8},
		{"rect": s1, "arch": true, "segs": 6},
		{"rect": s2, "arch": true, "segs": 6},
	]
	var t := Transform3D(Basis.IDENTITY, Vector3(x0, base, b.y))
	kit.wall(t, length, h, width, holes, stone, stone, stone_d, 15)
	# Parapets (perches) and ramps down to the street at both ends.
	for s: float in [-1.0, 1.0]:
		kit.box_between(Vector3(x0, deck, b.y + s * (width * 0.5) - 0.2), Vector3(x0 + length, deck + 0.85, b.y + s * (width * 0.5) + 0.2), stone_d, stone)
		for fx: float in [0.25, 0.5, 0.75]:
			ctx.add_perch(Vector3(x0 + length * fx, deck + 0.85, b.y + s * width * 0.5), Vector3(0, 0, s), Perch.Kind.LEDGE, 1.0, &"village")
	for e in [[x0, -1.0], [x0 + length, 1.0]]:
		var ex: float = e[0]
		var dirx: float = e[1]
		var gy := ctx.ground(ex + dirx * 9.0, b.y)
		var ramp := PackedVector2Array([Vector2(0.0, gy - 0.6), Vector2(0.0, deck), Vector2(9.0, gy + PAVING_TOP), Vector2(9.0, gy - 0.6)])
		if dirx < 0.0:
			for i in ramp.size():
				ramp[i].x = -ramp[i].x
			ramp.reverse()
		kit.prism(Transform3D(Basis.IDENTITY, Vector3(ex, 0.0, b.y - width * 0.5)), _ccw(ramp), width, Palette.c(&"cobble"), stone_d)
	# Deck surface strip (raised cobbles, not coplanar with the top: 12 cm,
	# 5 cm fought the deck on a 24-bit depth buffer from ~60 m).
	kit.box_between(Vector3(x0, deck, b.y - width * 0.5 + 0.2), Vector3(x0 + length, deck + 0.12, b.y + width * 0.5 - 0.2), Palette.c(&"cobble"))
	var foot := PackedVector2Array([Vector2(x0, b.y - width * 0.5), Vector2(x0 + length, b.y - width * 0.5), Vector2(x0 + length, b.y + width * 0.5), Vector2(x0, b.y + width * 0.5)])
	ctx.add_footprint("bridge", foot, base, 8.0, 2.5, -1.0, kit.name)
	ctx.add_feature(b.x, b.y, length * 0.5, "bridge")
	for s: float in [1.0, -1.0]:
		var n := Vector3(0, 0, s)
		var zc := b.y + s * width * 0.5
		# Clear height over the water up to the crown of the segmental arch.
		var clear_h := (wy + 3.9) - wy
		ctx.add_opening("bridge_main_" + ("s" if s > 0 else "n"), "bridge_arch", Vector3(b.x, wy + clear_h * 0.5, zc), n, 11.0, clear_h,
			WorldBuild.span_for_gap(clear_h), width * 0.5, 1 | 2 | 4)
		for sr: Rect2 in [s1, s2]:
			var cx := x0 + sr.get_center().x
			ctx.add_opening("bridge_side_%d_%s" % [int(cx), "s" if s > 0 else "n"], "bridge_arch", Vector3(cx, base + sr.get_center().y, zc), n,
				side_w, sr.size.y, WorldBuild.span_for_gap(minf(side_w, sr.size.y)), width * 0.5, 1 | 2 | 4)
	ctx.add_landmark("bridge", "bridge", Vector3(b.x, deck, b.y), length * 0.5)


## Makes a 2D polygon counter-clockwise.
static func _ccw(p: PackedVector2Array) -> PackedVector2Array:
	var a := 0.0
	for i in p.size():
		var j := (i + 1) % p.size()
		a += p[i].x * p[j].y - p[j].x * p[i].y
	if a < 0.0:
		var r := p.duplicate()
		r.reverse()
		return r
	return p
