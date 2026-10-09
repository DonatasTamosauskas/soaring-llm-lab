class_name Ecosystem
extends Node3D
## Keeps the sky alive around the player (scenes/ai/ecosystem.tscn, group
## "ecosystem").
##
## Population plan (re-made as the player grows), for max_npcs = 60:
##  * prey the player can eat and that is worth it, weighted towards the
##    larger edible species (the player's interest moves up the ladder);
##  * a few "dust" birds too small to be worth eating (ambient life);
##  * near-equals (neither can eat the other);
##  * threats: species that would actually hunt the player - they can eat it,
##    it is worth their while (SizeRules.is_worthwhile, the rule their brains
##    hunt by) and they hunt at all - weighted to keen hunters and the next
##    rungs up, flying solo (a flocked bird rarely breaks off to hunt); when
##    the ladder offers too few, oversized "apex" eagles;
##  * "giants": birds that could eat the player but would not bother (a
##    hawk does not chase a sparrow) - life and scale, not danger: big birds
##    are what a small player sees from afar;
##  * an ambient starling murmuration.
## Species caps keep it believable (a handful of eagles, not twenty).
## Without a player the plan is an ecological pyramid centred on the map.
##
## Life follows the player. Every bird wanders round a home placed about a
## focus point: for a player going somewhere (travelling: covering ground
## without circling, judged over its last TRACK_S) its position led by its
## velocity, so it flies into birds; for one circling an area (laps, a
## thermal, a dogfight) the middle of that area, the population spread over
## it (a point swinging round a lap would have the birds chasing it and
## never where the player is). Home ranges scale with the player's sky -
## how far it notices and chases birds (sky_radius()) - so a sparrow-sized
## player is not surrounded by birds 120 m off. The player's prey leans
## towards the player itself; the threats patrol the player.
## Spawning happens only outside the player's view cone and beyond the
## bird's near distance (spawn_distance(): 150 of its wingspans - under 0.4
## deg, a few pixels in the headset - at least 40 m, at most spawn_min),
## every member of a spawned flock is checked, and while the player travels
## never behind it; of the valid candidates the one nearest the focus.
## Removal only out of view: surplus after a re-plan; birds left far behind
## a travelling player (never within recycle_grace_s of their spawn, never
## mid-chase, mid-flight or hiding, never part of a flock still in sight);
## birds that stayed beyond despawn_radius; and - the one promise kept to
## the player - the farthest idle prey when none worth catching is near
## (_keep_prey_near). A player circling one area keeps the same birds (a
## population turnover of ~0.1-0.2 a minute, catches included).

## Level of detail: birds far from the player think, steer and feel less often
## and integrate every 2nd/3rd tick; anything chasing or being chased runs at
## full rate. Everything random comes from one seeded RNG, iteration order is
## fixed, so a seed reproduces a run exactly (reset(seed)).

signal npc_spawned(npc: NpcBird)
signal npc_despawned(npc: NpcBird, reason: StringName)

@export var max_npcs := 60
@export var rng_seed := 1
## Step from _physics_process. Tests turn it off and call step() themselves.
@export var auto_step := true
## Near distance for the biggest birds (see spawn_distance()).
@export var spawn_min := 70.0
@export var spawn_max := 180.0
@export var despawn_radius := 380.0
## Spawns must be at least this far (deg) off the player's view direction.
@export var view_half_angle_deg := 75.0
@export var tolerance := 4
@export var lod_near := 80.0
@export var lod_far := 200.0
## Home range of a bird in the population round a big player (see
## sky_radius(): smaller players get a smaller, denser sky).
@export var home_radius := 110.0
@export var rebalance_interval := 0.5
@export var max_spawns_per_rebalance := 4
## Seconds of the player's smoothed velocity the focus point leads it by.
@export var focus_lead_s := 6.0
## Birds this far behind a travelling player are recycled (out of view) and
## respawned where it is going...
@export var recycle_behind := 200.0
## ...and birds too slow to ever catch it up (cruise below its travel
## speed) already from this far behind.
@export var recycle_behind_slow := 110.0
## The player "travels" (goes somewhere, rather than circling one area)
## when over the last TRACK_S seconds it covered ground faster than this
## (net displacement / time, m/s) without turning more than TRAVEL_MAX_TURN.
## Only then are birds left behind recycled and spawns kept off the space
## behind it, and does life gather ahead of it rather than round its area.
@export var travel_drift := 4.5
## A bird is not recycled as "left behind" in its first seconds: a spawn
## must get the chance to fly into the player's sky before it is judged.
@export var recycle_grace_s := 12.0

## Prey the player can eat but that is not worth it (SizeRules.is_worthwhile,
## the game loop's rule) is "dust" to the plan: a few for life, no more.
## Believable maxima per species. The big ones are generous because they
## are all the worthwhile prey an eagle-sized player has left.
const SPECIES_CAP := {
	&"moth": 10, &"wren": 10, &"sparrow": 16, &"swallow": 12, &"starling": 24,
	&"pigeon": 14, &"crow": 12, &"gull": 14, &"hawk": 8, &"eagle": 4,
}
const PYRAMID := {
	&"moth": 6, &"wren": 5, &"sparrow": 10, &"swallow": 6, &"starling": 14,
	&"pigeon": 6, &"crow": 4, &"gull": 4, &"hawk": 3, &"eagle": 2,
}
const APEX_KEY := &"eagle:apex"
const MURM_KEY := &"starling:murm"
## Plan keys of threats (solo hunters that would hunt the player) end in this.
const HUNTER := ":hunter"
## Planned counts for max_npcs = 60 (scaled for other budgets).
const N_MURMURATION := 12
## A murmuration is at least this many starlings, whatever the budget (a
## third of it at most).
const N_MURMURATION_MIN := 8
const N_THREATS := 9
const MIN_THREATS := 6
## Giants (could eat the player, would not bother) matter at the small end:
## big birds are what a sparrow-sized player sees from afar - its sky is a
## big one - and what makes the world feel big (a small player in a sky of
## pigeons, crows and gulls). Few species qualify for bigger players.
const N_GIANTS := 8
const N_PEERS := 8
const N_DUST := 4
## Threats patrol within this fraction of sky_radius() of the player: close
## enough that a hungry one meets it every minute or two.
const THREAT_RANGE := 0.45
## The player's prey stays within PREY_RANGE x sky_radius() of homes spread
## over PREY_SPREAD x the usual offsets round the focus point.
const PREY_RANGE := 0.6
const PREY_SPREAD := 0.5
## How far the prey's homes lean from the middle of the circled area
## towards the player (see _place_home).
const PREY_PULL := 0.5
## Species hunt drive (SpeciesProfile "hunt") a threat needs.
const THREAT_MIN_DRIVE := 0.45
## Near distance for spawning, in the bird's own wingspans (see
## spawn_distance()), and its floor in metres.
const SPAWN_SPANS := 150.0
## The player's track is judged over this window (s), sampled every
## TRACK_DT. Circling of any kind - laps, thermalling, a dogfight - turns
## the heading through more than TRAVEL_MAX_TURN in it; a crossing does
## not. (Speed alone cannot tell them apart: over seconds a 180-m lap is as
## straight as a crossing. Judged by the 3-s velocity, every flying player
## "travelled", and birds spawned beside a lapping player were recycled
## seconds later as "left behind", round and round: a full turnover of the
## population every 15-30 s.)
const TRACK_S := 12.0
const TRACK_DT := 0.5
const TRAVEL_MAX_TURN := 1.05
## Seconds to blend the focus between "round its area" and "ahead of it".
const TRAVEL_BLEND_S := 4.0
## Seconds of the player's positions that make "the area it circles".
const AREA_S := 60.0
## Spawns while travelling stay off the space behind the player: no more
## than this cosine behind the drift direction (~104 deg). Beside it and
## ahead of abeam, out of the view cone.
const SPAWN_BEHIND_COS := -0.25
## A player position change larger than this in one step is a respawn, not
## flight (m).
const JUMP_M := 40.0
## Seconds a bird may stay beyond despawn_radius (heading home after a chase
## that carried it out) before it is recycled.
const FAR_GRACE_S := 20.0
## See _keep_prey_near().
const PREY_NEAR_N := 2
const PREY_NEAR_M := 120.0
## ...and at least one of them within this: prey close enough to see and
## go for, not only specks at the edge of the player's sky. Only prey that
## have lived PREY_CLOSE_GRACE_S are recycled for it (a lapping player keeps
## the birds it has; this only replaces long-lived far ones).
const PREY_CLOSE_M := 75.0
const PREY_CLOSE_GRACE_S := 60.0
const PREY_FAR_M := 170.0
const PREY_NEAR_S := 2.0
## Largest flock outside the murmuration.
const LOOSE_FLOCK_MAX := 6
const SPAWN_MIN_SMALL := 40.0
## NpcBird.player_interest / player_range of the threats placed around the
## player (it is why they are there): they rate it 1.25x and keep an eye on
## it from at least THREAT_WATCH_M (a swallow's or a crow's own hunting
## range is short; a hawk's already longer). Every other NPC treats it as
## just another bird.
const THREAT_INTEREST := 1.25
const THREAT_WATCH_M := 60.0
## The player's sky (see sky_radius()): this many times the distance it
## notices and chases birds at, never under SKY_MIN (m).
const SKY_PER_REACH := 1.25
const SKY_MIN := 60.0
## Spawns come no further than this many sky radii from the player.
const SPAWN_MAX_SKIES := 1.8
## The show (integration round 1, the experience verifier's "empty sky"):
## birds spread round the area a player circles, or over its sky, sit
## mostly beside and behind a flying player - it flies on past them - and
## straight ahead it saw on average 0.15 birds (0.05 big enough to see). So
## a few birds that are only life and scale (never the player's prey or its
## threats: the loop's pacing rests on those) are homed on a point ahead of
## the player's flight, SHOW_AHEAD x its sky (SHOW_MIN_M..SHOW_MAX_M) out:
## loose flocks wheeling there, big birds soaring there. The point stays
## put while it is within SHOW_CONE_DEG of the flight direction and between
## half and twice that distance; otherwise, at most every SHOW_HOLD_S, it
## moves ahead again - and the show crosses the view to follow it.
const SHOW_AHEAD := 0.65
const SHOW_MIN_M := 36.0
const SHOW_MAX_M := 110.0
const SHOW_CONE_DEG := 45.0
const SHOW_HOLD_S := 2.0
## The point is where the player's flight leads (a lap's curve included),
## at most this far round a turn (rad): a player circling tightly flies
## towards it instead of past it.
const SHOW_MAX_ARC := 1.4
## Home range round the show point, as a fraction of its distance ahead.
const SHOW_RANGE := 0.35
## Loose flocks and solo birds in the show at max_npcs = 60 (scaled down
## with the budget, at least one of each).
const SHOW_FLOCKS := 2
const SHOW_SOLOS := 5
const SHOW_SOLOS_MIN := 5
## The solos (big birds, seen from far) range further out than the flocks.
const SHOW_SOLO_AHEAD := 1.5
## A show bird this many times the show's distance from its point has
## wandered off (a thermal, a chase) and is replaced.
const SHOW_LOST := 3.0
## A member of the show keeps its place against a newcomer up to this much
## better placed (its key is scaled by it).
const SHOW_KEEP := 0.6

