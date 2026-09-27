class_name CatchSweep
extends RefCounted
## Sort-and-sweep broad phase for the catch rule (the tested alternative to
## the default spatial hash, CatchGrid).
##
## Items are sorted by x (one native sort of packed keys), then each item is
## compared only with the following items until the x gap exceeds `reach`;
## the y/z gaps are box-tested. Any pair whose points are within `reach` on
## every axis is reported exactly once.
##
## Kept beside the hash as a cross-check and a fallback: it needs no
## dictionary at all (one native sort), and both are verified against brute
## force (catch_rule_test) and give the loop identical outcomes.

## Keys pack a millimetre-quantised x with the item index in the low 10
## bits; doubles hold 53-bit integers exactly, so this is exact for
## |x| < 100 km and up to 1024 items.
const MAX_ITEMS := 1024
const _X_OFFSET := 100000.0

var _keys := PackedFloat64Array()
var _order := PackedInt32Array()


## points[i] for i in `items` (indices into points). Returns flattened pairs
## [i0, j0, i1, j1, ...] of item indices within `reach` on every axis.
func pairs(points: PackedVector3Array, items: PackedInt32Array, reach: float) -> PackedInt32Array:
	var m := items.size()
	var out := PackedInt32Array()
	if m < 2:
		return out
	_keys.resize(m)
	for a in m:
		var i := items[a]
		_keys[a] = floorf((points[i].x + _X_OFFSET) * 1000.0) * 1024.0 + float(a)
	_keys.sort()
	_order.resize(m)
	for a in m:
		_order[a] = items[int(_keys[a]) & 1023]
	for a in m:
		var i := _order[a]
		var pi := points[i]
		for b in range(a + 1, m):
			var j := _order[b]
			var pj := points[j]
			if pj.x - pi.x > reach:
				break
			if absf(pj.y - pi.y) > reach or absf(pj.z - pi.z) > reach:
				continue
			out.append(i)
			out.append(j)
	return out
