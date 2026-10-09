extends RefCounted
## Top-down maps of AI runs: the world's static geometry (from its layer-1
## collision shapes), thermals, refuges and perches, bird tracks coloured by
## size group, catches. Colours follow the data-viz reference palette: the
## three all-pairs-safe categorical slots for the three size groups (ten
## species would be unreadable as ten hues), ink for markers and text.

const Plot := preload("res://tests/unit/ai/ai_plot.gd")
const SURFACE := Color("#fcfcfb")
const INK := Color("#0b0b0b")
const INK2 := Color("#52514e")
const GEOM := Color("#cfcec8")
const THERMAL := Color("#8a8983")
const GROUP_COLORS := [Color("#2a78d6"), Color("#1baf7a"), Color("#eb6834")]
const GROUP_NAMES := ["MOTH WREN SPARROW SWALLOW", "STARLING PIGEON CROW", "GULL HAWK EAGLE"]


static func group_of(species: StringName) -> int:
	var i := SizeRules.species_index(species)
	return 0 if i <= 3 else (1 if i <= 6 else 2)


static func map(world: World, px: int, center: Vector2, half: float) -> Plot:
	var pl := Plot.new(px, px, SURFACE, center - Vector2(half, half), center + Vector2(half, half))
	var k := px / (2.0 * half)
	# Arena edge.
	pl.circle(pl.px(Vector2.ZERO), world.bounds_radius * k, INK2)
	for body in world.find_children("*", "StaticBody3D", true, false):
		for cs in body.get_children():
			var col := cs as CollisionShape3D
			if col == null or col.shape == null:
				continue
			var xf := col.global_transform
			if col.shape is BoxShape3D:
				var sz: Vector3 = (col.shape as BoxShape3D).size * 0.5
				var pts := PackedVector2Array()
				for c in [Vector3(-sz.x, 0, -sz.z), Vector3(sz.x, 0, -sz.z), Vector3(sz.x, 0, sz.z), Vector3(-sz.x, 0, sz.z)]:
					var w: Vector3 = xf * c
					pts.append(pl.px(Vector2(w.x, w.z)))
				pl.poly(pts, GEOM)
			elif col.shape is CylinderShape3D:
				var o := xf.origin
				pl.circle(pl.px(Vector2(o.x, o.z)), maxf((col.shape as CylinderShape3D).radius * k, 1.0), GEOM, true)
			elif col.shape is SphereShape3D:
				var o2 := xf.origin
				pl.circle(pl.px(Vector2(o2.x, o2.z)), (col.shape as SphereShape3D).radius * k, GEOM, true)
	var h := Habitat.for_world(world)
	for t in h.thermals:
		var tp: Vector3 = t["position"]
		pl.circle(pl.px(Vector2(tp.x, tp.z)), float(t["radius"]) * k, THERMAL)
		pl.circle(pl.px(Vector2(tp.x, tp.z)), float(t["radius"]) * k + 1.0, THERMAL)
	for r in h.refuges:
		var rp: Vector3 = r["position"]
		var q := pl.px(Vector2(rp.x, rp.z))
		pl.rect(q - Vector2(2, 2), q + Vector2(2, 2), INK2, false)
	return pl


## tracks: {key: {"species": StringName, "pts": PackedVector3Array}}
static func draw_tracks(pl: Plot, tracks: Dictionary, alpha: float = 0.45, only_group: int = -1) -> void:
	for key in tracks:
		var tr: Dictionary = tracks[key]
		var g := group_of(tr["species"])
		if only_group >= 0 and g != only_group:
			continue
		var c: Color = GROUP_COLORS[g]
		c.a = alpha
		var pts := PackedVector2Array()
		for p: Vector3 in tr["pts"]:
			pts.append(pl.top(p))
		pl.polyline(pts, c)


static func draw_catches(pl: Plot, catches: Array) -> void:
	for c in catches:
		pl.cross(pl.top(c["position"]), INK, 3)


static func legend(pl: Plot, at: Vector2, extra: Array = []) -> void:
	var y := at.y
	for i in 3:
		pl.rect(Vector2(at.x, y + 2), Vector2(at.x + 16, y + 10), GROUP_COLORS[i])
		pl.text(Vector2(at.x + 22, y), GROUP_NAMES[i], INK, 2)
		y += 20
	pl.cross(Vector2(at.x + 8, y + 7), INK, 4)
	pl.text(Vector2(at.x + 22, y), "CATCH", INK, 2)
	y += 20
	pl.circle(Vector2(at.x + 8, y + 7), 6, THERMAL)
	pl.text(Vector2(at.x + 22, y), "THERMAL", INK, 2)
	y += 20
	for line in extra:
		pl.text(Vector2(at.x, y), String(line), INK2, 2)
		y += 18
