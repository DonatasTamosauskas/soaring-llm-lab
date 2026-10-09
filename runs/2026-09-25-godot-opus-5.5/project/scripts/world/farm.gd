class_name FarmBuilder
extends RefCounted
## The farm west of the village: a big board-and-batten barn (open doors at
## both ends, a hay-loft hatch, gaps in the slats that only small birds can
## slip through, tie beams to roost on), a farmhouse, an old water tower whose
## tank has a single hatch, fences and round hay bales.

const BW := 0.22


static func build(ctx: WorldBuild) -> void:
	var rng := ctx.sub_rng("farm")
	_barn(ctx, rng)
	VillageBuilder.house(ctx, ctx.kit("farm"), rng, {
		"name": "farmhouse", "center": WorldLayout.FARMHOUSE, "yaw": -0.35,
		"W": 9.2, "D": 6.8, "storeys": 2, "through": true, "wall": &"wall_cream",
		"roof": &"roof_brown", "shutter": &"shutter_green", "pitch": deg_to_rad(40.0),
		"aerial": false, "district": &"farm",
	})
	_water_tower(ctx)
	_fences(ctx, rng)
	_bales(ctx, rng)
	ctx.add_landmark("farm", "farm", Vector3(WorldLayout.FARM.x, ctx.ground(WorldLayout.FARM.x, WorldLayout.FARM.y), WorldLayout.FARM.y), 45.0)


# --- barn --------------------------------------------------------------

