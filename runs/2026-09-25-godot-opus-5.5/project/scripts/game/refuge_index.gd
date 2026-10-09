class_name RefugeIndex
extends RefCounted
## The world's refuges (World.get_refuges(): {position, radius, max_span}),
## indexed for the question the game loop and the target cue ask many times
## a frame: "is this point inside a refuge too small for a bird this wide?"
## (blocks).
##
## The valley has ~300 refuges (most of them hedgerow hollows). A linear scan
## of every refuge dictionary for every worthwhile prey in the target cue's
## range cost 0.4-3 ms a frame (fix round 2 review); the budget for the whole
## threat/target pass is 0.3 ms. Here a query is one dictionary probe of a
## 2D grid of columns (refuges are small spheres near the ground, so x/z
## cells are enough) plus a few float compares on packed arrays.
##
## Built once from the list (GameLoop rebuilds it on World.generated). The
## refuges of a cell are sorted by max_span, smallest first, so a query for a
## bird of span s stops at the first refuge it fits into: every later one fits
## it too. CatchRule.in_refuge() is the linear reference it is tested against.

## Column edge (m). Refuge radii are 0.06-2 m, so a refuge touches at most a
## few cells; a query is always exactly one cell.
const CELL := 8.0

var size := 0
## Smallest max_span of any refuge: a bird no wider fits into every refuge,
## so nothing can block it (the common case for the player: one compare).
var min_max_span := INF

var _pos := PackedVector3Array()
var _r2 := PackedFloat64Array()
var _span := PackedFloat64Array()
## Cell key -> PackedInt32Array of refuge indices sorted by max_span.
var _cells := {}


func _init(refuges: Array[Dictionary] = []) -> void:
	build(refuges)


func build(refuges: Array[Dictionary]) -> void:
	size = refuges.size()
	_pos.resize(size)
	_r2.resize(size)
	_span.resize(size)
	_cells.clear()
	min_max_span = INF
	var lists := {}
	for i in size:
		var r := refuges[i]
		var p: Vector3 = r.get("position", Vector3.INF)
		var rad := float(r.get("radius", 0.0))
		var span := float(r.get("max_span", INF))
		_pos[i] = p
		_r2[i] = rad * rad
		_span[i] = span
		min_max_span = minf(min_max_span, span)
		if not p.is_finite() or rad <= 0.0:
			continue
		for cx in range(floori((p.x - rad) / CELL), floori((p.x + rad) / CELL) + 1):
			for cz in range(floori((p.z - rad) / CELL), floori((p.z + rad) / CELL) + 1):
				var k := _key(cx, cz)
				if not lists.has(k):
					lists[k] = []
				(lists[k] as Array).append(i)
	for k: int in lists:
		var ids: Array = lists[k]
		ids.sort_custom(func(a: int, b: int) -> bool:
			return _span[a] < _span[b] or (_span[a] == _span[b] and a < b))
		_cells[k] = PackedInt32Array(ids)


static func _key(cx: int, cz: int) -> int:
	return (cx + (1 << 20)) * (1 << 21) + (cz + (1 << 20))


## True if `pos` is inside a refuge whose max_span is smaller than
## `pred_span` (a predator that wide cannot follow the prey in). Same answer
## as CatchRule.in_refuge(pos, pred_span, refuges).
func blocks(pos: Vector3, pred_span: float) -> bool:
	if pred_span <= min_max_span:
		return false
	var ids: Variant = _cells.get(_key(floori(pos.x / CELL), floori(pos.z / CELL)))
	if ids == null:
		return false
	for i: int in ids:
		if _span[i] >= pred_span:
			return false  # sorted: every later refuge admits this bird too
		if pos.distance_squared_to(_pos[i]) <= _r2[i]:
			return true
	return false

