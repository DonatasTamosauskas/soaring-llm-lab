class_name PowerLineBuilder
extends RefCounted
## The power-line corridor between the village and the forest: wooden poles
## with cross-arms and insulators carrying three sagging wires. Wires are
## thin tubes that collide as chains of thin capsules (fast small birds must
## not tunnel through them), and are the classic perch for small birds.

const POLE_H := 9.6
const SAG := 0.95
const SEGS := 12
const WIRE_R_VIS := 0.014
const WIRE_R_COL := 0.02


static func build(ctx: WorldBuild) -> void:
	var rng := ctx.sub_rng("powerline")
	var kit := ctx.kit("powerline")
	kit.jitter = 0.03
	var line: Array[Vector2] = WorldLayout.POWER_LINE
	var total := WorldLayout.polyline_length(line)
	var n := WorldLayout.POWER_POLES
	var poles: Array[Dictionary] = []
	for i in n:
		var s := total * float(i) / float(n - 1)
		var at := WorldLayout.polyline_at(line, s)
		var p: Vector2 = at[0]
		var dir: Vector2 = at[1]
		# Never plant a pole in the river: slide it along the line.
		var guard := 0
		while WorldLayout.polyline_distance(p, WorldLayout.RIVER) < 13.0 and guard < 20:
			s += 2.0 if i < n / 2 else -2.0
			at = WorldLayout.polyline_at(line, s)
			p = at[0]
			guard += 1
		poles.append(_pole(ctx, kit, rng, p, dir, i))
	# Where the poles really stand (the nest boxes hang on two of them).
	ctx.set_meta(&"poles", poles)
	# Wires between consecutive poles: 3 conductors.
	for i in n - 1:
		var a: Dictionary = poles[i]
		var b: Dictionary = poles[i + 1]
		for w in 3:
			_wire(ctx, kit, a["attach"][w], b["attach"][w], i, w)
	ctx.add_landmark("power_line", "powerline", Vector3(line[1].x, 8.0, line[1].y), total * 0.5)


static func _pole(ctx: WorldBuild, kit: MeshKit, rng: RandomNumberGenerator, p: Vector2, dir: Vector2, idx: int) -> Dictionary:
	var g := ctx.ground(p.x, p.y)
	var base := Vector3(p.x, g - 1.2, p.y)
	var top := Vector3(p.x, g + POLE_H, p.y)
	var pole_c := Palette.c(&"pole")
	# Tapered pole; collides as a capsule of its base radius.
	var was := kit.collide
	kit.collide = false
	kit.cyl(base, top, 0.16, 0.12, 7, pole_c, false, true)
	kit.collide = was
	kit.add_capsule(base, top, 0.15)
	var across := Vector3(-dir.y, 0.0, dir.x)
	var arm_y := g + POLE_H - 0.9
	var arm_c := Vector3(p.x, arm_y, p.y)
	kit.beam(arm_c - across * 1.35, arm_c + across * 1.35, 0.13, 0.13, Palette.c(&"wood_dark"))
	# Diagonal braces under the arm.
	for s: float in [-1.0, 1.0]:
		kit.beam(Vector3(p.x, arm_y - 0.8, p.y) + across * 0.05 * s, arm_c + across * 0.75 * s - Vector3(0, 0.07, 0), 0.05, 0.05, Palette.c(&"metal_dark"))
	var ins := Palette.c(&"insulator")
	var attach: Array[Vector3] = []
	for s: float in [-1.1, 1.1]:
		var ib := arm_c + across * s + Vector3(0, 0.065, 0)
		kit.cyl(ib, ib + Vector3(0, 0.26, 0), 0.06, 0.045, 6, ins)
		attach.append(ib + Vector3(0, 0.28, 0))
	# The middle conductor rides a side pin near the top, leaving the pole
	# cap free as a lookout perch.
	var tb := top
	var pin := tb + Vector3(0, -0.35, 0) + across * 0.12
	kit.cyl(pin, pin + across * 0.26, 0.055, 0.04, 6, ins)
	attach.insert(1, pin + across * 0.28 + Vector3(0, 0.03, 0))
	# Every fourth pole carries a transformer drum.
	if idx % 4 == 2:
		var tc := Vector3(p.x, g + 6.2, p.y) + across.cross(Vector3.UP) * 0.5
		kit.cyl(tc - Vector3(0, 0.55, 0), tc + Vector3(0, 0.55, 0), 0.36, 0.36, 8, Palette.c(&"metal"))
		kit.box(Transform3D(Basis.IDENTITY, (tc + Vector3(p.x, g + 6.2, p.y)) * 0.5), Vector3(0.12, 0.12, 0.12), Palette.c(&"metal_dark"))
		ctx.add_perch(tc + Vector3(0, 0.55, 0), across, Perch.Kind.POLE_TOP, 0.95, &"powerline")
	# Perches: the pole cap (hawks), the arm ends (crows, pigeons).
	ctx.add_perch(tb, across, Perch.Kind.POLE_TOP, 2.1, &"powerline")
	for s: float in [-1.3, 1.3]:
		ctx.add_perch(arm_c + across * s + Vector3(0, 0.065, 0), across * signf(s), Perch.Kind.POLE_TOP, 1.0, &"powerline")
	ctx.add_feature(p.x, p.y, 2.0, "pole")
	ctx.add_footprint("pole_%d" % idx, PackedVector2Array([p]), g - 1.2, 1.5, 2.5, -1.0, kit.name)
	return {"attach": attach, "pos": p, "base": base, "top": top, "r0": 0.16, "r1": 0.12, "sides": 7, "r_col": 0.15}


static func _wire(ctx: WorldBuild, kit: MeshKit, a: Vector3, b: Vector3, span_idx: int, w: int) -> void:
	var col := Palette.c(&"wire")
	var pts := PackedVector3Array()
	for k in SEGS + 1:
		var t := float(k) / SEGS
		# Parabolic catenary: deepest sag mid-span.
		pts.append(a.lerp(b, t) + Vector3(0, -4.0 * SAG * t * (1.0 - t), 0))
	var was := kit.collide
	kit.collide = false
	for k in SEGS:
		kit.cyl(pts[k], pts[k + 1], WIRE_R_VIS, WIRE_R_VIS, 4, col, false, false)
		kit.add_capsule(pts[k], pts[k + 1], WIRE_R_COL)
	kit.collide = was
	# A perch every ~5 m, not too close to the insulators.
	var across := (b - a).cross(Vector3.UP).normalized()
	for k in range(2, SEGS - 1, 2):
		var p := pts[k] + Vector3(0, WIRE_R_COL, 0)
		ctx.add_perch(p, across if (k / 2) % 2 == 0 else -across, Perch.Kind.WIRE, 1.0, &"powerline")
