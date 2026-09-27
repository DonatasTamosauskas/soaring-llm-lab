extends TestCase
## Verifier probe (round 2, flight): trace of a head-on wall hit with
## neutral arms. In r2_rig_perch_probe the sparrow and the pigeon ended up
## 15-20 m BEHIND a 1 m thick, 60 m wide, 80 m tall wall after being
## stunned by it. Where did they cross the wall plane, and how?
## Output: artifacts/flight/verify/r2/wall_trace.txt

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const DT := 1.0 / 72.0

var fx: FX
var _lines := PackedStringArray()


func _log(s: String) -> void:
	_lines.append(s)
	print("[flight-verify] ", s)


func after_each() -> void:
	if fx != null:
		fx.teardown()
		fx = null
	await get_tree().process_frame


func after_all() -> void:
	var path := Paths.artifacts("flight").path_join("verify/r2/wall_trace.txt")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(_lines) + "\n")


func test_r2_wall_trace() -> void:
	var through := 0
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		for thick: float in [1.0, 0.2]:
			fx = FX.new(self)
			await fx.setup(sp, func(w: Variant) -> void:
				w.add_wall(Vector3(0, 40, -40), Vector3(60, 80, thick)))
			var p := fx.player
			var front := -40.0 + 0.5 * thick
			var back := -40.0 - 0.5 * thick
			p.start_flying(Vector3(0, 40, -40 + 6.0 * p.model.params.span + 3.0), 0.0, 0.0)
			var st := {"crossed": -1.0, "inside": 0, "prev": p.model.position, "log": PackedStringArray()}
			fx.on_tick = func(tick: int, f: Variant) -> void:
				var pl: PlayerBird = f.player
				var pos := pl.model.position
				var prev: Vector3 = st["prev"]
				var in_slab: bool = absf(pos.x) < 30.0 and pos.y < 80.0 and pos.y > 0.0
				if in_slab and pos.z < front and pos.z > back:
					st["inside"] += 1
				if st["crossed"] < 0.0 and in_slab and prev.z >= back and pos.z < back:
					st["crossed"] = tick * DT
				if tick % 9 == 0 or (in_slab and absf(pos.z - front) < 1.0):
					(st["log"] as PackedStringArray).append("t=%.3f pos=(%.2f, %.2f, %.3f) v=(%.2f, %.2f, %.2f) mode=%s heading=%.0f contact=%d stun_left=%.2f" % [
						tick * DT, pos.x, pos.y, pos.z, pl.model.velocity.x, pl.model.velocity.y, pl.model.velocity.z, pl.mode_name(),
						rad_to_deg(pl.model.heading()), pl.last_contact, pl.stun_left])
				st["prev"] = pos
			fx.run(8.0)
			var pos := p.model.position
			var behind: bool = pos.z < back and absf(pos.x) < 30.0 and pos.y < 80.0
			_log("%s wall %.1f m: end pos (%.1f, %.1f, %.1f), crossed the slab's back face inside its extent at %.2f s, ticks with the centre inside the slab %d, stuns %d" % [
				sp, thick, pos.x, pos.y, pos.z, st["crossed"], st["inside"], p.contacts["stun"]])
			if st["crossed"] >= 0.0 or st["inside"] > 0:
				through += 1
				for l in st["log"]:
					_log("   " + l)
			fx.teardown()
			fx = null
	eq(through, 0, "the bird never passes through (or sits inside) a wall after a head-on hit")
