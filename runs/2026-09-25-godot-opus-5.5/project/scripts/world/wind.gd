class_name WindField
extends RefCounted
## Moving air: a gusty breeze, drifting/pulsing thermals and ridge lift.
##
## wind_at() runs for every bird every physics frame, so it is built for
## GDScript speed: a 32 m lookup grid says which thermals / lift sources can
## touch a cell (most cells: none -> breeze only), thermals are compact
## bell-shaped columns evaluated analytically, and ridge lift is baked into
## an 8 m grid (strength + vertical band) that is bilinearly interpolated so
## it stays smooth.

const G_CELL := 32.0
const G_HALF := 704.0
const L_CELL := 8.0
const L_HALF := 704.0
## Thermals lean downwind as they rise (fraction of height).
const LEAN := 0.14
## Drift circle radius of thermal centres, m.
const DRIFT := 11.0
## Pulse amplitude of thermal strength (fraction).
const PULSE := 0.11
## Soft edge: over the last EDGE_BAND m inside the boundary the air pushes
## inward, up to EDGE_PUSH m/s at the wall, so a bird is slowed and turned
## back before it meets the invisible wall (the mountains it sees can be
## tens of metres further out at altitude).
const EDGE_BAND := 45.0
const EDGE_PUSH := 6.0
## The ridge-lift band's floor follows the ground; where the ground (so the
## floor) is steep, the band's bottom ramp widens so the lift a bird flies
## through changes by at most about this much per metre from that term.
const BAND_GRADIENT := 0.3
## Narrowest bottom ramp of the band, m.
const BAND_RAMP := 18.0

var g_n := int(G_HALF * 2.0 / G_CELL)
var l_n := int(L_HALF * 2.0 / L_CELL) + 1

## Per-cell code: bits 0-4 thermal A (+1), 5-9 thermal B (+1), bit 10 lift,
## bit 11 edge push.
var _cells := PackedInt32Array()
# Thermal state (current, updated by update()).
var _tx := PackedFloat32Array()
var _tz := PackedFloat32Array()
var _tinv := PackedFloat32Array()
var _ts := PackedFloat32Array()
var _ttop := PackedFloat32Array()
var _tg := PackedFloat32Array()
# Thermal constants.
var _bx := PackedFloat32Array()
var _bz := PackedFloat32Array()
var _bs := PackedFloat32Array()
var _br := PackedFloat32Array()
var _ph := PackedFloat32Array()
var _names: PackedStringArray = []
# Ridge-lift maps (L grid): strength, band bottom, band top.
var _lf := PackedFloat32Array()
var _llo := PackedFloat32Array()
var _lhi := PackedFloat32Array()
## Which source made each node's lift: 0 west cliff, 1 canyon massif,
## 2 west mountain slopes (for the visual cue).
var _lsrc := PackedByteArray()
## Bottom ramp height of the band per node, m (>= BAND_RAMP).
var _lramp := PackedFloat32Array()

var _breeze_base := WorldLayout.BREEZE
var _breeze := WorldLayout.BREEZE
var _lean_x := 0.0
var _lean_z := 0.0
var time := 0.0
var seed := 1


func _init(p_seed: int = 1) -> void:
	seed = p_seed


## Builds thermals and lift maps. terrain supplies ground heights.
func build(terrain: WorldTerrain) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed * 104729 + 3
	var bdir := Vector2(_breeze_base.x, _breeze_base.z).normalized()
	_lean_x = bdir.x * LEAN
	_lean_z = bdir.y * LEAN
	for t in WorldLayout.THERMALS:
		var p: Vector2 = t["pos"]
		_names.append(t["name"])
		_bx.append(p.x)
		_bz.append(p.y)
		_br.append(t["r"])
		_bs.append(t["s"])
		_tinv.append(1.0 / (float(t["r"]) * float(t["r"])))
		_ttop.append(t["top"])
		_tg.append(terrain.height_at(p.x, p.y) if terrain else 0.0)
		for k in 4:
			_ph.append(rng.randf() * TAU)
	_tx = _bx.duplicate()
	_tz = _bz.duplicate()
	_ts = _bs.duplicate()
	_build_lift(terrain)
	_build_cells()
	update(0.0)


