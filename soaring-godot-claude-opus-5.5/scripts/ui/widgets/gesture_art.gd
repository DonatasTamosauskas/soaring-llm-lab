class_name GestureArt
extends RefCounted
## Flat low-poly illustrations of the flying gestures, drawn with CanvasItem
## polygons so they scale to any card, cost no textures and match the world's
## faceted style. Each art id is one gesture; `t` (seconds) animates it.
##
## The figure is the player seen from the front wearing a headset, arms out
## as wings, with feathers hanging off each arm and a controller in each hand.

const IDS: Array[StringName] = [&"flap", &"glide", &"speed", &"turn", &"dive", &"perch", &"hunt", &"spread", &"controls"]

const SHIRT := Color("3f7fa8")
const SHIRT_DARK := Color("336a8d")
const VISOR := Color("16212f")
const ARROW := UITheme.ACCENT
const LIFT := Color("5fe0a8")
const AIR := Color(1, 1, 1, 0.55)
const BRANCH := Color("8a5a3c")
const LEAF := Color("5d9e4a")
const LEAF_DARK := Color("4a843b")


static func draw(ci: CanvasItem, id: StringName, rect: Rect2, t: float) -> void:
	match id:
		&"flap":
			_flap(ci, rect, t)
		&"glide", &"spread":
			_glide(ci, rect, t, id == &"spread")
		&"speed":
			_speed(ci, rect, t)
		&"turn":
			_turn(ci, rect, t)
		&"dive":
			_dive(ci, rect, t)
		&"perch":
			_perch(ci, rect, t)
		&"hunt":
			_hunt(ci, rect, t)
		&"controls":
			_controls(ci, rect, t)


# --- scenes -----------------------------------------------------------------

static func _flap(ci: CanvasItem, r: Rect2, t: float) -> void:
	var u := _unit(r)
	# Figure plus lift arrow span 7.4 u; centre that span in the card.
	var c := r.get_center() + Vector2(0, u * 2.1)
	# Downstroke faster than upstroke, like the birds: 40% of the cycle down.
	var ph := fposmod(t / 1.3, 1.0)
	var k := ph / 0.4 if ph < 0.4 else 1.0 - (ph - 0.4) / 0.6
	var down := _smooth(k)
	var hi := deg_to_rad(42.0)
	var lo := deg_to_rad(-28.0)
	var ang := lerpf(hi, lo, down)
	# Ghost arms at both ends of the stroke show its range in a still frame.
	for sd: float in [-1.0, 1.0]:
		for a: float in [hi, lo]:
			var sh := c + Vector2(sd * 1.15, -2.0) * u
			ci.draw_line(sh, sh + Vector2(sd * cos(a), -sin(a)) * u * 3.3, Color(UITheme.TEXT, 0.16), u * 0.36)
	_figure(ci, c, u, ang, ang, 1.0, 0.0)
	# Stroke arrows outside the wingtips, bright on the downstroke.
	var a_col := Color(ARROW, 1.0 if ph < 0.4 else 0.55)
	for sd: float in [-1.0, 1.0]:
		var x := c.x + sd * u * 5.3
		_arrow(ci, Vector2(x, c.y - u * 3.1), Vector2(x, c.y + u * 0.2), a_col, u * 0.34)
	# Lift arrow above the head, longest just after the downstroke.
	var lift := lerpf(0.9, 1.5, down if ph < 0.5 else 0.3)
	var top := c.y - u * 4.4
	_arrow(ci, Vector2(c.x, top), Vector2(c.x, top - u * lift), LIFT, u * 0.42)


