class_name CatchGrid
extends RefCounted
## Spatial hash for the catch rule's broad phase: GameLoop's default
## (CatchSweep, sort-and-sweep, is the tested alternative).
##
## GameLoop rebuilds it every physics frame from each bird's swept-segment
## midpoint. Birds are hashed into vertical columns of an x/z grid whose
## cell edge is the frame's reach (the largest contact distance plus the
## largest per-frame displacement): any pair that can touch during the frame
## lies in the same or an adjacent column, so pairs_of() finds every pair
## within reach on every axis, exactly once, and the narrow phase only runs
## on near neighbours instead of all n^2 pairs.
##
## Columns, not cubes: a sky is wide and shallow (a ~1.3 km valley under a
## 300 m ceiling), and a column has 4 "forward" neighbours to visit, a cube
## 13. Round 3's cube hash (a Dictionary of cells) cost ~135 µs a frame for
## 60 birds against ~20 µs for the sweep, so the sweep was the default; this
## one costs about what the sweep does (catch_rule_test.test_catch_cost_60_birds).
##
## Cells are keyed by one packed int (x + z*K). The table of cells is not a
## Dictionary but the items sorted by cell key (one native sort of packed
## keys): a column is a run of equal keys, its (+1, 0) neighbour the next
## run, and its three neighbours in the next row (keys + K - 1 .. + K + 1,
## consecutive integers) one native bsearch away. In GDScript a Dictionary
## probe or a function call per bird costs as much as a whole sort-and-sweep
## (a dictionary-of-arrays version of this hash cost ~65 µs for 60 birds,
## the sweep ~21 µs).

## Cells per axis: +-2^15 cells of the frame's reach (metres) is hundreds of
## km either way.
const _K := 1 << 16
const _HALF := 1 << 15

var cell_size := 4.0
var _keys := PackedFloat64Array()  # cell key * _slots + item slot, sorted
var _cell := PackedFloat64Array()  # cell key of each sorted item (bsearch)
var _order := PackedInt32Array()  # item index of each sorted item


## points[i] for i in `items` (indices into points). Returns flattened pairs
## [i0, j0, i1, j1, ...] of item indices within `reach` on every axis (the
## columns find the candidates, a box test keeps the near ones), each pair
## exactly once - CatchSweep.pairs' contract, for any number of items.
func pairs_of(points: PackedVector3Array, items: PackedInt32Array, reach: float) -> PackedInt32Array:
	var m := items.size()
	var out := PackedInt32Array()
	if m < 2:
		return out
	cell_size = maxf(reach, 0.01)
	var inv := 1.0 / cell_size
	# Keys pack the cell (< 2^32) above the item's slot (< 2^21): exact in a
	# double's 53 bits.
	var slots := 1
	while slots < m:
		slots <<= 1
	var fslots := float(slots)
	_keys.resize(m)
	for a in m:
		var pos := points[items[a]]
		var cx := clampi(floori(pos.x * inv) + _HALF, 1, _K - 2)
		var cz := clampi(floori(pos.z * inv) + _HALF, 1, _K - 2)
		_keys[a] = float(cx + cz * _K) * fslots + float(a)
	_keys.sort()
	_cell.resize(m)
	_order.resize(m)
	for a in m:
		var v := _keys[a]
		var c := floorf(v / fslots)
		_cell[a] = c
		_order[a] = items[int(v - c * fslots)]
	var r := reach
	var a0 := 0
	while a0 < m:
		var key := _cell[a0]
		var a1 := a0 + 1
		while a1 < m and _cell[a1] == key:
			a1 += 1
		# Pairs inside this column, and with the next column in its row
		# (key + 1: the run right after this one, if it is that key)...
		var b_end := a1
		if a1 < m and _cell[a1] == key + 1.0:
			b_end = a1 + 1
			while b_end < m and _cell[b_end] == key + 1.0:
				b_end += 1
		for a in range(a0, a1):
			var i := _order[a]
			var pi := points[i]
			for b in range(a + 1, b_end):
				var j := _order[b]
				var pj := points[j]
				if absf(pj.x - pi.x) <= r and absf(pj.y - pi.y) <= r and absf(pj.z - pi.z) <= r:
					out.append(i)
					out.append(j)
		# ...and with the three columns of the next row (keys + K - 1 ..
		# + K + 1). Every adjacent pair of columns is visited once.
		var lo := _cell.bsearch(key + float(_K) - 1.0)
		if lo < m and _cell[lo] <= key + float(_K) + 1.0:
			var hi := lo
			while hi < m and _cell[hi] <= key + float(_K) + 1.0:
				hi += 1
			for a in range(a0, a1):
				var i := _order[a]
				var pi := points[i]
				for b in range(lo, hi):
					var j := _order[b]
					var pj := points[j]
					if absf(pj.x - pi.x) <= r and absf(pj.y - pi.y) <= r and absf(pj.z - pi.z) <= r:
						out.append(i)
						out.append(j)
		a0 = a1
	return out
