class_name ScriptedPoseSource
extends PoseSource
## A HumanPoseModel driven by a tick-indexed script (FLIGHT_SPEC §3.1):
## driver.call(tick: int, t: float, body: HumanPoseModel) sets the joints for
## this tick. Deterministic from the model's seed. Used by tests, replays of
## gesture libraries and simulator runs (through HybridPoseSource).

var body: HumanPoseModel
var driver: Callable
var tick := 0
var dt := 1.0 / 72.0


func _init(p_body: HumanPoseModel = null, p_driver: Callable = Callable()) -> void:
	body = p_body if p_body != null else HumanPoseModel.new()
	driver = p_driver


func sample(out: PoseFrame, p_dt: float) -> void:
	dt = p_dt
	body.t = tick * p_dt
	if driver.is_valid():
		driver.call(tick, body.t, body)
	body.frame(out)
	tick += 1


func drives_nodes() -> bool:
	return true


func reset() -> void:
	tick = 0


# --- gesture helpers (usable from any driver) ---------------------------------

## Arm elevation of a stroke of amplitude `amp` (rad) about `base`, top at
## phase 0, downstroke share `duty`.
static func stroke(t: float, amp: float, hz: float, duty := 0.5, base := 0.0) -> float:
	return base + FlapDetector.stroke_elevation(t, amp, hz, duty)


## Both arms (side 0) or one arm (-1 left, +1 right) flap the reference stroke.
static func flap(body: HumanPoseModel, t: float, amp_deg := 45.0, hz := 1.0, side := 0, duty := 0.5, base_deg := 0.0) -> void:
	var d := stroke(t, deg_to_rad(amp_deg), hz, duty, deg_to_rad(base_deg))
	if side <= 0:
		body.arms[0].dihedral = d
	if side >= 0:
		body.arms[1].dihedral = d
