extends TestCase
## VERIFIER PROBE (vr, round 1, engineering lens): suite hygiene. The VR
## suites connect lambdas to the global Events / VR signals in before_all()
## (vr_manager_test, controls_test). Once a suite node is freed, a later
## suite (another area's, in the full run) emitting those signals must not
## hit a dangling connection, and the VR autoload's global state must be as
## the suites found it.

const SUITES := ["res://tests/unit/vr/vr_manager_test.gd", "res://tests/unit/vr/haptics_test.gd"]


func test_no_dangling_connections_after_vr_suites() -> void:
	var before := {
		"menu": Events.menu_requested.get_connections().size(),
		"unfocused": VR.session_unfocused.get_connections().size(),
		"focused": VR.session_focused.get_connections().size(),
		"stopping": VR.session_stopping.get_connections().size(),
	}
	for path in SUITES:
		var s := (load(path) as Script).new() as TestCase
		add_child(s)
		await s.before_all()
		await s.after_all()
		s.queue_free()
	await wait_frames(2)
	var after := {
		"menu": Events.menu_requested.get_connections().size(),
		"unfocused": VR.session_unfocused.get_connections().size(),
		"focused": VR.session_focused.get_connections().size(),
		"stopping": VR.session_stopping.get_connections().size(),
	}
	metric("connections_before", before)
	metric("connections_after", after)
	for k in before:
		eq(after[k], before[k], "%s: no connection left behind by the freed VR suites" % k)
	# Emitting now must be harmless (a dangling lambda would error here).
	Events.menu_requested.emit()
	VR.session_focused.emit()
	check(true, "emitted after the suites were freed")