static func _barn(ctx: WorldBuild, rng: RandomNumberGenerator) -> void:
	var kit := ctx.kit("farm")
	var c := WorldLayout.FARM
	var L := 20.0  # along local X (world -Z)
	var D := 12.0  # along local Z
	var H := 7.0
	var yaw := PI * 0.5
	var foot := WorldBuild.rect_points(c, Vector2(L * 0.5 + 0.2, D * 0.5 + 0.2), yaw)
	var gmin := ctx.ground_min(foot)
	var y0 := ctx.ground_max(foot) + 0.25
	var xf := Transform3D(Basis(Vector3.UP, yaw), Vector3(c.x, y0, c.y))
	var prev := kit.xf
	kit.xf = xf
	var red := Palette.c(&"barn_red")
	var red_d := Palette.c(&"barn_red_dark")
	var inside := Palette.c(&"wood_dark")
	var trim := Palette.c(&"trim")
	ctx.add_footprint("barn", foot, gmin - 0.6, 3.0, 2.5, -1.0, kit.name)
	ctx.add_feature(c.x, c.y, 12.0, "barn")
	# Stone plinth; its top is the earth floor.
	kit.box_between(Vector3(-L * 0.5 - 0.1, gmin - 0.6 - y0, -D * 0.5 - 0.1), Vector3(L * 0.5 + 0.1, 0.0, D * 0.5 + 0.1), Palette.c(&"plinth"), Palette.c(&"mud"))
	var splits := PackedFloat32Array()
	var u := 0.42
	while u < L:
		splits.append(u)
		u += 0.42
	# Long walls with slat gaps (local +Z and -Z faces).
	var gaps := [3.36, 8.4, 13.02, 16.8]
	var side_holes := []
	for g in gaps:
		side_holes.append({"rect": Rect2(g + 0.1, 1.3, 0.17, 2.7)})
	var t_front := Transform3D(Basis.IDENTITY, Vector3(-L * 0.5, 0.0, D * 0.5 - BW * 0.5))
	var t_back := Transform3D(Basis(Vector3.UP, PI), Vector3(L * 0.5, 0.0, -D * 0.5 + BW * 0.5))
	# Two broken boards in the north wall: holes a pigeon or a crow gets
	# through (the slats are for small birds, the doors for anything),
	# above the hay stacked along that wall.
	var broken := [{"rect": Rect2(5.45, 2.0, 0.42, 1.25)}, {"rect": Rect2(10.05, 2.25, 0.4, 1.1)}]
	kit.wall(t_front, L, H, BW, side_holes, red, inside, red_d, 1 | 2 | 4, splits, red_d)
	kit.wall(t_back, L, H, BW, side_holes + broken, red, inside, red_d, 1 | 2 | 4, splits, red_d)
	for i in broken.size():
		var r: Rect2 = broken[i]["rect"]
		ctx.add_opening("barn_broken_board_%d" % i, "barn_board", xf * (t_back * Vector3(r.get_center().x, r.get_center().y, BW * 0.5)),
			xf.basis * Vector3.FORWARD, r.size.x, r.size.y, WorldBuild.span_for_gap(r.size.x), 1.2, 15)
	var depth_in := D - 2.0 * BW - 0.4
	for i in side_holes.size():
		var r: Rect2 = side_holes[i]["rect"]
		for pair in [[t_front, Vector3.BACK, "s"], [t_back, Vector3.FORWARD, "n"]]:
			var t: Transform3D = pair[0]
			var centre := xf * (t * Vector3(r.get_center().x, r.get_center().y, BW * 0.5))
			ctx.add_opening("barn_slat_%s%d" % [pair[2], i], "barn_slat", centre, xf.basis * (pair[1] as Vector3), r.size.x, r.size.y,
				WorldBuild.span_for_gap(r.size.x), 1.2, 15)
	# Gable-end walls: big doors (and a loft hatch on one end).
	var ew := D - 2.0 * BW
	var door := Rect2(ew * 0.5 - 1.9, 0.0, 3.8, 4.4)
	var loft := Rect2(ew * 0.5 - 0.8, 5.05, 1.6, 1.4)
	var esplits := PackedFloat32Array()
	u = 0.42
	while u < ew:
		esplits.append(u)
		u += 0.42
	var t_e := Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(L * 0.5 - BW * 0.5, 0.0, D * 0.5 - BW))
	var t_w := Transform3D(Basis(Vector3.UP, -PI * 0.5), Vector3(-L * 0.5 + BW * 0.5, 0.0, -D * 0.5 + BW))
	# An owl hole high in the west end: a gull gets in, a hawk does not.
	var owl := Rect2(ew * 0.5 - 0.275, 5.2, 0.55, 0.62)
	kit.wall(t_e, ew, H, BW, [{"rect": door}, {"rect": loft}], red, inside, red_d, 4, esplits, red_d)
	kit.wall(t_w, ew, H, BW, [{"rect": door}, {"rect": owl, "arch": true, "segs": 4}], red, inside, red_d, 4, esplits, red_d)
	ctx.add_opening("barn_owl_hole", "owl_hole", xf * (t_w * Vector3(owl.get_center().x, owl.get_center().y, BW * 0.5)), xf.basis * Vector3.LEFT,
		owl.size.x, owl.size.y, WorldBuild.span_for_gap(owl.size.x), 1.2, 15)
	kit.box(t_w * Transform3D(Basis.IDENTITY, Vector3(owl.get_center().x, owl.position.y - 0.04, BW * 0.5 + 0.09)), Vector3(owl.size.x + 0.2, 0.08, 0.18), trim)
	ctx.add_perch(xf * (t_w * Vector3(owl.get_center().x + 0.2, owl.position.y, BW * 0.5 + 0.12)), xf.basis * Vector3.LEFT, Perch.Kind.LEDGE, 1.3, &"farm")
	# White door frames and the open leaves folded back against the wall.
	for pair in [[t_e, Vector3.RIGHT, "e"], [t_w, Vector3.LEFT, "w"]]:
		var t: Transform3D = pair[0]
		for s: float in [-1.0, 1.0]:
			var lc := door.get_center().x + s * (door.size.x * 0.5 + 0.98)
			kit.box(t * Transform3D(Basis.IDENTITY, Vector3(lc, 2.2, BW * 0.5 + 0.07)), Vector3(1.9, 4.4, 0.1), red_d)
			# Diagonal brace across the leaf, corner to corner.
			kit.box(t * Transform3D(Basis(Vector3.BACK, s * atan2(1.7, 4.2)), Vector3(lc, 2.2, BW * 0.5 + 0.14)), Vector3(0.12, 4.4, 0.04), trim)
		kit.box(t * Transform3D(Basis.IDENTITY, Vector3(door.get_center().x, 4.47, BW * 0.5 + 0.03)), Vector3(4.0, 0.14, 0.06), trim)
		var n := xf.basis * (pair[1] as Vector3)
		ctx.add_opening("barn_door_" + String(pair[2]), "barn_door", xf * (t * Vector3(door.get_center().x, 2.2, BW * 0.5)), n,
			door.size.x, door.size.y, WorldBuild.span_for_gap(door.size.x), 6.0, 15)
	ctx.add_opening("barn_loft", "barn_loft", xf * (t_e * Vector3(loft.get_center().x, loft.get_center().y, BW * 0.5)), xf.basis * Vector3.RIGHT,
		loft.size.x, loft.size.y, WorldBuild.span_for_gap(loft.size.y), 1.3, 15)
	# Gables and roof.
	var pitch := deg_to_rad(42.0)
	var rh := D * 0.5 * tan(pitch)
	var tri := PackedVector2Array([Vector2(-D * 0.5, 0.0), Vector2(D * 0.5, 0.0), Vector2(0.0, rh)])
	var gb := Basis(Vector3(0, 0, -1), Vector3.UP, Vector3(1, 0, 0))
	kit.prism(Transform3D(gb, Vector3(-L * 0.5, H, 0.0)), tri, BW, red)
	kit.prism(Transform3D(gb, Vector3(L * 0.5 - BW, H, 0.0)), tri, BW, red)
	var roof := VillageBuilder._roof(kit, L, D, H, pitch, Palette.c(&"roof_moss"))
	# Dark boarding under the roof inside: seen through the doors and the
	# hatch, the loft reads as a dim timber space (round 3 showed the moss
	# roof's green underside there, so the hatch read as a solid panel).
	var zin := D * 0.5 - BW
	var cp := cos(pitch)
	for s: float in [1.0, -1.0]:
		var n := Vector3(0.0, cp, sin(pitch) * s)
		var zmid := zin * 0.5
		var c_l := Vector3(0.0, H + (D * 0.5 - zmid) * tan(pitch), zmid * s) - n * 0.03
		kit.box(Transform3D(Basis(Vector3(1, 0, 0), n, Vector3(1, 0, 0).cross(n)), c_l), Vector3(L - 2.0 * BW, 0.05, zin / cp), Palette.c(&"wood_dark"))
	# The hatch framed in white like the doors, and the hay hoist's beam
	# over it (a perch with a view down the yard).
	var ft := BW * 0.5 + 0.03
	for bx in [[Vector3(loft.get_center().x, loft.end.y + 0.07, ft), Vector3(loft.size.x + 0.28, 0.14, 0.06)],
			[Vector3(loft.get_center().x, loft.position.y - 0.07, ft), Vector3(loft.size.x + 0.28, 0.14, 0.06)],
			[Vector3(loft.position.x - 0.07, loft.get_center().y, ft), Vector3(0.14, loft.size.y, 0.06)],
			[Vector3(loft.end.x + 0.07, loft.get_center().y, ft), Vector3(0.14, loft.size.y, 0.06)]]:
		kit.box(t_e * Transform3D(Basis.IDENTITY, bx[0]), bx[1], trim)
	kit.box(t_e * Transform3D(Basis.IDENTITY, Vector3(loft.get_center().x, 6.75, 0.6)), Vector3(0.2, 0.2, 1.2 + BW), Palette.c(&"wood_dark"))
	kit.box(t_e * Transform3D(Basis.IDENTITY, Vector3(loft.get_center().x, 6.6, BW * 0.5 + 1.08)), Vector3(0.12, 0.1, 0.12), Palette.c(&"metal_dark"))
	ctx.add_perch(xf * (t_e * Vector3(loft.get_center().x, 6.85, BW * 0.5 + 0.85)), xf.basis * Vector3.RIGHT, Perch.Kind.POLE_TOP, 1.3, &"farm")
	# Loft floor behind the hatch, tie beams, hay.
	kit.box_between(Vector3(L * 0.5 - 4.2, 4.85, -D * 0.5 + BW), Vector3(L * 0.5 - BW, 5.05, D * 0.5 - BW), Palette.c(&"wood"))
	var hay := Palette.c(&"hay")
	for bx in [L * 0.5 - 3.4, L * 0.5 - 1.9]:
		for bz in [-4.2, -2.9, 2.9, 4.2]:
			kit.box(Transform3D(Basis.IDENTITY, Vector3(bx, 5.5, bz)), Vector3(1.3, 0.9, 1.1), hay)
	for bx in [-7.5, -5.8, -4.1]:
		for by in [0.45, 1.35]:
			kit.box(Transform3D(Basis.IDENTITY, Vector3(bx, by, -D * 0.5 + 1.0)), Vector3(1.6, 0.9, 1.3), Palette.vary(hay, rng.randf_range(-0.08, 0.05)))
	for bx in [-6.5, -1.5, 3.5]:
		kit.box_between(Vector3(bx - 0.13, 6.6, -D * 0.5 + BW), Vector3(bx + 0.13, 6.9, D * 0.5 - BW), Palette.c(&"wood_dark"))
		ctx.add_perch(xf * Vector3(bx, 6.9, 2.5), xf.basis * Vector3.RIGHT, Perch.Kind.LEDGE, 1.3, &"farm")
		ctx.add_perch(xf * Vector3(bx, 6.9, -2.5), xf.basis * Vector3.LEFT, Perch.Kind.LEDGE, 1.3, &"farm")
	ctx.add_perch(xf * Vector3(L * 0.5 - 3.0, 5.05, 0.0), xf.basis * Vector3.RIGHT, Perch.Kind.LEDGE, 1.6, &"farm")
	ctx.add_refuge("barn_loft", xf * Vector3(L * 0.5 - 2.5, 5.8, 0.0), 1.2, WorldBuild.span_for_gap(loft.size.y))
	ctx.add_landmark("barn", "roost", xf * Vector3(0.0, 5.0, 0.0), 8.0)
	# Cupola with a weathervane on the ridge.
	var ry: float = roof["ridge_top"]
	kit.box(Transform3D(Basis.IDENTITY, Vector3(0.0, ry + 0.45, 0.0)), Vector3(1.4, 1.1, 1.4), Palette.c(&"trim"))
	kit.cyl(Vector3(0.0, ry + 1.0, 0.0), Vector3(0.0, ry + 2.0, 0.0), 1.2, 0.0, 4, Palette.c(&"roof_moss"), true, false, PI * 0.25)
	kit.rod(Vector3(0.0, ry + 1.9, 0.0), Vector3(0.0, ry + 2.9, 0.0), 0.035, 0.035, 4, Palette.c(&"metal_dark"))
	kit.box(Transform3D(Basis.IDENTITY, Vector3(0.0, ry + 2.6, 0.2)), Vector3(0.05, 0.25, 0.5), Palette.c(&"metal_dark"))
	ctx.add_perch(xf * Vector3(0.0, ry + 2.9, 0.0), xf.basis * Vector3.RIGHT, Perch.Kind.POLE_TOP, 1.0, &"farm")
	for fx: float in [-0.35, 0.3]:
		ctx.add_perch(xf * Vector3(L * fx, ry, 0.0), xf.basis * Vector3.BACK, Perch.Kind.ROOF, 2.1, &"farm")
	kit.xf = prev


