extends TestCase
## VERIFIER PROBE (vr, round 3, experience lens). Not part of the area suite:
##   tools/gd.sh vr_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/vr --suite=r3x_focus_scale
## 1. Focus chatter (a guardian boundary flickering, the system bar peeked
##    at repeatedly, presence sensor bouncing) while PLAYING and CAUGHT, with
##    a UI that TOGGLES pause on menu_requested (as UIRoot does): the game
##    must end paused, with exactly one menu request, never resumed by VR.
## 2. world_scale must never jump in play: a settings change of the
##    exponent (Settings menu mid-run) and a mid-run recalibration that
##    changes the arm span both ramp at <= 0.25 ln/s; garbage settings /
##    masses never produce a non-finite scale or near plane.

const Env := preload("res://scenes/dev/vr_dev_env.gd")
const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const DT := 1.0 / 72.0

var menu := 0
var toggles := 0


func _toggling_ui() -> void:
	menu += 1
	# UIRoot-like: the menu request toggles the pause menu.
	if Game.state == Game.State.PAUSED:
		Game.set_state(Game.State.PLAYING)
	elif Game.state == Game.State.PLAYING or Game.state == Game.State.CAUGHT:
		Game.set_state(Game.State.PAUSED)
	toggles += 1


func after_each() -> void:
	if Events.menu_requested.is_connected(_toggling_ui):
		Events.menu_requested.disconnect(_toggling_ui)
	Game.set_state(Game.State.BOOT)
	get_tree().paused = false
	VR.focused = false
	VR.user_present = true
	VR.session_state = "none"


func test_focus_chatter_pauses_once_and_never_resumes() -> void:
	var rows := {}
	for start in [Game.State.PLAYING, Game.State.CAUGHT]:
		for pattern in ["visible/focused x10", "presence off/on x10", "visible, presence off, stopping", "mixed"]:
			Game.set_state(Game.State.BOOT)
			get_tree().paused = false
			Game.set_state(start)
			VR._on_session_focused()
			menu = 0
			toggles = 0
			Events.menu_requested.connect(_toggling_ui)
			var states: Array[String] = []
			match pattern:
				"visible/focused x10":
					for i in 10:
						VR._on_session_visible()
						states.append(Game.state_name())
						VR._on_session_focused()
						states.append(Game.state_name())
				"presence off/on x10":
					for i in 10:
						VR._on_user_presence_changed(false)
						states.append(Game.state_name())
						VR._on_user_presence_changed(true)
						states.append(Game.state_name())
				"visible, presence off, stopping":
					VR._on_session_visible()
					VR._on_user_presence_changed(false)
					VR._on_session_stopping()
					states.append(Game.state_name())
				"mixed":
					for i in 5:
						VR._on_session_visible()
						VR._on_user_presence_changed(false)
						VR._on_session_focused()
						VR._on_user_presence_changed(true)
						states.append(Game.state_name())
			Events.menu_requested.disconnect(_toggling_ui)
			var tag := "%s: %s" % [Game.state_name(start), pattern]
			rows[tag] = {"menu_requests": menu, "end_state": Game.state_name(), "tree_paused": get_tree().paused, "states_seen": states}
			print("[vr-verify] ", tag, " ", rows[tag])
			eq(Game.state_name(), "PAUSED", "%s: ends paused" % tag)
			check(get_tree().paused, "%s: tree paused" % tag)
			eq(menu, 1, "%s: exactly one menu request (a toggling UI never resumes)" % tag)
			check(not states.has("PLAYING"), "%s: never back in PLAYING during the chatter" % tag)
	metric("focus_chatter", rows)


func test_world_scale_never_jumps_in_play() -> void:
	var store := MemoryStore.new()
	var rig := Env.build_rig(self, Vector3(0, 3, 0), store, false, false)
	await wait_frames(3)
	var extras: VRRigExtras = rig["extras"]
	var drv := extras.world_scale_driver
	drv.auto_step = false
	drv.store = store
	var p: Bird = rig["player"]
	p.mass = float(SizeRules.SPECIES[SizeRules.species_index(&"sparrow")]["mass"])
	drv.snap()
	drv.step(DT)
	var origin := rig["origin"] as XROrigin3D
	var cam := rig["camera"] as Camera3D
	var rows := {}
	var worst := 0.0
	var prev := origin.world_scale
	# 1. The player changes the exponent in the Settings menu mid-run.
	store.set_value("world_scale_exponent", 0.8)
	for i in int(3.0 / DT):
		drv.step(DT)
		worst = maxf(worst, absf(log(origin.world_scale) - log(prev)) / DT)
		prev = origin.world_scale
	rows["exponent 1.0 -> 0.8"] = {"worst_ln_per_s": snappedf(worst, 0.001), "ws": snappedf(origin.world_scale, 0.0001)}
	lt(worst, 0.25 + 1e-3, "exponent change mid-run ramps (worst %.3f ln/s)" % worst)
	# 2. A recalibration mid-run: the arm span changes by 0.4 m.
	worst = 0.0
	drv.arm_span_override = drv.arm_span() + 0.4
	for i in int(3.0 / DT):
		drv.step(DT)
		worst = maxf(worst, absf(log(origin.world_scale) - log(prev)) / DT)
		prev = origin.world_scale
	rows["arm span +0.4 m"] = {"worst_ln_per_s": snappedf(worst, 0.001), "ws": snappedf(origin.world_scale, 0.0001)}
	lt(worst, 0.25 + 1e-3, "a recalibrated span mid-run ramps (worst %.3f ln/s)" % worst)
	drv.arm_span_override = -1.0
	# 3. Garbage.
	for v in ["abc", -3.0, 0.0, 99.0, NAN]:
		store.set_value("world_scale_exponent", v)
		for m in [NAN, INF, -1.0, 0.0, 1e-9, 1e6]:
			p.mass = m
			for i in 3:
				drv.step(DT)
			var ok := is_finite(origin.world_scale) and origin.world_scale > 0.0 and is_finite(cam.near) and cam.near >= 0.001 - 1e-9
			if not ok:
				rows["garbage exp %s mass %s" % [str(v), str(m)]] = {"ws": origin.world_scale, "near": cam.near}
			check(ok, "exponent %s, mass %s: finite scale (%s) and near plane >= 1 mm (%s)" % [str(v), str(m), str(origin.world_scale), str(cam.near)])
	print("[vr-verify] world scale ", rows)
	metric("world_scale", rows)
	(rig["player"] as Node).queue_free()
	origin.world_scale = 1.0
	await wait_frames(2)
