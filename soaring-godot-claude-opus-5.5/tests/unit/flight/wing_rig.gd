extends RefCounted
## L2 helper: a HumanPoseModel driven by a tick-indexed script through
## ScriptedPoseSource into a WingInput (auto-calibration off unless asked).
##   const WR := preload("res://tests/unit/flight/wing_rig.gd")
##   var r := WR.new(func(tick, t, body): body.set_airplane())
##   r.run(2.0)   # seconds
##   r.ws.pitch ...

const DT := 1.0 / 72.0

var body: HumanPoseModel
var src: ScriptedPoseSource
var wi: WingInput
var frame := PoseFrame.new()
var ws: WingState
var tick := 0
## Per-tick callback after update: cb.call(tick, ws, rig)
var on_tick: Callable


func _init(driver: Callable = Callable(), auto_cal := false, p_body: HumanPoseModel = null, cal: WingCalibration = null) -> void:
	body = p_body if p_body != null else HumanPoseModel.new(7)
	src = ScriptedPoseSource.new(body, driver)
	wi = WingInput.new(cal)
	wi.auto_calibrate = auto_cal
	ws = wi.state


func run(seconds: float) -> WingState:
	var n := int(round(seconds / DT))
	for i in n:
		step()
	return ws


func step() -> WingState:
	src.sample(frame, DT)
	ws = wi.update(frame, DT)
	if on_tick.is_valid():
		on_tick.call(tick, ws, self)
	tick += 1
	return ws


## Numeric snapshot of every command and measurement (for "unchanged" asserts).
static func snap(w: WingState) -> Dictionary:
	return {
		"pitch": w.pitch, "roll": w.roll, "ext_l": w.ext_l, "ext_r": w.ext_r, "flap_l": w.flap_l, "flap_r": w.flap_r,
		"up_l": w.up_l, "up_r": w.up_r, "twist_l": w.twist_l, "twist_r": w.twist_r,
		"dihedral_l": w.dihedral_l, "dihedral_r": w.dihedral_r, "sweep_l": w.sweep_l, "sweep_r": w.sweep_r,
		"dir_l_x": w.flap_dir_l.x, "dir_l_y": w.flap_dir_l.y, "dir_l_z": w.flap_dir_l.z,
		"dir_r_x": w.flap_dir_r.x, "dir_r_y": w.flap_dir_r.y, "dir_r_z": w.flap_dir_r.z,
	}


static func max_diff(a: Dictionary, b: Dictionary) -> Array:
	var worst := 0.0
	var key := ""
	for k in a:
		var d := absf(float(a[k]) - float(b[k]))
		if d > worst:
			worst = d
			key = k
	return [worst, key]


## The standard airplane-arms body, optionally with a stroke.
static func airplane() -> Callable:
	return func(_tick: int, _t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
