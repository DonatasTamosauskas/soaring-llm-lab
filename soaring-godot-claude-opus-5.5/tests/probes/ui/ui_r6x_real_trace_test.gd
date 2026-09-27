extends TestCase
## VERIFIER PROBE (round 6, experience lens): a per-frame trace of where the
## HUD's notices are relative to the gaze and the REAL flight path, on the
## real game (scenes/main.tscn, the integration kit's bot flying the
## tutorial). Writes artifacts/ui/verify/r6/real_trace.csv.
##
##   GD_TIMEOUT=900 tools/gd.sh ui_verify --headless --fixed-fps 72 res://tests/runner.tscn -- \
##       --dir=res://tests/probes/ui --suite=ui_r6x_real_trace --fresh-settings

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var kit: Kit
var booted := false


func before_all() -> void:
	kit = Kit.new()
	booted = await kit.boot(self)


func after_all() -> void:
	if kit:
		await kit.teardown()
	await wait_frames(5)


func _rig_yaw_of(dir_world: Vector3) -> float:
	# Yaw of a world direction in the player's rig frame (deg, + = left, the
	# UIPanel convention).
	var rig := kit.main.player.origin
	var d := rig.global_basis.orthonormalized().inverse() * dir_world
	return rad_to_deg(atan2(-d.x, -d.z))


func _elev(dir: Vector3) -> float:
	return rad_to_deg(asin(clampf(dir.normalized().y, -1.0, 1.0)))


func _ecc(labels: Array[Label], gaze := Vector3.ZERO) -> float:
	var ui := kit.main.ui
	var cam := kit.main.player.camera
	var g := -cam.global_basis.z if gaze == Vector3.ZERO else gaze
	var worst := 0.0
	for lbl: Label in labels:
		if lbl == null or not lbl.is_visible_in_tree() or lbl.text == "":
			continue
		var f := lbl.get_theme_font(&"font")
		var w := f.get_string_size(lbl.text, HORIZONTAL_ALIGNMENT_LEFT, -1, lbl.get_theme_font_size(&"font_size")).x
		var r := lbl.get_global_rect()
		var x0 := r.position.x
		if lbl.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER:
			x0 = r.get_center().x - w * 0.5
		for x: float in [x0, x0 + w * 0.5, x0 + w]:
			var d := ui.hud_panel.pixel_to_world(Vector2(x, r.get_center().y)) - cam.global_position
			worst = maxf(worst, rad_to_deg(g.angle_to(d)))
	return worst


func test_trace_the_tutorial_in_the_real_game() -> void:
	if not check(booted, "booted"):
		return
	var m := kit.main
	var ui := m.ui
	ui.onboarding.reset()
	check(await kit.click(&"main", &"play"), "Play")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	var rows: Array[String] = ["t,lesson,mode,spd_h,vel_elev,flight_yaw,panel_yaw,vel_yaw,fwd_yaw,head_yaw,head_pitch,body_yaw,rig_yaw,ecc,ecc_level_path,opacity,notice_off,side,cam_local_y"]
	var clock := [0.0]
	var every := [0]
	var sampler := func() -> void:
		if Game.state != Game.State.PLAYING:
			return
		clock[0] += 1.0 / 72.0
		every[0] += 1
		if every[0] % 2 != 0:
			return
		var p := m.player
		var cam := p.camera
		var v := p.velocity
		var tel: Dictionary = p.telemetry()
		var fy := ui.flight_yaw()
		var gz := -cam.global_basis.z
		var vh := Vector3(v.x, 0.0, v.z)
		var lp := _ecc(ui.hud.lesson_labels(), vh.normalized()) if ui.hud.lesson_visible() and vh.length() > 0.3 else -1.0
		rows.append("%.3f,%s,%s,%.2f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.2f,%.1f,%d,%.2f" % [
			clock[0], ui.onboarding.current().get("id", ""), p.mode_name(),
			Vector2(v.x, v.z).length(), _elev(v) if v.length() > 0.1 else 0.0,
			rad_to_deg(fy) if is_finite(fy) else 999.0, rad_to_deg(ui.hud_panel.panel_yaw()),
			_rig_yaw_of(v) if Vector2(v.x, v.z).length() > 0.1 else 999.0,
			_rig_yaw_of(p.get_forward()),
			_rig_yaw_of(gz), _elev(gz),
			rad_to_deg(float(tel.get("body_yaw", 0.0))), rad_to_deg(float(tel.get("rig_yaw", 0.0))),
			_ecc(ui.hud.lesson_labels()) if ui.hud.lesson_visible() else -1.0, lp,
			ui.hud_panel.band_alpha(HUD.BAND_NOTICE), ui.hud_panel.band_offset(HUD.BAND_NOTICE).x, ui.hud.notice_side,
			cam.position.y])
	var _ls_sampler := LateSampler.new(sampler)
	add_child(_ls_sampler)
	kit.fly_bot()
	var ob := ui.onboarding
	var gesture := {&"spread": &"cruise", &"flap": &"flap", &"glide": &"glide", &"speed": &"speed",
		&"turn": &"turn", &"dive": &"dive", &"catch": &"cruise"}
	var t := 0.0
	while t < 100.0 and ob.active and ob.current().get("id") != &"catch":
		var id: StringName = ob.current().get("id", &"")
		var agl: float = kit.pilot.get(&"last_agl")
		var mode: StringName = gesture.get(id, &"cruise")
		if ob.celebrating > 0.0 or (mode in [&"glide", &"speed", &"dive"] and agl < 22.0):
			mode = &"climb"
		kit.set_mode(mode)
		await kit.advance(0.25)
		t += 0.25
	kit.set_mode(&"cruise")
	await kit.advance(15.0)
	_ls_sampler.queue_free()
	var path := Paths.artifacts("ui").path_join("verify/r6/real_trace.csv")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(rows) + "\n")
	print("[ui-verify] trace: %d rows -> %s" % [rows.size(), path])
	gt(float(rows.size()), 100.0, "traced")


class LateSampler:
	extends Node
	## Runs its callable at the END of every process frame (after the UI's
	## own _process has placed the panels for this frame, i.e. what is
	## rendered), unlike SceneTree.process_frame, which fires before every
	## node's _process (then the rig has moved this physics tick but the
	## panels have not, and a 7 m/s bird 0.2 m from its HUD reads 25+ deg off).
	var fn: Callable

	func _init(f: Callable) -> void:
		fn = f
		process_priority = 100000
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _process(_d: float) -> void:
		fn.call()
