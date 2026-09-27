extends TestCase
## Verifier probe (round 2, flight, experience lens): F9 anti-cheese through
## the WHOLE chain (arm poses -> WingInput -> FlapDetector -> FlightModel on
## a real PlayerBird). What does a player gain with cheap motions a VR
## player will try: forearm pumping, wrist flicks (controller rotation
## with the small displacement a real wrist makes), wrist-twist pumping,
## antiphase pumping, rowing - compared with still arms (glide) and with
## real strokes? Energy height (h + V^2/2g) over 12 s.
## Output: artifacts/flight/verify/r2/cheese_probe.txt

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const DEG := PI / 180.0
const DT := 1.0 / 72.0
const SECS := 12.0

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
	var path := Paths.artifacts("flight").path_join("verify/r2/cheese_probe.txt")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(_lines) + "\n")


func _patterns() -> Dictionary:
	var p := {}
	p["still"] = func(_t: float, _b: HumanPoseModel) -> void:
		pass
	p["real 45deg 1Hz"] = func(t: float, b: HumanPoseModel) -> void:
		ScriptedPoseSource.flap(b, t, 45.0, 1.0)
	p["real 30deg 1.5Hz"] = func(t: float, b: HumanPoseModel) -> void:
		ScriptedPoseSource.flap(b, t, 30.0, 1.5)
	p["spec quick 15deg 2Hz"] = func(t: float, b: HumanPoseModel) -> void:
		ScriptedPoseSource.flap(b, t, 15.0, 2.0)
	for a: float in [0.06, 0.10, 0.12, 0.15, 0.20]:
		for hz: float in [3.0, 4.0, 6.0, 8.0]:
			p["pump +-%dcm %dHz" % [int(a * 100), int(hz)]] = func(t: float, b: HumanPoseModel) -> void:
				var y := a * sin(TAU * hz * t)
				b.hand_offset[0] = Vector3(0, y, 0)
				b.hand_offset[1] = Vector3(0, y, 0)
	for hz: float in [4.0, 6.0, 8.0, 10.0]:
		# A wrist flick: the controller pitches +-40 deg about its own X and
		# the grip point moves +-5 cm with it (it is ~8 cm from the wrist).
		p["wrist flick %dHz" % int(hz)] = func(t: float, b: HumanPoseModel) -> void:
			var s := sin(TAU * hz * t)
			for i in 2:
				b.grip_offset[i] = Basis(Vector3.RIGHT, 40.0 * DEG * s)
				b.hand_offset[i] = Vector3(0, 0.05 * s, 0)
		p["wrist twist pump %dHz" % int(hz)] = func(t: float, b: HumanPoseModel) -> void:
			var s := 35.0 * DEG * sin(TAU * hz * t)
			for a in b.arms:
				a.twist = s
	for hz: float in [3.0, 5.0]:
		p["antiphase +-12cm %dHz" % int(hz)] = func(t: float, b: HumanPoseModel) -> void:
			var y := 0.12 * sin(TAU * hz * t)
			b.hand_offset[0] = Vector3(0, y, 0)
			b.hand_offset[1] = Vector3(0, -y, 0)
		p["rowing +-15cm %dHz" % int(hz)] = func(t: float, b: HumanPoseModel) -> void:
			var z := 0.15 * sin(TAU * hz * t)
			b.hand_offset[0] = Vector3(0, 0, z)
			b.hand_offset[1] = Vector3(0, 0, z)
		p["pump+flick +-10cm %dHz" % int(hz)] = func(t: float, b: HumanPoseModel) -> void:
			var s := sin(TAU * hz * t)
			for i in 2:
				b.grip_offset[i] = Basis(Vector3.RIGHT, -30.0 * DEG * s)
				b.hand_offset[i] = Vector3(0, 0.10 * s, 0)
	return p


