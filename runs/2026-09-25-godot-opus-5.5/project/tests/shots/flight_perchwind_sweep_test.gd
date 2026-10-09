extends TestCase
## The full F10 wind sweep (evidence): per species and wind (still, head,
## cross and tail at 1.5 and 2.1 m/s), the share of an approach set that
## perches. --set=glide (27 slow glide-ins, asserted with P10's thresholds)
## or --set=verifier (the round-3 verifier's 54, reported). Writes
## artifacts/flight/perch_wind_sweep_<set>.json.
##   tools/gd.sh flight --headless res://tests/runner.tscn -- --dir=res://tests/shots --suite=flight_perchwind_sweep --set=glide

const PW := preload("res://tests/unit/flight/perch_wind.gd")


func test_sweep() -> void:
	var winds := [["still", Vector3.ZERO], ["head 1.5", Vector3(0, 0, 1.5)], ["head 2.1", Vector3(0, 0, 2.1)],
		["cross 1.5", Vector3(1.5, 0, 0)], ["cross 2.1", Vector3(2.1, 0, 0)],
		["tail 1.5", Vector3(0, 0, -1.5)], ["tail 2.1", Vector3(0, 0, -2.1)]]
	var sps := [&"sparrow", &"pigeon", &"eagle"]
	var sp_arg := Paths.arg("species", "")
	if sp_arg != "":
		sps = [StringName(sp_arg)]
	var set_name := Paths.arg("set", "glide")
	var set_: Array = PW.glide_set() if set_name == "glide" else PW.verifier_set()
	var report := {"set": set_name}
	for sp in sps:
		var row := {}
		for wd in winds:
			var r: Dictionary = await PW.share(self, sp, wd[1], set_)
			row[wd[0]] = r
			var by_back := {}
			for m in r["misses"]:
				by_back[m[0]["back"]] = int(by_back.get(m[0]["back"], 0)) + 1
			print("[flight] perch wind sweep (%s) %s %-9s share %.2f (median %.2f s, stuns %d, max rig %.0f deg/s, %.0f deg/s2 in the air, %.0f deg/s2 at touchdown, view turn after %.1f deg, at rest in %.2f s) misses by start distance %s" % [
				set_name, sp, wd[0], r["share"], r["median_t"], r["stuns"], r["max_rate_deg"], r["air_accel_deg"], r["max_accel_deg"],
				r["after_deg"], r["rest_s"], str(by_back)])
		report[sp] = row
		var glide := set_name == "glide"
		for k in row:
			# P10's comfort split (fix round 4): crosswind landings crab the bird
			# and the view must follow smoothly in the air (round 3: a branch
			# contact's heading wiggle read as 720 deg/s^2); at touchdown the
			# rig's own turn brakes to rest at the comfort cap, then stays put.
			# The verifier's set starts 2-6 spans out with the track up to 36
			# deg off the branch: its last-moment crab turns the rig up to
			# ~160 deg/s, so it keeps round 3's bound in the air (by design the
			# rig's yaw acceleration is at most 360 + 240 = 600 deg/s^2 there)
			# and its turn after the touchdown, the stop at the cap (v^2 / 2a,
			# up to ~18 deg), is reported, not asserted.
			lt(float(row[k]["air_accel_deg"]), 0.75 * 720.0 if glide else 650.0, "%s %s: the approach stays clear of the rig's yaw-acceleration cap (deg/s^2)" % [sp, k])
			lt(float(row[k]["max_accel_deg"]), 720.0 + 1e-3, "%s %s: touchdown inside the cap (deg/s^2)" % [sp, k])
			if glide:
				lt(float(row[k]["after_deg"]), 5.0, "%s %s: the view turns < 5 deg after the touchdown" % [sp, k])
			lt(float(row[k]["rest_s"]), 0.35, "%s %s: the rig at rest within 0.35 s of the touchdown (s)" % [sp, k])
		if set_name != "glide":
			continue  # the verifier's set is reported, not asserted (FLIGHT.md §8)
		var still: float = row["still"]["share"]
		for k in row:
			if k == "still":
				continue
			# P10's thresholds: 80 %, 70 % for the 2.1 m/s tailwind (downwind the
			# branch arrives sooner with the same speed to lose).
			var need := 0.7 if k == "tail 2.1" else 0.8
			gt(float(row[k]["share"]), need * still - 1e-9, "%s %s: >= %d %% of still-air success (%.2f vs %.2f)" % [
				sp, k, int(need * 100.0), row[k]["share"], still])
			eq(row[k]["stuns"], 0, "%s %s: no stuns" % [sp, k])
	check(report.size() > 1, "swept %d species" % (report.size() - 1))
	var f := FileAccess.open(Paths.artifacts("flight").path_join("perch_wind_sweep_%s.json" % set_name), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(report, "\t"))