# --- water tower -------------------------------------------------------

static func _water_tower(ctx: WorldBuild) -> void:
	var kit := ctx.kit("water_tower")
	var c := WorldLayout.WATER_TOWER
	var g := ctx.ground(c.x, c.y)
	var base := Vector3(c.x, g, c.y)
	var metal := Palette.c(&"metal")
	var metal_d := Palette.c(&"metal_dark")
	var rust := Palette.c(&"rust")
	var leg_top := 22.0
	var hb := 2.4
	var ht := 1.7
	var corners := []
	for k in 4:
		var a := PI * 0.25 + k * PI * 0.5
		corners.append([Vector3(cos(a), 0, sin(a)) * hb * sqrt(2.0), Vector3(cos(a), 0, sin(a)) * ht * sqrt(2.0)])
	for k in 4:
		var b: Vector3 = base + corners[k][0] + Vector3(0, -0.8, 0)
		var t: Vector3 = base + corners[k][1] + Vector3(0, leg_top, 0)
		kit.rod(b, t, 0.2, 0.2, 6, metal_d)
		# Concrete footing.
		kit.box(Transform3D(Basis.IDENTITY, base + corners[k][0] + Vector3(0, 0.1, 0)), Vector3(0.9, 1.4, 0.9), Palette.c(&"stone"))
	# Rings and X bracing between the legs.
	var levels := [0.0, 7.5, 15.0, leg_top - 0.6]
	for li in levels.size():
		var y: float = levels[li]
		var f := y / leg_top
		for k in 4:
			var a: Vector3 = base + (corners[k][0] as Vector3).lerp(corners[k][1], f) + Vector3(0, y, 0)
			var b: Vector3 = base + (corners[(k + 1) % 4][0] as Vector3).lerp(corners[(k + 1) % 4][1], f) + Vector3(0, y, 0)
			if li > 0:
				kit.rod(a, b, 0.07, 0.07, 4, metal)
				if li == 1:
					ctx.add_perch(a.lerp(b, 0.5) + Vector3(0, 0.07, 0), (b - a).cross(Vector3.UP), Perch.Kind.WIRE, 0.6, &"farm")
			if li < levels.size() - 1:
				var y2: float = levels[li + 1]
				var f2 := y2 / leg_top
				var a2: Vector3 = base + (corners[k][0] as Vector3).lerp(corners[k][1], f2) + Vector3(0, y2, 0)
				var b2: Vector3 = base + (corners[(k + 1) % 4][0] as Vector3).lerp(corners[(k + 1) % 4][1], f2) + Vector3(0, y2, 0)
				kit.rod(a.lerp(a2, 0.03), b2.lerp(b, 0.03), 0.05, 0.05, 4, metal)
				kit.rod(b.lerp(b2, 0.03), a2.lerp(a, 0.03), 0.05, 0.05, 4, metal)
	# Walkway (octagonal deck) with a rail, then the tank on top of it.
	var ty := base.y + leg_top
	var apo := 2.9
	var oct := _octagon(apo + 1.1)
	kit.prism(Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(base.x, ty - 0.2, base.z)), oct, 0.2, metal_d)
	var rail_r := (apo + 1.0) / cos(PI / 8.0)
	for k in 8:
		var a0 := PI / 8.0 + k * PI / 4.0
		var a1 := a0 + PI / 4.0
		var p0 := Vector3(base.x + cos(a0) * rail_r, ty + 1.05, base.z + sin(a0) * rail_r)
		var p1 := Vector3(base.x + cos(a1) * rail_r, ty + 1.05, base.z + sin(a1) * rail_r)
		kit.rod(p0, p1, 0.045, 0.045, 4, metal)
		kit.rod(Vector3(p0.x, ty, p0.z), p0, 0.035, 0.035, 4, metal)
		if k % 2 == 0:
			ctx.add_perch(p0.lerp(p1, 0.5) + Vector3(0, 0.045, 0), Vector3(p0.x - base.x, 0, p0.z - base.z), Perch.Kind.WIRE, 0.66, &"farm")
	var tank_h := 5.2
	var side := 2.0 * apo * tan(PI / 8.0)
	var hatch := Rect2(side * 0.5 - 0.45, 1.9, 0.9, 1.0)
	var tank_col := Palette.c(&"tank")
	for k in 8:
		var ang := k * PI / 4.0
		var out := Vector3(cos(ang), 0, sin(ang))
		var basis := Basis.looking_at(-out, Vector3.UP)
		# Panel space: u along basis.x, outer face along +Z (= out).
		var origin := Vector3(base.x, ty, base.z) + out * (apo - 0.09) - basis.x * side * 0.5
		var t := Transform3D(basis, origin)
		var holes := [{"rect": hatch}] if k == 2 else []
		kit.wall(t, side, tank_h, 0.18, holes, Palette.vary(tank_col, 0.03 * (k % 2)), Palette.vary(Palette.c(&"tank_inside"), 0.04 * (k % 3) - 0.04), rust, 4 | 8)
		if k == 2:
			var centre := t * Vector3(hatch.get_center().x, hatch.get_center().y, 0.09)
			ctx.add_opening("water_tower_hatch", "tower", centre, out, hatch.size.x, hatch.size.y, WorldBuild.span_for_gap(hatch.size.x), 3.2, 15)
			kit.box(t * Transform3D(Basis.IDENTITY, Vector3(hatch.get_center().x, hatch.position.y - 0.04, 0.2)), Vector3(1.1, 0.08, 0.26), rust)
			ctx.add_perch(t * Vector3(hatch.get_center().x + 0.25, hatch.position.y, 0.24), out, Perch.Kind.LEDGE, 0.8, &"farm")
	# Tank floor, cap cone, finial, painted band.
	kit.prism(Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(base.x, ty, base.z)), _octagon(apo - 0.1), 0.15, Palette.c(&"rust"))
	kit.cyl(Vector3(base.x, ty + tank_h, base.z), Vector3(base.x, ty + tank_h + 2.6, base.z), (apo + 0.35) / cos(PI / 8.0), 0.0, 8, rust, true, false, PI / 8.0)
	kit.rod(Vector3(base.x, ty + tank_h + 2.4, base.z), Vector3(base.x, ty + tank_h + 3.4, base.z), 0.05, 0.05, 4, metal_d)
	ctx.add_perch(Vector3(base.x, ty + tank_h + 3.4, base.z), Vector3.BACK, Perch.Kind.POLE_TOP, 1.6, &"farm")
	ctx.add_refuge("water_tower_tank", Vector3(base.x, ty + 1.8, base.z), 2.0, WorldBuild.span_for_gap(0.9))
	ctx.add_landmark("water_tower", "tower", Vector3(base.x, ty + 2.5, base.z), 4.0)
	ctx.add_footprint("water_tower", PackedVector2Array([Vector2(c.x - hb, c.y - hb), Vector2(c.x + hb, c.y - hb), Vector2(c.x + hb, c.y + hb), Vector2(c.x - hb, c.y + hb)]), g - 0.8, 2.0, 2.5, -1.0, kit.name)
	ctx.add_feature(c.x, c.y, 5.0, "water_tower")