## Advances the air to time t (seconds): thermal drift/pulse, gusts.
func update(t: float) -> void:
	time = t
	for i in _bx.size():
		var p := i * 4
		# Each thermal wanders on its own slow Lissajous loop (~2-3 min).
		_tx[i] = _bx[i] + DRIFT * sin(t * (0.041 + 0.006 * i) + _ph[p])
		_tz[i] = _bz[i] + DRIFT * cos(t * (0.033 + 0.005 * i) + _ph[p + 1])
		_ts[i] = _bs[i] * (1.0 + PULSE * sin(t * (0.11 + 0.013 * i) + _ph[p + 2]))
	var g := 1.0 + 0.1 * sin(t * 0.57) + 0.05 * sin(t * 1.46 + 1.3)
	var yaw := 0.08 * sin(t * 0.21)
	_breeze = Vector3(
		(_breeze_base.x * cos(yaw) - _breeze_base.z * sin(yaw)) * g, 0.0,
		(_breeze_base.x * sin(yaw) + _breeze_base.z * cos(yaw)) * g)


## Air velocity at pos, m/s.
func wind_at(pos: Vector3) -> Vector3:
	var k := clampf(0.4 + pos.y * 0.02, 0.4, 1.0)
	var w := _breeze * k
	var ix := int((pos.x + G_HALF) * (1.0 / G_CELL))
	var iz := int((pos.z + G_HALF) * (1.0 / G_CELL))
	if ix < 0 or iz < 0 or ix >= g_n or iz >= g_n:
		return w
	var code := _cells[iz * g_n + ix]
	if code == 0:
		return w
	var t1 := code & 31
	if t1 != 0:
		w.y += _thermal(t1 - 1, pos)
		var t2 := (code >> 5) & 31
		if t2 != 0:
			w.y += _thermal(t2 - 1, pos)
	if code & 1024:
		w.y += _lift(pos)
	if code & 2048:
		w += edge_push(pos)
	return w


## The soft edge's inward push at pos (zero inside R - EDGE_BAND).
func edge_push(pos: Vector3) -> Vector3:
	var r := sqrt(pos.x * pos.x + pos.z * pos.z)
	var t := (r - (WorldLayout.BOUNDS - EDGE_BAND)) * (1.0 / EDGE_BAND)
	if t <= 0.0 or r < 1e-3:
		return Vector3.ZERO
	t = minf(t, 1.0)
	var s := -EDGE_PUSH * t * t * (3.0 - 2.0 * t) / r
	return Vector3(pos.x * s, 0.0, pos.z * s)


func _thermal(i: int, pos: Vector3) -> float:
	var dx := pos.x - _tx[i] - _lean_x * pos.y
	var dz := pos.z - _tz[i] - _lean_z * pos.y
	var u := (dx * dx + dz * dz) * _tinv[i]
	if u >= 1.0:
		return 0.0
	var b := 1.0 - u
	# Ramps in over the first 25 m above the ground, fades over the last 50 m.
	var lo := clampf((pos.y - _tg[i]) * 0.04, 0.0, 1.0)
	var hi := clampf((_ttop[i] - pos.y) * 0.02, 0.0, 1.0)
	return _ts[i] * b * b * lo * lo * (3.0 - 2.0 * lo) * hi * hi * (3.0 - 2.0 * hi)


