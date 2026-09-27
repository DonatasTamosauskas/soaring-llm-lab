extends Node
## VERIFIER PROBE (integration verify round 2, player-experience lens).
## How noisy are the HUD's in-world marks? The real main.tscn, a sparrow
## cruising the valley (protected, kit pilot), once a second for SECS: in
## the head camera's 90 deg view, how many birds wear the danger triangle
## (BirdModel.highlight 2) and the edible ring (1), and how many of the
## triangles belong to a bird that is actually after the player (hunting or
## stooping at it), plus the murmuration's members.
##
##   tools/gd.sh p2marks --headless --fixed-fps 72 res://tests/probes/integration/p2_marks.tscn -- --fresh-settings --tag=full [--quality=quest]

const Kit := preload("res://tests/unit/integration/game_kit.gd")

var kit: Kit
var main: GameMain
var tag := "full"
var secs := 150.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--tag="):
			tag = a.substr(6)
	_run.call_deferred()


func _run() -> void:
	kit = Kit.new()
	if not await kit.boot(self, true):
		get_tree().quit()
		return
	main = kit.main
	var m := main
	m.player.camera.fov = 90.0
	await kit.click(&"main", &"play")
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 5.0)
	m.ui.onboarding.skip()
	m.game_loop.set_protection(m.player, 1e6)
	kit.fly_bot(19)
	kit.set_mode(&"climb")
	await kit.advance(3.0)
	kit.set_mode(&"cruise")
	kit.pilot.set(&"agl", 25.0)
	await kit.advance(20.0)
	var rows := []
	var sums := {"danger": 0.0, "danger_after_player": 0.0, "edible": 0.0, "danger_murm": 0.0, "danger_flock": 0.0}
	var seconds_with_3plus_danger := 0
	var n := 0
	for i in int(secs):
		kit.bot.body.head_yaw = 0.0
		kit.bot.body.head_pitch = deg_to_rad(-5.0)
		await kit.advance(1.0)
		var cam := m.player.camera
		var vp := get_viewport().get_visible_rect()
		var d := 0
		var da := 0
		var e := 0
		var dm := 0
		var dfl := 0
		for b in m.ecosystem.get_npcs():
			if not is_instance_valid(b) or not b.alive or b.hidden or b.model == null:
				continue
			if cam.is_position_behind(b.global_position):
				continue
			var sp := cam.unproject_position(b.global_position)
			if not vp.has_point(sp):
				continue
			var hl := int(b.model.get(&"highlight"))
			if hl == 2:
				d += 1
				if (b.state == NpcBird.State.HUNT or b.state == NpcBird.State.STOOP) and b.target == m.player:
					da += 1
				if b.flock != null:
					dfl += 1
					if b.flock.kind == "murmuration":
						dm += 1
			elif hl == 1:
				e += 1
		sums["danger"] += d
		sums["danger_after_player"] += da
		sums["edible"] += e
		sums["danger_murm"] += dm
		sums["danger_flock"] += dfl
		if d >= 3:
			seconds_with_3plus_danger += 1
		n += 1
		rows.append([d, da, e, dm])
	for k in sums:
		sums[k] = snappedf(sums[k] / n, 0.01)
	sums["share_s_3plus_danger"] = snappedf(float(seconds_with_3plus_danger) / n, 0.01)
	sums["secs"] = n
	sums["npcs"] = m.ecosystem.count()
	sums["errors"] = kit.log.errors
	print("[integration] p2_marks %s %s" % [tag, sums])
	var f := FileAccess.open(Paths.artifacts("integration").path_join("verify/r2/p2_marks_%s.json" % tag), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"mean": sums, "rows": rows}, "  "))
		f.close()
	await kit.teardown()
	get_tree().quit()
