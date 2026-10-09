class_name Emblem
extends Control
## The title-screen emblem: a big low-poly bird soaring (seen from below),
## built from flat facets in cream, sand and sunflower over a sun disc.
## Drawn, not imported, so it stays crisp at any panel resolution. Static on
## purpose: an idle animation would make the main menu panel re-render every
## frame (U7: panels render only when something changed).


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	var c := size * 0.5
	var u := minf(size.x / 10.0, size.y / 6.0)
	# Sun: a faceted 10-gon behind the bird.
	var sun := PackedVector2Array()
	for i in 10:
		var a := TAU * i / 10.0 + 0.1
		sun.append(c + Vector2(u * 0.9, -u * 0.9) + Vector2(cos(a), sin(a)) * u * 1.9)
	GestureArt.poly(self, sun, Color(UITheme.ACCENT, 0.9))
	var sun2 := PackedVector2Array()
	for i in 10:
		var a := TAU * i / 10.0 + 0.1
		sun2.append(c + Vector2(u * 0.9, -u * 0.9) + Vector2(cos(a), sin(a)) * u * 1.35)
	GestureArt.poly(self, sun2, UITheme.ACCENT.lightened(0.25))
	var xf := Transform2D(-0.06, c + Vector2(0, u * 0.3))
	var cream := UITheme.FEATHER
	var sand := UITheme.FEATHER_DARK
	var deep := Color("8b7656")
	# Wings: three facets each, swept back; primaries fingered at the tips.
	for s: float in [-1.0, 1.0]:
		var facets := [
			[Vector2(0.2 * s, -0.5), Vector2(2.2 * s, -1.0), Vector2(1.6 * s, 0.25), Vector2(0.25 * s, 0.35)],
			[Vector2(2.2 * s, -1.0), Vector2(4.2 * s, -0.55), Vector2(3.3 * s, 0.1), Vector2(1.6 * s, 0.25)],
			[Vector2(4.2 * s, -0.55), Vector2(4.8 * s, -0.2), Vector2(3.3 * s, 0.1)],
		]
		var cols := [cream, sand, deep]
		for i in facets.size():
			var poly := PackedVector2Array()
			for p: Vector2 in facets[i]:
				poly.append(xf * (p * u))
			GestureArt.poly(self, poly, cols[i] if s > 0 else cols[i].darkened(0.06))
		# Finger feathers.
		for k in 3:
			var base := Vector2((3.5 + k * 0.4) * s, 0.02 - k * 0.12)
			var tip := base + Vector2(0.45 * s, 0.45)
			GestureArt.poly(self, PackedVector2Array([xf * (base * u), xf * ((base + Vector2(0.3 * s, -0.1)) * u), xf * (tip * u)]), deep)
	# Body, head and tail fan.
	var body := [Vector2(0, -0.95), Vector2(0.38, -0.45), Vector2(0.3, 0.6), Vector2(0, 0.85), Vector2(-0.3, 0.6), Vector2(-0.38, -0.45)]
	var bp := PackedVector2Array()
	for p: Vector2 in body:
		bp.append(xf * (p * u))
	GestureArt.poly(self, bp, sand)
	GestureArt.poly(self, PackedVector2Array([bp[0], bp[1], bp[2], bp[3]]), cream)
	var tail := PackedVector2Array([xf * (Vector2(-0.25, 0.7) * u), xf * (Vector2(0.25, 0.7) * u), xf * (Vector2(0.55, 1.55) * u), xf * (Vector2(0, 1.4) * u), xf * (Vector2(-0.55, 1.55) * u)])
	GestureArt.poly(self, tail, deep)
	var head := PackedVector2Array([xf * (Vector2(-0.22, -0.85) * u), xf * (Vector2(0, -1.3) * u), xf * (Vector2(0.22, -0.85) * u)])
	GestureArt.poly(self, head, cream)
	GestureArt.poly(self, PackedVector2Array([xf * (Vector2(-0.08, -1.2) * u), xf * (Vector2(0, -1.45) * u), xf * (Vector2(0.08, -1.2) * u)]), UITheme.ACCENT.darkened(0.15))