## A bird in the show cruises at least this fraction of the player's cruise
## speed (a sparrow flock cannot stay ahead of a sparrow-sized player
## flying on; pigeons, crows and gulls can).
const SHOW_KEEP_UP := 0.95
## Roles that may be in the show.
const SHOW_ROLES: Array[StringName] = [&"ambient", &"giant", &"peer", &"dust", &"extra"]
## Show hunts (integration round 2, the experience verifier: in 12 minutes
## of cruising the sky made 130 NPC-on-NPC catches and none within 60 m in
## the player's view - median 90-104 m away, mostly wrens taking moths; a
## hunt was in view within 60 m 2-6 % of the time). The brief's sky has
## hawks stooping and small birds diving for cover as a predator passes -
## where the player looks. So every SHOW_HUNT_S without a hunt in view the
## Ecosystem sets one up there: a bird of a show role (never the player's
## prey or threats: the loop's pacing rests on those) the player sees
## SHOW_HUNT_MIN_M..SHOW_HUNT_MAX_M out within SHOW_HUNT_VIEW_DEG of its
## gaze, and a hunter within SHOW_HUNTER_M of it that would hunt it anyway
## (would_hunt: a real hunter, a worthwhile meal) - never one of the
## player's threats and never one that would hunt the player itself, so a
## show hunt adds no danger - nearest first. The chase is then the hunter's
## own (NpcBrain.begin_hunt): pursuit, stoop, passes and give-up rules, and
## the prey's flight, jinks and dive into cover.
const SHOW_HUNT_S := 12.0
const SHOW_HUNT_MIN_M := 12.0
const SHOW_HUNT_MAX_M := 55.0
const SHOW_HUNT_VIEW_DEG := 40.0
const SHOW_HUNTER_M := 90.0
## With no pair to set up, look again this soon (s).
const SHOW_HUNT_RETRY_S := 2.0
## A stooping hunter with height on the prey counts this much nearer (m).
const SHOW_HUNT_STOOP_BONUS_M := 40.0

var world: World = null
var habitat: Habitat = null
## Bird the population centres on; defaults to Birds.player().
var focus: Bird = null

var _npcs: Array[NpcBird] = []
var _flocks: Array[FlockGroup] = []
var _rng := RandomNumberGenerator.new()
var _t := 0.0
var _rebalance_t := 0.0
var _lod_t := 0.0
var _home_t := 0.0
var _thermal_t := 0.0
## Where life is centred: the player's position plus focus_lead_s of its
## smoothed horizontal velocity (INF until there is a player).
var _focus_pt := Vector3.INF
var _vel_avg := Vector3.ZERO
## The player's horizontal position at the last step (to tell a respawn -
## a jump of more than JUMP_M in one step - from flight).
var _last_ph := Vector3.INF
## The player's net horizontal velocity over its recent track (see
## travel_drift) and whether it travels.
var _drift := Vector3.ZERO
var _travelling := false
## [time, x, z, unwrapped heading] every TRACK_DT, TRACK_S long.
var _track: Array = []
var _track_t := 0.0
## Blend of the focus: 0 (circling: the middle of its area) .. 1 (travelling:
## led by its velocity).
var _travel_k := 0.0
## The player's recent positions (one a second, AREA_S), their mean and RMS
## spread (see _update_area).
var _area: Array[Vector3] = []
var _area_t := 0.0
var _area_c := Vector3.ZERO
var _area_r := 0.0
## Instance id -> _t when the bird was spawned (for recycle_grace_s).
var _born := {}
## Instance id -> seconds it has been beyond despawn_radius (FAR_GRACE_S).
var _far_t := {}
var _rebalance_last := 0.0
var _prey_pull_t := -999.0
var _populated := false
## key -> {count, role, species, mass, pm}
var _plan := {}
var _plan_mass := -999.0
var _plan_t := -999.0
var _next_id := 1
var _stats := {}
var _tick_us: Array[int] = []
var _tick_i := 0
## Accumulated microseconds in [population upkeep, flocks, birds] and ticks.
var _part_us := [0, 0, 0]
var _part_n := 0
var _npc_key := {}
var _npc_offset := {}
## sky_radius() as of the last home update.
var _sky := 110.0
## The show (see SHOW_AHEAD): its point (INF: none yet), when it last moved,
## and its birds.
var _show_pt := Vector3.INF
var _show_moved_t := -999.0
var _show_flocks: Array[FlockGroup] = []
var _show_solos: Array[NpcBird] = []
## The player's smoothed turn rate (rad/s, + = left) for the show's point.
var _show_turn := 0.0
var _show_last_h := INF
var _show_last_t := 0.0
## Show hunts (see SHOW_HUNT_S): on or off, the hunter of the one under way,
## and seconds since the last one ended.
@export var show_hunts := true
var _show_hunter: NpcBird = null
var _show_hunt_t := 0.0
## The hunter keeping company with the show's first flock (or null).
var _show_stalker: NpcBird = null
## The murmuration's visual-only mass (MurmurationSwarm; integration round 2).
@export var murmuration_swarm := true
var swarm: MurmurationSwarm = null
## The sky's pellets (core loop round): moth swarms in open air along the
## player's path, outside the NPC budget (MothField).
@export var moth_swarms := true
var moths: MothField = null
## The danger director's attack (send_attacker): a hunter of the player is
## sent from ATTACK_MIN_M at least, preferably from about ATTACK_BEST_M
## (seconds of warning: ThreatWatch.warn_level), and never from further
## than its own hunting range allows.
const ATTACK_MIN_M := 22.0
const ATTACK_BEST_M := 50.0


func _ready() -> void:
	add_to_group(&"ecosystem")
	_rng.seed = rng_seed
	_reset_stats()
	# Diagnostics (cost comparisons): --no_show_hunts, --no_swarm.
	if Paths.arg("no_show_hunts") != "":
		show_hunts = false
	if Paths.arg("no_swarm") != "":
		murmuration_swarm = false
	if Paths.arg("no_moths") != "":
		moth_swarms = false
	if moth_swarms:
		moths = MothField.new(rng_seed)
		moths.eco = self
		add_child(moths)
	# Tuning sweeps of the attack on the player (NpcBrain.HUNT_PLAYER_*).
	if Paths.arg("hunt_commit") != "":
		NpcBrain.hunt_player_commit_s = float(Paths.arg("hunt_commit"))
	if Paths.arg("hunt_turn") != "":
		NpcBrain.hunt_player_turn = float(Paths.arg("hunt_turn"))
	if Paths.arg("hunt_reaim") != "":
		NpcBrain.hunt_player_reaim = float(Paths.arg("hunt_reaim"))


func _physics_process(delta: float) -> void:
	if auto_step:
		step(delta)


## Remove every NPC and start again (a new run). seed < 0 keeps rng_seed.
func reset(seed_value: int = -1) -> void:
	if seed_value >= 0:
		rng_seed = seed_value
	for npc in _npcs.duplicate():
		_remove(npc, &"reset")
	_npcs.clear()
	_flocks.clear()
	_npc_key.clear()
	_npc_offset.clear()
	_born.clear()
	_far_t.clear()
	_rebalance_last = 0.0
	_prey_pull_t = -999.0
	_rng.seed = rng_seed
	_t = 0.0
	_rebalance_t = 0.0
	_lod_t = 0.0
	_home_t = 0.0
	_plan = {}
	_plan_mass = -999.0
	_plan_t = -999.0
	_focus_pt = Vector3.INF
	_vel_avg = Vector3.ZERO
	_last_ph = Vector3.INF
	_drift = Vector3.ZERO
	_travelling = false
	_track.clear()
	_track_t = 0.0
	_travel_k = 0.0
	_area.clear()
	_area_t = 0.0
	_area_c = Vector3.ZERO
	_area_r = 0.0
	_show_pt = Vector3.INF
	_show_moved_t = -999.0
	_show_flocks.clear()
	_show_solos.clear()
	_show_turn = 0.0
	_show_last_h = INF
	_show_last_t = 0.0
	_show_hunter = null
	_show_hunt_t = 0.0
	_show_stalker = null
	_populated = false
	_next_id = 1
	if habitat:
		habitat.refresh()
	if moths != null:
		moths.reset(rng_seed)
	_reset_stats()


func get_npcs() -> Array[NpcBird]:
	return _npcs


func get_flocks() -> Array[FlockGroup]:
	return _flocks


func count() -> int:
	return _npcs.size()


## The point life is centred on (the player led by its velocity), or the
## player's position before the first step. Vector3.INF without a player.
func focus_point() -> Vector3:
	if _focus_pt != Vector3.INF:
		return _focus_pt
	var fb := _focus()
	return fb.get_body_position() if fb else Vector3.INF


## The catch lesson's prey (GameLoop.request_lesson_prey, for the UI's
## onboarding): a slow, unaware moth swarm in open air ahead of `near` along
## `dir` (the player's flight), nearer by `help` steps (MothField), kept
## ahead of the player until stop_lesson_prey(). Returns its moths ([] if
## there is no place for it).
func request_lesson_prey(near: Vector3, dir: Vector3 = Vector3.ZERO, help: int = 0) -> Array:
	if moths == null:
		return []
	return moths.request_lesson(_focus(), near, dir, help)


func stop_lesson_prey() -> void:
	if moths != null:
		moths.stop_lesson()


## The game loop's danger director asks for an attack on the player now
## (GameLoop._direct_danger). Of the birds that would hunt it (it can eat
## the player and thinks it worth a chase: would_hunt), that can hunt now
## (not digesting or resting, not fleeing, hiding or already hunting) and
## are between ATTACK_MIN_M and their hunting range from it, the one nearest
## ATTACK_BEST_M is sent (NpcBrain.begin_hunt: its own pursuit, stoop,
## committed pass and give-up rules). With none in range, the farthest such
## bird out of view is recycled and one of the plan's hunters brought in
## out of view at its near distance (a sparse sky - the Quest tier's 28
## NPCs - has few raptors near the player). Core loop round: the hunter
## brought in is one of the plan's hunters that would hunt the player (not
## an eagle for a swallow), and with the sky full and no far hunter to swap
## the farthest idle bird out of view makes room (the rebalance's rule) -
## real-chain runs waited a minute and more after the first flight for a
## director that found nobody to send. Returns the attacker, or null.
func send_attacker(p: Bird) -> NpcBird:
	if p == null or not p.alive or not p.is_inside_tree():
		return null
	var pp := p.get_body_position()
	var best: NpcBird = null
	var best_s := INF
	var far: NpcBird = null
	var far_d := -1.0
	for npc in _npcs:
		if not _can_attack(npc, p):
			continue
		var d := npc.global_position.distance_to(pp)
		var reach := float(npc.profile["hunt_range_m"]) * maxf(npc.player_range, 1.0)
		if d >= ATTACK_MIN_M and d <= reach:
			var s := absf(d - ATTACK_BEST_M)
			if s < best_s:
				best_s = s
				best = npc
		elif d > far_d and not in_view(npc.global_position, p):
			far_d = d
			far = npc
	if best == null:
		best = _bring_attacker(p, far)
	if best == null:
		return null
	if not best.brain.begin_hunt(p):
		_attack_failed(&"refused")
		return null
	_stats["attacks_sent"] = int(_stats.get("attacks_sent", 0)) + 1
	return best


## Why a call for an attacker came back empty (stats()["attack_fails"], by
## reason; last_attack_fail for the loop's log).
var last_attack_fail: StringName = &""


func _attack_failed(why: StringName) -> void:
	last_attack_fail = why
	var f: Dictionary = _stats.get("attack_fails", {})
	f[String(why)] = int(f.get(String(why), 0)) + 1
	_stats["attack_fails"] = f


## The farthest idle bird out of the player's view (not a threat, not the
## murmuration or a flock, not engaged, hidden or landing, past its spawn
## grace): room for a bird the sky needs now (the rebalance's rule).
func _idle_far_unseen(fb: Bird) -> NpcBird:
	var far: NpcBird = null
	var fd := -1.0
	var c3 := _eye(fb)
	for npc in _npcs:
		var k2: StringName = _npc_key.get(npc.get_instance_id(), npc.species)
		if _is_threat_key(k2) or k2 == MURM_KEY or npc.flock != null or npc.is_engaged() \
				or npc.hidden or npc.is_flaring() \
				or _t - float(_born.get(npc.get_instance_id(), _t)) < recycle_grace_s:
			continue
		var d2 := npc.global_position.distance_squared_to(c3)
		if d2 > fd and not in_view(npc.global_position, fb):
			fd = d2
			far = npc
	return far


