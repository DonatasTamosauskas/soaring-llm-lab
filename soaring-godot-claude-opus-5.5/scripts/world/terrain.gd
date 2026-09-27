class_name WorldTerrain
extends RefCounted
## The valley floor and the mountain ring: an analytic height function
## sampled onto an 8 m grid, drawn as flat-shaded vertex-coloured chunks and
## collided as a trimesh built from exactly those triangles, so
## ground_height() (same triangulation) agrees with physics.

const CELL := 8.0
const HALF := 760.0
const CHUNKS := 5
## Snow and rock thresholds for the mountain colouring.
const SNOW_Y := 250.0

var n := int(HALF * 2.0 / CELL)  # cells per side
var heights := PackedFloat32Array()
## Jittered vertex positions: the lattice is irregular on purpose (faceted
## low-poly look, organic shorelines) except along field edges.
var vx := PackedFloat32Array()
var vz := PackedFloat32Array()
const JITTER := 0.3
## The lake bed just inside the shore, and the bank just outside it (m under
## / over the water): the bank crosses the water line at >= ~0.2 slope (was
## 0.5 / 0.3 and 0.2 on the river: ~0.1).
const SHORE_DROP := 1.3
const SHORE_RISE := 0.7
var seed := 1

var _nl := FastNoiseLite.new()
var _nm := FastNoiseLite.new()
var _nr := FastNoiseLite.new()
var _na := FastNoiseLite.new()
var _nc := FastNoiseLite.new()
## Field crop per patch cell, filled by the builder (id -> colour key).
var south_crops := {}
var east_crops := {}
var village_y := 2.2
## The ring's named peaks: [bearing, height, angular width].
var _peaks: Array = []
## Angular lookup tables (the ring functions are hot in generation).
const LUT := 2048
var _lut_peak := PackedFloat32Array()
var _lut_r0 := PackedFloat32Array()


func _init(p_seed: int = 1) -> void:
	seed = p_seed
	for pair in [[_nl, 0.0035, 3], [_nm, 0.018, 2], [_nr, 0.009, 4], [_na, 1.0, 2], [_nc, 0.05, 1]]:
		var nz: FastNoiseLite = pair[0]
		nz.seed = p_seed + int(pair[1] * 1000.0)
		nz.frequency = pair[1]
		nz.fractal_octaves = pair[2]
		nz.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_nr.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	# A ring of distinct peaks (so the skyline reads as mountains, not a wall).
	var prng := RandomNumberGenerator.new()
	prng.seed = p_seed * 613 + 29
	var count := 15
	for i in count:
		var b := TAU * (float(i) + prng.randf_range(-0.3, 0.3)) / count
		_peaks.append([b, prng.randf_range(150.0, 290.0), prng.randf_range(0.13, 0.24)])
	_lut_peak.resize(LUT + 1)
	_lut_r0.resize(LUT + 1)
	for i in LUT + 1:
		var a := TAU * float(i) / LUT - PI
		var pk := _peak_sum_exact(a)
		_lut_peak[i] = pk
		_lut_r0[i] = 522.0 + 24.0 * _na.get_noise_2d(cos(a) * 1.3, sin(a) * 1.3) - 30.0 * (pk / 290.0 - 0.3)


# --- height ------------------------------------------------------------