static func _glide(ci: CanvasItem, r: Rect2, t: float, spread_only: bool) -> void:
	var u := _unit(r)
	var bob := sin(t * 1.6) * u * 0.12
	var c := r.get_center() + Vector2(0, u * 0.6 + bob)
	_figure(ci, c, u, deg_to_rad(4.0), deg_to_rad(4.0), 1.0, 0.0)
	if spread_only:
		# Arrows pushing the hands outwards: "spread wide".
		for s: float in [-1.0, 1.0]:
			_arrow(ci, Vector2(c.x + s * u * 3.3, c.y - u * 2.4), Vector2(c.x + s * u * 4.6, c.y - u * 2.4), ARROW, u * 0.34)
	else:
		# Air streaming past: a few speed lines behind the figure.
		for i in 3:
			var y := c.y + u * (1.4 + i * 0.7)
			var x0 := r.position.x + u * (0.6 + i * 0.5)
			var off := fposmod(t * 3.0 + i * 0.4, 1.0) * u * 0.8
			ci.draw_line(Vector2(x0 + off, y), Vector2(x0 + off + u * 1.6, y), AIR, u * 0.12)
			ci.draw_line(Vector2(r.end.x - x0 - off - u * 1.6, y), Vector2(r.end.x - x0 - off, y), AIR, u * 0.12)


static func _speed(ci: CanvasItem, r: Rect2, t: float) -> void:
	# Two side views of a wing: edge up = balloon, then slow; edge down =
	# nose down and fast. Each half: label, wing section with a twist arrow,
	# and the flight path it produces with a bird at the end.
	var half := Vector2(r.size.x * 0.5, r.size.y)
	var u := _unit(r)
	var labels := u >= 22.0
	for side in 2:
		var q := Rect2(r.position + Vector2(half.x * side, 0), half)
		var up := side == 0
		var col := LIFT if up else ARROW
		if labels:
			var f := UITheme.font(900)
			var txt := "Slow" if up else "Fast"
			var w := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FS_BODY).x
			ci.draw_string(f, Vector2(q.get_center().x - w * 0.5, q.position.y + f.get_ascent(UITheme.FS_BODY) - UITheme.LINE_TIGHTEN + u * 0.1),
				txt, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FS_BODY, col)
		var wob := sin(t * 2.0) * 0.06
		var pitch := deg_to_rad(18.0 if up else -18.0) + wob
		var chord := minf(q.size.x * 0.46, u * 4.6)
		var wc := q.position + Vector2(q.size.x * 0.56, q.size.y * (0.47 if labels else 0.36))
		_airfoil(ci, wc, chord, pitch)
		# Twist arrow hugging the leading edge, turning the way it tilts.
		var lead := wc + Vector2(-chord * 0.5, 0).rotated(pitch)
		# Up: sweep upward along the leading edge; down: sweep downward.
		_curved_arrow(ci, lead, u * 0.9, deg_to_rad(150.0 if up else 210.0), deg_to_rad(250.0 if up else 110.0), col, u * 0.24)
		# Flight path below: balloon (rises then flattens) vs dive (steepening).
		var x0 := q.position.x + q.size.x * 0.08
		var x1 := q.position.x + q.size.x * 0.72
		var y0 := q.position.y + q.size.y * 0.84
		var pts := PackedVector2Array()
		for i in 13:
			var fr := i / 12.0
			# Balloon: rises then settles. Dive: starts high, steepens.
			var y := y0 - sin(fr * PI * 0.8) * u * 1.2 if up else y0 - u * 1.4 + fr * fr * u * 1.3
			pts.append(Vector2(lerpf(x0, x1, fr), y))
		ci.draw_polyline(pts, Color(col, 0.9), u * 0.16, true)
		var tip := pts[pts.size() - 1]
		var dir := (tip - pts[pts.size() - 2]).normalized()
		draw_bird(ci, tip + dir * u * 1.2, u * 1.9, UITheme.FEATHER, 1.0, 0.2)
		# Speed streaks behind the bird: one when slow, four when fast.
		for i in (1 if up else 4):
			var yy := tip.y + u * (0.7 + i * 0.25)
			ci.draw_line(Vector2(tip.x - u * (1.8 + i * 0.35), yy), Vector2(tip.x - u * 0.3, yy), AIR, u * 0.09)
	var mx := r.position.x + r.size.x * 0.5
	ci.draw_line(Vector2(mx, r.position.y + u * 0.6), Vector2(mx, r.end.y - u * 0.6), Color(UITheme.TEXT_DIM, 0.3), 3.0)


