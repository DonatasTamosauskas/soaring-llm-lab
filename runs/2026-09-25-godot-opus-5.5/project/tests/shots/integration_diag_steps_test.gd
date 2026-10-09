extends TestCase
## DIAGNOSTIC (integration hygiene): which part of the game allocates the
## ~2 MB that stays at the first tier-up to a pigeon (and similar one-time
## steps later)? Grows the player tier by tier (GameLoop's own mass setter,
## the same events as a catch) and prints the static memory's floor after
## each, with parts of the game switched off by --off=<list>:
##   wings (VR first-person wings), hud (the HUD panel), eco (the NPC sky),
##   audio, fx, trails.
##
##   tools/gd.sh ih_steps --headless --fixed-fps 72 res://tests/runner.tscn -- --dir=res://tests/shots --suite=integration_diag_steps --fresh-settings [--off=wings,hud]

const Kit := preload("res://tests/unit/integration/game_kit.gd")
const Census := preload("res://tests/soak/soak_census.gd")

var kit: Kit


func before_all() -> void:
	kit = Kit.new()
	check(await kit.boot(self), "the game loaded")


func after_all() -> void:
	if kit:
		await kit.teardown()
	await wait_frames(5)


func _floor_mb(seconds: float) -> float:
	var lo := INF
	for i in int(seconds * 72.0):
		await kit.advance(1.0 / 72.0)
		lo = minf(lo, OS.get_static_memory_usage() / 1048576.0)
	return lo


func test_steps() -> void:
	var m := kit.main
	check(await kit.click(&"main", &"play"), "Play")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	m.ui.onboarding.skip()
	m.game_loop.set_protection(m.player, 1e6)
	kit.fly_bot(7)
	kit.set_mode(&"climb")
	await kit.advance(4.0)
	kit.set_mode(&"cruise")
	var off := Paths.arg("off", "").split(",", false)
	for part in off:
		match part:
			"wings":
				m.rig_extras.wings.queue_free()
			"hud":
				m.ui.hud_panel.queue_free()
			"eco":
				m.ecosystem.process_mode = Node.PROCESS_MODE_DISABLED
				for b in m.ecosystem.get_npcs():
					b.queue_free()
			"audio":
				m.audio.queue_free()
				m.ui_sounds.queue_free()
			"fx":
				m.fx.queue_free()
			"xrs":
				m.rig_extras.world_scale_driver.enabled = false
			"flight":
				m.player.auto_process = false
			"tierui", "tierall", "fitonly", "hudtier", "apexonly":
				# Whoever listens to growth and tier changes in the UI (or
				# anywhere, for tierall) stops hearing them.
				for sig in ["player_tier_changed", "player_grew"]:
					for conn in Events.get_signal_connection_list(sig):
						var o: Object = (conn["callable"] as Callable).get_object()
						if part in ["tierall", "fitonly"] or (o is Node and m.ui.is_ancestor_of(o as Node)) or o == m.ui:
							print("[integration] steps: %s disconnects %s from %s" % [part, o, sig])
							Events.disconnect(sig, conn["callable"])
		print("[integration] steps: switched off %s" % part)
	await kit.advance(2.0)
	var prev := await _floor_mb(2.0)
	var o_prev := kit.objects()
	var rows := []
	for sp in ["swallow", "starling", "pigeon", "crow", "gull", "hawk", "eagle", "sparrow", "pigeon", "eagle"]:
		var mass: float = SizeRules.species_data(StringName(sp))["mass"] * 1.02
		m.game_loop.set_protection(m.player, 1e6)
		if off.has("fitonly"):
			# Only the HUD's title fit (UIScreen.fit_size), no tier change.
			var t0 := OS.get_static_memory_usage()
			var sz := UIScreen.fit_size(UITheme.font(900), "Now %s!" % UIScreen.a_an(UIScreen.species_name(StringName(sp))),
				HUD.TOAST_TITLE_SIZE, UITheme.FS_BODY + 10, HUD.TOAST_TEXT_W)
			print("[integration] steps: fit_size(%s) = %d, %+.3f MB at once" % [sp, sz, (OS.get_static_memory_usage() - t0) / 1048576.0])
		elif off.has("hudtier") or off.has("apexonly"):
			# The tier change without the UI's reaction, then one part of it.
			var old_t := SizeRules.tier_for_mass(m.player.mass)
			m.game_loop._set_player_mass(m.player, mass, &"diag")
			await kit.advance(1.0)
			var t1 := OS.get_static_memory_usage()
			if off.has("hudtier"):
				m.ui.hud.show_tier_up(old_t, SizeRules.tier_for_mass(mass), mass)
			else:
				m.ui._refresh_apex()
			print("[integration] steps: %s(%s) %+.3f MB at once" % [off, sp, (OS.get_static_memory_usage() - t1) / 1048576.0])
		else:
			m.game_loop._set_player_mass(m.player, mass, &"diag")
		var now := await _floor_mb(4.0)
		var fc := Census.font_caches(UITheme._fonts.values() + [ThemeDB.fallback_font])
		print("[integration] steps: -> %-8s floor %.3f MB (%+.3f), objects %d (%+d), font pages %d glyphs %d, ws %.3f" % [
			sp, now, now - prev, kit.objects(), kit.objects() - o_prev, fc["pages"], fc["glyphs"], m.player.origin.world_scale])
		rows.append([sp, snappedf(now - prev, 0.001)])
		prev = now
		o_prev = kit.objects()
	print("[integration] steps (%s): %s" % [off, rows])
	check(true, "ran")
