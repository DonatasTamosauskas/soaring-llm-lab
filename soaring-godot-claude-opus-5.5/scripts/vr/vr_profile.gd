class_name VRProfile
extends RefCounted
## Cumulative CPU time of the VR area's per-frame work, so the simulator
## harness can report exactly what the VR features cost (Quest budget:
## GDScript shares the main thread with 60 birds; the Mac is ~3-4x faster).

## Off in the game: the simulator harness and the perf test switch it on,
## so production frames pay one static read per feature, nothing else.
static var enabled := false
static var usec := {}
static var calls := {}


## Start timestamp for add(), or 0 when profiling is off.
static func begin() -> int:
	return Time.get_ticks_usec() if enabled else 0


static func add(key: StringName, t0_usec: int) -> void:
	if not enabled:
		return
	usec[key] = int(usec.get(key, 0)) + (Time.get_ticks_usec() - t0_usec)
	calls[key] = int(calls.get(key, 0)) + 1


static func reset() -> void:
	usec.clear()
	calls.clear()


## {key: mean microseconds per call}
static func report() -> Dictionary:
	var out := {}
	for k in usec:
		out[k] = snappedf(float(usec[k]) / maxf(float(calls[k]), 1.0), 0.1)
	return out