static func _turn(ci: CanvasItem, r: Rect2, t: float) -> void:
	var u := _unit(r)
	var c := r.get_center() + Vector2(0, u * 1.9)
	var k := 0.5 + 0.5 * sin(t * 1.4)
	# Arms as the player holds them: left hand a little higher (dihedral)
	# and each wrist twisted the opposite way; the body stays upright.
	var ang_l := deg_to_rad(8.0 + 16.0 * k)
	var ang_r := deg_to_rad(8.0 - 16.0 * k)
	_figure(ci, c, u, ang_l, ang_r, 1.0, 0.0)
	# Side-view insets above each hand: left edge up (more lift), right edge
	# down (less lift) -> the bird rolls right.
	for sd: float in [-1.0, 1.0]:
		var ang := ang_l if sd < 0.0 else ang_r
		var hand := c + Vector2(sd * 1.15, -2.0) * u + Vector2(sd * cos(ang), -sin(ang)) * u * 3.3
		var inset := hand + Vector2(sd * u * 0.3, -u * 1.6)
		var up := sd < 0.0
		var pitch := deg_to_rad(22.0 if up else -22.0) * (0.4 + 0.6 * k)
		_airfoil(ci, inset, u * 2.0, pitch)
		var lead := inset + Vector2(-u, 0).rotated(pitch)
		_curved_arrow(ci, lead, u * 0.62, deg_to_rad(150.0 if up else 210.0), deg_to_rad(250.0 if up else 110.0), LIFT if up else ARROW, u * 0.2)
	# The result: a sweep to the right over the head.
	var ctr := c + Vector2(0, -u * 3.2)
	var pts := PackedVector2Array()
	for i in 12:
		var a := lerpf(deg_to_rad(-145.0), deg_to_rad(-35.0), i / 11.0)
		pts.append(ctr + Vector2(cos(a) * 2.0, sin(a) * 0.9) * u)
	ci.draw_polyline(pts, UITheme.TEXT, u * 0.2, true)
	_arrow_head(ci, pts[11], (pts[11] - pts[10]).normalized(), UITheme.TEXT, u * 0.6)


static func _dive(ci: CanvasItem, r: Rect2, t: float) -> void:
	var u := _unit(r)
	var drop := fposmod(t * 0.8, 1.0)
	var c := r.get_center() + Vector2(0, -u * 0.4 + drop * u * 0.6)
	_figure(ci, c, u, deg_to_rad(-70.0), deg_to_rad(-70.0), 0.45, 0.0)
	# Arrows pulling the arms in, and a long dive arrow with speed streaks.
	for s: float in [-1.0, 1.0]:
		_arrow(ci, Vector2(c.x + s * u * 4.4, c.y - u * 0.4), Vector2(c.x + s * u * 2.6, c.y - u * 0.4), ARROW, u * 0.3)
	_arrow(ci, Vector2(c.x + u * 4.1, c.y + u * 0.8), Vector2(c.x + u * 4.1, c.y + u * 3.4), UITheme.THREAT.lightened(0.2), u * 0.36)
	for i in 3:
		var x := c.x - u * (3.6 + i * 0.4)
		var y0 := c.y - u * (2.4 - i * 0.5)
		ci.draw_line(Vector2(x, y0), Vector2(x, y0 - u * 1.4), AIR, u * 0.1)


