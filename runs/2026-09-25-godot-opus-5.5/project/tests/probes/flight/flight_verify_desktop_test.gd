extends TestCase
## Verifier probe (round 1, flight): F13 for sizes the builder did not fly.
## Reuses the builder's closed-loop key pilot (desktop_test.gd _fly_lab:
## key events only) at starling, crow, gull and eagle size, and collects its
## own assertions (rings, 180 turn, tuck, landing, take-off, comfort).

const DT_SUITE := preload("res://tests/unit/flight/desktop_test.gd")

var _lines := PackedStringArray()


func after_all() -> void:
	var path := Paths.artifacts("flight").path_join("verify").path_join("desktop_probe.txt")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(_lines))


func test_f13_other_sizes() -> void:
	for sp: StringName in [&"starling", &"crow", &"gull", &"eagle"]:
		var inst: Node = DT_SUITE.new()
		inst.name = "desktop_probe_%s" % sp
		add_child(inst)
		inst._current = "f13_%s" % sp
		var r: Dictionary = await inst._fly_lab(sp)
		var ok: bool = r["rings"] == 3 and r["turned"] and r["turn_x_err"] < 3.0 and r["max_speed_tuck"] > 1.3 \
			and r["landed"] and r["stuns"] == 0 and r["took_off"] and r["climb_after_takeoff"] > 0.5 and not r["nan"]
		var fails: PackedStringArray = inst._failures
		_lines.append("%s: %s rings %d miss %s turned %s x_err %.2f tuck x%.2f landed %s (%s) stuns %d took_off %s climb %.2f; inner failures %s" % [
			sp, "OK" if ok else "FAIL", r["rings"], str(r["ring_miss"]), str(r["turned"]), r["turn_x_err"], r["max_speed_tuck"], str(r["landed"]),
			r["land_mode"], r["stuns"], str(r["took_off"]), r["climb_after_takeoff"], str(fails)])
		check(ok, "%s: the key pilot flies the lab (rings %d, turned %s, x_err %.2f, tuck x%.2f, landed %s, stuns %d, took off %s)" % [
			sp, r["rings"], str(r["turned"]), r["turn_x_err"], r["max_speed_tuck"], str(r["landed"]), r["stuns"], str(r["took_off"])])
		eq(fails.size(), 0, "%s: no inner assertion failures (%s)" % [sp, str(fails)])
		inst._release_all()
		remove_child(inst)
		inst.free()
