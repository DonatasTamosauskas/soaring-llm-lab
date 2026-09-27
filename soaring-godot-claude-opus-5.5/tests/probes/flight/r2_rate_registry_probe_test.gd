extends TestCase
## Verifier probe (round 2, flight, experience lens):
##  - the Birds registry after the PlayerBird is freed (restart / scene
##    reload): PlayerBird overrides Bird._exit_tree without super();
##  - does flight FEEL the same at the Quest Pro's display rates? The VR
##    autoload ticks physics at the refresh rate (72 / 90 / 120 Hz): the
##    whole pose chain (poses -> WingInput -> detector -> model) should give
##    the same climb per stroke, the same turn and the same glide.
## Output: artifacts/flight/verify/r2/rate_registry_probe.txt

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const PLAYER := preload("res://scenes/player/player.tscn")
const DEG := PI / 180.0

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
	var path := Paths.artifacts("flight").path_join("verify/r2/rate_registry_probe.txt")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(_lines) + "\n")


func test_r2_registry_forgets_a_freed_player() -> void:
	var n0 := Birds.count()
	var p := PLAYER.instantiate() as PlayerBird
	p.auto_process = false
	p.use_settings = false
	p.default_source = &"none"
	add_child(p)
	await get_tree().process_frame
	var registered := Birds.player() == p
	remove_child(p)
	p.free()
	await get_tree().process_frame
	var dangling := 0
	for b in Birds.all():
		if not is_instance_valid(b):
			dangling += 1
	var pl_valid := Birds.player() == null or is_instance_valid(Birds.player())
	_log("registry: registered as player %s; after free: count %d (before %d), dangling entries %d, Birds.player() valid-or-null %s" % [
		registered, Birds.count(), n0, dangling, pl_valid])
	check(registered, "the player registers on entering the tree")
	eq(dangling, 0, "no freed PlayerBird left in Birds.all() (Bird._exit_tree must run: PlayerBird._exit_tree lacks super())")
	check(pl_valid, "Birds.player() is null or valid after the player is freed")
	# Clean the registry for the suites that follow (the probe's own mess).
	for b in Birds.all().duplicate():
		if not is_instance_valid(b):
			Birds.all().erase(b)


func _fly(sp: StringName, hz: float, kind: String) -> Dictionary:
	fx = FX.new(self)
	await fx.setup(sp)
	var f := fx
	var p := f.player
	var dt := 1.0 / hz
	p.start_flying(Vector3(0, 400, 0), 0.0, 0.0)
	var cal := p.wing_input.calibration
	# The pose script is driven by time, never by tick count.
	var st := {"t": 0.0}
	var drv := func(_tick: int, _t: float, b: HumanPoseModel) -> void:
		var t: float = st["t"]
		b.set_airplane()
		if kind == "flap":
			ScriptedPoseSource.flap(b, t, 40.0, 1.0)
			for a in b.arms:
				a.twist = -12.0 * DEG
		elif kind == "bursts":
			var tt := fmod(t, 4.0)
			if tt < 2.0:
				ScriptedPoseSource.flap(b, tt, 40.0, 1.0)
		elif kind == "turn":
			b.synth(0.1, 0.6, 1.0, cal)
		else:
			b.synth(0.3, 0.0, 1.0, cal)
	var src := ScriptedPoseSource.new(f.body, drv)
	p.set_pose_source(src)
	var m := p.model
	var e0 := m.position.y + m.velocity.length_squared() / 19.62
	var h0 := m.heading()
	var turned := 0.0
	var prev := h0
	var onsets := 0
	var n := int(round(12.0 * hz))
	for i in n:
		st["t"] = i * dt
		p.tick(dt)
		var hh := m.heading()
		turned += wrapf(hh - prev, -PI, PI)
		prev = hh
		var ws := p.wing_state()
		onsets += (1 if ws.onset_l else 0) + (1 if ws.onset_r else 0)
	var e1 := m.position.y + m.velocity.length_squared() / 19.62
	var r := {"de": e1 - e0, "turn": rad_to_deg(turned), "v": m.airspeed(), "onsets": onsets}
	fx.teardown()
	fx = null
	return r


func test_r2_rate_feel_72_90_120() -> void:
	var worst := 0.0
	var worst_tag := ""
	for sp: StringName in [&"sparrow", &"pigeon", &"eagle"]:
		for kind in ["flap", "bursts", "turn", "glide"]:
			var ref: Dictionary = await _fly(sp, 72.0, kind)
			for hz: float in [90.0, 120.0]:
				var r: Dictionary = await _fly(sp, hz, kind)
				var d_e: float = absf(float(r["de"]) - float(ref["de"])) / maxf(absf(float(ref["de"])), 5.0)
				var d_t: float = absf(float(r["turn"]) - float(ref["turn"])) / maxf(absf(float(ref["turn"])), 10.0)
				var d_v: float = absf(float(r["v"]) - float(ref["v"])) / maxf(float(ref["v"]), 1.0)
				var d := maxf(d_e, maxf(d_t, d_v))
				_log("%s %-6s %3d Hz vs 72 Hz: energy-height change %.2f vs %.2f m (%.1f%%), turn %.0f vs %.0f deg (%.1f%%), end V %.2f vs %.2f (%.1f%%), onsets %d vs %d" % [
					sp, kind, int(hz), r["de"], ref["de"], 100.0 * d_e, r["turn"], ref["turn"], 100.0 * d_t, r["v"], ref["v"], 100.0 * d_v,
					r["onsets"], ref["onsets"]])
				if d > worst:
					worst = d
					worst_tag = "%s %s %d Hz" % [sp, kind, int(hz)]
				lt(d, 0.10, "%s %s at %d Hz: climb, turn and speed within 10%% of 72 Hz" % [sp, kind, int(hz)])
	_log("rate feel: worst relative difference %.1f%% (%s)" % [100.0 * worst, worst_tag])
	metric("rate_worst", worst)