## Whether npc could be sent at the player now (see send_attacker).
func _can_attack(npc: NpcBird, p: Bird) -> bool:
	if not npc.alive or npc.hidden or npc.threat != null or npc.is_flaring():
		return false
	var st := npc.state
	if st == NpcBird.State.FLEE or st == NpcBird.State.HIDE or st == NpcBird.State.HUNT or st == NpcBird.State.STOOP:
		return false
	if not (SizeRules.can_eat(npc.mass, p.mass) and would_hunt(npc.species, npc.mass, p.mass)):
		return false
	return npc.brain.may_hunt()


## A hunter of the player brought in out of view (see send_attacker): a
## threat of the plan, spawned at its near distance; `swap` (a bird that
## would hunt it but is too far to) makes room for it.
func _bring_attacker(p: Bird, swap: NpcBird) -> NpcBird:
	var keys: Array = []
	var hunters: Array = []
	for k in spawn_order(_plan.keys()):
		if _is_threat_key(k):
			keys.append(k)
			var e: Dictionary = _plan[k]
			var m := float(e["mass"]) if float(e["mass"]) > 0.0 else float(SizeRules.species_data(e["species"])["mass"])
			if SizeRules.can_eat(m, p.mass) and would_hunt(e["species"], m, p.mass):
				hunters.append(k)
	if not hunters.is_empty():
		keys = hunters
	if keys.is_empty():
		_attack_failed(&"no_hunter_planned")
		return null
	var k: StringName = keys[_rng.randi() % keys.size()]
	if swap == null and _npcs.size() >= max_npcs:
		swap = _idle_far_unseen(p)
	if swap != null and _npcs.size() >= max_npcs:
		_remove(swap, &"surplus")
	elif _npcs.size() >= max_npcs:
		_attack_failed(&"no_room")
		return null
	var n0 := _npcs.size()
	if _spawn_group(k, 1, p) <= 0 or _npcs.size() <= n0:
		_attack_failed(&"no_spawn_spot")
		return null
	var npc: NpcBird = _npcs[_npcs.size() - 1]
	if not _can_attack(npc, p):
		_attack_failed(&"brought_cannot_hunt")
		return null
	return npc


## True if an NPC of this mass would hunt a bird of prey_mass: it can eat
## it, it is worth its while (the rule NpcBrain hunts by) and its species is
## a real hunter (drive >= THREAT_MIN_DRIVE: a pigeon or a starling can eat
## a sparrow but hardly ever sets off after one). What makes a bird a
## *threat* to the player, as opposed to merely bigger.
static func would_hunt(species: StringName, mass: float, prey_mass: float) -> bool:
	return float(SpeciesProfile.of(species)["hunt"]) >= THREAT_MIN_DRIVE and SizeRules.is_worthwhile(mass, prey_mass)


## Numbers for tests, the dev overlay and the game loop.
func stats() -> Dictionary:
	var by_species := {}
	var by_state := {}
	var lod := [0, 0, 0]
	for npc in _npcs:
		by_species[String(npc.species)] = by_species.get(String(npc.species), 0) + 1
		by_state[npc.state_name()] = by_state.get(npc.state_name(), 0) + 1
		lod[clampi(npc.lod, 0, 2)] += 1
	var out := _stats.duplicate(true)
	out["npcs"] = _npcs.size()
	out["target"] = max_npcs
	out["time"] = _t
	out["by_species"] = by_species
	out["by_state"] = by_state
	out["by_role"] = _count_roles()
	out["lod"] = lod
	out["flocks"] = _flocks.size()
	out["show"] = show_info()
	out["swarm"] = swarm.shown() if swarm != null else 0
	out["moths"] = moths.stats() if moths != null else {}
	out["plan"] = _plan_summary()
	var ms := _tick_ms()
	out["tick_ms_avg"] = ms[0]
	out["tick_ms_p95"] = ms[1]
	out["tick_ms_max"] = ms[2]
	var n := maxf(_part_n, 1)
	out["tick_parts_ms"] = {"upkeep": _part_us[0] / 1000.0 / n, "flocks": _part_us[1] / 1000.0 / n, "birds": _part_us[2] / 1000.0 / n}
	return out


func _reset_stats() -> void:
	_stats = {
		"catches": 0, "catches_by_species": {}, "caught_by_species": {},
		"caught_by_player": 0, "ate_player": 0,
		"behaviour": {}, "entered": {},
		"spawned": 0, "despawned": {},
		"flock_time": 0.0,
		"hunts_on_player": 0,
		"show_hunts": 0, "show_hunt_catches": 0, "show_hunt_misses": {},
		"attacks_sent": 0,
	}
	_tick_us.clear()
	_tick_i = 0
	_part_us = [0, 0, 0]
	_part_n = 0


# ---------------------------------------------------------------- stepping

## Advance the whole population by dt (physics tick, or manual in tests).
func step(dt: float) -> void:
	var t0 := Time.get_ticks_usec()
	if habitat == null:
		world = World.find(get_tree()) if is_inside_tree() else null
		habitat = Habitat.for_world(world)
		# The habitat is shared per world and remembers what earlier birds
		# learned (thermal circling directions, lift found by chance): a new
		# population starts from the world's own state, or the same seed in a
		# reused world would give a different sky.
		habitat.refresh()
	# The world generates during its own _ready; do not populate an empty one.
	if world != null and is_instance_valid(world) and not world.is_generated:
		return
	_t += dt
	_thermal_t += dt
	if _thermal_t >= 10.0:
		_thermal_t = 0.0
		habitat.refresh_thermals()
	var fb := _focus()
	_update_focus(fb, dt)
	if not _populated:
		_rebalance(fb, true)
		_populated = true
	_rebalance_t += dt
	if _rebalance_t >= rebalance_interval:
		_rebalance_t = 0.0
		_rebalance(fb, false)
	_lod_t += dt
	if _lod_t >= 0.25:
		_update_lod(fb, _lod_t)
		_lod_t = 0.0
	_home_t += dt
	if _home_t >= 1.0:
		_update_homes(fb)
		_update_show_hunt(fb, _home_t)
		_home_t = 0.0
	var t1 := Time.get_ticks_usec()
	var murm: FlockGroup = null
	for fl in _flocks:
		fl.update(dt)
		if fl.kind == "murmuration":
			murm = fl
	_step_swarm(dt, murm)
	if moths != null:
		moths.habitat = habitat
		moths.step(dt, fb, max_npcs)
	var t2 := Time.get_ticks_usec()
	NpcBrain.snapshot_begin()
	for npc in _npcs:
		npc.tick(dt)
	NpcBrain.snapshot_end()
	var t3 := Time.get_ticks_usec()
	_part_us[0] += t1 - t0
	_part_us[1] += t2 - t1
	_part_us[2] += t3 - t2
	_part_n += 1
	var us := t3 - t0
	if _tick_us.size() < 600:
		_tick_us.append(us)
	else:
		_tick_us[_tick_i] = us
		_tick_i = (_tick_i + 1) % 600


## The focus point. For a player going somewhere: its position, led by
## focus_lead_s of its (3-s smoothed) velocity, so it flies into birds
## instead of leaving them behind. For one circling an area (laps, a
## thermal, a dogfight): the middle of the area it has flown over lately
## (its positions over AREA_S), and the population spreads over that area
## (see _update_area). Led by its velocity, the point would swing round a
## lap wider and faster than the player itself (6 s ahead on a 90-m lap is
## 65 m round the curve, at 1.2x its speed), and on the player itself it
## would still circle the lap at the player's speed: birds homed on either
## chase it round without ever settling where the player flies. Blended
## over TRAVEL_BLEND_S, followed with a 2-s lag.
func _update_focus(fb: Bird, dt: float) -> void:
	if fb == null:
		return
	var pp := fb.get_body_position()
	var v := fb.velocity
	if not (is_finite(v.x) and is_finite(v.z)):
		v = Vector3.ZERO
	var ph := Vector3(pp.x, 0.0, pp.z)
	if _last_ph != Vector3.INF and ph.distance_to(_last_ph) > JUMP_M:
		# The player was put somewhere else (GameLoop's respawn at the spawn
		# point after being caught): its sky starts over there at once - not
		# after the minute it takes the area it circles to forget the old
		# place, or the travel detector to call a teleport a journey.
		_area.clear()
		_track.clear()
		_travelling = false
		_travel_k = 0.0
		_drift = Vector3.ZERO
		_vel_avg = Vector3.ZERO
		_focus_pt = ph
		_prey_pull_t = -999.0
	_last_ph = ph
	_vel_avg = _vel_avg.lerp(Vector3(v.x, 0.0, v.z), clampf(dt / 3.0, 0.0, 1.0))
	var was := _travelling
	_update_track(ph, v, dt)
	if was and not _travelling:
		# Arrived somewhere: the area it circles now starts here.
		_area.clear()
	_update_area(ph, dt)
	_travel_k = move_toward(_travel_k, 1.0 if _travelling else 0.0, dt / TRAVEL_BLEND_S)
	# An area only just begun (the player arrived, or turned round) is not
	# yet the middle of anything: until AREA_S of it is known the point
	# leans towards the player itself.
	var settled := clampf(float(_area.size()) / AREA_S, 0.0, 1.0)
	var circling := ph.lerp(_area_c, settled)
	var want := habitat.clamp_inside(circling.lerp(ph + _vel_avg * focus_lead_s, _travel_k), 60.0)
	want.y = 0.0
	if _focus_pt == Vector3.INF:
		_focus_pt = ph
	_focus_pt = _focus_pt.lerp(want, clampf(dt / 2.0, 0.0, 1.0))


## The area the player circles: the mean of its positions over the last
## AREA_S (sampled every second) and their RMS distance from it.
func _update_area(ph: Vector3, dt: float) -> void:
	_area_t += dt
	if _area_t < 1.0 and not _area.is_empty():
		return
	_area_t = 0.0
	_area.append(ph)
	while _area.size() > int(AREA_S):
		_area.pop_front()
	var c := Vector3.ZERO
	for q: Vector3 in _area:
		c += q
	c /= float(_area.size())
	var r2 := 0.0
	for q: Vector3 in _area:
		r2 += q.distance_squared_to(c)
	_area_c = c
	_area_r = sqrt(r2 / float(_area.size()))


## Sample the player's track and decide whether it travels (see
## travel_drift, TRACK_S).
func _update_track(ph: Vector3, v: Vector3, dt: float) -> void:
	_track_t += dt
	if _track_t < TRACK_DT and not _track.is_empty():
		return
	_track_t = 0.0
	var hv := Vector2(v.x, v.z)
	var hd := 0.0
	if not _track.is_empty():
		var last: Array = _track[-1]
		hd = float(last[3])
		if hv.length_squared() > 0.25:
			# Unwrapped: a lap keeps adding up, it does not wrap back to 0.
			hd += wrapf(atan2(hv.y, hv.x) - fposmod(hd + PI, TAU) + PI, -PI, PI)
	elif hv.length_squared() > 0.25:
		hd = atan2(hv.y, hv.x)
	_track.append([_t, ph.x, ph.z, hd])
	while _track.size() > 2 and _t - float(_track[0][0]) > TRACK_S:
		_track.pop_front()
	var first: Array = _track[0]
	var last2: Array = _track[-1]
	var span_t := float(last2[0]) - float(first[0])
	if span_t < TRACK_S * 0.66:
		_drift = Vector3.ZERO
		_travelling = false
		return
	_drift = Vector3(float(last2[1]) - float(first[1]), 0.0, float(last2[2]) - float(first[2])) / span_t
	_travelling = _drift.length() > travel_drift and absf(float(last2[3]) - float(first[3])) < TRAVEL_MAX_TURN