func _lift(pos: Vector3) -> float:
	var gx := (pos.x + L_HALF) * (1.0 / L_CELL)
	var gz := (pos.z + L_HALF) * (1.0 / L_CELL)
	var i := int(gx)
	var j := int(gz)
	if i < 0 or j < 0 or i >= l_n - 1 or j >= l_n - 1:
		return 0.0
	var fx := gx - i
	var fz := gz - j
	var k := j * l_n + i
	var f00 := _lf[k]
	var f10 := _lf[k + 1]
	var f01 := _lf[k + l_n]
	var f11 := _lf[k + l_n + 1]
	var f := (f00 * (1.0 - fx) + f10 * fx) * (1.0 - fz) + (f01 * (1.0 - fx) + f11 * fx) * fz
	if f <= 0.001:
		return 0.0
	var lo := (_llo[k] * (1.0 - fx) + _llo[k + 1] * fx) * (1.0 - fz) + (_llo[k + l_n] * (1.0 - fx) + _llo[k + l_n + 1] * fx) * fz
	var hi := (_lhi[k] * (1.0 - fx) + _lhi[k + 1] * fx) * (1.0 - fz) + (_lhi[k + l_n] * (1.0 - fx) + _lhi[k + l_n + 1] * fx) * fz
	var rp := (_lramp[k] * (1.0 - fx) + _lramp[k + 1] * fx) * (1.0 - fz) + (_lramp[k + l_n] * (1.0 - fx) + _lramp[k + l_n + 1] * fx) * fz
	var a := clampf((pos.y - lo) / rp, 0.0, 1.0)
	var c := clampf((hi - pos.y) * (1.0 / 60.0) + 1.0, 0.0, 1.0)
	return f * a * a * (3.0 - 2.0 * a) * c * c * (3.0 - 2.0 * c)


# --- construction -------------------------------------------------------

