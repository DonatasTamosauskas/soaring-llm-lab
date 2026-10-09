extends TestCase
## Verifier probe (round 3, engineering lens). Checks behaviours the ui suite
## does not pin (mutations of them survive the suite), and drives the UI
## against the REAL GameLoop (scripts/game/game_loop.gd) instead of the mock.
##   tools/gd.sh ui_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/ui --suite=ui_r3eng

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")

var k: Kit


func before_each() -> void:
	k = Kit.new()
	k.setup(self, true)
	await k.settle(self, 4)


func after_each() -> void:
	k.teardown()
	await wait_frames(3)


func _btn(screen: StringName, id: StringName) -> Button:
	return k.ui.get_screen(screen).get_button(id)


## Quit to menu from a pause taken while CAUGHT, with the real 0.8 s hold.
func test_hold_quit_to_menu_from_a_caught_pause() -> void:
	k.gl.start_run()
	await k.settle(self, 2)
	var hawk := UIMockPlayer.new()
	hawk.species = &"hawk"
	k.gl.fake_caught(hawk)
	await wait_seconds(0.3)
	Events.menu_requested.emit()
	await k.settle(self, 3)
	eq(Game.state, Game.State.PAUSED, "paused from CAUGHT")
	var quit := _btn(&"pause", &"quit_menu") as HoldButton
	await k.hold_control(self, quit)
	eq(k.gl.quits, 1, "hold on Quit to menu quits the run")
	eq(Game.state, Game.State.MENU, "MENU reached")
	check(not get_tree().paused, "tree unpaused at the main menu")
	eq(k.ui.current_screen_id(), &"main", "main menu shown")
	hawk.free()


## The HUD panel follows yaw lazily (claimed dead zone 24 deg), never head-locked.
func test_hud_panel_is_lazy_in_yaw() -> void:
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 4)
	var p := k.ui.hud_panel
	p.snap_to_head()
	await k.settle(self, 2)
	var pos0 := p.global_position
	k.set_head(Vector3(0, Kit.EYE, 0), 15.0)
	await wait_seconds(0.6)
	var moved := p.global_position.distance_to(pos0)
	metric("hud_move_after_15deg_glance_m", moved)
	lt(moved, 0.001, "a 15 deg glance leaves the HUD in place (%.4f m)" % moved)
	k.set_head(Vector3(0, Kit.EYE, 0), 70.0)
	await wait_frames(1)
	gt(absf(rad_to_deg(p.yaw_error())), 60.0, "one frame after a 70 deg turn the HUD has not jumped")
	p.peak_follow_speed = 0.0
	await wait_seconds(2.5)
	lt(absf(rad_to_deg(p.yaw_error())), 3.0, "then it recentres")
	lt(p.peak_follow_speed, 110.5, "at <= 110 deg/s (%.1f)" % p.peak_follow_speed)


## VR.recentered snaps an open panel straight in front at once.
func test_vr_recentered_snaps_the_menu() -> void:
	var p := k.ui.menu_panel
	p.snap_to_head()
	await k.settle(self, 2)
	k.set_head(Vector3(0, Kit.EYE, 0), 25.0)
	await wait_seconds(0.4)
	gt(absf(rad_to_deg(p.yaw_error())), 20.0, "inside the dead zone the panel stayed")
	VR.recentered.emit()
	await wait_frames(1)
	lt(absf(rad_to_deg(p.yaw_error())), 0.5, "VR.recentered re-places it in front at once (%.2f deg)" % rad_to_deg(p.yaw_error()))


## Menu button on the run summary goes to the main menu.
func test_menu_button_on_summary_goes_to_main_menu() -> void:
	k.gl.start_run()
	await k.settle(self, 2)
	k.gl.fake_end({"score": 10})
	await k.settle(self, 3)
	eq(k.ui.current_screen_id(), &"summary", "summary up")
	await wait_seconds(0.3)
	Events.menu_requested.emit()
	await k.settle(self, 3)
	eq(Game.state, Game.State.MENU, "menu button on the summary -> MENU")
	eq(k.ui.current_screen_id(), &"main", "main menu shown")