func _tick_ms() -> Array:
	if _tick_us.is_empty():
		return [0.0, 0.0, 0.0]
	var s := _tick_us.duplicate()
	s.sort()
	var sum := 0
	for v in s:
		sum += v
	return [sum / 1000.0 / s.size(), s[int(s.size() * 0.95)] / 1000.0, s[-1] / 1000.0]


func _focus() -> Bird:
	if focus != null and is_instance_valid(focus):
		return focus
	var p := Birds.player()
	return p if p != null and is_instance_valid(p) else null


func _eye(fb: Bird) -> Vector3:
	return fb.get_body_position() if fb else Vector3.ZERO


## How far round the player its sky reaches, m: the distance at which it
## notices and chases birds - 70 of its wingspans or 6 s of its cruise,
## whichever is further (a sparrow ~54 m, a pigeon ~73 m, an eagle ~147 m) -
## times SKY_PER_REACH, at least SKY_MIN, at most home_radius. Home ranges,
## the threats' patrol and spawn distances scale with it: the world shrinks
## as the player grows (world_scale), so the population's spread must grow
## with it. At a fixed 110 m a sparrow-sized player had the average bird
## 120-140 m away, beyond its sight, and flew through an empty sky.
func sky_radius() -> float:
	var fb := _focus()
	if fb == null:
		return home_radius
	var pm := fb.mass
	var reach := maxf(70.0 * SizeRules.wingspan_for_mass(pm), 6.0 * SizeRules.cruise_speed(pm))
	# A player circling a wider area than that (a sparrow flying 180-m
	# laps) has the birds spread over the area it flies, not bunched in the
	# middle where it never is.
	var area := _area_r * (1.0 - _travel_k) * 1.15
	return clampf(maxf(reach * SKY_PER_REACH, area), minf(SKY_MIN, home_radius), home_radius)


## True while the player is going somewhere (see travel_drift).
func travelling() -> bool:
	return _travelling


## The player's net velocity over its recent track (see travel_drift).
func drift() -> Vector3:
	return _drift


## Where the player is looking: the head (camera) in VR, not the body.
func _view_dir(fb: Bird) -> Vector3:
	if fb == null:
		return Vector3.FORWARD
	if fb.has_method(&"get_view_direction"):
		return fb.call(&"get_view_direction")
	if fb.is_player() and is_inside_tree():
		var cam := get_viewport().get_camera_3d()
		if cam != null:
			return -cam.global_basis.z
	return fb.get_forward()


## True if pos is where the player could see a bird pop in.
func in_view(pos: Vector3, fb: Bird = null) -> bool:
	if fb == null:
		fb = _focus()
	if fb == null:
		return false
	var rel := pos - _eye(fb)
	var d := rel.length()
	if d < spawn_min:
		return true
	var vd := _view_dir(fb)
	return vd.dot(rel / d) > cos(deg_to_rad(view_half_angle_deg))


func _update_lod(fb: Bird, dt: float) -> void:
	var c := _eye(fb)
	var n2 := lod_near * lod_near
	var f2 := lod_far * lod_far
	for npc in _npcs:
		var d2 := npc.global_position.distance_squared_to(c)
		npc.lod = 0 if d2 < n2 else (1 if d2 < f2 else 2)
		if npc.state == NpcBird.State.FLOCK:
			_stats["flock_time"] += dt


func _update_homes(fb: Bird) -> void:
	if fb == null or _focus_pt == Vector3.INF:
		return
	# Homes ride on the focus point (the player led by its velocity): birds
	# gather where the player is going rather than where it was. Threats
	# patrol the player itself (a short lead only), at half the offset: they
	# are there to hunt it.
	var c := _focus_pt
	_sky = sky_radius()
	for npc in _npcs:
		var off: Vector3 = _npc_offset.get(npc.get_instance_id(), Vector3.ZERO)
		_place_home(npc, _npc_key.get(npc.get_instance_id(), npc.species), off, fb)
	for fl in _flocks:
		# (The show's flocks are homed by _update_show.)
		if fl.kind != "murmuration" and not _show_flocks.has(fl):
			var prey := fl.members.size() > 0 and _role_of(_npc_key.get(fl.members[0].get_instance_id(), &"")) == &"prey"
			var lim := _sky * (PREY_SPREAD if prey else 0.6)
			var fc := c
			if prey:
				var pp := fb.get_body_position()
				fc = c.lerp(Vector3(pp.x, 0.0, pp.z), PREY_PULL * (1.0 - _travel_k))
			fl.home_radius = _sky * 0.75
			fl.set_home(Vector3(fc.x, 0.0, fc.z) + Vector3(fl.home.x - fc.x, 0.0, fl.home.z - fc.z).limit_length(lim))
	_update_show(fb)


## The show (see SHOW_AHEAD): moves its point ahead of the player when the
## player has turned away from it, keeps its birds (re-picking any that
## left: freed, grown into prey or a threat, joined by the player's growth
## to another role), and homes them on it - after _place_home, over the
## homes it gave them.
func _update_show(fb: Bird) -> void:
	if fb == null:
		return
	var pp := fb.get_body_position()
	var ph := Vector3(pp.x, 0.0, pp.z)
	var fwd := _vel_avg
	if fwd.length() < 1.0:
		var vd := _view_dir(fb)
		fwd = Vector3(vd.x, 0.0, vd.z)
	if fwd.length() < 1e-3:
		return
	var speed := maxf(fwd.length(), 3.0)
	fwd = fwd.normalized()
	# The turn rate, from the smoothed heading between calls.
	var hd := atan2(fwd.x, fwd.z)
	if _show_last_h != INF and _t > _show_last_t:
		var w := wrapf(hd - _show_last_h, -PI, PI) / (_t - _show_last_t)
		_show_turn = lerpf(_show_turn, w, 0.5)
	_show_last_h = hd
	_show_last_t = _t
	var dist := clampf(_sky * SHOW_AHEAD, SHOW_MIN_M, SHOW_MAX_M)
	var stale := _show_pt == Vector3.INF
	if not stale:
		var to := _show_pt - ph
		var d := to.length()
		stale = d < dist * 0.4 or d > dist * 2.0 or fwd.dot(to / maxf(d, 1e-3)) < cos(deg_to_rad(SHOW_CONE_DEG))
	if stale and _t - _show_moved_t >= SHOW_HOLD_S:
		# Where the flight leads in dist / speed seconds: straight on, or
		# round the curve it is turning on (a lap's own circle).
		var arc := clampf(_show_turn * dist / speed, -SHOW_MAX_ARC, SHOW_MAX_ARC)
		var lead := fwd * dist
		if absf(arc) > 0.05:
			var rad := dist / arc
			var side := Vector3(fwd.z, 0.0, -fwd.x)
			lead = fwd * sin(arc) * rad + side * (1.0 - cos(arc)) * rad
		var p := habitat.clamp_inside(ph + lead, 60.0)
		_show_pt = Vector3(p.x, 0.0, p.z)
		_show_moved_t = _t
	if _show_pt == Vector3.INF:
		return
	var scale := float(max_npcs) / 60.0
	var want_fl := maxi(1, int(round(SHOW_FLOCKS * scale)))
	var want_solo := maxi(SHOW_SOLOS_MIN, int(round(SHOW_SOLOS * scale)))
	# Only birds that can keep up with the player stay ahead of it.
	var keep_up := SizeRules.cruise_speed(fb.mass) * SHOW_KEEP_UP
	# The show's birds, chosen afresh each time from those that can be in
	# it, best first (members already in the show are favoured, so it does
	# not churn): the murmuration (the brief's own picture), then flocks
	# and birds that will show best soonest - near the point and big (a gull
	# is seen from 180 m, a sparrow from 40): distance over visible size. A
	# flock that is roosting, or a bird busy hunting, fleeing or hiding,
	# joins only once it is free again.
	var cands: Array = []
	for fl in _flocks:
		if fl.size() == 0 or not _show_flock_ok(fl) or fl.cruise < keep_up:
			continue
		var was := _show_flocks.has(fl)
		# A roosting flock sits wherever the show was when it tired: out.
		if fl.mood != FlockGroup.Mood.FLY:
			continue
		var fspan := SizeRules.wingspan_for_mass(float(SizeRules.species_data(fl.species).get("mass", 0.03)))
		var key := fl.centroid().distance_to(_show_pt) / (fspan * sqrt(float(fl.size())))
		if fl.kind == "murmuration":
			key = -1.0
		cands.append([key * (SHOW_KEEP if was else 1.0), fl.id, fl])
	cands.sort_custom(_by_dist_then_id)
	var fls: Array[FlockGroup] = []
	for c in cands.slice(0, want_fl):
		fls.append(c[2])
	for fl in _show_flocks:
		if not fls.has(fl):
			fl.show_alt = NAN
			fl.home_goal = Vector3.INF
	_show_flocks = fls
	var cands2: Array = []
	for npc in _npcs:
		if not _show_solo_ok(npc) or npc.flight.cruise < keep_up:
			continue
		var was2 := _show_solos.has(npc)
		# Only a bird on the wing and free: one hunting, fleeing, hiding or
		# sitting on a perch is busy (it leaves the show, another joins; a
		# show bird that gets hungry still hunts - and so leaves it: the
		# valley's 10-minute soak made 42 NPC catches by 8 species with the
		# show, 42 by 7 without).
		if not (npc.state in [NpcBird.State.WANDER, NpcBird.State.SOAR]):
			continue
		var d2 := npc.global_position.distance_to(_show_pt)
		# (One that has wandered off beyond SHOW_LOST x the distance - a
		# thermal, a chase - is not coming back soon.)
		if d2 > dist * SHOW_LOST and was2:
			continue
		cands2.append([d2 / npc.get_wingspan() * (SHOW_KEEP if was2 else 1.0), npc.get_instance_id(), npc])
	cands2.sort_custom(_by_dist_then_id)
	var solos: Array[NpcBird] = []
	for c in cands2.slice(0, want_solo):
		solos.append(c[2])
	_show_solos = solos
	var r := dist * SHOW_RANGE
	for fl in _show_flocks:
		fl.home_radius = r
		# (Its home glides there: FlockGroup.home_goal.)
		fl.home_goal = _show_pt
		# Wheeling at about the player's height, where it looks; not settling
		# down to roost wherever the show happened to be.
		fl.show_alt = pp.y
	# The solos further out along the same line, spread round it (fixed per
	# slot, not stacked).
	var far := Vector3(_show_pt.x - ph.x, 0.0, _show_pt.z - ph.z) * SHOW_SOLO_AHEAD + ph
	for i in _show_solos.size():
		var npc := _show_solos[i]
		var a := TAU * float(i) / float(_show_solos.size())
		npc.home = far + Vector3(cos(a), 0.0, sin(a)) * r
		npc.home_radius = r * 1.5
	# A hunter keeps company with the show's first flock (see SHOW_HUNT_S):
	# a free bird that would hunt its kind - and never the player - homed on
	# the show's point, so a show hunt has a hunter at hand where the player
	# looks. (A solo already chosen may be it; it then leaves the far ring.)
	_show_stalker = null
	if show_hunts and not _show_flocks.is_empty():
		var fl0 := _show_flocks[0]
		var fmass := float(SizeRules.species_data(fl0.species).get("mass", 0.1))
		var best_d := INF
		for npc in _npcs:
			if npc.flock != null or npc.flight.cruise < keep_up or not _may_show_hunt(npc, fb) \
					or not would_hunt(npc.species, npc.mass, fmass):
				continue
			var d3 := npc.global_position.distance_to(_show_pt)
			if d3 < best_d:
				best_d = d3
				_show_stalker = npc
		if _show_stalker != null:
			_show_stalker.home = _show_pt
			_show_stalker.home_radius = r


