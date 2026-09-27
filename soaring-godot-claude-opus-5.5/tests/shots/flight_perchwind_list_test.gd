extends TestCase
## Diagnostic: lists the misses of an approach set for one species in one
## wind (or several: --winds=still,head2.1,cross2.1,tail1.5,tail2.1).
##   tools/gd.sh flight --headless res://tests/runner.tscn -- --dir=res://tests/shots --suite=flight_perchwind_list --species=sparrow --winds=tail2.1 --set=glide

const PW := preload("res://tests/unit/flight/perch_wind.gd")
const WINDS := {"still": Vector3.ZERO, "head1.5": Vector3(0, 0, 1.5), "head2.1": Vector3(0, 0, 2.1), "cross1.5": Vector3(1.5, 0, 0),
	"cross2.1": Vector3(2.1, 0, 0), "tail1.5": Vector3(0, 0, -1.5), "tail2.1": Vector3(0, 0, -2.1)}


func test_list() -> void:
	var set_: Array = PW.glide_set() if Paths.arg("set", "glide") == "glide" else PW.verifier_set()
	for sp_s in Paths.arg("species", "sparrow").split(","):
		var sp := StringName(sp_s)
		for wn in Paths.arg("winds", "still").split(","):
			var r: Dictionary = await PW.share(self, sp, WINDS[wn], set_)
			print("[flight] %s %s share %.2f stuns %d" % [sp, wn, r["share"], r["stuns"]])
			for m in r["misses"]:
				print("[flight]   miss %s -> closest %.2f spans" % [str(m[0]), m[1]])
	check(true, "listed")