static func _perch(ci: CanvasItem, r: Rect2, t: float) -> void:
	var u := _unit(r)
	# A branch coming in from the right with two leaf clumps.
	var y := r.position.y + r.size.y * 0.7
	var x0 := r.position.x + r.size.x * 0.38
	var x1 := r.end.x
	poly(ci, PackedVector2Array([
		Vector2(x0, y - u * 0.2), Vector2(x1, y - u * 0.55), Vector2(x1, y + u * 0.45), Vector2(x0, y + u * 0.2)]), BRANCH)
	poly(ci, PackedVector2Array([Vector2(x0, y - u * 0.2), Vector2(x1, y - u * 0.55), Vector2(x1, y - u * 0.1)]), BRANCH.lightened(0.12))
	poly(ci, PackedVector2Array([
		Vector2(x1 - u * 2.6, y - u * 0.4), Vector2(x1 - u * 1.2, y - u * 2.6), Vector2(x1 - u * 0.1, y - u * 0.5)]), LEAF)
	poly(ci, PackedVector2Array([
		Vector2(x1 - u * 3.6, y - u * 0.35), Vector2(x1 - u * 2.7, y - u * 1.8), Vector2(x1 - u * 1.8, y - u * 0.35)]), LEAF_DARK)
	# The approach: descending onto the branch, dashes bunching up as the
	# bird slows (the cue: arrive slowly).
	var land := Vector2(x0 + u * 2.0, y - u * 0.95)
	var start := Vector2(r.position.x + u * 1.2, r.position.y + r.size.y * 0.2)
	var path := func(f: float) -> Vector2:
		return start.lerp(land, f) + Vector2(0, -sin(f * PI) * u * 0.8)
	# A fixed count of dashes (a while-loop on a shrinking step never ends).
	var f := 0.0
	var step := 0.2
	for i in 9:
		ci.draw_line(path.call(f), path.call(minf(f + step * 0.45, 1.0)), Color(UITheme.TEXT, 0.7), u * 0.14)
		f += step
		step *= 0.8
	# The bird glides along and settles on the branch, wings folding.
	var f2 := clampf(fposmod(t * 0.3, 1.0) * 1.3, 0.0, 1.0)
	draw_bird(ci, path.call(f2), u * 2.0, UITheme.FEATHER, 1.0, lerpf(1.0, -0.3, f2))


static func _hunt(ci: CanvasItem, r: Rect2, t: float) -> void:
	var u := _unit(r)
	var cy := r.get_center().y
	var wob := sin(t * 3.0) * u * 0.15
	var prey := Vector2(r.position.x + r.size.x * 0.16, cy + wob)
	var me := Vector2(r.position.x + r.size.x * 0.48, cy)
	var big := Vector2(r.position.x + r.size.x * 0.83, cy - wob)
	draw_bird(ci, prey, u * 1.2, UITheme.PREY, -1.0, sin(t * 9.0))
	draw_bird(ci, me, u * 2.2, UITheme.FEATHER, -1.0, sin(t * 5.0) * 0.6)
	draw_bird(ci, big, u * 3.4, UITheme.THREAT, -1.0, sin(t * 3.5) * 0.5)
	# You chase the small one; the big one chases you.
	_arrow(ci, me + Vector2(-u * 1.5, 0), prey + Vector2(u * 1.0, 0), UITheme.PREY, u * 0.3)
	_arrow(ci, big + Vector2(-u * 2.3, u * 0.9), me + Vector2(u * 1.7, u * 0.9), Color(UITheme.THREAT, 0.9), u * 0.3)