## The murmuration's visual-only mass follows the murmuration flock (see
## MurmurationSwarm), sized by the budget.
func _step_swarm(dt: float, murm: FlockGroup) -> void:
	if not murmuration_swarm:
		if swarm != null:
			swarm.visible = false
		return
	var want := MurmurationSwarm.size_for_budget(max_npcs)
	if swarm == null:
		swarm = MurmurationSwarm.new(want, rng_seed * 13 + 5)
		add_child(swarm)
	elif swarm.size != want:
		swarm.resize(want)
	swarm.step(dt, murm)


## Sets up a show hunt where the player looks when none has been in view
## for SHOW_HUNT_S (see there). Called once a second.
func _update_show_hunt(fb: Bird, dt: float) -> void:
	if fb == null or not show_hunts:
		return
	if _show_hunter != null:
		if is_instance_valid(_show_hunter) and _show_hunter.alive and _show_hunter.target != null \
				and (_show_hunter.state == NpcBird.State.HUNT or _show_hunter.state == NpcBird.State.STOOP):
			return
		_show_hunter = null
		_show_hunt_t = 0.0
	_show_hunt_t += dt
	if _show_hunt_t < SHOW_HUNT_S:
		return
	var eye := _eye(fb)
	var vd := _view_dir(fb)
	var cos_v := cos(deg_to_rad(SHOW_HUNT_VIEW_DEG))
	# A hunt already where the player looks: nothing to set up.
	for npc in _npcs:
		if npc.target != null and is_instance_valid(npc.target) and not npc.target.is_player() \
				and _looked_at(npc.global_position, eye, vd, cos_v, 0.0):
			_show_hunt_t = SHOW_HUNT_S * 0.5
			return
	var best_h: NpcBird = null
	var best_q: Bird = null
	var best_k := INF
	var hunters: Array[NpcBird] = []
	for h in _npcs:
		if _may_show_hunt(h, fb):
			hunters.append(h)
	if not hunters.is_empty():
		for q in _npcs:
			if q.hidden or q.perched or not q.alive or q.pursuers > 0:
				continue
			if not (q.state in [NpcBird.State.WANDER, NpcBird.State.FLOCK, NpcBird.State.SOAR]):
				continue
			if not SHOW_ROLES.has(_role_of(_npc_key.get(q.get_instance_id(), q.species))):
				continue
			var qp := q.get_body_position()
			if not _looked_at(qp, eye, vd, cos_v, SHOW_HUNT_MIN_M):
				continue
			for h in hunters:
				if h == q or not would_hunt(h.species, h.mass, q.mass):
					continue
				var d := h.global_position.distance_to(qp)
				if d > SHOW_HUNTER_M:
					continue
				var k := d + 0.5 * eye.distance_to(qp)
				# A raptor with height on its prey stoops (the brief's picture):
				# preferred.
				if bool(h.profile.get("stoop", false)) and h.global_position.y - qp.y > 10.0:
					k -= SHOW_HUNT_STOOP_BONUS_M
				if k < best_k:
					best_k = k
					best_h = h
					best_q = q
		# The pellets too (core loop round): a wren or a sparrow taking a moth
		# out of a swarm where the player looks - plentiful, in open air,
		# caught more often than not (the lead's direction: "predation
		# witnessed a few times per session").
		if moths != null:
			for sw in moths.swarms:
				for mo in sw.moths:
					if not mo.alive:
						continue
					var mp := mo.get_body_position()
					if not _looked_at(mp, eye, vd, cos_v, SHOW_HUNT_MIN_M):
						continue
					for h in hunters:
						if not would_hunt(h.species, h.mass, mo.mass):
							continue
						var d2 := h.global_position.distance_to(mp)
						if d2 > SHOW_HUNTER_M:
							continue
						var k2 := d2 + 0.5 * eye.distance_to(mp)
						if k2 < best_k:
							best_k = k2
							best_h = h
							best_q = mo
	if best_h == null or not best_h.brain.begin_hunt(best_q):
		# Nothing to set up now: look again in a moment.
		var why := "no_hunter" if hunters.is_empty() else ("no_pair" if best_h == null else "refused")
		var miss: Dictionary = _stats["show_hunt_misses"]
		miss[why] = int(miss.get(why, 0)) + 1
		_show_hunt_t = SHOW_HUNT_S - SHOW_HUNT_RETRY_S
		return
	_show_hunter = best_h
	_stats["show_hunts"] += 1


## In the player's gaze (within SHOW_HUNT_VIEW_DEG), min_m..SHOW_HUNT_MAX_M out.
static func _looked_at(p: Vector3, eye: Vector3, vd: Vector3, cos_v: float, min_m: float) -> bool:
	var rel := p - eye
	var d := rel.length()
	return d >= min_m and d <= SHOW_HUNT_MAX_M and vd.dot(rel / maxf(d, 1e-3)) >= cos_v


## A bird that may be a show hunt's hunter: free to hunt, not one of the
## player's threats, and not one that would hunt the player (a show hunt
## adds no danger to the player's run).
func _may_show_hunt(h: NpcBird, fb: Bird) -> bool:
	if not h.alive or h.hidden or h.brain == null or not h.brain.may_hunt() or h.threat != null:
		return false
	if not (h.state in [NpcBird.State.WANDER, NpcBird.State.FLOCK, NpcBird.State.SOAR, NpcBird.State.PERCHED]):
		return false
	# A hunter of the player adds no danger by a show hunt while the game
	# loop keeps NPCs off the player (its respites: meta "npc_ignore"; core
	# loop round - the danger director decides when the player is hunted).
	var calm: bool = fb.is_player() and bool(fb.get_meta(&"npc_ignore", false))
	if _role_of(_npc_key.get(h.get_instance_id(), h.species)) == &"threat" and not calm:
		return false
	if fb.is_player() and would_hunt(h.species, h.mass, fb.mass) and h.can_eat(fb) and not calm:
		return false
	return true


static func _by_dist_then_id(a: Array, b: Array) -> bool:
	if float(a[0]) != float(b[0]):
		return float(a[0]) < float(b[0])
	return int(a[1]) < int(b[1])


func _show_flock_ok(fl: FlockGroup) -> bool:
	if fl.members.is_empty():
		return false
	var m0: Variant = fl.members[0]
	if not is_instance_valid(m0):
		return false
	return SHOW_ROLES.has(_role_of(_npc_key.get((m0 as NpcBird).get_instance_id(), &"")))


func _show_solo_ok(npc: NpcBird) -> bool:
	if npc.flock != null or npc.hidden:
		return false
	return SHOW_ROLES.has(_role_of(_npc_key.get(npc.get_instance_id(), npc.species)))


## The show's point (Vector3.INF before there is one) and its birds.
func show_info() -> Dictionary:
	var n := 0
	for fl in _show_flocks:
		n += fl.size()
	return {"point": _show_pt, "flocks": _show_flocks.size(), "flock_birds": n, "solos": _show_solos.size(),
		"stalker": String(_show_stalker.species) if _show_stalker != null and is_instance_valid(_show_stalker) else ""}


## Home and home range by the bird's current role (roles change as the
## player grows): threats patrol the player itself; the player's prey
## keeps close to where it is going (a travelling player must fly into it,
## not past its edge); everything else ranges wider round the focus.
func _place_home(npc: NpcBird, key: StringName, off: Vector3, fb: Bird) -> void:
	if fb == null:
		return
	var role := _role_of(key)
	if role == &"threat":
		var tp := _threat_point(fb)
		npc.home = Vector3(tp.x + off.x * 0.5 * _sky, 0.0, tp.z + off.z * 0.5 * _sky)
		npc.home_radius = _sky * THREAT_RANGE
		return
	var c := focus_point()
	var k := PREY_SPREAD if role == &"prey" else 1.0
	if role == &"prey":
		# The player's prey keeps between the middle of the area it circles
		# and the player itself: a player lapping wider than its prey's
		# range still flies through it every lap.
		var pp := fb.get_body_position()
		c = c.lerp(Vector3(pp.x, 0.0, pp.z), PREY_PULL * (1.0 - _travel_k))
	npc.home = Vector3(c.x + off.x * k * _sky, 0.0, c.z + off.z * k * _sky)
	npc.home_radius = _sky * (PREY_RANGE if role == &"prey" else 1.0)


func _role_of(key: StringName) -> StringName:
	if _is_threat_key(key):
		return &"threat"
	return _plan[key]["role"] if _plan.has(key) else &"ambient"


## Where threats patrol: the player, led by 2 s of its smoothed velocity.
func _threat_point(fb: Bird) -> Vector3:
	var pp := fb.get_body_position()
	return Vector3(pp.x, 0.0, pp.z) + _vel_avg * 2.0


static func _is_threat_key(k: StringName) -> bool:
	return k == APEX_KEY or String(k).ends_with(HUNTER)


# ---------------------------------------------------------------- planning

## key -> {count, role, species, mass, pm}. pm <= 0: no player, use the pyramid.
func _make_plan(pm: float) -> Dictionary:
	var plan := {}
	var scale := float(max_npcs) / 60.0
	if pm <= 0.0:
		for s in PYRAMID:
			plan[s] = {"count": int(round(PYRAMID[s] * scale)), "role": &"ambient", "species": s, "mass": -1.0, "pm": -1.0}
		_trim(plan)
		return plan
	var prey := []
	var dust := []
	var peers := []
	var threats := []
	var giants := []
	for s in SizeRules.SPECIES:
		var m: float = s["mass"]
		var id: StringName = s["id"]
		if SizeRules.can_eat(pm, m):
			if SizeRules.is_worthwhile(pm, m):
				prey.append(id)
			else:
				dust.append(id)
		elif SizeRules.can_eat(m * 1.09, pm):
			# A threat if some individual of the species (its mass band,
			# +-9%) could eat the player and would think it worth a chase;
			# hunters are then spawned inside that part of the band
			# (_make_npc). A crow of 0.46 kg hunts a swallow-sized bird, one
			# of 0.54 kg would not bother.
			if _hunter_band(id, pm).x > 0.0:
				threats.append(id)
			elif SizeRules.can_eat(m, pm):
				giants.append(id)
			else:
				peers.append(id)
		else:
			peers.append(id)
	var left := max_npcs
	# Ambient murmuration (starlings) whatever their role.
	var n_murm := maxi(int(round(N_MURMURATION * scale)), mini(N_MURMURATION_MIN, max_npcs / 3))
	# (What a small budget's murmuration takes over its share comes out of
	# the near-equals, never out of the player's prey.)
	var murm_extra := n_murm - int(round(N_MURMURATION * scale))
	left -= _add(plan, MURM_KEY, &"starling", n_murm, &"ambient")
	# Threats: keen hunters first, mostly the next rungs up.
	var n_threat := int(round(N_THREATS * scale))
	var tw := func(i: int, id: StringName) -> float:
		return float(SpeciesProfile.of(id)["hunt"]) / pow(i + 1.0, 0.7)
	var placed_threats := _fill(plan, threats, n_threat, tw, &"threat", HUNTER, pm)
	left -= placed_threats
	# Near the top the ladder runs out of birds that would hunt the player (a
	# handful of eagles at most): top up with "apex" eagles sized to stay a
	# threat (with margin, as the player is still growing; _rebalance
	# recycles any it outgrows). There is always something to fear. (Margin
	# 1.5: at 1.3 all three were outgrown together every ~30% of growth and
	# recycled at once, and a fast-growing player went seconds with no
	# threat within 200 m while their replacements came in.)
	var min_threats := int(round(MIN_THREATS * scale))
	if placed_threats < min_threats:
		var n_apex := mini(min_threats - placed_threats, 3) if placed_threats > 0 else mini(3, n_threat)
		var eagle_mass: float = SizeRules.species_data(&"eagle")["mass"]
		plan[APEX_KEY] = {"count": n_apex, "role": &"threat", "species": &"eagle",
			"mass": maxf(eagle_mass * 0.95, pm * SizeRules.EAT_RATIO * 1.5), "pm": pm}
		left -= n_apex
	# Big birds that would not bother with the player: life, not danger.
	left -= _fill(plan, giants, mini(int(round(N_GIANTS * scale)), left), func(_i: int, _id: StringName) -> float: return 1.0, &"giant")
	# Near-equals.
	left -= _fill(plan, peers, mini(maxi(int(round(N_PEERS * scale)) - murm_extra, 0), left), func(_i: int, _id: StringName) -> float: return 1.0, &"peer")
	# Dust: a few, for life.
	left -= _fill(plan, dust, mini(int(round(N_DUST * scale)), left), func(i: int, _id: StringName) -> float: return float(i + 1), &"dust")
	# Everything else is worthwhile prey, weighted to the larger species.
	var pw := func(_i: int, id: StringName) -> float: return sqrt(float(SizeRules.species_data(id)["mass"]) / pm)
	left -= _fill(plan, prey, left, pw, &"prey")
	if left > 0:
		# Caps hit: spread the rest over whatever can still take birds.
		for pool in [prey, peers, dust, giants]:
			if left <= 0:
				break
			left -= _fill(plan, pool, left, func(_i: int, _id: StringName) -> float: return 1.0, &"extra")
		if left > 0:
			left -= _fill(plan, threats, left, tw, &"threat", HUNTER, pm)
	_trim(plan)
	return plan