## Cue ring keeps its angle and apparent size at every world_scale.
func test_cues_keep_angle_and_size_across_world_scale() -> void:
	k.ui.onboarding.skip()
	k.gl.start_run()
	await k.settle(self, 3)
	var bird := Bird.new()
	bird.mass = 0.01
	add_child(bird)
	var ref := -1.0
	var rows := {}
	for ws: float in [1.0, 0.15, 1.3]:
		k.set_world_scale(ws)
		await k.settle(self, 2)
		var head := k.cam.global_transform
		bird.global_position = head.origin + head.basis * Vector3(-4.0 * ws, 0, 0)
		Events.target_changed.emit(null)
		await wait_frames(2)
		Events.target_changed.emit(bird)
		await wait_seconds(0.6)
		var cue := k.ui.indicators.cue_mesh(&"target")
		if not check(cue.visible, "cue drawn at ws=%.2f" % ws):
			continue
		var local := head.affine_inverse() * cue.global_position
		var ecc := rad_to_deg(acos(-local.z / local.length()))
		var size_deg := rad_to_deg(2.0 * atan(cue.global_transform.basis.x.length() * 0.5 / local.length()))
		rows[str(ws)] = [snappedf(ecc, 0.01), snappedf(size_deg, 0.001)]
		near(ecc, 24.0, 0.5, "cue 24 deg out at ws=%.2f" % ws)
		if ref < 0.0:
			ref = size_deg
		near(size_deg, ref, ref * 0.01, "cue apparent size constant at ws=%.2f (%.3f vs %.3f deg)" % [ws, size_deg, ref])
	metric("cue_by_scale", rows)
	Events.target_changed.emit(null)
	bird.queue_free()


## An untracked hand's trigger does not take the pointer over.
func test_untracked_hand_does_not_take_over() -> void:
	k.left.tracked = false
	k.aim_at_control(k.left, _btn(&"main", &"howto"))
	await k.click(self, k.left)
	eq(k.ui.pointer.active_index, 1, "pointer stays on the tracked right hand")
	eq(k.ui.current_screen_id(), &"main", "nothing clicked by a hand with no tracking")
	k.left.tracked = true


## The rendered curved mesh matches the analytic cylinder the pointer and the
## legibility maths use (vertices on it, chords within 0.5 mm).
func test_render_mesh_matches_the_analytic_surface() -> void:
	for panel: UIPanel in [k.ui.menu_panel, k.ui.hud_panel]:
		var worst_v := 0.0
		var worst_mid := 0.0
		for q: MeshInstance3D in panel._quads:
			var arr := q.mesh.surface_get_arrays(0)
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var uvs: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
			for i in verts.size():
				worst_v = maxf(worst_v, verts[i].distance_to(panel.local_point(uvs[i])))
			# Chord midpoints of the first triangle of each strip (a -> b along the top edge).
			for t in range(0, verts.size(), 6):
				var mid := (verts[t] + verts[t + 1]) * 0.5
				var muv := (uvs[t] + uvs[t + 1]) * 0.5
				worst_mid = maxf(worst_mid, mid.distance_to(panel.local_point(muv)))
		metric("%s_mesh_err_mm" % panel.name, [snappedf(worst_v * 1000.0, 0.001), snappedf(worst_mid * 1000.0, 0.001)])
		lt(worst_v, 1e-4, "%s vertices on the analytic surface (%.4f mm)" % [panel.name, worst_v * 1000.0])
		lt(worst_mid, 5e-4, "%s chords within 0.5 mm of the surface (%.3f mm)" % [panel.name, worst_mid * 1000.0])


# --- the real GameLoop -----------------------------------------------------------

func _real_loop() -> Node:
	k.gl.remove_from_group(&"game_loop")
	k.gl.queue_free()
	var gl := GameLoop.new()
	gl.records_path = "user://ui_r3eng_records_%d.cfg" % (Time.get_ticks_usec() % 1000000)
	gl.verbose = false
	add_child(gl)
	await k.settle(self, 2)
	k.ui._connect_game_loop()
	return gl


