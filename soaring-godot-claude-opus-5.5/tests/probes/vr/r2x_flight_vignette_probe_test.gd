extends TestCase
## VERIFIER PROBE (vr, round 2, experience lens). Not part of the area suite:
##   tools/gd.sh vr_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/vr --suite=r2x_flight
## Question: in ORDINARY flight -- straight, flapping, in open sky, no
## surface within reach of the optic-flow rays, no turning -- does the
## comfort vignette stay open, as VR.md §2.5 claims ("straight, fast flight
## in open sky keeps the full view")? The unit suite only feeds the vignette
## smooth synthetic rigs; here the rig is flown by flight's REAL PlayerBird
## (scenes/player/player.tscn, heave smoother on) with scripted arm strokes,
## exactly as flight's own PB-08 bob test does, and ComfortVignette measures
## the XROrigin3D's motion at the default setting (0.6).
## Pass bar (experience): straight open-sky flapping never narrows the view
## visibly: strength peak <= 0.10 (inner edge >= 52°, alpha x0.5) and it is
## above 0.05 for <= 10 % of the time (no "breathing" tunnel on every beat).

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const DT := 1.0 / 72.0
const DEG := PI / 180.0
const SETTING := 0.6

var fx: Variant


func after_each() -> void:
	if fx != null:
		fx.teardown()
		fx = null
	XRServer.world_scale = 1.0


func _fly(sp: StringName, kind: String, warm: float, secs: float) -> Dictionary:
	fx = FX.new(self)
	await fx.setup(sp)
	var p: PlayerBird = fx.player
	if kind == "hover":
		p.start_flying(Vector3(0, 200, 0), 0.0, 0.5)
		p.model.velocity = Vector3.ZERO
		fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			ScriptedPoseSource.flap(b, t, 45.0, 1.0)
			for a in b.arms:
				a.twist = 20.0 * DEG
	elif kind == "cruise":
		p.start_flying(Vector3(0, 200, 0), 0.0, 0.0)
		fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			ScriptedPoseSource.flap(b, t, 25.0, 1.0)
			for a in b.arms:
				a.twist = -20.0 * DEG
	elif kind == "climb":
		p.start_flying(Vector3(0, 200, 0), 0.0, 0.0)
		fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			ScriptedPoseSource.flap(b, t, 45.0, 1.0)
	elif kind == "fast_flaps":
		# An eager player: 1.6 Hz strokes, 40° amplitude.
		p.start_flying(Vector3(0, 200, 0), 0.0, 0.0)
		fx.driver = func(_tick: int, t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
			ScriptedPoseSource.flap(b, t, 40.0, 1.6)
	else:
		# Glide, no flapping (control).
		p.start_flying(Vector3(0, 200, 0), 0.0, 0.0)
		fx.driver = func(_tick: int, _t: float, b: HumanPoseModel) -> void:
			b.set_airplane()
	var vig := ComfortVignette.new()
	vig.auto_update = false
	vig.setting_override = SETTING
	p.camera.add_child(vig)
	vig.origin = p.origin
	var n_warm := int(round(warm / DT))
	for i in n_warm:
		fx.step()
		vig.measure(DT)
		vig.update_strength(DT)
	var peak := 0.0
	var sum := 0.0
	var over := 0
	var peak_acc := 0.0
	var peak_yaw := 0.0
	var peak_flow := 0.0
	var n := int(round(secs / DT))
	var ws := p.origin.world_scale
	var flaps0: int = fx.events["flapped"]
	for i in n:
		fx.step()
		vig.measure(DT)
		var s := vig.update_strength(DT)
		peak = maxf(peak, s)
		sum += s
		if s > 0.05:
			over += 1
		peak_acc = maxf(peak_acc, vig.accel / maxf(ws, 0.01))
		peak_yaw = maxf(peak_yaw, absf(rad_to_deg(vig.yaw_rate)))
		peak_flow = maxf(peak_flow, vig.flow)
	var out := {"peak": snappedf(peak, 0.001), "mean": snappedf(sum / n, 0.001), "frac_over_0.05": snappedf(float(over) / n, 0.001),
		"peak_perceived_accel": snappedf(peak_acc, 0.1), "peak_yaw_dps": snappedf(peak_yaw, 0.1), "peak_flow": snappedf(peak_flow, 0.01),
		"ws": snappedf(ws, 0.001), "airspeed": snappedf(p.model.airspeed(), 0.01), "flaps": fx.events["flapped"] - flaps0,
		"mode": p.mode_name()}
	vig.queue_free()
	fx.teardown()
	fx = null
	return out


func test_straight_flapping_in_open_sky_keeps_the_view_open() -> void:
	var cases := {
		"sparrow": ["glide", "cruise", "climb", "hover", "fast_flaps"],
		"starling": ["cruise", "climb"],
		"pigeon": ["cruise", "climb"],
		"eagle": ["cruise", "climb"],
	}
	var all := {}
	for sp in cases:
		for kind in cases[sp]:
			var r: Dictionary = await _fly(StringName(sp), kind, 6.0, 6.0)
			var tag := "%s %s" % [sp, kind]
			all[tag] = r
			print("[vr-verify] ", tag, " ", r)
			lt(float(r["peak_yaw_dps"]), 35.0, "%s: straight flight (rig yaw < 35°/s, so the yaw term is 0)" % tag)
			eq(float(r["peak_flow"]), 0.0, "%s: open sky (no surface within the flow rays)" % tag)
			lt(float(r["peak"]), 0.10, "%s: vignette peak in straight open-sky flight (default setting 0.6)" % tag)
			lt(float(r["frac_over_0.05"]), 0.10, "%s: fraction of time the view is visibly narrowed" % tag)
	metric("r2x_straight_flight_vignette", all)