## Birds of species id already planned under any key (apex eagles are a
## device to keep a threat above the player, not part of the population the
## caps keep believable).
func _planned(plan: Dictionary, id: StringName) -> int:
	var n := 0
	for k in plan:
		if k != APEX_KEY and plan[k]["species"] == id:
			n += int(plan[k]["count"])
	return n


## Add up to n birds of species id under plan key `key`, within the
## species cap. Returns how many were added.
func _add(plan: Dictionary, key: StringName, id: StringName, n: int, role: StringName, pm: float = -1.0) -> int:
	var room: int = SPECIES_CAP.get(id, 10) - _planned(plan, id)
	var k := clampi(n, 0, room)
	if k <= 0:
		return 0
	if plan.has(key):
		plan[key]["count"] += k
	else:
		plan[key] = {"count": k, "role": role, "species": id, "mass": -1.0, "pm": pm}
	return k


## Share n birds over ids by weight (largest remainder), respecting caps.
## Keys are the species id plus `suffix`.
func _fill(plan: Dictionary, ids: Array, n: int, weight: Callable, role: StringName, suffix: String = "", pm: float = -1.0) -> int:
	if ids.is_empty() or n <= 0:
		return 0
	var placed := 0
	for round_i in 3:
		var want := n - placed
		if want <= 0:
			break
		var w := []
		var total := 0.0
		for i in ids.size():
			var x: float = weight.call(i, ids[i])
			if _planned(plan, ids[i]) >= SPECIES_CAP.get(ids[i], 10):
				x = 0.0
			w.append(x)
			total += x
		if total <= 0.0:
			break
		var shares := []
		var got := 0
		for i in ids.size():
			var exact: float = w[i] / total * want
			shares.append([ids[i], int(floor(exact)), exact - floor(exact)])
			got += int(floor(exact))
		shares.sort_custom(func(a: Array, c: Array) -> bool: return a[2] > c[2])
		for i in shares.size():
			if got >= want:
				break
			if w[ids.find(shares[i][0])] > 0.0:
				shares[i][1] += 1
				got += 1
		for sh in shares:
			placed += _add(plan, StringName(String(sh[0]) + suffix), sh[0], sh[1], role, pm)
	return placed


func _trim(plan: Dictionary) -> void:
	var total := 0
	for k in plan:
		total += int(plan[k]["count"])
	# Over budget (rounding): shave the largest groups.
	while total > max_npcs:
		var big: Variant = null
		for k in plan:
			if big == null or plan[k]["count"] > plan[big]["count"]:
				big = k
		plan[big]["count"] -= 1
		total -= 1


func _plan_summary() -> Dictionary:
	var out := {}
	for k in _plan:
		out[String(k)] = _plan[k]["count"]
	return out


## Roles as the player sees them right now: prey (worth eating), dust,
## peers, threats (would hunt it) and giants (could eat it, would not
## bother).
func _count_roles() -> Dictionary:
	var fb := _focus()
	var out := {"prey": 0, "dust": 0, "peer": 0, "threat": 0, "giant": 0}
	if fb == null:
		return out
	for npc in _npcs:
		if SizeRules.can_eat(fb.mass, npc.mass):
			if SizeRules.is_worthwhile(fb.mass, npc.mass):
				out["prey"] += 1
			else:
				out["dust"] += 1
		elif SizeRules.can_eat(npc.mass, fb.mass):
			out["threat" if would_hunt(npc.species, npc.mass, fb.mass) else "giant"] += 1
		else:
			out["peer"] += 1
	return out


# ---------------------------------------------------------------- population

func _rebalance(fb: Bird, initial: bool) -> void:
	var pm := fb.mass if fb else -1.0
	_sky = sky_radius()
	if _plan.is_empty() or (pm > 0.0 and (_plan_mass <= 0.0 or absf(pm - _plan_mass) / _plan_mass > 0.08)) \
			or (pm <= 0.0 and _plan_mass > 0.0) \
			or (pm > 0.0 and _t - _plan_t > 3.0 and not _threats_still_qualify(pm)):
		_plan = _make_plan(pm)
		_plan_mass = pm
		_plan_t = _t
	# The caught are gone. A bird still trapped after backing out of a pocket
	# along its trail (NpcBird.trapped - a last resort that no measured run
	# has needed since the escape exists) is taken out of play unseen and
	# reborn elsewhere, rather than left grinding in a crevice for good.
	for npc in _npcs.duplicate():
		if not npc.alive:
			_remove(npc, &"caught")
		elif npc.trapped() and (fb == null or not in_view(npc.global_position, fb)):
			_remove(npc, &"stuck")
	if fb != null:
		var c := _eye(fb)
		# Recycling waits while the population is short (a refill that
		# found no valid spawn spot): it must never thin the sky.
		var behind_n := 0 if _npcs.size() >= max_npcs else 2
		for npc: NpcBird in _npcs.duplicate():
			if not is_instance_valid(npc) or not _npcs.has(npc):
				continue  # went with its flock earlier in this loop
			var pos := npc.global_position
			# Threats exist to threaten the player: one it has outgrown (or
			# that no longer thinks it worth a chase) is recycled and replaced
			# at the current size.
			var key: StringName = _npc_key.get(npc.get_instance_id(), &"")
			if _is_threat_key(key) \
					and not (SizeRules.can_eat(npc.mass, pm) and would_hunt(npc.species, npc.mass, pm)):
				if not in_view(pos, fb):
					_remove(npc, &"outgrown")
				else:
					# In view it cannot go yet, but it no longer fills a
					# threat's place: it is one of its species now (a surplus
					# one leaves unseen), and the threat it was is replaced
					# at once. (Two outgrown apex eagles circling in front of
					# a fast-growing player held both apex places for 5 s
					# with nothing within 200 m that would hunt it.)
					_npc_key[npc.get_instance_id()] = npc.species
				continue
			# Drifted far from the player and staying there: recycled out of
			# view. A bird in a chase gets slack (a story going on), and one
			# just back from a chase that carried it out gets FAR_GRACE_S to
			# turn for home before it counts as lost.
			var d := pos.distance_to(c)
			var id := npc.get_instance_id()
			if d > despawn_radius * (1.5 if npc.is_engaged() else 1.0):
				_far_t[id] = float(_far_t.get(id, 0.0)) + (_t - _rebalance_last)
				if (npc.is_engaged() or float(_far_t[id]) > FAR_GRACE_S or d > despawn_radius * 1.5) and not in_view(pos, fb):
					_remove(npc, &"far")
				continue
			_far_t.erase(id)
			# Left behind a player that is going somewhere: recycled ahead,
			# out of view - never a bird in the middle of a chase, a flight or
			# hiding, never one just spawned, never a flock member while any
			# of its flock is in view or still ahead of the player (flocks
			# are recycled as flocks, not picked apart in front of it).
			if behind_n < 2 and travelling() and _left_behind(npc, c, fb) and _flock_gone(npc, c, fb):
				_remove(npc, &"behind")
				behind_n += 1
	_rebalance_last = _t
	if fb != null:
		_keep_prey_near(fb)
	# Surplus after a re-plan: recycle the farthest unseen ones.
	var counts := {}
	for npc in _npcs:
		var k: StringName = _npc_key.get(npc.get_instance_id(), npc.species)
		counts[k] = counts.get(k, 0) + 1
	var removed := 0
	for k in counts:
		var want: int = _plan[k]["count"] if _plan.has(k) else 0
		var extra: int = counts[k] - want
		if extra <= 0:
			continue
		var pool: Array[NpcBird] = []
		for npc in _npcs:
			if _npc_key.get(npc.get_instance_id(), npc.species) == k and (fb == null or not in_view(npc.global_position, fb)):
				pool.append(npc)
		var c2 := _eye(fb)
		pool.sort_custom(func(a: NpcBird, b2: NpcBird) -> bool:
			return a.global_position.distance_squared_to(c2) > b2.global_position.distance_squared_to(c2))
		for i in mini(extra, pool.size()):
			if removed >= max_spawns_per_rebalance and not initial:
				break
			_remove(pool[i], &"surplus")
			removed += 1
	# Deficits: spawn out of view.
	counts.clear()
	for npc in _npcs:
		var k: StringName = _npc_key.get(npc.get_instance_id(), npc.species)
		counts[k] = counts.get(k, 0) + 1
	var budget := max_npcs - _npcs.size()
	# A threat short while the sky is full (an outgrown threat still in view
	# stays, as one of its species, until it is out of sight): make room for
	# its replacement now, from the farthest unseen idle bird that is not a
	# threat, past its grace period.
	if budget <= 0 and fb != null:
		var short := false
		for k in _plan:
			if _is_threat_key(k) and int(_plan[k]["count"]) > int(counts.get(k, 0)):
				short = true
				break
		if short:
			var far: NpcBird = null
			var fd := -1.0
			var c3 := _eye(fb)
			for npc in _npcs:
				var k2: StringName = _npc_key.get(npc.get_instance_id(), npc.species)
				if _is_threat_key(k2) or k2 == MURM_KEY or npc.flock != null or npc.is_engaged() \
						or npc.hidden or npc.is_flaring() \
						or _t - float(_born.get(npc.get_instance_id(), _t)) < recycle_grace_s:
					continue
				var d2 := npc.global_position.distance_squared_to(c3)
				if d2 > fd and not in_view(npc.global_position, fb):
					fd = d2
					far = npc
			if far != null:
				_remove(far, &"surplus")
				budget += 1
	# Spawn order decides who draws which numbers from the seeded RNG, so it
	# must not depend on the process: sort by text. (Array.sort() orders
	# StringNames by their interned pointer, i.e. by whatever allocated them
	# first - plan keys like "crow:hunter" are made at run time, so the same
	# seed gave a different sky after other plans had been made.)
	var keys := spawn_order(_plan.keys())
	# Refill to target every rebalance (only recycling is rate-limited): a
	# catch or a recycled bird is replaced within half a second, out of view.
	for k in keys:
		var need: int = _plan[k]["count"] - counts.get(k, 0)
		while need > 0 and budget > 0:
			var n := _spawn_group(k, mini(need, budget), fb)
			if n <= 0:
				break
			need -= n
			budget -= n