static func _controls(ci: CanvasItem, r: Rect2, t: float) -> void:
	# A left Quest Pro (Touch Pro) controller seen from above: no tracking
	# ring, a rounded head with its tracking cameras, flowing into the grip.
	# Callouts for the only buttons the game uses outside flight: menu
	# (pause), trigger (select) and Y (back). Flying needs no buttons at all.
	var u := _unit(r)
	var labels := u >= 22.0
	# Centred so the enlarged controller (head top -2.2, grip tip +4.0 units
	# of uc from c) sits inside the card.
	var c := Vector2(r.position.x + r.size.x * (0.26 if labels else 0.5), r.get_center().y - u * 0.8)
	# The controller is drawn a size up from the card unit: it is the subject.
	var uc := u * 1.3
	# Head: a faceted rounded shield, wider than the grip.
	var head := PackedVector2Array()
	for i in 9:
		var a := lerpf(PI * 0.92, PI * 2.08, i / 8.0)
		head.append(c + Vector2(-uc * 0.1, -uc * 0.3) + Vector2(cos(a) * 1.75, sin(a) * 1.4) * uc)
	head.append(c + Vector2(1.3, 0.8) * uc)
	head.append(c + Vector2(-1.45, 0.75) * uc)
	poly(ci, head, Color("2f405a"))
	# Grip, tapering towards the stylus tip at the bottom.
	poly(ci, PackedVector2Array([c + Vector2(-1.25, 0.5) * uc, c + Vector2(1.15, 0.45) * uc, c + Vector2(0.75, 2.7) * uc,
		c + Vector2(0.1, 3.1) * uc, c + Vector2(-0.8, 2.6) * uc]), Color("1f2a3a"))
	# Tracking cameras on the front of the head.
	for k in 3:
		ci.draw_circle(c + Vector2(-1.15 + k * 1.1, -1.4 + absf(k - 1) * 0.3) * uc, uc * 0.16, Color("0e141d"))
	# Thumbstick, X/Y buttons, menu button, trigger.
	var stick := c + Vector2(-0.45, -0.2) * uc
	ci.draw_circle(stick, uc * 0.42, Color("111822"))
	ci.draw_circle(stick, uc * 0.3, Color("3a4a60"))
	var ybtn := c + Vector2(0.65, -0.55) * uc
	var xbtn := c + Vector2(0.55, 0.25) * uc
	var menu := c + Vector2(0.15, 1.05) * uc
	var pulse := 0.5 + 0.5 * sin(t * 3.0)
	ci.draw_circle(ybtn, uc * 0.26, UITheme.TEXT_DIM.lerp(UITheme.ACCENT, pulse))
	ci.draw_circle(xbtn, uc * 0.26, Color("8193a8"))
	ci.draw_circle(menu, uc * 0.2, UITheme.ACCENT)
	for k in 3:
		ci.draw_line(menu + Vector2(-uc * 0.1, (k - 1) * uc * 0.07), menu + Vector2(uc * 0.1, (k - 1) * uc * 0.07), UITheme.INK, maxf(1.0, uc * 0.03))
	var trig := c + Vector2(-1.25, -1.0) * uc
	poly(ci, PackedVector2Array([trig + Vector2(-0.3, -0.35) * uc, trig + Vector2(0.35, -0.2) * uc, trig + Vector2(0.2, 0.35) * uc, trig + Vector2(-0.35, 0.2) * uc]), UITheme.PREY)
	if not labels:
		return
	var f := UITheme.font(800)
	# Callouts top to bottom in the same order as the buttons, so leader
	# lines never cross; text starts where the longest label still fits.
	var rows := [[trig, "Trigger: select", UITheme.PREY], [ybtn, "Y / B: back", UITheme.TEXT], [menu, "Menu: pause", UITheme.ACCENT]]
	var widest := 0.0
	for row: Array in rows:
		widest = maxf(widest, f.get_string_size(row[1], HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FS_BODY).x)
	var x_text := minf(r.position.x + r.size.x * 0.5, r.end.x - widest - u * 0.3)
	for i in rows.size():
		var y := r.position.y + r.size.y * (0.2 + i * 0.3)
		var anchor: Vector2 = rows[i][0]
		var col: Color = rows[i][2]
		ci.draw_polyline(PackedVector2Array([anchor, Vector2(x_text - u * 0.8, y), Vector2(x_text - u * 0.3, y)]), Color(col, 0.8), maxf(2.0, u * 0.07), true)
		ci.draw_string(f, Vector2(x_text, y + f.get_ascent(UITheme.FS_BODY) * 0.36), rows[i][1], HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FS_BODY, col)


