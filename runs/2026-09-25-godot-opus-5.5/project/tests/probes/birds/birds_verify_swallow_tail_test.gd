extends TestCase
## Verifier probe (birds, round 1): the swallow's folded wing against its
## tail streamers while the perch blend settles (landing), fold 1 and
## fold 0.99, perch 0.5 .. 1.0. Records how much of the landing shows the
## wing passing through the tail.

const Geo := preload("res://tests/unit/birds/bird_geo.gd")


func test_swallow_wing_vs_tail_during_perch_blend() -> void:
	var arr := Geo.arrays(&"swallow", 0)
	var rest: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var g := Geo.groups(arr)
	var right := Geo.wing_tris(arr, 1.0)
	var left := Geo.wing_tris(arr, -1.0)
	var tail := PackedInt32Array()
	for t in range(0, g.size(), 3):
		if g[t] == BirdPose.G_TAIL:
			tail.append(t)
	var rows := {}
	var crossing_perch := []
	for fold in [1.0, 0.99, 0.95]:
		for k in 11:
			var perch := 0.5 + k * 0.05
			var v := Geo.posed(arr, Vector4(0.69, 0.0, fold, perch))
			var n := Geo.count_crossings(v, rest, right, tail, false, 1000) + Geo.count_crossings(v, rest, left, tail, false, 1000)
			rows["f%.2f_p%.2f" % [fold, perch]] = n
			if n > 0:
				crossing_perch.append([fold, perch])
	metric("swallow_wing_tail_by_perch", rows)
	metric("crossing_at", crossing_perch)
	eq(crossing_perch.size(), 0, "swallow folded wing never passes through the tail during the perch blend (%s)" % str(crossing_perch))
