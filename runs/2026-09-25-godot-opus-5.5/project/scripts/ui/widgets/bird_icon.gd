class_name BirdIcon
extends Control
## A flat, faceted bird silhouette seen from below, wings spread: the
## field-guide view, which reads as "bird" at any size (a side view with a
## raised wing reads as a fish). Each species has its own shape, so the
## shape says *what* a bird is (forked swallow tail, fingered eagle wings,
## bent gull wings, a moth's four wings) while the colour says what it is
## *to you*: prey worth chasing, prey too small to bother with, threat,
## you, or neutral. Used on the food-chain ladder, the catch tally, the
## caught screen and the HUD growth strip.

## DUST: you could eat it, but it is not worth the chase any more
## (SizeRules.is_worthwhile is false): drawn muted and faded, so the ladder
## shows the smallest birds dropping off your menu as you grow.
enum Relation { NEUTRAL, PREY, THREAT, YOU, DUST }

@export var relation: Relation = Relation.NEUTRAL
## 0..1 visual size within the rect (the ladder row sizes birds by tier).
@export var fill := 1.0
## Unused by the from-below view (kept for callers that set it).
@export var facing := 1.0
@export var species: StringName = &"sparrow"

## Silhouette height as a fraction of wingspan (fits the tallest species).
const ASPECT := 0.8

## Shape per species, in units of wingspan (x right, y towards the tail):
##   chord  wing depth at the body    sweep  how far back the tip sits
##   bend   wrist pushed forward      tip    point | round | fingers
##   fingers  count of primaries       tail   fork | square | fan | wedge | notch
##   tail_len / tail_w, head (radius), body (width, length), bill (length)
const SHAPES := {
	&"wren": {"chord": 0.25, "sweep": 0.03, "bend": 0.0, "tip": "round", "tail": "fan", "tail_len": 0.12, "tail_w": 0.1,
		"head": 0.1, "body": Vector2(0.26, 0.3), "bill": 0.05},
	&"sparrow": {"chord": 0.22, "sweep": 0.05, "bend": 0.0, "tip": "round", "tail": "notch", "tail_len": 0.2, "tail_w": 0.12,
		"head": 0.08, "body": Vector2(0.17, 0.34), "bill": 0.04},
	&"swallow": {"chord": 0.13, "sweep": 0.2, "bend": 0.02, "tip": "point", "tail": "fork", "tail_len": 0.36, "tail_w": 0.16,
		"head": 0.06, "body": Vector2(0.11, 0.32), "bill": 0.02},
	&"starling": {"chord": 0.2, "sweep": 0.12, "bend": 0.0, "tip": "point", "tail": "square", "tail_len": 0.13, "tail_w": 0.12,
		"head": 0.07, "body": Vector2(0.14, 0.32), "bill": 0.07},
	&"pigeon": {"chord": 0.21, "sweep": 0.1, "bend": 0.0, "tip": "point", "tail": "fan", "tail_len": 0.24, "tail_w": 0.16,
		"head": 0.06, "body": Vector2(0.17, 0.38), "bill": 0.03},
	&"crow": {"chord": 0.24, "sweep": 0.03, "bend": 0.0, "tip": "fingers", "fingers": 4, "hand": 0.39, "tail": "fan", "tail_len": 0.24,
		"tail_w": 0.17, "head": 0.085, "body": Vector2(0.15, 0.36), "bill": 0.08},
	&"gull": {"chord": 0.12, "sweep": 0.15, "bend": 0.1, "tip": "point", "tail": "square", "tail_len": 0.12, "tail_w": 0.13,
		"head": 0.07, "body": Vector2(0.13, 0.34), "bill": 0.06},
	&"hawk": {"chord": 0.29, "sweep": 0.03, "bend": 0.0, "tip": "fingers", "fingers": 4, "hand": 0.4, "tail": "fan", "tail_len": 0.24,
		"tail_w": 0.22, "head": 0.08, "body": Vector2(0.16, 0.34), "bill": 0.03},
	&"eagle": {"chord": 0.28, "sweep": 0.0, "bend": 0.0, "tip": "fingers", "fingers": 5, "hand": 0.34, "tail": "wedge", "tail_len": 0.16,
		"tail_w": 0.17, "head": 0.09, "body": Vector2(0.17, 0.36), "bill": 0.08},
}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func setup(p_relation: Relation, p_fill: float = 1.0, p_species: StringName = &"") -> BirdIcon:
	relation = p_relation
	fill = p_fill
	if p_species != &"":
		species = p_species
	queue_redraw()
	return self


static func color_for(rel: Relation) -> Color:
	match rel:
		Relation.PREY:
			return UITheme.PREY
		Relation.THREAT:
			return UITheme.THREAT
		Relation.YOU:
			return UITheme.FEATHER
		Relation.DUST:
			return UITheme.DUST
	return UITheme.TEXT_DISABLED