# --- building blocks ----------------------------------------------------------

static func _unit(r: Rect2) -> float:
	return minf(r.size.x / 11.0, r.size.y / 8.0)


static func _smooth(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)


## The player: headset, torso, arms at elevation angles (rad, + = up),
## feathered wings hanging off the arms, controllers in the hands.
## `ext` 0..1 shortens the arms (tucked), `lean` tilts the whole body.
static func _figure(ci: CanvasItem, c: Vector2, u: float, ang_l: float, ang_r: float, ext: float, lean: float) -> void:
	var xf := Transform2D(lean, c)
	var shoulders := [Vector2(-1.15, -2.0) * u, Vector2(1.15, -2.0) * u]
	# Wings first, so the torso overlaps the wing roots.
	for s in 2:
		var sd := -1.0 if s == 0 else 1.0
		var ang: float = ang_l if s == 0 else ang_r
		var sh: Vector2 = shoulders[s]
		var arm_len := u * 3.3 * lerpf(0.55, 1.0, ext)
		var hand := sh + Vector2(sd * cos(ang), -sin(ang)) * arm_len
		_wing(ci, xf, sh, hand, sd, u, ext)
		# Arm (skin) over the wing's leading edge.
		ci.draw_line(xf * sh, xf * hand, UITheme.SKIN, u * 0.42)
		_controller(ci, xf * hand, u, ang * sd)
	# Torso: a faceted trapezoid in two shades.
	var torso := [Vector2(-1.3, -2.25), Vector2(1.3, -2.25), Vector2(0.95, 1.6), Vector2(-0.95, 1.6)]
	var tp := PackedVector2Array()
	for p in torso:
		tp.append(xf * (p * u))
	poly(ci, tp, SHIRT)
	poly(ci, PackedVector2Array([tp[0], xf * Vector2(0, -2.25 * u), xf * Vector2(0, 1.6 * u), tp[3]]), SHIRT_DARK)
	# Head: an octagon with the headset's visor.
	var head := PackedVector2Array()
	for i in 8:
		var a := TAU * (i + 0.5) / 8.0
		head.append(xf * (Vector2(0, -3.25 * u) + Vector2(cos(a), sin(a)) * u * 0.85))
	poly(ci, head, UITheme.SKIN)
	var visor := PackedVector2Array([
		xf * (Vector2(-0.95, -3.55) * u), xf * (Vector2(0.95, -3.55) * u),
		xf * (Vector2(0.85, -2.95) * u), xf * (Vector2(-0.85, -2.95) * u)])
	poly(ci, visor, VISOR)


## Feathers hanging below an arm: a sawtooth trailing edge, two tones.
static func _wing(ci: CanvasItem, xf: Transform2D, sh: Vector2, hand: Vector2, sd: float, u: float, ext: float) -> void:
	var along := hand - sh
	var n := along.normalized()
	# Downward perpendicular to the arm (towards the feet when arms are level).
	var perp := Vector2(-n.y, n.x) if sd > 0.0 else Vector2(n.y, -n.x)
	if perp.y < 0.0:
		perp = -perp
	var count := 5
	var dark := PackedVector2Array([xf * sh, xf * hand])
	var light := PackedVector2Array([xf * sh, xf * hand])
	for i in range(count, -1, -1):
		var f := i / float(count)
		var base := sh + along * f
		var flen := u * lerpf(1.2, 2.3, 1.0 - absf(f - 0.72)) * lerpf(0.6, 1.0, ext)
		var back := -n * u * 0.35
		dark.append(xf * (base + perp * flen + back))
		light.append(xf * (base + perp * flen * 0.72 + back * 0.8))
		if i > 0:
			var mid := sh + along * ((i - 0.5) / float(count))
			dark.append(xf * (mid + perp * flen * 0.62))
			light.append(xf * (mid + perp * flen * 0.45))
	poly(ci, dark, UITheme.FEATHER_DARK)
	poly(ci, light, UITheme.FEATHER)


