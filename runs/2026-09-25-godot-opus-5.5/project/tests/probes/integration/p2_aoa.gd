extends Node
## VERIFIER PROBE (integration verify round 2, player-experience lens).
## Requirement 2 with an analog wrist (as in VR, not the desktop's all-or-
## nothing S key): from a trimmed glide, both wrists leading edge up by a
## fixed amount (the bot body's pitch command 0.2 / 0.4 / 0.6 / 0.85: flight's
## BotPoseSource turns it into the wrist twist the real WingInput reads), no
## flapping, held 8 s. Does the bird balloon, then bleed speed and settle
## slower (a new, slower steady glide) without stalling? And leading edge
## down (-0.3, -0.6): nose drops, speed builds. Sparrow and pigeon.
##
##   tools/gd.sh p2aoa --headless --fixed-fps 72 res://tests/probes/integration/p2_aoa.tscn -- --fresh-settings

const Kit := preload("res://tests/unit/integration/game_kit.gd")


class HoldPilot:
	extends FlightAutopilot
	var cmd_pitch := 0.0
	var tuck := false

	func update(_pos: Vector3, _vel: Vector3, _as: float, _dt: float) -> void:
		pitch = cmd_pitch
		roll = 0.0
		spread = 1.0
		effort = 0.0
		flapping = false
		grip = false


var kit: Kit
var main: GameMain
var out := {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_run.call_deferred()


func _run() -> void:
	kit = Kit.new()
	if not await kit.boot(self, true):
		get_tree().quit()
		return
	main = kit.main
	var m := main
	await kit.click(&"main", &"play")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 5.0)
	m.ui.onboarding.skip()
	m.game_loop.set_protection(m.player, 1e6)
	kit.fly_bot(4)
	var hp := HoldPilot.new(m.player.model.params, null)
	kit.bot.pilot = hp
	kit.pilot = null
	var A := Vector3(-300, m.world.ground_height(-300, -300) + 120.0, -300)
	for sz in [["sparrow", 0.03], ["pigeon", 0.3]]:
		m.game_loop._set_player_mass(m.player, sz[1], &"probe")
		hp.params = m.player.model.params
		await kit.advance(3.0)
		var res := {}
		for cmd in [0.0, 0.2, 0.4, 0.6, 0.85, -0.3, -0.6]:
			hp.cmd_pitch = 0.0
			m.player.start_flying(A, 0.0, 0.0)
			m.game_loop.teleported(m.player)
			await kit.advance(1.5)
			var y0 := m.player.global_position.y
			var v0 := float(m.player.telemetry()["airspeed"])
			hp.cmd_pitch = cmd
			var peak := -INF
			var t_peak := 0.0
			var stall_s := 0.0
			var rows := []
			for i in 8 * 72:
				await get_tree().physics_frame
				var tel: Dictionary = m.player.telemetry()
				var dy: float = m.player.global_position.y - y0
				if dy > peak:
					peak = dy
					t_peak = i / 72.0
				if tel["stalled"]:
					stall_s += 1.0 / 72.0
				if i % 36 == 0:
					rows.append([snappedf(i / 72.0, 0.1), snappedf(dy, 0.01), snappedf(float(tel["airspeed"]), 0.01), snappedf(float(tel["vertical_speed"]), 0.01),
						snappedf(rad_to_deg(float(tel["aoa"])), 0.1), tel["stalled"], snappedf(float(tel["pitch_input"]), 0.01)])
			var tel2: Dictionary = m.player.telemetry()
			res[str(cmd)] = {"v0": snappedf(v0, 0.01), "balloon_peak_m": snappedf(peak, 0.01), "t_peak": snappedf(t_peak, 0.01),
				"v_end": snappedf(float(tel2["airspeed"]), 0.01), "vs_end": snappedf(float(tel2["vertical_speed"]), 0.01),
				"stalled_s": snappedf(stall_s, 0.01), "rows": rows}
			print("[integration] p2_aoa %s pitch %.2f: v0 %.1f peak +%.2f m at %.1f s, end v %.1f vs %.2f, stalled %.1f s of 8" % [
				sz[0], cmd, v0, peak, t_peak, tel2["airspeed"], tel2["vertical_speed"], stall_s])
		out[sz[0]] = res
	out["errors"] = kit.log.errors
	var f := FileAccess.open(Paths.artifacts("integration").path_join("verify/r2/p2_aoa.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(out, "  "))
		f.close()
	await kit.teardown()
	get_tree().quit()