## The one promise the population makes the player: something worth
## catching is always about. When fewer than PREY_NEAR_N worthwhile prey are
## in sight (not hidden) within PREY_NEAR_M of it (it outflew them, grew so
## that its prey are now birds that lived elsewhere), or none within
## PREY_CLOSE_M (the prey it has were eaten by others and their
## replacements came in at the edge of its sky), the farthest idle one of
## them - out of view, not busy, not new, beyond PREY_FAR_M (PREY_NEAR_M
## for the second case) - is recycled and so reborn near it, one every
## PREY_NEAR_S at most. Birds follow the player of their own accord; this
## only covers the gaps (a run's first laps, a growth step that turns a far
## flock into prey, a small player whose moths keep being eaten).
func _keep_prey_near(fb: Bird) -> void:
	if _t - _prey_pull_t < PREY_NEAR_S:
		return
	var pm := fb.mass
	var c := _eye(fb)
	var near := 0
	var close := 0
	var cand: Array[NpcBird] = []
	var cand_d: Array[float] = []
	for npc in _npcs:
		if not (SizeRules.can_eat(pm, npc.mass) and SizeRules.is_worthwhile(pm, npc.mass)):
			continue
		var d := Vector2(npc.global_position.x - c.x, npc.global_position.z - c.z).length()
		if d < PREY_NEAR_M:
			if not npc.hidden:
				near += 1
				if d < PREY_CLOSE_M:
					close += 1
		elif _t - float(_born.get(npc.get_instance_id(), 0.0)) > recycle_grace_s \
				and not (npc.is_engaged() or npc.hidden or npc.is_flaring()) and npc.flock == null \
				and not in_view(npc.global_position, fb):
			cand.append(npc)
			cand_d.append(d)
	if near >= PREY_NEAR_N and close >= 1:
		return
	var gap := near < PREY_NEAR_N
	var far_d := PREY_FAR_M if gap else PREY_NEAR_M
	var far_one: NpcBird = null
	for i in cand.size():
		if not gap and _t - float(_born.get(cand[i].get_instance_id(), 0.0)) < PREY_CLOSE_GRACE_S:
			continue
		if cand_d[i] > far_d:
			far_d = cand_d[i]
			far_one = cand[i]
	if far_one != null:
		_prey_pull_t = _t
		_remove(far_one, &"prey_far")
		return
	if gap:
		# No lone bird to bring over: a whole loose flock of the player's prey
		# far off, all of it out of view and idle (a pigeon-sized player
		# respawned 300 m away had only starling flocks for prey, and no
		# lone bird to recycle: 18 s before two were within 120 m).
		var best_fl: FlockGroup = null
		var best_d := PREY_FAR_M
		for fl in _flocks:
			if fl.kind == "murmuration" or fl.members.is_empty():
				continue
			var ok := true
			var dmin := INF
			for m in fl.members:
				if not is_instance_valid(m) or not (m as NpcBird).alive:
					continue
				var n: NpcBird = m
				if not (SizeRules.can_eat(pm, n.mass) and SizeRules.is_worthwhile(pm, n.mass)) \
						or _t - float(_born.get(n.get_instance_id(), 0.0)) <= recycle_grace_s \
						or n.is_engaged() or n.hidden or n.is_flaring() or in_view(n.global_position, fb):
					ok = false
					break
				dmin = minf(dmin, Vector2(n.global_position.x - c.x, n.global_position.z - c.z).length())
			if ok and dmin > best_d:
				best_d = dmin
				best_fl = fl
		if best_fl != null:
			_prey_pull_t = _t
			for m in best_fl.members.duplicate():
				if is_instance_valid(m) and _npcs.has(m):
					_remove(m, &"prey_far")


## True if npc is behind a travelling player and will not catch it up:
## behind its drift, far (recycle_behind; recycle_behind_slow for a bird
## whose cruise is slower than the drift), out of view, past its grace
## period, and not busy (hunting, fleeing, hiding, being chased, landing).
func _left_behind(npc: NpcBird, c: Vector3, fb: Bird) -> bool:
	if not is_instance_valid(npc) or not npc.alive:
		return false
	if _t - float(_born.get(npc.get_instance_id(), _t)) < recycle_grace_s:
		return false
	if npc.is_engaged() or npc.hidden or npc.state == NpcBird.State.HIDE or npc.is_flaring():
		return false
	# About to land: let it (it can go once it sits there, out of sight).
	if npc.state == NpcBird.State.PERCH and npc.perch_spot != null \
			and npc.perch_spot.position.distance_to(npc.global_position) < 30.0:
		return false
	var rel := npc.global_position - c
	var d := rel.length()
	var dr := _drift.length()
	# The player's own prey matters most: slower than it, it is reborn ahead
	# once a little more than the player's sky behind (a sparrow's ~70 m, an
	# eagle's ~100 m), where it could never be caught up with anyway.
	var slow_d := recycle_behind_slow
	if fb != null and SizeRules.can_eat(fb.mass, npc.mass) and SizeRules.is_worthwhile(fb.mass, npc.mass):
		slow_d = minf(slow_d, _sky * 0.9)
	if not (d > recycle_behind or (d > slow_d and npc.flight.cruise < dr)):
		return false
	if rel.dot(_drift) > -0.3 * d * dr:
		return false
	return not in_view(npc.global_position, fb)


## True unless npc's flock (not the murmuration: it keeps to its roost and
## goes only beyond despawn_radius) has a member in view or not yet behind
## the travelling player.
func _flock_gone(npc: NpcBird, c: Vector3, fb: Bird) -> bool:
	if npc.flock == null:
		return true
	if npc.flock.kind == "murmuration":
		return false
	for m in npc.flock.members:
		if not is_instance_valid(m) or not m.alive:
			continue
		var rel: Vector3 = (m as NpcBird).global_position - c
		if in_view((m as NpcBird).global_position, fb) or rel.dot(_drift) > -0.3 * rel.length() * _drift.length():
			return false
	return true


## Plan keys in the order their deficits are filled: by text, whatever order
## the dictionary holds them in or the StringNames were made in.
static func spawn_order(keys: Array) -> Array:
	var out := keys.duplicate()
	out.sort_custom(func(a: StringName, c: StringName) -> bool: return String(a) < String(c))
	return out


## Spawns up to `need` birds for plan key k (a whole flock for flocking
## species). Returns how many were spawned.
func _spawn_group(k: StringName, need: int, fb: Bird) -> int:
	var entry: Dictionary = _plan[k]
	var sp: StringName = entry["species"]
	var mass_override: float = entry["mass"]
	var solo: bool = entry["role"] == &"threat"
	var prof := SpeciesProfile.of(sp)
	var fs: Array = prof["flock_size"]
	# Only the ambient murmuration is one big flock; other flocks are small
	# groups (a dozen birds in one cluster leave the rest of the sky empty).
	# (A smaller budget plans a smaller murmuration - the Quest's 28 NPCs
	# plan 8 - and it must still form: with the species' own minimum of 12
	# its starlings flew alone and the Quest sky had no murmuration.)
	var fmin := mini(int(fs[0]), int(entry["count"])) if k == MURM_KEY else mini(int(fs[0]), LOOSE_FLOCK_MAX)
	var fmax := int(fs[1]) if k == MURM_KEY else mini(int(fs[1]), LOOSE_FLOCK_MAX)
	var flocking := not solo and float(prof["flock"]) >= 0.5 and need >= fmin
	var n := mini(need, fmax) if flocking else 1
	# The widest individual this key can produce (masses vary by up to +9%):
	# spawn distances are checked against it.
	var span := SizeRules.wingspan_for_mass(mass_override if mass_override > 0.0 else float(SizeRules.species_data(sp)["mass"]) * 1.09)
	# A flocking species short of a whole flock tops up an existing flock of
	# its kind (joining it out of view) rather than flying alone.
	if not flocking and not solo and float(prof["flock"]) >= 0.5:
		var fl := _flock_to_join(sp, fb)
		if fl != null:
			var at0 := _spawn_point(sp, span, fb)
			if at0 != Vector3.INF:
				var joiner := _make_npc(k, sp, mass_override, at0)
				joiner.flock = fl
				fl.members.append(joiner)
				joiner.set_state(NpcBird.State.FLOCK)
				return 1
	# Perched spawns for perching loners (hawks on poles, wrens in bushes);
	# threats always arrive on the wing, near the player.
	if not flocking and not solo and _rng.randf() < float(prof["perch"]) * 0.5:
		var perch := _spawn_perch(sp, span, fb)
		if perch != null:
			var npc := _make_npc(k, sp, mass_override, perch.position)
			npc.land_on(perch, true)
			npc.set_state(NpcBird.State.PERCHED)
			return 1
	var at := _spawn_point(sp, span, fb)
	if at == Vector3.INF:
		return 0
	if not flocking:
		_make_npc(k, sp, mass_override, at)
		return 1
	var home := Vector3(at.x, 0.0, at.z)
	var kind: String = prof["flock_kind"]
	# One murmuration is the ambient spectacle over its roost; starlings in
	# any other role fly as ordinary flocks that follow the player.
	if kind == "murmuration" and k != MURM_KEY:
		kind = "loose"
	if kind == "murmuration":
		var roosts := habitat.landmarks_of("roost")
		var c := focus_point() if fb else Vector3.ZERO
		for r in roosts:
			var rp: Vector3 = r["position"]
			if Vector2(rp.x - c.x, rp.z - c.z).length() < _sky * 1.5:
				home = Vector3(rp.x, 0.0, rp.z)
				break
	var fl := FlockGroup.new(_next_id, sp, kind, home, habitat, _rng.randi())
	_next_id += 1
	_flocks.append(fl)
	for i in n:
		# Scatter the members round the checked anchor point, each checked
		# again (out of view, beyond its near distance, in open air): a
		# member must never pop in at the edge of the view cone either.
		var p := at
		for attempt in 4:
			var off := Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-0.5, 0.5), _rng.randf_range(-1, 1)) * maxf(span * 6.0, 2.0)
			var q := at + off
			if _spawn_ok(q, span, fb):
				p = q
				break
		var npc := _make_npc(k, sp, mass_override, p)
		npc.flock = fl
		fl.members.append(npc)
		npc.set_state(NpcBird.State.FLOCK)
	return n


func _flock_to_join(sp: StringName, _fb: Bird) -> FlockGroup:
	for fl in _flocks:
		var cap := int(SpeciesProfile.of(sp)["flock_size"][1]) + 4 if fl.kind == "murmuration" else LOOSE_FLOCK_MAX + 1
		if fl.species == sp and fl.size() < cap:
			return fl
	return null


## False once the player has grown out of reach of a planned threat
## species (no individual of its band could eat it any more, or the apex
## eagles are too light): the plan must be re-made now, not at the next 8%
## of growth, or every hunter it spawns is outgrown on arrival.
func _threats_still_qualify(pm: float) -> bool:
	for k in _plan:
		if not _is_threat_key(k):
			continue
		var e: Dictionary = _plan[k]
		if k == APEX_KEY:
			if not (SizeRules.can_eat(float(e["mass"]), pm) and would_hunt(&"eagle", float(e["mass"]), pm)):
				return false
		elif _hunter_band(e["species"], pm).x <= 0.0:
			return false
	return true


## Mass range (lo, hi) of individuals of this species that could eat prey
## of mass pm and would hunt it (a real hunter, the meal worth its while),
## or (0, 0) if there are none.
static func _hunter_band(id: StringName, pm: float) -> Vector2:
	if float(SpeciesProfile.of(id)["hunt"]) < THREAT_MIN_DRIVE:
		return Vector2.ZERO
	var base: float = SizeRules.species_data(id)["mass"]
	var lo := maxf(base * 0.91, pm * SizeRules.EAT_RATIO * 1.02)
	var hi := minf(base * 1.09, _max_hunter_mass(pm) * 0.98)
	return Vector2(lo, hi) if hi > lo else Vector2.ZERO


## Heaviest a hunter may be and still find prey of mass pm worth a chase
## (SizeRules.is_worthwhile is monotonic in the eater's mass).
static func _max_hunter_mass(pm: float) -> float:
	var lo := pm * SizeRules.EAT_RATIO
	var hi := pm * 40.0
	if not SizeRules.is_worthwhile(lo, pm):
		return lo
	for i in 30:
		var mid := (lo + hi) * 0.5
		if SizeRules.is_worthwhile(mid, pm):
			lo = mid
		else:
			hi = mid
	return lo


