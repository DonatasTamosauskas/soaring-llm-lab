class_name WorldLayout
extends RefCounted
## The district plan: where everything in the valley sits. Hand-placed
## anchors (so the valley always has the same readable geography: village in
## the middle, lake south-east, forest north-west, cliffs west, canyon north,
## big meadow north-east); the seeded RNG only varies the details inside them.
##
## Coordinates are metres on the XZ plane (Vector2(x, z)); -Z is north.

const BOUNDS := 680.0
const CEILING := 300.0
## One water level for the lake and the river: the river "flows" through a
## carved channel, which reads fine in low poly and keeps ground_height cheap.
const WATER_Y := -0.6
## Inner populated zone: density criteria apply inside this radius.
const INNER_R := 480.0

# --- village ---
const VILLAGE := Vector2(-95.0, 30.0)
const STREET_Z := 30.0
const STREET_X0 := -205.0
const STREET_X1 := 30.0
const SQUARE := Vector2(-90.0, 30.0)
const CHURCH := Vector2(-90.0, 4.0)
## House slots: [x, side] side +1 = south of the street (door faces north).
const HOUSES := [
	[-186.0, -1], [-168.0, -1], [-150.0, -1], [-130.0, -1], [-50.0, -1], [-32.0, -1],
	[-186.0, 1], [-167.0, 1], [-148.0, 1], [-129.0, 1], [-52.0, 1], [-34.0, 1], [-15.0, 1],
]
const FARM := Vector2(-262.0, 118.0)
const FARMHOUSE := Vector2(-228.0, 96.0)
const WATER_TOWER := Vector2(-205.0, 168.0)
const ORCHARD := Vector2(-110.0, 205.0)

# --- water ---
## River centre line from the canyon head down to the lake.
const RIVER: Array[Vector2] = [
	Vector2(190, -578), Vector2(181, -520), Vector2(160, -450), Vector2(140, -390),
	Vector2(122, -320), Vector2(98, -230), Vector2(66, -130), Vector2(48, -40),
	Vector2(47, 30), Vector2(62, 95), Vector2(95, 150), Vector2(122, 186),
]
const RIVER_HALF := 6.0
const BRIDGE := Vector2(47.0, 30.0)
const LAKE := Vector2(228.0, 228.0)
const LAKE_R := Vector2(132.0, 98.0)
const LAKE_ROT := 0.35
const LAKE_ARCH := Vector2(318.0, 268.0)

# --- open country ---
const MEADOW := Vector2(335.0, -140.0)
## Nothing solid is placed inside this radius: the valley's vast open space.
const MEADOW_CLEAR := 165.0
const FOREST := Vector2(-262.0, -258.0)
const FOREST_R := 168.0
## The old wood: inside this radius trunks stand ~6 m apart and the crowns
## close over (the place you must weave); outside it the wood thins to an
## open edge.
const FOREST_CORE_R := 92.0
## Rides (woodland tracks): lanes to dash along, one from the south-east
## edge into the glade, one from the glade out to the west.
const FOREST_RIDES: Array = [
	[Vector2(-128, -322), Vector2(-178, -290), Vector2(-222, -246), Vector2(-255, -222)],
	[Vector2(-290, -206), Vector2(-338, -184), Vector2(-392, -176)],
]
const RIDE_HALF := 3.2
const MAST := Vector2(468.0, 110.0)
const RUIN := Vector2(-20.0, -250.0)

# --- rock ---
## West escarpment: face polyline (south to north); the face looks east
## (into the prevailing wind), which is what makes its ridge lift.
const CLIFF: Array[Vector2] = [
	Vector2(-463, 262), Vector2(-458, 200), Vector2(-452, 130), Vector2(-455, 60),
	Vector2(-447, -10), Vector2(-440, -70),
]
## Cliff top height above y = 0 at each CLIFF vertex (tapers at the ends so
## the escarpment grows out of the ground rather than stopping square).
const CLIFF_TOP: Array[float] = [10.0, 46.0, 58.0, 60.0, 50.0, 14.0]
## Rock-mass cross-section shared by the rock builder and the ridge lift.
const ROCK_TOP_DEPTH := 22.0
const ROCK_BACK_SLOPE := 0.8  # tan(angle) of the back slope
## Canyon: river gorge cutting north into the mountains. Centre line.
const CANYON: Array[Vector2] = [
	Vector2(122, -320), Vector2(140, -390), Vector2(160, -450), Vector2(181, -520), Vector2(190, -578),
]
const CANYON_HALF_GAP := 17.0
## Canyon wall top height at each CANYON vertex (rising into the mountains).
const CANYON_TOP: Array[float] = [22.0, 52.0, 66.0, 80.0, 92.0]

# --- power line corridor (pole positions interpolate between these) ---
const POWER_LINE: Array[Vector2] = [Vector2(-338, -42), Vector2(-20, -60), Vector2(128, -92), Vector2(150, -95)]
const POWER_POLES := 15