static func _smooth(e0: float, e1: float, x: float) -> float:
	var t := clampf((x - e0) / (e1 - e0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## Inner radius where the foothills start rising, by bearing: spurs reach
## in under the peaks, bays open between them.
func ring_start(ang: float) -> float:
	var f := (wrapf(ang, -PI, PI) + PI) / TAU * LUT
	var i := clampi(int(f), 0, LUT - 1)
	return lerpf(_lut_r0[i], _lut_r0[i + 1], f - i)


func _peak_sum(ang: float) -> float:
	var f := (wrapf(ang, -PI, PI) + PI) / TAU * LUT
	var i := clampi(int(f), 0, LUT - 1)
	return lerpf(_lut_peak[i], _lut_peak[i + 1], f - i)


func _peak_sum_exact(ang: float) -> float:
	var hsum := 0.0
	for pk in _peaks:
		var d := wrapf(ang - float(pk[0]), -PI, PI)
		var w: float = pk[2]
		hsum = maxf(hsum, float(pk[1]) * exp(-(d * d) / (w * w)))
	return hsum


## The ring: gentle green foothills, then steep rock rising to snowy peaks
## beyond the boundary. Peaks and saddles vary with bearing so the skyline
## reads as a range, not a wall.
func _mountain(x: float, z: float, r: float) -> float:
	var ang := atan2(z, x)
	var r0 := ring_start(ang)
	if r < r0:
		return 0.0
	var u := r - r0
	var foot := 34.0 * _smooth(0.0, 120.0, u) * (1.0 + 0.35 * _nm.get_noise_2d(x * 0.4, z * 0.4))
	var m := _smooth(r0 + 45.0, r0 + 290.0, r)
	var peak := 215.0 + _peak_sum(ang) + 25.0 * _na.get_noise_2d(cos(ang) * 17.0, sin(ang) * 17.0 + 3.0)
	var ridges := _nr.get_noise_2d(x * 0.45, z * 0.45) * 22.0 * m
	var h := foot + pow(m, 1.5) * peak + ridges
	# The terrain grid ends at |x|, |z| = HALF. Keep the rim there >= 320 m so
	# from anywhere under the 300 m ceiling the edge is hidden behind it.
	h = maxf(h, 330.0 * _smooth(705.0, 758.0, r))
	return minf(h, 600.0 + 40.0 * _na.get_noise_2d(x * 0.01, z * 0.01))


func _flat_mask(x: float, z: float) -> float:
	var f := 0.0
	# Village block (street + houses + square), with a soft 26 m margin.
	var dx := maxf(maxf(-215.0 - x, x - 38.0), 0.0)
	var dz := maxf(maxf(-32.0 - z, z - 78.0), 0.0)
	f = maxf(f, 1.0 - _smooth(0.0, 26.0, sqrt(dx * dx + dz * dz)))
	# Farm yard and orchard.
	f = maxf(f, 1.0 - _smooth(62.0, 92.0, Vector2(x, z).distance_to(Vector2(-245, 128))))
	f = maxf(f, 1.0 - _smooth(46.0, 70.0, Vector2(x, z).distance_to(WorldLayout.ORCHARD)))
	return f


func _hill(x: float, z: float, c: Vector2, r: float, hgt: float) -> float:
	var d := Vector2(x, z).distance_to(c)
	if d >= r:
		return 0.0
	var t := 1.0 - d / r
	return hgt * t * t * (3.0 - 2.0 * t)


func sample(x: float, z: float) -> float:
	var r := sqrt(x * x + z * z)
	var hb := 2.4 + _nl.get_noise_2d(x, z) * 5.5 + _nm.get_noise_2d(x, z) * 1.1
	hb += _hill(x, z, WorldLayout.MAST, 95.0, 11.0)
	hb += _hill(x, z, WorldLayout.RUIN, 95.0, 9.0)
	hb += _hill(x, z, Vector2(-330, 420), 110.0, 12.0)
	hb += _hill(x, z, Vector2(430, 330), 90.0, 10.0)
	# Keep the populated floor above the water everywhere except where the
	# lake and river carve it, so water shows only where it is meant to.
	hb = maxf(hb, WorldLayout.WATER_Y + 1.6 + _nc.get_noise_2d(x, z) * 0.4)
	var f := _flat_mask(x, z)
	if f > 0.0:
		hb = lerpf(hb, village_y, f)
	var hm := _mountain(x, z, r)
	# Canyon floor: the gorge cuts the ring; flatten well past the rock faces
	# (>= face offset + one triangle diameter) so no terrain pokes out in
	# front of the canyon walls.
	if x > 60.0 and x < 260.0 and z < -260.0:
		var dc := WorldLayout.polyline_distance(Vector2(x, z), WorldLayout.CANYON)
		var cf := 1.0 - _smooth(31.0, 52.0, dc)
		if cf > 0.0:
			hm *= 1.0 - cf
			hb = lerpf(hb, 1.6 + _nc.get_noise_2d(x, z) * 0.5, cf)
	var h := hb + hm
	# Lake basin. The bank crosses the water line steeply (from SHORE_DROP
	# under the water to SHORE_RISE over it within one lattice cell): where
	# a shallow bank met the flat water the two surfaces lay within a few
	# depth-buffer steps of each other along the whole shore, a flickering
	# band on the Quest's 24-bit depth buffer (integration round 1,
	# tests/unit/integration/depth_precision_test.gd).
	var q := WorldLayout.lake_q(x, z)
	if q < 1.3:
		var hl: float
		if q < 1.0:
			hl = WorldLayout.WATER_Y - SHORE_DROP - (6.1 - SHORE_DROP) * sqrt(1.0 - q)
		else:
			hl = lerpf(WorldLayout.WATER_Y + SHORE_RISE, h, _smooth(1.0, 1.3, q))
		h = minf(h, hl)
	# River channel (its bank as steep, for the same reason).
	if x > -20.0 and x < 230.0 and z > -620.0 and z < 220.0:
		var dr := WorldLayout.polyline_distance(Vector2(x, z), WorldLayout.RIVER)
		if dr < 18.0:
			var hr: float
			if dr < 7.2:
				hr = WorldLayout.WATER_Y - 1.4
			else:
				hr = WorldLayout.WATER_Y + SHORE_RISE + (dr - 7.2) * 0.32
			h = minf(h, hr)
	return h


## Samples the jittered lattice, row by row. (Tried on the
## WorkerThreadPool: GDScript workers calling into shared objects contend on
## reference counts and ran ~1.5x SLOWER than one thread, so it is serial.)
func generate() -> void:
	village_y = 2.2
	heights = PackedFloat32Array()
	vx = PackedFloat32Array()
	vz = PackedFloat32Array()
	for j in n + 1:
		var r := _gen_row(j)
		vx.append_array(r[0])
		vz.append_array(r[1])
		heights.append_array(r[2])


## One lattice row: [vx, vz, heights].
func _gen_row(j: int) -> Array:
	var n1 := n + 1
	var amp := JITTER * CELL
	var rx := PackedFloat32Array()
	var rz := PackedFloat32Array()
	var rh := PackedFloat32Array()
	rx.resize(n1)
	rz.resize(n1)
	rh.resize(n1)
	var z := -HALF + j * CELL
	for i in n1:
		var x := -HALF + i * CELL
		var jx := 0.0
		var jz := 0.0
		if i > 0 and j > 0 and i < n and j < n:
			var hsh := ((i * 73856093) ^ (j * 19349663) ^ (seed * 83492791)) & 0x7fffffff
			jx = (float(hsh & 1023) / 1023.0 - 0.5) * 2.0 * amp
			jz = (float((hsh >> 10) & 1023) / 1023.0 - 0.5) * 2.0 * amp
			if _on_field_line_x(x, z):
				jx = 0.0
			if _on_field_line_z(x, z):
				jz = 0.0
		rx[i] = x + jx
		rz[i] = z + jz
		rh[i] = sample(x + jx, z + jz)
	return [rx, rz, rh]


## Field borders are straight so crops and hedgerows line up.
func _on_field_line_x(x: float, z: float) -> bool:
	return _on_line(x, z, WorldLayout.FIELDS_ORIGIN.x, WorldLayout.FIELDS_CELL.x, WorldLayout.FIELDS_SIZE.x,
			WorldLayout.FIELDS_ORIGIN.y, WorldLayout.FIELDS_SIZE.y) \
		or _on_line(x, z, WorldLayout.EAST_FIELDS_ORIGIN.x, WorldLayout.EAST_FIELDS_CELL.x, WorldLayout.EAST_FIELDS_SIZE.x,
			WorldLayout.EAST_FIELDS_ORIGIN.y, WorldLayout.EAST_FIELDS_SIZE.y)


func _on_field_line_z(x: float, z: float) -> bool:
	return _on_line(z, x, WorldLayout.FIELDS_ORIGIN.y, WorldLayout.FIELDS_CELL.y, WorldLayout.FIELDS_SIZE.y,
			WorldLayout.FIELDS_ORIGIN.x, WorldLayout.FIELDS_SIZE.x) \
		or _on_line(z, x, WorldLayout.EAST_FIELDS_ORIGIN.y, WorldLayout.EAST_FIELDS_CELL.y, WorldLayout.EAST_FIELDS_SIZE.y,
			WorldLayout.EAST_FIELDS_ORIGIN.x, WorldLayout.EAST_FIELDS_SIZE.x)


static func _on_line(a: float, b: float, a0: float, step: float, size: float, b0: float, bsize: float) -> bool:
	if a < a0 - 0.5 or a > a0 + size + 0.5 or b < b0 - CELL or b > b0 + bsize + CELL:
		return false
	var k := (a - a0) / step
	return absf(k - roundf(k)) * step < 0.5


## Height of the drawn/collided terrain surface at (x, z): the exact
## triangle the renderer and the trimesh collider use.
func height_at(x: float, z: float) -> float:
	var gx := (x + HALF) / CELL
	var gz := (z + HALF) / CELL
	var i := clampi(int(floor(gx)), 0, n - 1)
	var j := clampi(int(floor(gz)), 0, n - 1)
	var h := _cell_height(i, j, x, z)
	if not is_nan(h):
		return h
	# Jitter moves vertices by up to 30% of a cell, so only neighbours on the
	# near side(s) can hold the point.
	var fx := gx - i
	var fz := gz - j
	var di := -1 if fx < 0.5 else 1
	var dj := -1 if fz < 0.5 else 1
	var ii := clampi(i + di, 0, n - 1)
	var jj := clampi(j + dj, 0, n - 1)
	h = _cell_height(ii, j, x, z)
	if not is_nan(h):
		return h
	h = _cell_height(i, jj, x, z)
	if not is_nan(h):
		return h
	h = _cell_height(ii, jj, x, z)
	if not is_nan(h):
		return h
	# Numerical edge cases on shared edges: nearest vertex.
	return heights[j * (n + 1) + i]


func _cell_height(i: int, j: int, px: float, pz: float) -> float:
	var n1 := n + 1
	var a := j * n1 + i
	var c := a + n1 + 1
	var x0 := vx[a]
	var z0 := vz[a]
	var x2 := vx[c]
	var z2 := vz[c]
	# Triangle (00, 11, 10), then (00, 01, 11); barycentric weights.
	for t in 2:
		var b := c
		var d := a + 1
		if t == 1:
			b = a + n1
			d = c
		var x1 := vx[b]
		var z1 := vz[b]
		var x3 := vx[d]
		var z3 := vz[d]
		var den := (z1 - z3) * (x0 - x3) + (x3 - x1) * (z0 - z3)
		var u := ((z1 - z3) * (px - x3) + (x3 - x1) * (pz - z3)) / den
		if u < -1e-5:
			continue
		var v := ((z3 - z0) * (px - x3) + (x0 - x3) * (pz - z3)) / den
		if v < -1e-5 or u + v > 1.00001:
			continue
		return u * heights[a] + v * heights[b] + (1.0 - u - v) * heights[d]
	return NAN


# --- rock masses on the floor --------------------------------------------

## The cliff and canyon walls are closed rock meshes standing on the valley
## floor. Their triangles (exactly the collided ones) are bucketed here so
## the world's ground_height() can report the rock, not the buried valley
## floor under it. Faces can overhang (the recess above the swallow band,
## jittered face rows), so "ground" is the first solid-to-air boundary going
## UP from the floor, not the highest rock surface: a bird in front of the
## band, under the overhang, is in the air.
const ROCK_CELL := 4.0
var _rock_tris := PackedVector3Array()
## 1 = the triangle faces up (leaving rock upward), 0 = faces down.
var _rock_up := PackedByteArray()
var _rock_grid := {}
var _rock_rect := Rect2()


## faces: triangles in Godot winding (as MeshKit.faces holds them).
func add_rock(faces: PackedVector3Array) -> void:
	for t in faces.size() / 3:
		var a := faces[t * 3]
		var c := faces[t * 3 + 1]
		var b := faces[t * 3 + 2]
		# Stored (a, c, b): the outward normal is (b - a) x (c - a).
		var ny := (b - a).cross(c - a).y
		if absf(ny) <= 1e-6:
			continue
		var idx := _rock_tris.size() / 3
		_rock_tris.append(a)
		_rock_tris.append(b)
		_rock_tris.append(c)
		_rock_up.append(1 if ny > 0.0 else 0)
		var lo := Vector2(minf(minf(a.x, b.x), c.x), minf(minf(a.z, b.z), c.z))
		var hi := Vector2(maxf(maxf(a.x, b.x), c.x), maxf(maxf(a.z, b.z), c.z))
		var r := Rect2(lo, hi - lo)
		_rock_rect = r if _rock_rect.size == Vector2.ZERO else _rock_rect.merge(r)
		for j in range(floori(lo.y / ROCK_CELL), floori(hi.y / ROCK_CELL) + 1):
			for i in range(floori(lo.x / ROCK_CELL), floori(hi.x / ROCK_CELL) + 1):
				var key := Vector2i(i, j)
				var arr: PackedInt32Array = _rock_grid.get(key, PackedInt32Array())
				arr.append(idx)
				_rock_grid[key] = arr


## The rock ground above a floor height at (x, z): the lowest rock surface
## crossed above `floor_y` if it faces up (the column is rock from the
## floor up to there), else -INF (air above the floor: an overhang or no
## rock at all).
func rock_ground_at(x: float, z: float, floor_y: float) -> float:
	if x < _rock_rect.position.x or z < _rock_rect.position.y or x > _rock_rect.end.x or z > _rock_rect.end.y:
		return -INF
	var cell: Variant = _rock_grid.get(Vector2i(floori(x / ROCK_CELL), floori(z / ROCK_CELL)))
	if cell == null:
		return -INF
	var best := INF
	var best_up := false
	var above := floor_y + 0.02
	for idx in (cell as PackedInt32Array):
		var a := _rock_tris[idx * 3]
		var b := _rock_tris[idx * 3 + 1]
		var c := _rock_tris[idx * 3 + 2]
		var den := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
		if absf(den) < 1e-9:
			continue
		var u := ((b.z - c.z) * (x - c.x) + (c.x - b.x) * (z - c.z)) / den
		if u < -1e-5 or u > 1.00001:
			continue
		var v := ((c.z - a.z) * (x - c.x) + (a.x - c.x) * (z - c.z)) / den
		if v < -1e-5 or u + v > 1.00001:
			continue
		var h := u * a.y + v * b.y + (1.0 - u - v) * c.y
		if h > above and h < best:
			best = h
			best_up = _rock_up[idx] == 1
	return best if best_up else -INF


## Surface normal of the terrain at (x, z) (from the grid triangle).
func normal_at(x: float, z: float) -> Vector3:
	var e := 0.5
	var hx := height_at(x + e, z) - height_at(x - e, z)
	var hz := height_at(x, z + e) - height_at(x, z - e)
	return Vector3(-hx, 2.0 * e, -hz).normalized()


# --- colour ------------------------------------------------------------

func _field_color(cell: int, crops: Dictionary) -> Color:
	var key: StringName = crops.get(cell, &"field_green")
	return Palette.c(key)


func color_at(x: float, z: float, hc: float, ny: float) -> Color:
	var wy := WorldLayout.WATER_Y
	if hc < wy + 0.1:
		return Palette.c(&"mud")
	var r := sqrt(x * x + z * z)
	var n_var := _nm.get_noise_2d(x * 1.3, z * 1.3)
	var n_big := _nl.get_noise_2d(x * 2.0 + 50.0, z * 2.0)
	var r0 := ring_start(atan2(z, x))
	if r > r0 + 20.0 or hc > 40.0:
		# Snow caps high up (steeper faces hold snow only on the peaks).
		if hc > 300.0 + n_var * 30.0 and ny > 0.32:
			return Palette.c(&"snow")
		if hc > 235.0 + n_var * 30.0 and ny > 0.62:
			return Palette.c(&"snow")
		if ny < 0.42:
			return Palette.c(&"rock_dark") if n_var < -0.2 else Palette.c(&"mountain_rock")
		if hc < 95.0 + n_big * 35.0:
			if ny < 0.66:
				return Palette.c(&"scree")
			return Palette.c(&"mountain_grass").lerp(Palette.c(&"grass_dark"), clampf(0.5 + n_var, 0.0, 1.0) * 0.7)
		if hc < 190.0 + n_big * 40.0:
			if ny > 0.74:
				return Palette.c(&"mountain_grass").lerp(Palette.c(&"scree"), 0.25)
			return Palette.c(&"scree") if ny > 0.58 else Palette.c(&"mountain_rock")
		return Palette.c(&"scree") if ny > 0.7 else Palette.c(&"mountain_rock")
	if ny < 0.7:
		return Palette.c(&"rock")
	# Shores: sand where the ground dips to the waterline.
	if hc < wy + 1.3:
		return Palette.c(&"sand")
	var fm := _flat_mask(x, z)
	if fm > 0.6:
		return Palette.c(&"grass_light").lerp(Palette.c(&"grass"), clampf(0.5 + n_var, 0.0, 1.0))
	var cell := WorldLayout.field_cell(x, z, WorldLayout.FIELDS_ORIGIN, WorldLayout.FIELDS_SIZE, WorldLayout.FIELDS_CELL, WorldLayout.FIELDS_ROT)
	if cell >= 0 and south_crops.has(cell):
		return _field_color(cell, south_crops)
	cell = WorldLayout.field_cell(x, z, WorldLayout.EAST_FIELDS_ORIGIN, WorldLayout.EAST_FIELDS_SIZE, WorldLayout.EAST_FIELDS_CELL, 0.0)
	if cell >= 0 and east_crops.has(cell):
		return _field_color(cell, east_crops)
	var dm := Vector2(x, z).distance_to(WorldLayout.MEADOW)
	if dm < WorldLayout.MEADOW_CLEAR + 30.0:
		return Palette.c(&"meadow").lerp(Palette.c(&"meadow_flower"), clampf(n_var * 1.6, 0.0, 1.0))
	if Vector2(x, z).distance_to(WorldLayout.FOREST) < WorldLayout.FOREST_R + 10.0:
		# Rides: worn earth tracks through the wood.
		if FloraBuilder.ride_distance(Vector2(x, z)) < WorldLayout.RIDE_HALF * 0.7:
			return Palette.c(&"path").lerp(Palette.c(&"mud"), clampf(0.5 + n_var, 0.0, 1.0))
		# Shaded woodland floor: mossy olive with leaf litter, darkest in the
		# old wood where the canopy closes.
		var df := Vector2(x, z).distance_to(WorldLayout.FOREST)
		var floor_col := Palette.c(&"forest_floor").lerp(Palette.c(&"leaf_litter"), clampf(0.35 + n_var * 1.2, 0.0, 0.8))
		return floor_col.lerp(Palette.c(&"grass_dark"), _smooth(WorldLayout.FOREST_CORE_R, WorldLayout.FOREST_R + 10.0, df))
	var g := Palette.c(&"grass")
	if n_big > 0.0:
		g = g.lerp(Palette.c(&"grass_light"), clampf(n_big * 1.8, 0.0, 1.0))
	else:
		g = g.lerp(Palette.c(&"grass_dark"), clampf(-n_big * 1.5, 0.0, 1.0))
	return g


# --- meshes ------------------------------------------------------------

## Far terrain: a chunk whose nearest point is more than LOD_DIST m from
## the camera (on the ground plane) is drawn from a 16 m lattice (the fine
## lattice's even vertices, so every drawn vertex lies on the collided
## surface), a quarter of the triangles. Switched by update_lod() from the
## nearest point, not the chunk's centre: a mountain chunk's bounds are
## 600 m tall, so a centre-based visibility range would coarsen the slope
## right beside a bird.
const LOD_DIST := 260.0
const LOD_MARGIN := 15.0
var _lod_chunks: Array = []
## One colour per fine cell (its first triangle's), for the far meshes,
## and which cells the fine mesh leaves out (set by _chunk_arrays).
var _cell_cols := PackedColorArray()
var _cell_skip := PackedByteArray()


static func _mesh_from(ca: Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = ca[0]
	arrays[Mesh.ARRAY_NORMAL] = ca[1]
	arrays[Mesh.ARRAY_COLOR] = ca[2]
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Builds the terrain chunks under visual_parent / body_parent.
func build(visual_parent: Node3D, body_parent: Node3D, material: Material) -> Array:
	var made: Array = []
	var per := int(ceil(float(n) / CHUNKS))
	_cell_cols.resize(n * n)
	_cell_skip.resize(n * n)
	_cell_skip.fill(0)
	for cj in CHUNKS:
		for ci in CHUNKS:
			var ca := _chunk_arrays(ci, cj)
			var verts: PackedVector3Array = ca[0]
			var mi := MeshInstance3D.new()
			mi.name = "terrain_%d_%d" % [ci, cj]
			mi.mesh = _mesh_from(ca)
			mi.material_override = material
			# The ground receives shadows; it does not need to cast them (the
			# mountains' self-shadowing is invisible at the shadow distance).
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			visual_parent.add_child(mi)
			var body := StaticBody3D.new()
			body.name = mi.name + "_body"
			body.collision_mask = 0
			var shape := ConcavePolygonShape3D.new()
			shape.set_faces(verts)
			var o := body.create_shape_owner(body)
			body.shape_owner_add_shape(o, shape)
			body_parent.add_child(body)
			mi.set_meta(&"collider", body)
			made.append(mi)
			var coarse := MeshInstance3D.new()
			coarse.name = "terrain_far_%d_%d" % [ci, cj]
			coarse.mesh = _mesh_from(_chunk_coarse_arrays(ci, cj))
			coarse.material_override = material
			coarse.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			coarse.visible = false
			coarse.set_meta(&"collider", body)
			# Its vertices are the fine lattice's own: on the collided surface.
			# Shown only while the camera is this far from every point of it.
			coarse.set_meta(&"stand_in_min_dist", LOD_DIST - LOD_MARGIN)
			coarse.set_meta(&"stand_in_flat", true)
			visual_parent.add_child(coarse)
			var lo := Vector2(-HALF + ci * per * CELL, -HALF + cj * per * CELL)
			var hi := Vector2(-HALF + mini((ci + 1) * per, n) * CELL, -HALF + mini((cj + 1) * per, n) * CELL)
			_lod_chunks.append([Rect2(lo, hi - lo).grow(CELL * JITTER), mi, coarse])
	return made


## Swaps far chunks to their coarse mesh for a camera at `eye` (call every
## frame; 25 rectangle distances). Hysteresis: LOD_MARGIN either side.
func update_lod(eye: Vector3) -> void:
	var p := Vector2(eye.x, eye.z)
	for c in _lod_chunks:
		var r: Rect2 = c[0]
		var q := Vector2(clampf(p.x, r.position.x, r.end.x), clampf(p.y, r.position.y, r.end.y))
		var d := q.distance_to(p)
		var coarse: MeshInstance3D = c[2]
		if coarse.visible and d < LOD_DIST - LOD_MARGIN:
			coarse.visible = false
			(c[1] as MeshInstance3D).visible = true
		elif not coarse.visible and d > LOD_DIST + LOD_MARGIN:
			coarse.visible = true
			(c[1] as MeshInstance3D).visible = false


## True if the fine mesh leaves cell (i, j) out (all four corners beyond
## 800 m: behind the ring's crest, never seen).
func _cell_skipped(i: int, j: int) -> bool:
	return _cell_skip[j * n + i] == 1


## Lattice vertex (i, j).
func _v(i: int, j: int) -> Vector3:
	var k := j * (n + 1) + i
	return Vector3(vx[k], heights[k], vz[k])


## Blocks (2 x 2 cells) a far chunk must still draw at full resolution:
## where the water line runs (the lake and river surfaces are fine-grained),
## on the east fields, whose borders fall on odd lattice lines, and where
## two coarse triangles would miss a lattice vertex by more than
## LOD_MAX_ERR (rugged slopes): the far mesh then never strays from the
## collided surface by more than that, under 0.6 degrees from LOD_DIST.
const LOD_MAX_ERR := 2.4


func _block_is_fine(i: int, j: int) -> bool:
	# The block's 3 x 3 lattice points, then each omitted one against the
	# two coarse triangles (c00, c11, c10) and (c00, c01, c11).
	var n1 := n + 1
	var px := PackedFloat32Array()
	var pz := PackedFloat32Array()
	var ph := PackedFloat32Array()
	for dj in 3:
		for di in 3:
			var k := (j + dj) * n1 + i + di
			px.append(vx[k])
			pz.append(vz[k])
			ph.append(heights[k])
	for m in [4, 1, 3, 5, 7]:
		for t in 2:
			var b := 2 if t == 0 else 6
			var den := (pz[8] - pz[b]) * (px[0] - px[b]) + (px[b] - px[8]) * (pz[0] - pz[b])
			if absf(den) < 1e-9:
				continue
			var u := ((pz[8] - pz[b]) * (px[m] - px[b]) + (px[b] - px[8]) * (pz[m] - pz[b])) / den
			var v := ((pz[b] - pz[0]) * (px[m] - px[b]) + (px[0] - px[b]) * (pz[m] - pz[b])) / den
			if u >= -1e-4 and v >= -1e-4 and u + v <= 1.0001:
				if absf(u * ph[0] + v * ph[8] + (1.0 - u - v) * ph[b] - ph[m]) > LOD_MAX_ERR:
					return true
				break
	var wy := WorldLayout.WATER_Y
	for h in ph:
		if absf(h - wy) < 1.6:
			return true
	var x := -HALF + (i + 1) * CELL
	var z := -HALF + (j + 1) * CELL
	var eo := WorldLayout.EAST_FIELDS_ORIGIN
	var es := WorldLayout.EAST_FIELDS_SIZE
	return x > eo.x - 2.0 * CELL and x < eo.x + es.x + 2.0 * CELL and z > eo.y - 2.0 * CELL and z < eo.y + es.y + 2.0 * CELL


## A chunk's far mesh: 2 x 2 cell blocks as two triangles, or as a fan
## round the block's centre vertex that takes in the middle vertex of every
## edge it shares with a fine block or with the chunk's border, so no
## vertex of a neighbour ever lies on an edge it does not have (no cracks).
func _chunk_coarse_arrays(ci: int, cj: int) -> Array:
	var per := int(ceil(float(n) / CHUNKS))
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var i0 := ci * per
	var j0 := cj * per
	var bw := (mini(i0 + per, n) - i0) / 2
	var bh := (mini(j0 + per, n) - j0) / 2
	var fine := PackedByteArray()
	fine.resize(bw * bh)
	for bj in bh:
		for bi in bw:
			var ii := i0 + bi * 2
			var jj := j0 + bj * 2
			var part := 0
			for d in 4:
				if _cell_skipped(ii + d % 2, jj + d / 2):
					part += 1
			fine[bj * bw + bi] = 1 if _block_is_fine(ii, jj) or (part > 0 and part < 4) else 0
	for bj in bh:
		for bi in bw:
			var i := i0 + bi * 2
			var j := j0 + bj * 2
			var c00: Vector3 = _v(i, j)
			var c11: Vector3 = _v(i + 2, j + 2)
			var c10: Vector3 = _v(i + 2, j)
			var c01: Vector3 = _v(i, j + 2)
			# The fine mesh skips cells wholly beyond 800 m (behind the crest):
			# a block that is partly skipped is drawn cell by cell, exactly.
			var skipped := 0
			for dj in 2:
				for di in 2:
					if _cell_skipped(i + di, j + dj):
						skipped += 1
			if skipped == 4:
				continue
			if fine[bj * bw + bi] == 1 or skipped > 0:
				for dj in 2:
					for di in 2:
						if _cell_skipped(i + di, j + dj):
							continue
						var p00: Vector3 = _v(i + di, j + dj)
						var p10: Vector3 = _v(i + di + 1, j + dj)
						var p01: Vector3 = _v(i + di, j + dj + 1)
						var p11: Vector3 = _v(i + di + 1, j + dj + 1)
						_tri_far(verts, norms, cols, p00, p11, p10)
						_tri_far(verts, norms, cols, p00, p01, p11)
				continue
			# Which edges need their middle vertex (-j, +i, +j, -i sides).
			var need_w := bi == 0 or fine[bj * bw + bi - 1] == 1
			var need_e := bi == bw - 1 or fine[bj * bw + bi + 1] == 1
			var need_n := bj == 0 or fine[(bj - 1) * bw + bi] == 1
			var need_s := bj == bh - 1 or fine[(bj + 1) * bw + bi] == 1
			if not (need_w or need_e or need_n or need_s):
				_tri_far(verts, norms, cols, c00, c11, c10)
				_tri_far(verts, norms, cols, c00, c01, c11)
				continue
			var ring: Array[Vector3] = [c00]
			if need_w:
				ring.append(_v(i, j + 1))
			ring.append(c01)
			if need_s:
				ring.append(_v(i + 1, j + 2))
			ring.append(c11)
			if need_e:
				ring.append(_v(i + 2, j + 1))
			ring.append(c10)
			if need_n:
				ring.append(_v(i + 1, j))
			var centre: Vector3 = _v(i + 1, j + 1)
			for k in ring.size():
				_tri_far(verts, norms, cols, centre, ring[k], ring[(k + 1) % ring.size()])
	return [verts, norms, cols]


## One chunk's triangles: [verts, normals, colours].
func _chunk_arrays(ci: int, cj: int) -> Array:
	var per := int(ceil(float(n) / CHUNKS))
	var n1 := n + 1
	var out := [PackedVector3Array(), PackedVector3Array(), PackedColorArray()]
	var verts: PackedVector3Array = out[0]
	var norms: PackedVector3Array = out[1]
	var cols: PackedColorArray = out[2]
	out[0] = null
	out[1] = null
	out[2] = null
	var i0 := ci * per
	var j0 := cj * per
	var i1 := mini(i0 + per, n)
	var j1 := mini(j0 + per, n)
	for j in range(j0, j1):
		for i in range(i0, i1):
			var k := j * n1 + i
			var p00 := Vector3(vx[k], heights[k], vz[k])
			var p10 := Vector3(vx[k + 1], heights[k + 1], vz[k + 1])
			var p01 := Vector3(vx[k + n1], heights[k + n1], vz[k + n1])
			var p11 := Vector3(vx[k + n1 + 1], heights[k + n1 + 1], vz[k + n1 + 1])
			# The square's far corners lie behind the ring's crest (>= 330
			# m) and outside the boundary: never seen, never reached.
			if minf(minf(Vector2(p00.x, p00.z).length(), Vector2(p11.x, p11.z).length()),
					minf(Vector2(p10.x, p10.z).length(), Vector2(p01.x, p01.z).length())) > 800.0:
				_cell_skip[j * n + i] = 1
				continue
			_tri(verts, norms, cols, p00, p11, p10)
			# The far mesh reuses a cell's colour (no second colour pass).
			_cell_cols[j * n + i] = cols[cols.size() - 1]
			_tri(verts, norms, cols, p00, p01, p11)
	return [verts, norms, cols]


## Emits one far-mesh triangle in the colour of the fine cell under its
## centroid, shaded by its own normal.
func _tri_far(verts: PackedVector3Array, norms: PackedVector3Array, cols: PackedColorArray, a: Vector3, b: Vector3, c: Vector3) -> void:
	var nrm := (b - a).cross(c - a).normalized()
	var ci := clampi(int(((a.x + b.x + c.x) / 3.0 + HALF) / CELL), 0, n - 1)
	var cj := clampi(int(((a.z + b.z + c.z) / 3.0 + HALF) / CELL), 0, n - 1)
	var col := _cell_cols[cj * n + ci]
	verts.append(a)
	verts.append(c)
	verts.append(b)
	norms.append(nrm)
	norms.append(nrm)
	norms.append(nrm)
	cols.append(col)
	cols.append(col)
	cols.append(col)


## Emits one terrain triangle given CCW-from-above points (Godot winding out).
## The facet's value jitter is a hash of its centroid (not an RNG stream),
## so chunks can be built in any order, on any thread, identically.
func _tri(verts: PackedVector3Array, norms: PackedVector3Array, cols: PackedColorArray, a: Vector3, b: Vector3, c: Vector3) -> void:
	var nrm := (b - a).cross(c - a).normalized()
	var cx := (a.x + b.x + c.x) / 3.0
	var cz := (a.z + b.z + c.z) / 3.0
	var cy := (a.y + b.y + c.y) / 3.0
	var col := color_at(cx, cz, cy, nrm.y)
	var h := sin(cx * 12.9898 + cz * 78.233 + float(seed) * 0.37) * 43758.5453
	col = Palette.vary(col, (h - floorf(h) - 0.5) * 0.05)
	verts.append(a)
	verts.append(c)
	verts.append(b)
	norms.append(nrm)
	norms.append(nrm)
	norms.append(nrm)
	cols.append(col)
	cols.append(col)
	cols.append(col)


## Water surfaces: every grid cell with a corner below the water level gets
## a flat quad at WATER_Y (coloured by depth), which is also its collider.
func build_water(visual_parent: Node3D, body_parent: Node3D) -> MeshInstance3D:
	var kit := MeshKit.new("water", seed)
	kit.jitter = 0.02
	var n1 := n + 1
	var wy := WorldLayout.WATER_Y
	for j in n:
		for i in n:
			var k := j * n1 + i
			var lo := minf(minf(heights[k], heights[k + 1]), minf(heights[k + n1], heights[k + n1 + 1]))
			if lo >= wy - 0.02:
				continue
			var avg := (heights[k] + heights[k + 1] + heights[k + n1] + heights[k + n1 + 1]) * 0.25
			var depth := wy - avg
			var col: Color
			if depth < 0.4:
				col = Palette.c(&"water_shallow")
			elif depth < 2.8:
				col = Palette.c(&"water")
			else:
				col = Palette.c(&"water_deep")
			var a := Vector3(vx[k], wy, vz[k])
			var b := Vector3(vx[k + 1], wy, vz[k + 1])
			var c := Vector3(vx[k + n1 + 1], wy, vz[k + n1 + 1])
			var d := Vector3(vx[k + n1], wy, vz[k + n1])
			# Split along the diagonal that lies inside the quad: the jittered
			# lattice makes a few quads concave, and there the a-c split laid
			# two triangles of different shades over each other in one plane
			# (a fight at any distance; integration hygiene, 2026-09-27).
			var ac := Vector2(c.x - a.x, c.z - a.z)
			var sb := ac.cross(Vector2(b.x - a.x, b.z - a.z))
			var sd := ac.cross(Vector2(d.x - a.x, d.z - a.z))
			if sb * sd < 0.0:
				kit.tri(a, c, b, col)
				kit.tri(a, d, c, col)
			else:
				kit.tri(a, d, b, col)
				kit.tri(b, d, c, col)
	var out := kit.commit(visual_parent, body_parent, Palette.water_material(), 1, false)
	return out.get("mesh")


## Distant peaks beyond the ring: visual depth only, fogged, never reachable
## (the ring's crest and the boundary wall stand in between).
func build_backdrop(visual_parent: Node3D, body_parent: Node3D, material: Material) -> MeshInstance3D:
	var kit := MeshKit.new("backdrop", seed)
	kit.jitter = 0.06
	var segs := 72
	var radii := [1110.0, 1260.0, 1420.0, 1600.0]
	var hs := []
	for ri in radii.size():
		var row := PackedFloat32Array()
		for s in segs:
			var ang := TAU * float(s) / segs
			var base: float = [120.0, 420.0, 620.0, 380.0][ri]
			var v: float = base + 210.0 * _na.get_noise_2d(cos(ang) * 4.0 + ri * 3.0, sin(ang) * 4.0)
			row.append(maxf(v, 60.0))
		hs.append(row)
	for ri in radii.size() - 1:
		for s in segs:
			var s2 := (s + 1) % segs
			var a0 := TAU * float(s) / segs
			var a1 := TAU * float(s2) / segs
			var p00 := Vector3(cos(a0) * radii[ri], hs[ri][s], sin(a0) * radii[ri])
			var p01 := Vector3(cos(a1) * radii[ri], hs[ri][s2], sin(a1) * radii[ri])
			var p10 := Vector3(cos(a0) * radii[ri + 1], hs[ri + 1][s], sin(a0) * radii[ri + 1])
			var p11 := Vector3(cos(a1) * radii[ri + 1], hs[ri + 1][s2], sin(a1) * radii[ri + 1])
			var c0 := Palette.c(&"far_mountain")
			var hy := (p00.y + p01.y + p10.y + p11.y) * 0.25
			var col := Palette.c(&"snow") if hy > 540.0 else c0
			# Faces look inward (toward the valley).
			kit.tri(p00, p11, p10, col)
			kit.tri(p00, p01, p11, Palette.vary(col, -0.06))
	var out := kit.commit(visual_parent, body_parent, material, 1, false)
	return out.get("mesh")