func _make_npc(k: StringName, sp: StringName, mass_override: float, at: Vector3) -> NpcBird:
	var npc := NpcBird.new()
	npc.managed = true
	var base: float = SizeRules.species_data(sp)["mass"]
	# Individuals vary a little; +-9% keeps same-species cannibalism impossible
	# (1.09 / 0.91 < EAT_RATIO).
	var m := mass_override if mass_override > 0.0 else base * _rng.randf_range(0.91, 1.09)
	var entry: Dictionary = _plan.get(k, {})
	var pm := float(entry.get("pm", -1.0))
	var fb0 := _focus()
	if fb0 != null and pm > 0.0:
		pm = fb0.mass  # the player as it is now (the plan may be up to 8% old)
	if String(k).ends_with(HUNTER) and pm > 0.0:
		# A hunter of the player: inside the part of its species' band that
		# can eat the player and still thinks it worth the chase.
		var band := _hunter_band(sp, pm)
		if band.x > 0.0:
			m = lerpf(band.x, band.y, _rng.randf())
	npc.configure(sp, m, _rng.randi(), habitat)
	npc.name = "%s_%d" % [sp, _next_id]
	# A whole sky spawned in one tick must not integrate in lockstep
	# (NpcBird._stagger): phases in turn, no random draw.
	npc.set_tick_phase(_next_id)
	_next_id += 1
	var fb := _focus()
	# Offsets are in sky radii (the sky scales with the player).
	var off := Vector3(_rng.randf_range(-1, 1), 0.0, _rng.randf_range(-1, 1)) * 0.4
	_npc_offset[npc.get_instance_id()] = off
	var c := focus_point()
	npc.home = Vector3(at.x, 0.0, at.z)
	npc.home_radius = _sky
	_place_home(npc, k, off, fb)
	if entry.get("role", &"") == &"threat":
		npc.player_interest = THREAT_INTEREST
		npc.player_range = maxf(1.0, THREAT_WATCH_M / maxf(float(npc.profile["hunt_range_m"]), 1.0))
	add_child(npc)
	var dir := Vector3(_rng.randf_range(-1, 1), 0.0, _rng.randf_range(-1, 1))
	if fb:
		dir = (c - at)
		dir.y = 0.0
		dir = dir.rotated(Vector3.UP, _rng.randf_range(-0.8, 0.8))
	dir = dir.normalized() if dir.length_squared() > 1e-4 else Vector3.FORWARD
	npc.global_position = at
	npc.flight.set_velocity(dir * npc.flight.cruise)
	npc.global_transform = Transform3D(Basis.looking_at(dir, Vector3.UP), at)
	# A new bird shows its model's fields at once, not smoothed in from the
	# model's defaults (the birds contract: snap() after spawning).
	if npc.model:
		npc.model.snap()
	_npcs.append(npc)
	_npc_key[npc.get_instance_id()] = k
	_born[npc.get_instance_id()] = _t
	npc.state_changed.connect(_on_state_changed)
	npc.behaviour.connect(_on_behaviour)
	npc.ate.connect(_on_ate)
	npc.caught.connect(_on_caught)
	_stats["spawned"] += 1
	npc_spawned.emit(npc)
	return npc


## How close to the player a bird of this wingspan may appear (out of view
## as well): where it spans under 1/SPAWN_SPANS rad (0.38 deg, ~8 px on a
## Quest Pro) even if the player turned straight to it - a moth, wren or
## sparrow from 40 m, a swallow from 50 m, a starling from 60 m, a pigeon or
## anything bigger from spawn_min (70 m) as before. Why: out-of-view spawns
## round a player looking where it flies can only be on its flanks, so at a
## fixed 70 m they were >= 68 m to its side, and prey slower than the player
## (moths, wrens and swallows for the small sizes) never closed that gap: a
## travelling sparrow flew through an empty sky (worthwhile prey within
## 60 m about half the time; ~90% now, tests/unit/ai/ecosystem_test.gd).
func spawn_distance(span: float) -> float:
	return clampf(SPAWN_SPANS * span, SPAWN_MIN_SMALL, spawn_min)


## True if a bird of this span appearing at p could be noticed: inside the
## player's view cone or nearer than its near distance.
func spawn_visible(p: Vector3, span: float, fb: Bird = null) -> bool:
	if fb == null:
		fb = _focus()
	if fb == null:
		return false
	var rel := p - _eye(fb)
	var d := rel.length()
	if d < spawn_distance(span):
		return true
	return _view_dir(fb).dot(rel / d) > cos(deg_to_rad(view_half_angle_deg))


## A spawn spot: unnoticeable (spawn_visible), in open air, and - while the
## player travels - not behind it (a bird put there would be left behind
## at once: spawned only to be recycled).
func _spawn_ok(p: Vector3, span: float, fb: Bird) -> bool:
	if fb and spawn_visible(p, span, fb):
		return false
	if _behind_traveller(p, fb):
		return false
	return not habitat.blocked(p, maxf(span * 2.0, 2.0))


## A bearing (radians, x-z plane) to try a spawn at: anywhere round the
## player, or - while it travels, when only its flanks are both out of view
## and not behind it - on a flank, so most tries are valid.
func _spawn_bearing(fb: Bird) -> float:
	if not travelling():
		return _rng.randf() * TAU
	var da := atan2(_drift.z, _drift.x)
	var side := 1.0 if _rng.randf() < 0.5 else -1.0
	return da + side * _rng.randf_range(deg_to_rad(70.0), deg_to_rad(108.0))


func _behind_traveller(p: Vector3, fb: Bird) -> bool:
	if fb == null or not travelling():
		return false
	var rel := p - _eye(fb)
	rel.y = 0.0
	return rel.dot(_drift.normalized()) < SPAWN_BEHIND_COS * rel.length()


## Furthest a bird of this span is spawned from the player: SPAWN_MAX_SKIES
## sky radii (its sky, see sky_radius()), at most spawn_max.
func _spawn_far(span: float) -> float:
	return clampf(_sky * SPAWN_MAX_SKIES, spawn_distance(span) + 30.0, maxf(spawn_max, spawn_distance(span) + 30.0))


## Out of view, spawn_distance().._spawn_far() from the player; of the valid
## candidates the one nearest the focus point (where the player is going),
## with a little seeded jitter so spawns do not stack on one spot.
func _spawn_point(sp: StringName, span: float, fb: Bird) -> Vector3:
	var alt: Array = SpeciesProfile.of(sp)["alt"]
	var c := _eye(fb) if fb else Vector3.ZERO
	var fp := focus_point() if fb else Vector3.ZERO
	var best := Vector3.INF
	var best_s := INF
	var valid := 0
	for attempt in 24:
		var p := Vector3.ZERO
		if fb:
			var a := _spawn_bearing(fb)
			var d := _rng.randf_range(spawn_distance(span), _spawn_far(span))
			p = Vector3(c.x + cos(a) * d, 0.0, c.z + sin(a) * d)
		else:
			var a2 := _rng.randf() * TAU
			var r := sqrt(_rng.randf()) * habitat.bounds_radius * 0.7
			p = Vector3(cos(a2) * r, 0.0, sin(a2) * r)
		p = habitat.clamp_inside(p, minf(110.0, habitat.bounds_radius * 0.3))
		var top := minf(float(alt[1]), habitat.ceiling * 0.7)
		p.y = habitat.ground(p.x, p.z) + _rng.randf_range(float(alt[0]), maxf(top, float(alt[0]) + 1.0))
		p = habitat.clamp_inside(p, 40.0)
		if not _spawn_ok(p, span, fb):
			continue
		if fb == null:
			return p
		var score := Vector2(p.x - fp.x, p.z - fp.z).length() + _rng.randf() * 40.0
		if score < best_s:
			best_s = score
			best = p
		valid += 1
		if valid >= 6:
			break
	return best


func _spawn_perch(sp: StringName, span: float, fb: Bird) -> Perch:
	var kinds: Array = SpeciesProfile.of(sp)["perch_kinds"]
	var c := _eye(fb) if fb else Vector3.ZERO
	var fp := focus_point() if fb else Vector3.ZERO
	var best: Perch = null
	var best_s := INF
	for attempt in 4:
		var probe := Vector3.ZERO
		if fb:
			var a := _spawn_bearing(fb)
			var d := _rng.randf_range(spawn_distance(span), _spawn_far(span))
			probe = c + Vector3(cos(a) * d, 0.0, sin(a) * d)
		else:
			var a2 := _rng.randf() * TAU
			probe = Vector3(cos(a2), 0.0, sin(a2)) * sqrt(_rng.randf()) * habitat.bounds_radius * 0.8
		var list := habitat.find_perches(probe, 60.0, span, kinds)
		for p in list:
			if fb and (spawn_visible(p.position, span, fb) or _behind_traveller(p.position, fb)):
				continue
			if fb == null:
				return p
			var score := Vector2(p.position.x - fp.x, p.position.z - fp.z).length()
			if score < best_s:
				best_s = score
				best = p
			break
	return best


func _remove(npc: NpcBird, reason: StringName) -> void:
	var i := _npcs.find(npc)
	if i >= 0:
		_npcs.remove_at(i)
	_npc_key.erase(npc.get_instance_id())
	_npc_offset.erase(npc.get_instance_id())
	_born.erase(npc.get_instance_id())
	_far_t.erase(npc.get_instance_id())
	if npc.flock != null:
		npc.flock.remove(npc)
		if npc.flock.size() == 0:
			_flocks.erase(npc.flock)
		npc.flock = null
	if npc.brain:
		npc.brain.on_removed()
	_show_solos.erase(npc)
	npc.release_perch()
	# No bird may keep pointing at a freed one: a flock mate reads another
	# bird's `threat` in its own think (the alarm wave), before that bird's
	# tick would have dropped it. The brains tolerate a stale reference too;
	# this keeps the sky's state clean the moment a bird leaves it.
	for o in _npcs:
		if o.threat == npc:
			o.threat = null
		if o.target == npc:
			o.target = null
		if o.strike == npc:
			o.strike = null
	var d: Dictionary = _stats["despawned"]
	d[String(reason)] = d.get(String(reason), 0) + 1
	npc_despawned.emit(npc, reason)
	npc.alive = false
	if npc.get_parent() == self:
		remove_child(npc)
	npc.queue_free()


# ---------------------------------------------------------------- stats hooks

func _on_state_changed(npc: NpcBird, old: int, new_state: int) -> void:
	var e: Dictionary = _stats["entered"]
	var n: String = NpcBird.STATE_NAMES[new_state]
	e[n] = e.get(n, 0) + 1
	# A new hunt on the player (a stoop pulling out back into HUNT is not).
	if new_state == NpcBird.State.HUNT and old != NpcBird.State.STOOP and npc.target != null \
			and is_instance_valid(npc.target) and npc.target.is_player():
		_stats["hunts_on_player"] += 1


func _on_behaviour(_npc: NpcBird, what: StringName) -> void:
	var b: Dictionary = _stats["behaviour"]
	b[String(what)] = b.get(String(what), 0) + 1


func _on_ate(npc: NpcBird, prey: Bird) -> void:
	_stats["catches"] += 1
	if npc == _show_hunter:
		_stats["show_hunt_catches"] += 1
	var c: Dictionary = _stats["catches_by_species"]
	c[String(npc.species)] = c.get(String(npc.species), 0) + 1
	if prey != null and is_instance_valid(prey) and prey.is_player():
		_stats["ate_player"] += 1


func _on_caught(npc: NpcBird, by: Bird) -> void:
	var c: Dictionary = _stats["caught_by_species"]
	c[String(npc.species)] = c.get(String(npc.species), 0) + 1
	if by != null and is_instance_valid(by) and by.is_player():
		_stats["caught_by_player"] += 1