## Regular octagon with apothem a, flat sides facing the axes, CCW.
static func _octagon(a: float) -> PackedVector2Array:
	var r := a / cos(PI / 8.0)
	var out := PackedVector2Array()
	for k in 8:
		var ang := PI / 8.0 + k * PI / 4.0
		out.append(Vector2(cos(ang), sin(ang)) * r)
	return out


# --- fences and bales --------------------------------------------------

## Post-and-rail fence along a polyline. Every third post top is a perch.
static func fence(ctx: WorldBuild, kit: MeshKit, pts: Array, district: StringName, gap_every := 0) -> void:
	var wood := Palette.c(&"wood")
	var wood_d := Palette.c(&"wood_dark")
	var count := 0
	for i in pts.size() - 1:
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[i + 1]
		var l := a.distance_to(b)
		var n := maxi(1, int(round(l / 2.6)))
		var prev_top := Vector3.ZERO
		for k in n + 1:
			if k == 0 and i > 0:
				prev_top = Vector3(a.x, ctx.ground(a.x, a.y) + 1.2, a.y)
				continue
			var p := a.lerp(b, float(k) / n)
			var g := ctx.ground(p.x, p.y)
			var top := Vector3(p.x, g + 1.2, p.y)
			kit.box(Transform3D(Basis.IDENTITY, Vector3(p.x, g + 0.5, p.y)), Vector3(0.14, 1.4, 0.14), wood_d)
			ctx.add_footprint("fence_post", PackedVector2Array([p]), g - 0.2, 0.5, 2.5, -1.0, kit.name)
			count += 1
			if count % 3 == 0:
				ctx.add_perch(top + Vector3(0, 0.0, 0), Vector3(-(b - a).y, 0, (b - a).x), Perch.Kind.POLE_TOP, 0.66, district)
			if k > 0 and not (gap_every > 0 and count % gap_every == 0):
				for ry in [0.55, 1.0]:
					var pa := Vector3(prev_top.x, prev_top.y - 1.2 + ry, prev_top.z)
					var pb := Vector3(top.x, top.y - 1.2 + ry, top.z)
					kit.beam(pa, pb, 0.06, 0.1, wood)
			prev_top = top
		ctx.add_feature((a.x + b.x) * 0.5, (a.y + b.y) * 0.5, l * 0.5, "fence")