static func _controller(ci: CanvasItem, p: Vector2, u: float, rot: float) -> void:
	var hexa := PackedVector2Array()
	for i in 6:
		var a := TAU * i / 6.0 + rot
		hexa.append(p + Vector2(cos(a), sin(a)) * u * 0.42)
	poly(ci, hexa, VISOR)
	var ring := hexa.duplicate()
	ring.append(hexa[0])
	ci.draw_polyline(ring, UITheme.ACCENT, u * 0.1)


## A wing cross-section: rounded leading edge (left), sharp trailing edge.
static func _airfoil(ci: CanvasItem, c: Vector2, chord: float, pitch: float) -> void:
	var pts := PackedVector2Array()
	var top := [Vector2(-0.5, 0.0), Vector2(-0.44, -0.07), Vector2(-0.3, -0.11), Vector2(-0.05, -0.1), Vector2(0.25, -0.05), Vector2(0.5, 0.0)]
	var bot := [Vector2(0.25, 0.02), Vector2(-0.05, 0.03), Vector2(-0.3, 0.03), Vector2(-0.44, 0.03)]
	# Screen y points down, so a positive rotation turns clockwise on screen:
	# rotating by +pitch lifts the leading edge (left) for pitch > 0.
	for p in top + bot:
		pts.append(c + (p * chord).rotated(pitch))
	poly(ci, pts, UITheme.FEATHER)
	# Lower facet shade for the low-poly look.
	var shade := PackedVector2Array([pts[0], pts[5], pts[6], pts[7], pts[8], pts[9]])
	poly(ci, shade, UITheme.FEATHER_DARK)
	# Oncoming air (skipped on small insets, where it is only clutter).
	for i in (3 if chord > 120.0 else 0):
		var y := c.y + (i - 1) * chord * 0.22
		ci.draw_line(Vector2(c.x - chord * 1.0, y), Vector2(c.x - chord * 0.65, y), AIR, chord * 0.03)


static func _arrow(ci: CanvasItem, from: Vector2, to: Vector2, col: Color, width: float) -> void:
	var d := (to - from)
	var len := d.length()
	if len < 1.0:
		return
	var n := d / len
	var head := minf(width * 2.6, len * 0.5)
	ci.draw_line(from, to - n * head * 0.8, col, width)
	_arrow_head(ci, to, n, col, head)


static func _arrow_head(ci: CanvasItem, tip: Vector2, n: Vector2, col: Color, head: float) -> void:
	var side := Vector2(-n.y, n.x)
	poly(ci, PackedVector2Array([tip, tip - n * head + side * head * 0.62, tip - n * head - side * head * 0.62]), col)


static func _curved_arrow(ci: CanvasItem, c: Vector2, radius: float, a0: float, a1: float, col: Color, width: float) -> void:
	var pts := PackedVector2Array()
	var n := 10
	for i in n + 1:
		var a := lerpf(a0, a1, i / float(n))
		pts.append(c + Vector2(cos(a), sin(a)) * radius)
	ci.draw_polyline(pts, col, width, true)
	_arrow_head(ci, pts[n], (pts[n] - pts[n - 1]).normalized(), col, width * 2.6)