func _draw() -> void:
	var span := minf(size.x, size.y / ASPECT) * clampf(fill, 0.2, 1.0)
	draw_species(self, size * 0.5, span, species, color_for(relation))
	if relation == Relation.YOU:
		# A ring marks "you" in the ladder.
		var r := minf(size.x, size.y) * 0.5 - 3.0
		var pts := PackedVector2Array()
		for i in 7:
			var a := TAU * i / 6.0 + PI / 6.0
			pts.append(size * 0.5 + Vector2(cos(a), sin(a)) * r)
		draw_polyline(pts, UITheme.ACCENT, 4.0)


## Draw `sp` seen from below, centred on c, `span` px wing tip to wing tip.
## Faceted like the rest of the art: wing coverts, darker flight feathers
## (split on a diagonal, as real feather tracts are), body, head and tail
## are separate flat polygons.
static func draw_species(ci: CanvasItem, c: Vector2, span: float, sp: StringName, col: Color) -> void:
	if sp == &"moth":
		_draw_moth(ci, c, span, col)
		return
	var p: Dictionary = SHAPES.get(sp, SHAPES[&"sparrow"])
	var body: Vector2 = p["body"]
	var hr: float = p["head"]
	# Centre the whole silhouette (bill tip .. tail end) on c.
	var top := -body.y * 0.5 - hr * 1.5 - float(p["bill"])
	var bottom := body.y * 0.4 + float(p["tail_len"])
	var o := c - Vector2(0.0, (top + bottom) * 0.5 * span)
	var dark := col.darkened(0.2)
	var mid := col.darkened(0.07)
	GestureArt.poly(ci, _px(_tail(p), o, span), dark)
	for sd: float in [-1.0, 1.0]:
		var w := _wing(p, sd)
		GestureArt.poly(ci, _px(w[0], o, span), col)
		GestureArt.poly(ci, _px(w[1], o, span), dark)
		for f: PackedVector2Array in w[2]:
			GestureArt.poly(ci, _px(f, o, span), dark)
	# Body: a teardrop, widest at the chest, narrowing to the vent.
	var hw := body.x * 0.5
	var bl := body.y * 0.5
	var torso := PackedVector2Array([Vector2(0.0, -bl - hr * 0.2), Vector2(hw * 0.7, -bl * 0.75), Vector2(hw, -bl * 0.2),
		Vector2(hw * 0.8, bl * 0.45), Vector2(hw * 0.35, bl), Vector2(-hw * 0.35, bl), Vector2(-hw * 0.8, bl * 0.45),
		Vector2(-hw, -bl * 0.2), Vector2(-hw * 0.7, -bl * 0.75)])
	GestureArt.poly(ci, _px(torso, o, span), mid)
	var hc := Vector2(0.0, -bl - hr * 0.55)
	GestureArt.poly(ci, _px(_ellipse(hc, Vector2(hr, hr * 1.05), 8), o, span), mid.darkened(0.06))
	var bill: float = p["bill"]
	if bill > 0.0:
		var by := hc.y - hr * 0.9
		GestureArt.poly(ci, _px(PackedVector2Array([Vector2(-hr * 0.38, by + hr * 0.25), Vector2(0.0, by - bill),
			Vector2(hr * 0.38, by + hr * 0.25)]), o, span), UITheme.ACCENT.darkened(0.15))


