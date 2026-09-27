extends TestCase
## Predation the player can see (integration round 2; the experience
## verifier's major finding: "the ecosystem is alive but off-screen" - in 12
## minutes of cruising the sky made 130 NPC-on-NPC catches and none within
## 60 m inside the player's view; a hunt was in view within 60 m 2-6 % of
## the time; stoops, soaring and dives into cover were almost never on
## screen).
##
## The real game (main.tscn), a protected sparrow flown by the bot through
## the real WingInput on the verifier's lap (~25 m over the valley, the head
## along the flight, 5 deg down, the Quest Pro's ~106 x 90 deg view), for
## PLAY_S of game time at each tier. Counted, from the player's eyes:
##  * readable hunts: an NPC hunting (or stooping on) another NPC, both
##    within READ_M of the eye and in view, for at least READ_S (each
##    hunter-prey pair once);
##  * NPC catches in view within READ_M;
##  * stoops, soaring and dives into cover begun in view within SEE_M.
## Pinned per tier: at least MIN_HUNTS readable hunts in PLAY_S, at least
## MIN_SHOW_HUNTS of them set up by the Ecosystem where the player looked,
## and the murmuration's visual mass (MurmurationSwarm, round 2 too) flying.
## Measured on three seeds (--hunt_seed 13, 21, 29) x two tiers: readable
## hunts 28 in the six flights with the show hunts (1-7 a flight), 17
## without (1-5; the sky's own) - the spread is large, and on this test's
## seed the sky alone makes 4 / 3, so the show's own count is pinned too
## (without the show it is 0). Recorded
## (not pinned: 0-3 per flight over the seeds tried, none at the Quest
## tier's 28 NPCs, whose sky has few raptors): stoops and dives into cover
## begun in view. The Ecosystem's show hunts (Ecosystem.SHOW_HUNT_S) set a
## hunt up where the player looks when none is there; without them
## (Ecosystem.show_hunts off) the same flights see what the verifier saw.

const Kit := preload("res://tests/unit/integration/game_kit.gd")
const PLAY_S := 300.0
const SETTLE_S := 20.0
const READ_M := 40.0
const READ_S := 1.0
const SEE_M := 60.0
const HALF_H_DEG := 53.0
const HALF_V_DEG := 45.0
const MIN_HUNTS := 3
const MIN_SHOW_HUNTS := 3
const DT := 1.0 / 12.0

var kit: Kit
var booted := false


func before_all() -> void:
	kit = Kit.new()
	booted = await kit.boot(self)


func after_all() -> void:
	if kit:
		await kit.teardown()
	await wait_frames(5)


## In the head view along the flight (5 deg down), within max_m of the eye.
func _in_view(p: Vector3, max_m: float) -> bool:
	var m := kit.main
	var eye := m.player.camera.global_position
	var rel := p - eye
	if rel.length() > max_m:
		return false
	var v := m.player.velocity
	var fdir := Vector3(v.x, 0.0, v.z)
	if fdir.length() < 0.5:
		fdir = -m.player.global_basis.z
	fdir = Vector3(fdir.x, 0.0, fdir.z).normalized()
	var inv := (Basis.looking_at(fdir, Vector3.UP) * Basis(Vector3.RIGHT, deg_to_rad(-5.0))).inverse()
	var loc := inv * rel
	return loc.z < -0.1 and absf(loc.x / -loc.z) <= tan(deg_to_rad(HALF_H_DEG)) and absf(loc.y / -loc.z) <= tan(deg_to_rad(HALF_V_DEG))