static func _sm(e0: float, e1: float, x: float) -> float:
	var t := clampf((x - e0) / (e1 - e0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## Signed distance to a polyline's right-hand side (+ = in front of a face
## that looks right of travel), arc length of the closest point, and the
## interpolated top height there.
static func _ridge_coords(p: Vector2, pts: Array, tops: Array) -> Vector3:
	var best := INF
	var out := Vector3(INF, 0, 0)
	var acc := 0.0
	for i in pts.size() - 1:
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[i + 1]
		var ab := b - a
		var l := ab.length()
		var dir := ab / l
		var t := clampf((p - a).dot(dir), 0.0, l)
		var c := a + dir * t
		var d2 := p.distance_squared_to(c)
		if d2 < best:
			best = d2
			var nrm := Vector2(-dir.y, dir.x)
			var sd := (p - c).dot(nrm)
			# Beyond the polyline ends use the true distance (sign from the side).
			var dist := sqrt(d2) * (1.0 if sd >= 0.0 else -1.0)
			out = Vector3(dist, acc + t, lerpf(tops[i], tops[i + 1], t / l))
		acc += l
	return out


func _build_lift(terrain: WorldTerrain) -> void:
	var total := l_n * l_n
	_lf.resize(total)
	_llo.resize(total)
	_lhi.resize(total)
	_lf.fill(0.0)
	_llo.fill(0.0)
	_lhi.fill(0.0)
	_lsrc.resize(total)
	_lsrc.fill(0)
	var ridges := _ridge_defs()
	for j in l_n:
		var z := -L_HALF + j * L_CELL
		for i in l_n:
			var x := -L_HALF + i * L_CELL
			var k := j * l_n + i
			var best_f := 0.0
			var lo := 0.0
			var hi := 0.0
			var src := 0
			for ri in ridges.size():
				var r: Dictionary = ridges[ri]
				var bb: Rect2 = r["bbox"]
				if not bb.has_point(Vector2(x, z)):
					continue
				var rc := _ridge_coords(Vector2(x, z), r["pts"], r["tops"])
				var d := rc.x
				var L: float = r["length"]
				var ff := _sm(-12.0, 8.0, d) * (1.0 - _sm(55.0, 125.0, d))
				ff *= _sm(0.0, 45.0, rc.y) * (1.0 - _sm(L - 45.0, L, rc.y))
				var f: float = ff * r["s"]
				if f > best_f:
					best_f = f
					src = ri
					# Tops are heights above the valley floor in front of the face.
					var ground := terrain.height_at(x, z) if terrain else 0.0
					lo = ground + 0.2 * rc.z
					hi = ground + rc.z + 25.0
			# Mountain ring, windward (west) side: lift hugs the slope.
			var rr := sqrt(x * x + z * z)
			if rr > 470.0 and x < 0.0:
				var ww := _sm(0.1, 0.55, -x / rr) * _sm(470.0, 540.0, rr) * (1.0 - _sm(705.0, 740.0, rr))
				var fm := 2.7 * ww
				if fm > best_f:
					best_f = fm
					src = 2
					var g := terrain.height_at(x, z) if terrain else 0.0
					lo = g + 4.0
					hi = g + 55.0
			_lf[k] = best_f
			_llo[k] = lo
			_lhi[k] = hi
			_lsrc[k] = src
	_finish_band(total)


## Nodes just outside a lift zone take their neighbour's band (so the
## interpolated floor does not plunge to 0 at the zone's edge), then every
## node gets a bottom ramp wide enough for its floor's slope.
func _finish_band(total: int) -> void:
	var n := l_n
	var lift := PackedInt32Array()
	for k in total:
		if _lf[k] > 0.0:
			lift.append(k)
	var best := PackedFloat32Array()
	best.resize(total)
	best.fill(0.0)
	var lo := _llo.duplicate()
	var hi := _lhi.duplicate()
	var touched := PackedInt32Array()
	for k in lift:
		var i := k % n
		var j := k / n
		for d in 4:
			var ii := i + (1 if d == 0 else (-1 if d == 1 else 0))
			var jj := j + (1 if d == 2 else (-1 if d == 3 else 0))
			if ii < 0 or jj < 0 or ii >= n or jj >= n:
				continue
			var kk := jj * n + ii
			if _lf[kk] > 0.0 or _lf[k] <= best[kk]:
				continue
			if best[kk] == 0.0:
				touched.append(kk)
			best[kk] = _lf[k]
			lo[kk] = _llo[k]
			hi[kk] = _lhi[k]
	_llo = lo
	_lhi = hi
	_lramp.resize(total)
	_lramp.fill(BAND_RAMP)
	lift.append_array(touched)
	var diag := L_CELL * sqrt(2.0)
	for k in lift:
		var i := k % n
		var j := k / n
		var fmax := maxf(_lf[k], best[k])
		var grad := 0.0
		for dj in range(-1, 2):
			var jj := j + dj
			if jj < 0 or jj >= n:
				continue
			for di in range(-1, 2):
				var ii := i + di
				if (di == 0 and dj == 0) or ii < 0 or ii >= n:
					continue
				var kk := jj * n + ii
				fmax = maxf(fmax, _lf[kk])
				grad = maxf(grad, absf(_llo[kk] - _llo[k]) / (diag if di != 0 and dj != 0 else L_CELL))
		# smoothstep' <= 1.5 / ramp, times the lift, times the slope.
		_lramp[k] = maxf(BAND_RAMP, 1.5 * fmax * grad / BAND_GRADIENT)


func _ridge_defs() -> Array:
	var out := []
	# West cliff: vertical face looking east into the breeze.
	var cp: Array = []
	for p in WorldLayout.CLIFF:
		cp.append(p)
	out.append(_ridge(cp, Array(WorldLayout.CLIFF_TOP), 3.4))
	# Canyon east massif: its outer back slope faces east. The lift line is
	# its crest (face offset + top depth to the right of the centre line).
	var ep: Array = []
	var cn := WorldLayout.CANYON
	for i in cn.size():
		var dir: Vector2
		if i == 0:
			dir = (cn[1] - cn[0]).normalized()
		elif i == cn.size() - 1:
			dir = (cn[i] - cn[i - 1]).normalized()
		else:
			dir = (cn[i + 1] - cn[i - 1]).normalized()
		var right := Vector2(-dir.y, dir.x)
		ep.append(cn[i] + right * (WorldLayout.CANYON_HALF_GAP + WorldLayout.ROCK_TOP_DEPTH))
	out.append(_ridge(ep, Array(WorldLayout.CANYON_TOP), 2.8))
	return out


func _ridge(pts: Array, tops: Array, strength: float) -> Dictionary:
	var bb := Rect2(pts[0], Vector2.ZERO)
	for p in pts:
		bb = bb.expand(p)
	bb = bb.grow(140.0)
	var l := 0.0
	for i in pts.size() - 1:
		l += (pts[i] as Vector2).distance_to(pts[i + 1])
	return {"pts": pts, "tops": tops, "s": strength, "bbox": bb, "length": l}


func _build_cells() -> void:
	_cells.resize(g_n * g_n)
	_cells.fill(0)
	var reach_pad := DRIFT + LEAN * WorldLayout.CEILING + G_CELL * 0.75
	for j in g_n:
		var cz := -G_HALF + (j + 0.5) * G_CELL
		for i in g_n:
			var cx := -G_HALF + (i + 0.5) * G_CELL
			var code := 0
			var slot := 0
			for t in _bx.size():
				# Lean moves the column downwind with height; test the cell
				# against the whole swept footprint (ground to 300 m).
				var near := false
				for y in [0.0, 150.0, WorldLayout.CEILING]:
					var ox: float = _bx[t] + _lean_x * y
					var oz: float = _bz[t] + _lean_z * y
					if Vector2(cx - ox, cz - oz).length() < _br[t] + reach_pad:
						near = true
						break
				if near:
					# Two thermal slots per cell; the layout keeps thermals
					# >= 150 m apart so a third never shares a cell.
					assert(slot < 2, "three thermals share a 32 m wind cell: widen the cell code")
					if slot < 2:
						code |= (t + 1) << (5 * slot)
						slot += 1
			if _cell_has_lift(cx, cz):
				code |= 1024
			# Any corner of the cell inside the edge band.
			if Vector2(absf(cx) + G_CELL * 0.5, absf(cz) + G_CELL * 0.5).length() > WorldLayout.BOUNDS - EDGE_BAND:
				code |= 2048
			_cells[j * g_n + i] = code


func _cell_has_lift(cx: float, cz: float) -> bool:
	var h := G_CELL * 0.5 + L_CELL
	for dz in [-h, 0.0, h]:
		for dx in [-h, 0.0, h]:
			var i := int((cx + dx + L_HALF) / L_CELL)
			var j := int((cz + dz + L_HALF) / L_CELL)
			if i >= 0 and j >= 0 and i < l_n and j < l_n and _lf[j * l_n + i] > 0.0:
				return true
	return false


# --- queries for visuals, AI and tests -----------------------------------

## Live thermal columns: [{name, position (centre at its ground), radius,
## strength (core m/s now), top, lean}].
func thermals() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in _bx.size():
		out.append({
			"name": _names[i],
			"position": Vector3(_tx[i], _tg[i], _tz[i]),
			"radius": _br[i],
			"strength": _ts[i],
			"base_strength": _bs[i],
			"top": _ttop[i],
			"lean": Vector3(_lean_x, 0.0, _lean_z),
		})
	return out


## Centre of thermal i at altitude y (the column leans downwind).
func thermal_center(i: int, y: float) -> Vector3:
	return Vector3(_tx[i] + _lean_x * y, y, _tz[i] + _lean_z * y)


func thermal_count() -> int:
	return _bx.size()


func breeze() -> Vector3:
	return _breeze


## Lift-map nodes where ridge lift reaches at least min_strength m/s, per
## source (0 cliff, 1 canyon massif, 2 west slopes):
## [[Vector4(x, z, band bottom, band top), ...], ...] (for the visual cue).
func lift_nodes(min_strength: float) -> Array:
	var out := [[], [], []]
	for j in l_n:
		for i in l_n:
			var k := j * l_n + i
			if _lf[k] >= min_strength:
				(out[_lsrc[k]] as Array).append(Vector4(-L_HALF + i * L_CELL, -L_HALF + j * L_CELL, _llo[k], _lhi[k]))
	return out


## Ridge-lift strength (m/s) at the lift-map node nearest (x, z), for plots.
func lift_strength_at(x: float, z: float) -> float:
	var i := clampi(int(round((x + L_HALF) / L_CELL)), 0, l_n - 1)
	var j := clampi(int(round((z + L_HALF) / L_CELL)), 0, l_n - 1)
	return _lf[j * l_n + i]