## A side-view low-poly bird in flight: round head and short beak, a
## compact body, a fanned tail and two long tapering wings (the far one
## darker) whose tips rise and fall with `flap` (-1 down .. 1 up). The long
## raised wings, head and fan tail are what read as "bird" rather than
## "fish" at icon size. facing 1 = beak to the right.
static func draw_bird(ci: CanvasItem, c: Vector2, size: float, col: Color, facing: float, flap: float) -> void:
	var s := size * 0.5
	var f := facing
	var dark := col.darkened(0.25)
	var mid := col.darkened(0.1)
	var p := func(x: float, y: float) -> Vector2: return c + Vector2(f * x, y) * s
	# Far wing first (behind the body), a little higher and shorter.
	_side_wing(ci, p, flap, 0.08, 0.85, dark)
	# Fan tail: spreads to a flat end (a fork would read as a fish's fin).
	poly(ci, PackedVector2Array([p.call(-0.45, -0.06), p.call(-1.05, -0.2), p.call(-1.12, 0.1), p.call(-0.45, 0.12)]), dark)
	var body := PackedVector2Array([p.call(-0.55, 0.0), p.call(-0.2, -0.2), p.call(0.3, -0.22), p.call(0.55, -0.1),
		p.call(0.5, 0.12), p.call(0.1, 0.24), p.call(-0.35, 0.16)])
	poly(ci, body, col)
	# Belly facet.
	poly(ci, PackedVector2Array([body[4], body[5], body[6], body[0]]), mid)
	var head := PackedVector2Array()
	for i in 7:
		var a := TAU * i / 7.0
		head.append(p.call(0.6 + cos(a) * 0.2, -0.2 + sin(a) * 0.19))
	poly(ci, head, col)
	poly(ci, PackedVector2Array([p.call(0.76, -0.27), p.call(1.02, -0.17), p.call(0.76, -0.11)]), UITheme.ACCENT.darkened(0.1))
	ci.draw_circle(p.call(0.66, -0.24), maxf(1.5, s * 0.055), UITheme.INK)
	# Near wing over the body.
	_side_wing(ci, p, flap, 0.0, 1.0, col.lightened(0.08))


## One wing of the side-view bird: from the shoulder to a pointed tip that
## sits above (flap > 0) or below the body, trailing edge cut into feather
## tips. `lift` raises it, `reach` scales its length.
static func _side_wing(ci: CanvasItem, p: Callable, flap: float, lift: float, reach: float, col: Color) -> void:
	var tip_y := -0.25 - 0.95 * clampf(flap, -1.0, 1.0) - lift
	var tip_x := -0.25 - 0.2 * (1.0 - absf(flap))
	var sh_front: Vector2 = p.call(0.28, -0.14 - lift)
	var sh_back: Vector2 = p.call(-0.12, -0.12 - lift)
	var tip: Vector2 = p.call(tip_x * reach, (tip_y + 0.14) * reach - 0.14)
	var pts := PackedVector2Array([sh_front, tip])
	# Feather notches along the trailing edge, from the tip back to the body.
	for i in range(1, 4):
		var k := i / 4.0
		var q := tip.lerp(sh_back, k)
		var nrm := (sh_back - tip).orthogonal().normalized() * signf(tip_y)
		pts.append(q + nrm * (sh_back - tip).length() * 0.06)
		pts.append(tip.lerp(sh_back, k + 0.08))
	pts.append(sh_back)
	poly(ci, pts, col)


## A filled polygon that never errors. CanvasItem.draw_colored_polygon logs
## "triangulation failed" for degenerate or self-intersecting outlines (wing
## poses at the ends of an animation, clipper slivers); here we triangulate
## ourselves, fall back to a fan, and submit plain triangles.
static func poly(ci: CanvasItem, pts: PackedVector2Array, col: Color) -> void:
	if pts.size() < 3:
		return
	var tris := PackedVector2Array()
	var idx := Geometry2D.triangulate_polygon(pts)
	if idx.is_empty():
		# Self-intersecting: a fan from the first point, skipping slivers.
		for i in range(1, pts.size() - 1):
			if absf((pts[i] - pts[0]).cross(pts[i + 1] - pts[0])) > 0.01:
				tris.append_array([pts[0], pts[i], pts[i + 1]])
	else:
		for i in idx:
			tris.append(pts[i])
	if tris.is_empty():
		return
	var cols := PackedColorArray()
	cols.resize(tris.size())
	cols.fill(col)
	RenderingServer.canvas_item_add_triangle_array(ci.get_canvas_item(), PackedInt32Array(), tris, cols)