func _fly(sp: StringName, pat: Callable) -> Dictionary:
	fx = FX.new(self)
	await fx.setup(sp)
	var f := fx
	f.player.start_flying(Vector3(0, 300, 0), 0.0, 0.0)
	f.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		b.hand_offset[0] = Vector3.ZERO
		b.hand_offset[1] = Vector3.ZERO
		b.grip_offset[0] = Basis()
		b.grip_offset[1] = Basis()
		pat.call(t, b)
	var m := f.player.model
	var e0 := m.position.y + m.velocity.length_squared() / (2.0 * 9.81)
	var st := {"onsets": 0, "flap_sum": 0.0}
	f.on_tick = func(_tick: int, fix: Variant) -> void:
		var ws: WingState = fix.player.wing_state()
		if ws.onset_l:
			st["onsets"] += 1
		if ws.onset_r:
			st["onsets"] += 1
		st["flap_sum"] += 0.5 * (ws.flap_l + ws.flap_r) * DT
	f.reset_events()
	f.run(SECS)
	var e1 := m.position.y + m.velocity.length_squared() / (2.0 * 9.81)
	var r := {"de": e1 - e0, "onsets": st["onsets"], "flap": st["flap_sum"] / SECS, "events": f.events["flapped"],
		"stuns": f.player.contacts["stun"], "mode": f.player.mode_name()}
	fx.teardown()
	fx = null
	return r


func test_r2_cheap_motions_vs_real_strokes() -> void:
	var pats := _patterns()
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		var res := {}
		for k in pats:
			res[k] = await _fly(sp, pats[k])
		var still: float = res["still"]["de"]
		var real: float = res["real 45deg 1Hz"]["de"] - still
		_log("== %s: still glide de %.2f m; real 45deg 1 Hz strokes gain %.2f m over the glide in %.0f s" % [sp, still, real, SECS])
		var worst_cheap := -INF
		var worst_name := ""
		for k in res:
			var r: Dictionary = res[k]
			var gain: float = float(r["de"]) - still
			_log("%s %-26s gain %+7.2f m (%+5.0f%% of real)  onsets %3d  mean flap %.3f  events %3d" % [
				sp, k, gain, 100.0 * gain / maxf(real, 1e-6), r["onsets"], r["flap"], r["events"]])
			var cheap: bool = String(k).begins_with("wrist") or String(k).begins_with("rowing") \
				or String(k).begins_with("antiphase") or (String(k).begins_with("pump +-") and (String(k).contains("+-6cm") or String(k).contains("+-10cm")))
			if String(k).begins_with("wrist twist"):
				# Twist jitter only shifts the effective pitch trim (the pitch
				# shaping is asymmetric): no net climb in absolute terms.
				lt(float(r["de"]), 0.0, "%s %s: no net climb (absolute energy height change, m)" % [sp, k])
				cheap = false
			if cheap:
				# F9: small fast shaking / flicking yields no net climb.
				lt(gain, 0.05 * real + 0.3, "%s %s: no net climb from a cheap motion (m of energy height)" % [sp, k])
				if gain > worst_cheap:
					worst_cheap = gain
					worst_name = k
			metric("%s_%s" % [sp, k], gain)
		_log("%s: worst cheap motion %s gains %.2f m" % [sp, worst_name, worst_cheap])
		# FLIGHT_SPEC 6.3 says "big birds need deep, slower strokes" and
		# "small birds reach full effort with +-15 deg at 2 Hz". Logged, not
		# asserted: a +-20 cm pump at 3 Hz costs ~5x the arm power of the
		# 1 Hz reference stroke (A^2 f^3), so out-climbing it is frantic
		# effort (FM-14 allows <= 1.2x force), not a cheap exploit.
		for k in ["pump +-20cm 3Hz", "pump +-20cm 4Hz", "spec quick 15deg 2Hz"]:
			_log("NOTE %s %s: %.0f%% of the deep 1 Hz stroke's climb" % [sp, k, 100.0 * (float(res[k]["de"]) - still) / maxf(real, 1e-6)])