# --- air ---
## Prevailing breeze at altitude, m/s (blows toward -X: from the east).
const BREEZE := Vector3(-2.6, 0.0, 0.45)
## Thermals: position (x, z), bell radius, core strength m/s, top altitude.
## Sited over sun-warmed ground (the square's roofs, wheat, ploughed soil,
## bare rock) and spaced >= 150 m apart. Every bell reaches at least 35 m
## out and the weaker ones further, so that an eagle's ~19 m thermalling circle
## (30 degrees of bank just above its stall speed) still gains >= 1.5 m/s
## of mean lift at the weakest of the pulse, well over the ~1 m/s it sinks
## circling (suite: every species, every thermal, 10 minutes of air).
const THERMALS := [
	{"name": "square", "pos": Vector2(-90, 48), "r": 36.0, "s": 4.0, "top": 240.0, "ground": &"roofs"},
	{"name": "south_wheat", "pos": Vector2(-230, 330), "r": 38.0, "s": 4.2, "top": 270.0, "ground": &"wheat"},
	{"name": "meadow", "pos": Vector2(335, -140), "r": 44.0, "s": 4.4, "top": 285.0, "ground": &"meadow"},
	{"name": "east_plough", "pos": Vector2(438, 8), "r": 37.0, "s": 3.8, "top": 250.0, "ground": &"ploughed"},
	{"name": "north_rocks", "pos": Vector2(30, -318), "r": 35.0, "s": 4.2, "top": 260.0, "ground": &"rock"},
	{"name": "south_fields", "pos": Vector2(40, 372), "r": 36.0, "s": 4.0, "top": 250.0, "ground": &"wheat"},
	{"name": "hay_field", "pos": Vector2(-322, 192), "r": 40.0, "s": 3.9, "top": 230.0, "ground": &"hay"},
	{"name": "forest_glade", "pos": Vector2(-272, -212), "r": 40.0, "s": 3.8, "top": 230.0, "ground": &"glade"},
]

## South fields: an origin, rotation and cell size for the patchwork grid.
## Field edges sit on the 8 m terrain grid so crop colours have crisp
## straight borders (hedgerows run along them).
const FIELDS_ORIGIN := Vector2(-360, 248)
const FIELDS_SIZE := Vector2(448, 192)
const FIELDS_CELL := Vector2(112, 64)
const FIELDS_ROT := 0.0
const EAST_FIELDS_ORIGIN := Vector2(368, -32)
const EAST_FIELDS_SIZE := Vector2(128, 320)
const EAST_FIELDS_CELL := Vector2(64, 80)


static func lake_q(x: float, z: float) -> float:
	## Normalised elliptical radius of (x, z) from the lake centre (1 = shore).
	var d := Vector2(x, z) - LAKE
	var c := cos(LAKE_ROT)
	var s := sin(LAKE_ROT)
	var u := (d.x * c + d.y * s) / LAKE_R.x
	var v := (-d.x * s + d.y * c) / LAKE_R.y
	return sqrt(u * u + v * v)


## Distance from p to a polyline.
static func polyline_distance(p: Vector2, pts: Array[Vector2]) -> float:
	var best := INF
	for i in pts.size() - 1:
		var a := pts[i]
		var b := pts[i + 1]
		var ab := b - a
		var t := clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
		var d := p.distance_squared_to(a + ab * t)
		if d < best:
			best = d
	return sqrt(best)


static func polyline_length(pts: Array[Vector2]) -> float:
	var l := 0.0
	for i in pts.size() - 1:
		l += pts[i].distance_to(pts[i + 1])
	return l


## Point and unit tangent at arc length s along a polyline.
static func polyline_at(pts: Array[Vector2], s: float) -> Array:
	var acc := 0.0
	for i in pts.size() - 1:
		var seg := pts[i].distance_to(pts[i + 1])
		if s <= acc + seg or i == pts.size() - 2:
			var t := clampf((s - acc) / seg, 0.0, 1.0)
			var dir := (pts[i + 1] - pts[i]) / seg
			return [pts[i].lerp(pts[i + 1], t), dir]
		acc += seg
	return [pts[-1], (pts[-1] - pts[-2]).normalized()]


## Field patch id (cell index) and local position for the south patchwork,
## or -1 when outside it.
static func field_cell(x: float, z: float, origin: Vector2, size: Vector2, cell: Vector2, rot: float) -> int:
	var d := Vector2(x, z) - origin
	var c := cos(rot)
	var s := sin(rot)
	var u := d.x * c + d.y * s
	var v := -d.x * s + d.y * c
	if u < 0.0 or v < 0.0 or u > size.x or v > size.y:
		return -1
	var nx := int(ceil(size.x / cell.x))
	return int(v / cell.y) * nx + int(u / cell.x)