func _fly(tier: StringName) -> Dictionary:
	var m := kit.main
	var q := QualityTier.new()
	if tier == &"quest":
		q.set_quest()
	q.apply_ecosystem(m.ecosystem)
	if Game.state != Game.State.PLAYING:
		m.ui.bridge.start_run()
		await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	m.game_loop.restart_run()
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	if m.ui.onboarding.has_method(&"skip"):
		m.ui.onboarding.skip()
	m.game_loop.set_protection(m.player, 1e6)
	kit.fly_bot(int(Paths.arg("hunt_seed", "13")))
	kit.set_mode(&"climb")
	await kit.advance(3.0)
	kit.set_mode(&"cruise")
	kit.pilot.set(&"agl", 25.0)
	kit.orbit_radius = 120.0
	kit.cruise()
	await kit.advance(SETTLE_S)
	var eco0: Dictionary = m.ecosystem.stats()
	var seen_catches := [0]
	var seen_catches_60 := [0]
	var all_catches := [0]
	var on_caught := func(pred: Bird, prey: Bird) -> void:
		if pred == m.player or prey == m.player:
			return
		all_catches[0] += 1
		if _in_view(prey.global_position, READ_M):
			seen_catches[0] += 1
		if _in_view(prey.global_position, SEE_M):
			seen_catches_60[0] += 1
	Events.bird_caught.connect(on_caught)
	# hunter id -> {prey id -> seconds readable}
	var readable_s := {}
	var readable := {}
	var entered := {"stoop": 0, "hide": 0, "soar": 0, "flee": 0}
	var last_state := {}
	var t := 0.0
	var hunt_view_s := 0.0
	var swarm_max := 0
	while t < PLAY_S:
		await kit.advance(DT)
		t += DT
		if m.ecosystem.swarm != null:
			swarm_max = maxi(swarm_max, m.ecosystem.swarm.shown())
		var any_hunt := false
		for b in m.ecosystem.get_npcs():
			if not is_instance_valid(b) or not b.alive:
				continue
			var id := b.get_instance_id()
			var st: int = b.state
			if int(last_state.get(id, st)) != st and _in_view(b.global_position, SEE_M):
				match st:
					NpcBird.State.STOOP:
						entered["stoop"] += 1
					NpcBird.State.HIDE:
						entered["hide"] += 1
					NpcBird.State.SOAR:
						entered["soar"] += 1
					NpcBird.State.FLEE:
						entered["flee"] += 1
			last_state[id] = st
			if (st == NpcBird.State.HUNT or st == NpcBird.State.STOOP) and b.target != null and is_instance_valid(b.target) \
					and not b.target.is_player() and _in_view(b.global_position, READ_M) and _in_view(b.target.global_position, READ_M):
				any_hunt = true
				var key := "%d:%d" % [id, b.target.get_instance_id()]
				readable_s[key] = float(readable_s.get(key, 0.0)) + DT
				if float(readable_s[key]) >= READ_S and not readable.has(key):
					readable[key] = "%s->%s" % [b.species, b.target.species]
		if any_hunt:
			hunt_view_s += DT
	Events.bird_caught.disconnect(on_caught)
	var eco: Dictionary = m.ecosystem.stats()
	var res := {"readable_hunts": readable.size(), "pairs": readable.values(), "npc_catches": all_catches[0],
		"npc_catches_seen": seen_catches[0], "npc_catches_seen_60m": seen_catches_60[0], "hunt_in_view_share": snappedf(hunt_view_s / PLAY_S, 0.001), "entered_in_view": entered,
		"show_hunts": int(eco.get("show_hunts", 0)) - int(eco0.get("show_hunts", 0)),
		"show_hunt_catches": int(eco.get("show_hunt_catches", 0)) - int(eco0.get("show_hunt_catches", 0)), "npcs": m.ecosystem.count(),
		"show_hunt_misses": eco.get("show_hunt_misses", {}), "swarm_max": swarm_max, "budget": m.ecosystem.max_npcs}
	print("[integration] sky hunts %s: %s" % [tier, res])
	return res


func test_the_player_sees_birds_hunt_birds() -> void:
	if not check(booted, "the game loaded"):
		return
	var out := {}
	for tier: StringName in [&"quest", &"full"]:
		var r := await _fly(tier)
		out[tier] = r
		# The murmuration's visual mass (MurmurationSwarm) flies with it.
		eq(int(r["swarm_max"]), MurmurationSwarm.size_for_budget(int(r["budget"])), "%s tier: the murmuration's visual mass (%d starlings) flew" % [
			tier, int(r["swarm_max"])])
		# The mechanism, not only the outcome: the Ecosystem sets hunts up where
		# the player looks (without them the same flights still see 1-5
		# readable hunts - the sky's own - on the seeds tried, 1-7 with them).
		gt(float(r["show_hunts"]), MIN_SHOW_HUNTS - 0.5, "%s tier: %d show hunts set up where the player looked" % [tier, r["show_hunts"]])
		gt(float(r["readable_hunts"]), MIN_HUNTS - 0.5, "%s tier: %d hunts readable within %.0f m in view in %.0f s (%s; the verifier: none within 60 m)" % [
			tier, r["readable_hunts"], READ_M, PLAY_S, r["pairs"]])
	metric("sky_hunts", out)
	QualityTier.new().apply_ecosystem(kit.main.ecosystem)
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())