static func _fences(ctx: WorldBuild, rng: RandomNumberGenerator) -> void:
	var kit := ctx.kit("farm")
	var c := WorldLayout.FARM
	# Farm yard: an open-sided paddock south of the barn.
	fence(ctx, kit, [Vector2(c.x - 22, c.y + 16), Vector2(c.x - 22, c.y + 44), Vector2(c.x + 14, c.y + 44), Vector2(c.x + 14, c.y + 28)], &"farm")
	# Along the yard's east side, between the barn and the farmhouse.
	fence(ctx, kit, [Vector2(-241, 150), Vector2(-241, 76)], &"farm")
	# Orchard enclosure (open on the village side).
	var o := WorldLayout.ORCHARD
	fence(ctx, kit, [Vector2(o.x - 42, o.y - 28), Vector2(o.x - 42, o.y + 28), Vector2(o.x + 42, o.y + 28), Vector2(o.x + 42, o.y - 28)], &"orchard")


static func _bales(ctx: WorldBuild, rng: RandomNumberGenerator) -> void:
	var kit := ctx.kit("farm_bales")
	var hay := Palette.c(&"hay")
	var centre := Vector2(-292, 186)
	for i in 11:
		var p := centre + Vector2(rng.randf_range(-26, 26), rng.randf_range(-16, 16))
		var yaw := rng.randf() * PI
		var ax := Vector3(cos(yaw), 0, sin(yaw)) * 0.65
		var ends := PackedVector2Array([p + Vector2(ax.x, ax.z), p - Vector2(ax.x, ax.z), p])
		var g := ctx.ground_min(ends)
		var ctr := Vector3(p.x, g + 0.72, p.y)
		kit.cyl(ctr - ax, ctr + ax, 0.78, 0.78, 10, Palette.vary(hay, rng.randf_range(-0.08, 0.06)), true, true, 0.0, Palette.c(&"wheat_dark"))
		ctx.add_perch(ctr + Vector3(0, 0.77, 0), Vector3(-ax.z, 0, ax.x), Perch.Kind.ROCK, 1.3, &"farm")
		ctx.add_feature(p.x, p.y, 1.0, "bale")
		ctx.add_footprint("bale_%d" % i, ends, g - 0.06, 0.8, 2.5, -1.0, kit.name)