## [coverts polygon, flight-feather polygon, finger polygons] for one wing
## (sd = -1 left, +1 right), in wingspan units (tip at x = 0.5).
static func _wing(p: Dictionary, sd: float) -> Array:
	var ch: float = p["chord"]
	var sw: float = p["sweep"]
	var bend: float = p["bend"]
	var x0: float = Vector2(p["body"]).x * 0.3
	var xw := 0.24
	# Leading edge: root, then the wrist (a little forward, a lot for a gull).
	var a := Vector2(x0, -ch * 0.45)
	var wr := Vector2(xw, -ch * 0.52 - bend)
	var root_te := Vector2(x0, ch * 0.55)
	# End of the secondaries on the trailing edge: the covert/primary split
	# runs diagonally from the wrist to here.
	var s1 := Vector2(xw + 0.06, ch * 0.5 + sw * 0.45)
	var inner := PackedVector2Array([a, wr, s1, root_te])
	var outer := PackedVector2Array()
	var fingers: Array[PackedVector2Array] = []
	match str(p["tip"]):
		"point":
			# Swept, pointed hand; trailing edge curving in towards the tip.
			outer = PackedVector2Array([wr, Vector2(0.4, -ch * 0.35 + sw * 0.55), Vector2(0.5, sw), Vector2(0.42, sw * 0.85 + ch * 0.2), s1])
		"round":
			# Short rounded hand: the tip is an arc, the trailing edge bows.
			outer.append(wr)
			for i in 6:
				var t := i / 5.0
				var ang := lerpf(-PI * 0.5, PI * 0.45, t)
				outer.append(Vector2(0.39, sw + ch * 0.02) + Vector2(cos(ang) * 0.11, sin(ang) * ch * 0.5))
			outer.append(s1)
		"fingers":
			# A broad hand whose tip splits into separate primaries; the
			# slots between them are what reads as "big bird of prey".
			var hand: float = p.get("hand", 0.4)
			var y0 := -ch * 0.5 + sw
			var y1 := ch * 0.42 + sw
			outer = PackedVector2Array([wr, Vector2(hand, y0), Vector2(hand, y1), s1])
			var n: int = p.get("fingers", 5)
			var pitch := (y1 - y0) / n
			for i in n:
				var fy := y0 + pitch * (i + 0.5)
				# Front fingers reach furthest and the fan sweeps back; each
				# finger tapers to a blunt tip with a clear slot between.
				var reach := 0.5 - float(i) / n * (0.5 - hand) * 0.45
				var hwf := pitch * 0.4
				var back := (reach - hand) * 0.25 * (float(i) / maxf(1.0, n - 1.0))
				fingers.append(PackedVector2Array([Vector2(hand - 0.02, fy - hwf), Vector2(reach, fy - hwf * 0.55 + back),
					Vector2(reach, fy + hwf * 0.35 + back), Vector2(hand - 0.02, fy + hwf)]))
	var out := [_mirror(inner, sd), _mirror(outer, sd), []]
	for f in fingers:
		out[2].append(_mirror(f, sd))
	return out


static func _tail(p: Dictionary) -> PackedVector2Array:
	var y0: float = Vector2(p["body"]).y * 0.3
	var l: float = p["tail_len"]
	var w: float = p["tail_w"]
	var r := w * 0.3
	match str(p["tail"]):
		"fork":
			return PackedVector2Array([Vector2(-r, y0), Vector2(r, y0), Vector2(w * 0.5, y0 + l), Vector2(0.0, y0 + l * 0.45),
				Vector2(-w * 0.5, y0 + l)])
		"notch":
			return PackedVector2Array([Vector2(-r, y0), Vector2(r, y0), Vector2(w * 0.5, y0 + l), Vector2(0.0, y0 + l * 0.85),
				Vector2(-w * 0.5, y0 + l)])
		"wedge":
			return PackedVector2Array([Vector2(-r, y0), Vector2(r, y0), Vector2(w * 0.5, y0 + l * 0.8), Vector2(0.0, y0 + l),
				Vector2(-w * 0.5, y0 + l * 0.8)])
		"fan":
			var pts := PackedVector2Array([Vector2(r, y0)])
			for i in 5:
				var a := lerpf(0.35, PI - 0.35, i / 4.0)
				pts.append(Vector2(0.0, y0 + l - w * 0.5) + Vector2(cos(a), sin(a)) * w * 0.5)
			pts.append(Vector2(-r, y0))
			return pts
	return PackedVector2Array([Vector2(-r, y0), Vector2(r, y0), Vector2(w * 0.5, y0 + l), Vector2(-w * 0.5, y0 + l)])


static func _draw_moth(ci: CanvasItem, c: Vector2, span: float, col: Color) -> void:
	var dark := col.darkened(0.22)
	var o := c + Vector2(0.0, -0.02 * span)
	for sd: float in [-1.0, 1.0]:
		var fore := PackedVector2Array([Vector2(0.03, -0.08), Vector2(0.5, -0.2), Vector2(0.44, 0.02), Vector2(0.03, 0.05)])
		var hind := PackedVector2Array([Vector2(0.03, 0.03), Vector2(0.3, 0.07), Vector2(0.33, 0.2), Vector2(0.18, 0.27), Vector2(0.03, 0.17)])
		GestureArt.poly(ci, _px(_mirror(hind, sd), o, span), dark)
		GestureArt.poly(ci, _px(_mirror(fore, sd), o, span), col)
		var tip := _mirror(PackedVector2Array([Vector2(0.03, -0.14), Vector2(0.14, -0.3)]), sd)
		ci.draw_line(o + tip[0] * span, o + tip[1] * span, dark, maxf(1.5, span * 0.02))
	GestureArt.poly(ci, _px(_ellipse(Vector2(0.0, 0.04), Vector2(0.04, 0.2), 6), o, span), dark.darkened(0.1))


static func _mirror(pts: PackedVector2Array, sd: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for q in pts:
		out.append(Vector2(q.x * sd, q.y))
	if sd < 0.0:
		out.reverse()
	return out


static func _ellipse(c: Vector2, r: Vector2, n: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in n:
		var a := TAU * i / n
		out.append(c + Vector2(cos(a) * r.x, sin(a) * r.y))
	return out


static func _px(pts: PackedVector2Array, o: Vector2, span: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for q in pts:
		out.append(o + q * span)
	return out