func test_ui_against_the_real_game_loop() -> void:
	var gl := await _real_loop() as GameLoop
	k.ui.onboarding.skip()
	# Play by pointer.
	await k.click_control(self, _btn(&"main", &"play"))
	eq(Game.state, Game.State.PLAYING, "Play -> PLAYING through the real GameLoop")
	eq(gl.phase, GameLoop.Phase.PLAYING, "GameLoop is running a run")
	check(k.ui.hud_panel.shown, "HUD shown")
	eq(k.ui.hud.tier_text(), "Sparrow", "strip reads the player's real mass")
	# Pause lines agree with GameLoop's own worthwhile list.
	await wait_seconds(0.3)
	Events.menu_requested.emit()
	await k.settle(self, 3)
	eq(Game.state, Game.State.PAUSED, "paused")
	var stats := gl.get_run_stats()
	var chain := PauseScreen.food_chain(k.player.mass)
	var ui_prey: Array = []
	for i: int in chain["prey"]:
		ui_prey.append(SizeRules.SPECIES[i]["id"])
	var gl_prey: Array = []
	for s: StringName in stats["worthwhile_species"]:
		if s != SizeRules.species_for_mass(k.player.mass):
			gl_prey.append(s)
	eq(str(ui_prey), str(gl_prey), "UI 'Hunt' species == GameLoop worthwhile_species")
	k.ui.resume()
	await k.settle(self, 2)
	eq(Game.state, Game.State.PLAYING, "resumed")
	# Become the eagle through GameLoop's own mass setter.
	gl._set_player_mass(k.player, 3.05, &"probe")
	await k.settle(self, 3)
	check(k.ui.hud.toast_active(), "eagle celebration")
	var lines := k.ui.hud.toast_lines()
	metric("eagle_toast", lines)
	check(lines.size() >= 2 and lines[1].contains("5"), "toast states the apex goal (%s)" % str(lines))
	eq(k.ui.hud.next_text(), "0 of 5 to win", "strip shows the apex goal from GameLoop's stats")
	# Real apex catches (hawks) through the catch commit path.
	for i in 4:
		var prey := Bird.new()
		prey.mass = 1.3
		prey.species = &"hawk"
		add_child(prey)
		prey.global_position = Vector3(500 + i * 10, 50, 500)
		gl._commit_catch(k.player, prey)
		await k.settle(self, 2)
		prey.queue_free()
	await k.settle(self, 2)
	eq(k.ui.hud.next_text(), "4 of 5 to win", "strip follows GameLoop's apex_progress")
	var last := Bird.new()
	last.mass = 1.3
	last.species = &"hawk"
	add_child(last)
	last.global_position = Vector3(600, 50, 500)
	gl._commit_catch(k.player, last)
	await k.settle(self, 4)
	last.queue_free()
	eq(Game.state, Game.State.ENDED, "fifth apex catch ends the run in victory")
	var ss := k.ui.get_screen(&"summary") as SummaryScreen
	eq(k.ui.current_screen_id(), &"summary", "summary shown")
	check(ss.victory_shown(), "summary presents a victory")
	check(_btn(&"summary", &"keep_flying").visible, "Keep flying offered")
	var t_before := Game.run_time
	await k.click_control(self, _btn(&"summary", &"keep_flying"))
	eq(Game.state, Game.State.PLAYING, "Keep flying -> PLAYING")
	check(bool(gl.endless), "GameLoop in its victory lap (endless)")
	gt(Game.run_time + 0.001, t_before, "run clock kept (%.2f -> %.2f)" % [t_before, Game.run_time])
	eq(k.ui.hud.next_text(), "You won!", "strip says the run is won")
	# Caught by a bigger bird through the real path, then the countdown.
	var giant := Bird.new()
	giant.mass = 6.0
	giant.species = &"eagle"
	add_child(giant)
	giant.global_position = Vector3(700, 50, 500)
	gl._commit_catch(giant, k.player)
	await k.settle(self, 3)
	eq(Game.state, Game.State.CAUGHT, "caught by the real GameLoop")
	eq(k.ui.current_screen_id(), &"caught", "caught screen")
	var cs := k.ui.get_screen(&"caught") as CaughtScreen
	metric("caught_countdown", cs.countdown_text())
	check(cs.countdown_text().begins_with("Back in the air in"), "countdown from GameLoop's respawn_in (%s)" % cs.countdown_text())
	var lives := cs.lives_shown()
	eq(lives.y, GameLoop.MAX_LIVES, "life pips = GameLoop.MAX_LIVES")
	eq(lives.x, int(gl.lives), "full pips = GameLoop.lives")
	giant.queue_free()
	# Restart from the pause by a real hold.
	await wait_seconds(0.3)
	Events.menu_requested.emit()
	await k.settle(self, 3)
	eq(Game.state, Game.State.PAUSED, "paused during the caught beat")
	await k.hold_control(self, _btn(&"pause", &"restart"))
	eq(Game.state, Game.State.PLAYING, "held Restart run -> PLAYING")
	eq(gl.phase, GameLoop.Phase.PLAYING, "GameLoop started a new run")
	near(k.player.mass, GameLoop.START_MASS, 1e-6, "new run at the start mass")
	eq(int(gl.lives), GameLoop.MAX_LIVES, "lives reset")
	eq(k.ui.hud.tier_text(), "Sparrow", "HUD back to Sparrow")
	# Quit to menu by a hold: GameLoop idle, MENU.
	await wait_seconds(0.3)
	Events.menu_requested.emit()
	await k.settle(self, 3)
	await k.hold_control(self, _btn(&"pause", &"quit_menu"))
	eq(Game.state, Game.State.MENU, "held Quit to menu -> MENU")
	eq(gl.phase, GameLoop.Phase.IDLE, "GameLoop abandoned the run")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(gl.records_path))
	gl.queue_free()
