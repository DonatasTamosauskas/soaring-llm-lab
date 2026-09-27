extends TestCase
## Verifier probes (round 1, flight): F12 bot pilot robustness on seeds the
## builder never pinned (their full sweep is seeds 31-40; development 21-30).
## Every run: poses only, window within 60 % of its clearance, 0 stuns, 0
## frame hits, PERCHED on the target within the time limit, comfort monitor.
##   -- --seeds=1-10 (default) | --seeds=41-50 ; --species=all (default S3)

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const BC := preload("res://tests/unit/flight/bot_course.gd")

var _fx: FX
var _lines := PackedStringArray()


func after_each() -> void:
	if _fx != null:
		_fx.teardown()
		_fx = null
	await get_tree().process_frame


func after_all() -> void:
	var tag := Paths.arg("seeds", "1-10")
	var path := Paths.artifacts("flight").path_join("verify").path_join("bot_probe_seeds_%s.txt" % tag)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(_lines))


func test_f12_bot_unpinned_seeds() -> void:
	var range_s: String = Paths.arg("seeds", "1-10")
	var parts := range_s.split("-")
	var s0 := int(parts[0])
	var s1 := int(parts[1]) if parts.size() > 1 else s0
	var sps: Array = [&"sparrow", &"starling", &"pigeon", &"crow", &"gull", &"eagle"] if Paths.arg("species", "") == "all" \
		else [&"sparrow", &"pigeon", &"eagle"]
	var ok := 0
	var n := 0
	var per_sp := {}
	for sp in sps:
		per_sp[sp] = [0, 0]
		for seed in range(s0, s1 + 1):
			_fx = FX.new(self)
			var b := BC.new(_fx, sp)
			await b.setup(false, 1, seed)
			b.fly()
			var c := b.course
			var p := _fx.player
			var stuns: int = p.contacts["stun"]
			var slides: int = p.contacts["slide"]
			var comfort_ok: bool = _fx.comfort["basis_bad"] == 0 and _fx.comfort["origin_bad"] == 0 \
				and rad_to_deg(_fx.comfort["max_rate"]) <= 240.001 and rad_to_deg(_fx.comfort["max_accel"]) < 756.0
			var good: bool = b.window_ok(0.6) and b.perched_on_target and stuns == 0 and slides == 0 and comfort_ok \
				and b.perched_t >= 0.0 and b.perched_t <= b.limit_s
			n += 1
			per_sp[sp][1] += 1
			if good:
				ok += 1
				per_sp[sp][0] += 1
			_lines.append("%s seed %d: %s window worst %.2f (err %s) crossed %s perched %s at %.1f s (limit %.0f) stuns %d slides %d brushes %d final mode %s comfort %s maxacc %.0f" % [
				sp, seed, "OK  " if good else "FAIL", b.worst_window_frac(), str(b.window_err), str(b.window_crossed), str(b.perched_on_target),
				b.perched_t, b.limit_s, stuns, slides, p.contacts["brush"], p.mode_name(), str(comfort_ok), rad_to_deg(_fx.comfort["max_accel"])])
			_fx.teardown()
			_fx = null
	_lines.append("TOTAL %d / %d ; per species %s" % [ok, n, str(per_sp)])
	metric("ok", ok)
	metric("runs", n)
	metric("per_species", per_sp)
	# The builder's claim is 60/60 on seeds 31-40 and >= 95 % as the sweep bar.
	gt(float(ok) / n, 0.95 - 1e-6, "B1 completion on unpinned seeds %s (%d / %d)" % [range_s, ok, n])
