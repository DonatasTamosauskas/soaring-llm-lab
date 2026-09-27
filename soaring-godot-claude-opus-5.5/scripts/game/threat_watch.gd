class_name ThreatWatch
extends RefCounted
## What the player should fear and what they should chase, for UI, audio
## and haptics. Owned by GameLoop, which emits Events.threat_changed /
## Events.target_changed from the results.
##
## Threat: every bird that can eat the player gets a raw level 0..1 from its
## time-to-contact (gap to catch distance / closing speed), weighted by
## whether it is pointed at the player, with a small floor for sheer
## proximity, and by its intent when it exposes one (intent_weight: one
## hunting someone else, or nothing, counts at NOT_HUNTING_WEIGHT). Each
## predator's raw level is smoothed ON ITS OWN (low-pass + slew limits: rises
## fast, falls slowly), so tracking noise never flickers a cue. The cue names
## ONE predator and reports THAT bird's own smoothed level - never another
## bird's - and the name is sticky against birds that are not attacking: a
## rival takes over only when its level beats the named one's by
## switch_margin for switch_hold_s, or when the named one has been quiet
## (below QUIET_LEVEL, shown as no threat) for switch_hold_s; a named bird
## that leaves the game (eaten, despawned, outgrown) is replaced at once.
## A REAL ATTACK is named at once (fix round 5): a bird hunting the player at
## attack strength (announce_level) takes the name the frame it gets there
## unless the named bird is itself a live attack that strikes at least as
## soon (see _strikes_first). Why (fix round 4 review): with one smoothed
## "worst level" and a name held only while the named bird's raw threat
## stayed above 0, an attacker that jinked for half a second handed its
## name - and its attack-level threat - to whichever bystander was nearby,
## and took it back when it turned in again: in the valley the HUD arrow,
## the haptic danger pattern and the predator's call hopped hunter ->
## bystander -> hunter every ~0.6 s during attacks (239 hops in 4.8
## attack-minutes), and a crow merely passing (own threat 0.04) was named at
## level 0.43. Why the attack rule (fix round 5 review): round 4's hold also
## held real attacks back behind a faintly shown bird - a bystander at
## 0.1-0.35, or a hunter that had already turned away and whose level was
## only decaying - while a bird hunting the player climbed to 0.4-0.8
## unnamed (516 masked episodes in 58 attack-minutes; with another hunter
## named at 0.66, a second one stooping from behind was named 0.13 s before
## contact). Jinks still never hand the name to a bystander: a bystander is
## not hunting the player.
##
## Target: among birds the player can eat AND that are worth eating
## (SizeRules.is_worthwhile), the best by worth x how catchable it is
## (chase_odds: near-equals escape; height_edge: prey below beats prey
## above; prey_ease: a drifting moth swarm beats a wary bird), distance and
## whether they are ahead - never one in cover (CatchRule.is_hidden),
## sheltering in a refuge the player is too wide to enter, or out of the
## player's REACH IN OPEN AIR (`space`: the line to it crosses the world's
## geometry, or it sits in clutter - a tree crown, a hedge, a wall within
## reach_clear() of it). A target that stops being reachable is dropped at
## once (core loop round, the lead's direction: through the real flight
## chain the ringed bird sat 15-37 m away inside tree crowns, the catch
## lesson timed out and a person following the ring flew into the trees).
## The current target is kept until it becomes invalid, or a rival scores
## clearly better (target_switch_ratio) after a minimum hold time - and never
## by preference while the player is closing on it (target_commit_s).
##
## Birds in cover are out of play (CatchRule.is_hidden): never a threat and
## never the target (their highlight still says what they are).
##
## Highlights (BirdModel.highlight): 1 = worthwhile prey, 2 = danger, 0 =
## neither — including prey too small to be worth it, which is how the loop
## visibly moves up the ladder as the player grows. Danger (2) marks only a
## bird that is HUNTING the player or has hunted it within
## DANGER_MARK_HOLD_S - the cue names a hunter the frame it sets off
## (warn_level), so the named attacker is marked (core loop round, the lead's
## direction: marks on
## every bird that could eat the player covered the harmless starling
## murmuration - 8-12 marks round a sparrow - and the attacker did not stand
## out). A bigger bird that is not after the player shows as itself.
##
## Distances are in multiples of the player's wingspan (the player's
## world_scale grows with their wingspan, so "40 spans" looks the same in the
## headset at every size), but never less than a few seconds of flight: see
## target_range_s.

## Seconds of time-to-contact at which the threat starts to register.
var ttc_horizon := 3.5
## The warning of an attack (core loop round, the lead's direction: "a
## telegraphed attack ... with an audible/visible warning early enough to
## evade"): a bird HUNTING the player within warn_range() of it is named and
## shown at least at warn_level from the moment it sets off - the HUD's
## arrow (from 0.12), its danger mark (highlight 2), a quiet heartbeat
## (audio, from 0.02) - not only once its time to contact is inside the
## horizon. The urgent cues still come with the attack itself: the level
## climbs with the time to contact to the haptic danger pulse (0.35), attack
## strength (0.3, ATTACK_LEVEL in GameLoop) and the predator's scream
## (0.6). A floor under attack strength: a hunter circling out there is
## announced, not an attack under way. (Tried at 0.35 over 60 m: the whole
## approach counted as an attack - the modelled person evaded ~20% of its
## play from hunters 40-60 m out, none of the 24 attacks in 60 minutes got
## within a wingspan, and nothing was ever eaten.)
var warn_level := 0.2
## warn_range(): at least WARN_MIN_M, or this many of the hunter's
## wingspans (a big raptor is seen and heard from further out).
var warn_spans := 40.0
const WARN_MIN_M := 60.0
## A bird that hunted the player keeps its danger mark this long after it
## stopped (a hunter breaking off and coming round again stays marked).
const DANGER_MARK_HOLD_S := 3.0
## A predator not pointed at the player is at most this dangerous.
var unaimed_weight := 0.55
## Proximity floor: within this many *predator* wingspans a big bird is a
## threat (level up to proximity_weight) even when it is not closing.
var proximity_spans := 6.0
var proximity_weight := 0.4
## Level smoothing, per predator: an asymmetric low-pass (fast attack, slow
## release) follows the upper envelope of its raw level, so tracking noise on
## a flapping predator does not make the cue flutter...
var rise_tau := 0.06
var fall_tau := 0.4
## ...and hard slew limits, per second, bound it on top.
var rise_rate := 6.0
var fall_rate := 0.9
## A rival must be this much more threatening than the named predator (both
## smoothed levels)...
var switch_margin := 0.15
## ...for this long (s) to take the name; the named predator also keeps it
## until it has been quiet this long. 0.5 s: an attacker's jink (it stops
## closing for 0.3-0.8 s and turns in again) never hands its name to a
## bystander, while a real new attacker is named within about half a second.
var switch_hold_s := 0.5
## Below this smoothed level a named predator is "quiet": the cue shows
## nothing about it (the UI calls a threat real from 0.1, UIRoot.REAL_THREAT;
## the HUD draws its arrow from 0.12, the haptics pulse from 0.35)...
const QUIET_LEVEL := 0.1
## ...and a rival at this level (an attack: GameLoop.ATTACK_LEVEL) takes the
## name from a quiet one at once - nothing shown can hop, and an attack is
## never announced late. (With the hold alone, a faint bystander holding the
## name delayed the warning of 32 attacks in 20 valley minutes by up to
## 0.5 s - a quarter of a sparrow's warning time.) A rival HUNTING the player
## at this level takes it at once from any named bird that is not itself a
## live attack striking at least as soon (_strikes_first).
var announce_level := 0.3
## Two birds both attacking the player: the name goes to the one that will
## strike first - a rival whose time-to-contact is shorter by this fraction
## of the cue's horizon (0.14 s for a sparrow, more for bigger, slower birds)
## and whose level is higher, or whose level is higher by switch_margin.
## Under it the name stays: a 0.3 m wobble in two hawks' lead (0.1 s of
## time-to-contact) never moves it (threat_test).
var strike_margin := 0.04
## Target search radius and highlight radius, in player wingspans.
var target_range_spans := 45.0
var highlight_range_spans := 70.0
## ...or, if further, this many seconds of flight at the player's cruise
## speed. The AI's Ecosystem spreads birds over metric radii (70-230 m), so
## for a small player the nearest worthwhile bird is typically 80-120 of its
## wingspans away: a range in wingspans alone would leave a sparrow's cue
## and highlights empty. Birds you could reach in a few seconds are always
## in play. (Core loop round: the target's 4 s -> 6 s, as far as the
## highlights reach - the sky's moth swarms are placed just beyond that, and
## the ring leads the player to them as it comes in range.)
var target_range_s := 6.0
var highlight_range_s := 6.0
## Hysteresis on ranges: once in, a bird stays in until range * this.
var range_hysteresis := 1.15
## ...and the target's own: once named, it stays in range until the range x
## this (core loop fix round 1: 1.15 dropped a bird the player was still
## chasing as it drew ahead, ~1 a minute through the real chain).
var target_range_hysteresis := 1.3
## Prey behind this angle from the player's heading are never auto-targeted.
var target_max_angle_deg := 110.0
## A rival target must score this many times the current one to take over...
var target_switch_ratio := 3.0
## ...and only after the current one has been held this long. An invalid
## target (eaten, hidden, sheltered, out of range or sight, no longer worth
## it) is replaced at once regardless.
var target_min_hold_s := 10.0
## ...and never while the player is closing on it: from the moment it is
## named, every time the player gets TARGET_PROGRESS closer than it has been,
## the target is committed for this long (x the square root of body time,
## like the catch assist: an eagle closes slower in seconds). A chase the
## player is winning is never taken from it; one it has stopped gaining on
## is free to go to a much better bird. (Progress is measured against the
## closest the player has been, not against a moment of a sliding window:
## fix round 5 tried the latter, and through the real flight chain a person
## wedged against a wall near its target - the distance going back and forth
## - kept the target committed and stayed wedged; integration's whole-game
## catch test went from 3 catches in 6 minutes to 0.)
## Why (fix round 5 review, and integration round 2): at 1.35x after 1.5 s
## the cue moved on from a bird the player was still chasing ~9 times a
## minute (median hold 2.2 s, 65% within 3 s, the abandoned bird 32
## wingspans away), and through the real flight chain 55-80% of the chases
## of a person following the cue ended because it named another bird.
var target_commit_s := 2.5
## The catch lesson (GameLoop keeps lesson_active current: lesson prey is up):
## the lesson's moths (duck-typed `lesson`) are the target whenever one is
## reachable - scored LESSON_PREFERENCE x, looked for out to LESSON_RANGE_M
## and all round, and taken from any other target at once (core loop fix
## round 1: the card said "Catch a Moth" while the ring stayed on another
## bird for 6-23 s, and a player cruising 80 m up had its lesson moths out of
## the 54 m range - no ring, no arrow, until the lesson timed out).
var lesson_active := false
const LESSON_PREFERENCE := 50.0
const LESSON_RANGE_M := 120.0
const TARGET_PROGRESS := 0.05
## Also committed while the player is closing on it at speed: TARGET_PROGRESS
## nearer than at any moment of the last TARGET_WINDOW_S, flying at
## TARGET_CLOSING_SPEED x its cruise speed or more (core loop fix round 1:
## through the real flight chain the ring left a bird the player was gaining
## on - coming round again after a missed pass, not yet nearer than its best
## - 1.3-4 times a minute; the speed floor keeps a person wedged at a wall
## near its target free to be given another, fix round 5's lesson).
const TARGET_WINDOW_S := 2.0
const TARGET_CLOSING_SPEED := 0.3
## The player's body time (SizeRules.time_scale; GameLoop keeps it current).
var body_time := 1.0
## The world's refuges (GameLoop keeps this current): prey sheltering in one
## the player is too wide to enter is never the target. Assigning the list
## builds refuge_index (RefugeIndex), which the pass queries.
var refuges: Array[Dictionary] = []:
	set(v):
		refuges = v
		if not _index_given:
			refuge_index = RefugeIndex.new(v) if not v.is_empty() else null
var refuge_index: RefugeIndex = null
var _index_given := false
## The physics space whose static geometry (layer 1) can hide prey from the
## player (GameLoop passes the player's; null = open air, all reachable). The
## cue names only prey the player can reach in open air: the line from the
## player to it is clear (in the valley two in three of a big player's chases
## ended with the prey out of sight behind a house, a crown or a cliff within
## a few seconds - fix round 3) AND nothing solid is within reach_clear() of
## the bird itself (core loop round: through the real flight chain a bird
## seen through a gap in a crown, or perched on a branch inside it, was ringed
## and the person following the ring flew into the tree - 63 of 77 chases of
## integration's whole-game catch test ended wedged). The ray and the sphere
## are cast only for a bird that would matter (the target, or one that beats
## the best so far), and each answer is kept for SIGHT_CACHE_S.
var space: PhysicsDirectSpaceState3D = null
const SIGHT_CACHE_S := 0.25
## reach_clear(): open air round the prey, at least CLEAR_MIN_M, or this
## many of the player's wingspans (a person steering a body by its arms
## cannot thread a bird out of a crown; a big bird cannot fly in there).
var clear_spans := 3.0
const CLEAR_MIN_M := 1.2
## A target whose line of sight is cut keeps the ring this long after it was
## last seen (core loop fix round 1: dropped at once, the ring left a
## still-valid bird 4-13 times a minute through the real chain - a trunk, a
## roof or a crown edge crossing the line for a second or two - and hopped
## to another). (Fix round 5 held every lost target 1 s, and a 2 s version,
## for birds in crowns too, made a person following the cue wedge itself at
## the geometry again and again: a bird with geometry round it is still
## dropped soon, CLUTTER_GRACE_S.)
const SIGHT_GRACE_S := 2.0
## ...but a target with geometry round it (in a crown, against a wall: not in
## open air) only this long - the lead's direction, "drop a target that
## becomes hidden instead of holding it": one that has gone into cover
## (CatchRule.is_hidden) is dropped at once; one diving into a crown keeps
## the ring until it is in (tuning seeds: at 0.75 s the ring left a fleeing
## bird the moment it reached the leaves, 0.5-0.7 times a minute).
const CLUTTER_GRACE_S := 1.5
## ...and the target's own open-air check uses this share of reach_clear()
## (hysteresis: a bird that has flown past a crown is not dropped for
## brushing it; one that has gone into it still is).
const TARGET_CLEAR_KEEP := 0.5
## instance id -> _Sight.
var _sight := {}
var _now := 0.0
var _clear_q: PhysicsShapeQueryParameters3D = null
var _clear_shape: SphereShape3D = null


## Takes the refuges with their index built already: GameLoop builds one per
## world and shares it (building a second, identical one here was wasted
## work at every world generation, and memory - fix round 3 review).
func use_refuges(list: Array[Dictionary], index: RefugeIndex) -> void:
	_index_given = true
	refuges = list
	_index_given = false
	refuge_index = index

## Outputs.
## The named predator's own smoothed threat (0 when nobody is named): what
## the HUD, audio and haptics show, about the bird they point at.
var level := 0.0
## The worst raw (unsmoothed) threat of any predator this frame (charts).
var raw_level := 0.0
## The worst smoothed threat of any predator: whether the player is under
## attack at all, whoever is named (GameLoop's attack respite reads it).
var peak_level := 0.0
## The same over the birds hunting the player (or within DANGER_MARK_HOLD_S
## of hunting it; a bird that shows no intent counts): what GameLoop calls
## an attack (core loop round, second pass - a bird on a near-collision
## course that was not after the player reached attack strength at its
## 0.35 weight, and its "attack" started the full attack respite in the
## first flight: the sky's first real attack came a minute or two late).
var hunt_peak_level := 0.0
var predator: Bird = null
var predator_ttc := INF
## Why the named predator last changed: &"new" (nobody was named), &"gone"
## (the named bird left the game or stopped being a predator), &"attack" (a
## real attack named at once: a rival at announce_level while the named bird
## was quiet, or a rival hunting the player at announce_level that the named
## bird does not strike before - _strikes_first), &"challenge" (a rival
## clearly worse for switch_hold_s), &"quiet" (the named bird quiet for
## switch_hold_s), &"faded" (to nobody). Diagnostics and tests.
var last_change := &""
var target: Bird = null
var target_score := 0.0
## The player is closing on the target (see target_commit_s): no preference
## switch now.
var target_committed := false
## Why the target last changed: &"preference" (a rival target_switch_ratio x
## better after the hold, not while committed) or why the old one stopped
## being a target: &"new" (there was none), &"gone" (eaten, despawned),
## &"hidden", &"sheltered", &"outgrown" (no longer worth it), &"range",
## &"sight" (the line to it blocked), &"clutter" (geometry round it: no
## longer in open air). Diagnostics.
var last_target_change := &""
## instance_id -> 0/1/2, the last highlight written per bird.
var highlights := {}

var _target_held := 0.0
## Closest distance to the target since it was named, and when the player
## last got TARGET_PROGRESS closer than that (the watch's clock).
var _target_best_d := INF
var _target_progress_at := -INF
## [time, distance] samples of the target over the last TARGET_WINDOW_S.
var _target_hist: Array[Vector2] = []
## Every bird that can eat the player (instance id -> _Threat): its geometry
## (wingspan and body radius, recomputed only when its mass changes -
## SizeRules' log/exp per call made up a third of the watch pass with 60
## birds) and its own raw and smoothed threat.
var _threats := {}
## Every live bird the pass has seen (instance id -> _Threat, the same
## record once it is a predator): what does not change from frame to frame
## is looked up once - its BirdModel, whether it exposes intent - and
## records of birds not seen in a pass are pruned after it (fix round 5:
## round 4's per-bird property lookups and erases cost ~1.5 µs a bird, a
## worst-case frame of 60 birds ~0.32 ms under load).
var _recs := {}
var _frame := 0
## How long a rival has beaten the named predator by switch_margin, and how
## long the named predator (or nobody) has been quiet (s).
var _challenge_for := 0.0
var _quiet_for := 0.0


class _Threat:
	var mass := -1.0
	var span := 0.0
	var radius := 0.0
	var raw := 0.0
	var level := 0.0
	var ttc := INF
	## Hunting the player (intent in full: intent_weight 1).
	var hunting := false
	## When it was last seen hunting the player (the watch's clock).
	var hunted_at := -INF
	## A predator of the player in the last pass (it is in _threats).
	var is_pred := false
	## The pass (_frame) that last saw the bird alive.
	var seen := 0
	## Whether the bird exposes intent (a `target` property), once.
	var has_intent := false
	## Its BirdModel if it has one with a `highlight` (null: none yet - asked
	## again every MODEL_RECHECK passes, a model may come after the bird).
	var model: Object = null
	var model_at := -1000000

	func _init(q: Bird) -> void:
		has_intent = &"target" in q


## Whether rival track s, hunting the player at attack strength, is a real
## attack the named track c (null: nobody) does not strike before: c is
## quiet, harmless right now (its own raw threat under QUIET_LEVEL: it has
## turned away and its level is only decaying) or not hunting the player (a
## bystander, whatever level it shows) - or s will strike sooner: its
## time-to-contact shorter by strike_margin of the horizon and its level
## above c's threat right now (c's raw: a hunter that has made its pass and
## is flying off keeps a high smoothed level for a while, but it is not the
## attack any more), or its level above that by switch_margin.
func _strikes_first(s: _Threat, c: _Threat) -> bool:
	if c == null or c.level < QUIET_LEVEL or c.raw < QUIET_LEVEL or not c.hunting:
		return true
	if s.level > c.raw + switch_margin:
		return true
	return s.level > c.raw and s.ttc < c.ttc - strike_margin * ttc_horizon


class _Sight:
	var checked_at := -INF
	var seen_at := -INF
	var visible := true
	## Not reachable because of geometry round the bird (not the line to it).
	var clutter := false


func reset() -> void:
	level = 0.0
	raw_level = 0.0
	peak_level = 0.0
	hunt_peak_level = 0.0
	predator = null
	predator_ttc = INF
	target = null
	target_score = 0.0
	target_committed = false
	last_target_change = &""
	_target_held = 0.0
	_target_best_d = INF
	_target_progress_at = -INF
	_target_hist.clear()
	_challenge_for = 0.0
	_quiet_for = 0.0
	last_change = &""
	_threats.clear()
	_recs.clear()
	_sight.clear()


## A predator's own smoothed threat as the cue last computed it (0 for a bird
## that is not a predator of the player, or unknown).
func level_of(q: Bird) -> float:
	var t: _Threat = _threats.get(q.get_instance_id()) if q != null else null
	return t.level if t != null else 0.0


## Whether q hunted the player within DANGER_MARK_HOLD_S (the danger mark's
## hold).
func hunted_recently(q: Bird) -> bool:
	var t: _Threat = _threats.get(q.get_instance_id()) if q != null else null
	return t != null and _now - t.hunted_at <= DANGER_MARK_HOLD_S


## A predator's own raw threat as the cue last computed it (0 if unknown).
func raw_of(q: Bird) -> float:
	var t: _Threat = _threats.get(q.get_instance_id()) if q != null else null
	return t.raw if t != null else 0.0


## Time-to-contact (s) of predator q reaching player p, INF if not closing.
## contact is the centre distance at which q catches p.
static func time_to_contact(p_pos: Vector3, p_vel: Vector3, q_pos: Vector3, q_vel: Vector3, contact: float) -> float:
	var rel := q_pos - p_pos
	var dist := rel.length()
	var gap := maxf(dist - contact, 0.0)
	if gap <= 0.0:
		return 0.0
	var closing := -rel.dot(q_vel - p_vel) / maxf(dist, 1e-6)
	if closing <= 0.05:
		return INF
	return gap / closing


## Instantaneous threat of q to p, 0..1.
func threat_of(p: Bird, q: Bird, rule: CatchRule) -> float:
	var pp := p.get_body_position()
	var qp := q.get_body_position()
	var contact := rule.contact_distance(q.get_body_radius(), q.get_wingspan(), q.is_player(), p.get_body_radius(),
			p.is_player())
	var ttc := time_to_contact(pp, p.velocity, qp, q.velocity, contact)
	return _threat_level(pp, qp, q.get_forward(), q.get_wingspan(), contact, ttc) * intent_weight(q, p)


## Intent: a bird that exposes what it is hunting (NpcBird.target; SimBird
## mirrors it) and is hunting someone else, or nothing, is a much smaller
## threat than one hunting the player - birds read that intent from each
## other (the AI's prey flee a hunter chasing *them* on sight and only keep
## clear of one passing by), and a cue that fires for every big bird that
## crosses the player's path would cry wolf. Birds that do not expose it
## count in full.
const NOT_HUNTING_WEIGHT := 0.35


static func intent_weight(q: Bird, p: Bird) -> float:
	if not (&"target" in q):
		return 1.0
	return 1.0 if q.get(&"target") == p else NOT_HUNTING_WEIGHT


func _threat_level(pp: Vector3, qp: Vector3, q_fwd: Vector3, q_span: float, contact: float, ttc: float) -> float:
	var rel := qp - pp
	var dist := maxf(rel.length(), 1e-6)
	var aim := clampf(q_fwd.dot(-rel / dist), 0.0, 1.0)
	var ttc_term := 0.0
	if ttc < ttc_horizon:
		ttc_term = (1.0 - ttc / ttc_horizon) * lerpf(unaimed_weight, 1.0, aim)
	var gap := maxf(dist - contact, 0.0)
	var prox := clampf(1.0 - gap / (proximity_spans * q_span), 0.0, 1.0) * proximity_weight
	return maxf(ttc_term, prox)


## One evaluation pass over all birds. Returns a bit mask of what changed:
## 1 = threat level or predator, 2 = target. apply_highlights writes
## BirdModel.highlight on birds that have a `model`.
func update(p: Bird, birds: Array[Bird], dt: float, rule: CatchRule, apply_highlights: bool = true) -> int:
	var old_level := level
	var old_pred := predator
	var old_target := target
	_now += dt
	var pp := p.get_body_position()
	var pv := p.velocity
	var pm := p.mass
	var pr := p.get_body_radius()
	var pspan := p.get_wingspan()
	var pfwd := p.get_forward()
	var p_is_player := p.is_player()
	var hl_r := highlight_range(pm)
	var tg_r := target_range(pm)
	var cos_max := cos(deg_to_rad(target_max_angle_deg))
	var edible_limit := pm / SizeRules.EAT_RATIO  # prey must weigh <= this
	var danger_limit := pm * SizeRules.EAT_RATIO  # predators weigh >= this

	# Per-predator smoothing factors for this step (the same for every bird).
	var a_up := 1.0 - exp(-dt / rise_tau)
	var a_down := 1.0 - exp(-dt / fall_tau)
	var best_raw := 0.0
	var peak := 0.0
	var hunt_peak := 0.0
	# The named predator's track, and the strongest other predator (rival).
	var cur: _Threat = null
	var rival: _Threat = null
	var rival_bird: Bird = null
	# Other birds hunting the player at attack strength (real attacks), and
	# their tracks: a few at most.
	var strikers: Array[Bird] = []
	var striker_tracks: Array[_Threat] = []
	# Every bird hunting the player at attack strength with a live raw threat,
	# the named one included (the no-mask rule below).
	var live_hunters: Array[Bird] = []
	var live_tracks: Array[_Threat] = []
	var best_score := 0.0
	var best_prey: Bird = null
	var best_lesson := false
	var cur_target_score := -1.0
	var cur_lesson := false

	_frame += 1
	var n_seen := 0
	# An NPC's strike on the player reaches reach_k of its wingspan past the
	# two bodies (CatchRule.contact_distance, linear in the span).
	var reach_k := rule.reach_margin(1.0, false, p_is_player)
	var horizon := ttc_horizon
	for q in birds:
		if q == p:
			continue
		var id := q.get_instance_id()
		if not q.alive:
			if highlights.has(id):
				if apply_highlights:
					_set_highlight(q, 0)
				highlights.erase(id)
			continue  # (its records are pruned below: not seen alive)
		var g: _Threat = _recs.get(id)
		if g == null:
			g = _Threat.new(q)
			_recs[id] = g
		g.seen = _frame
		n_seen += 1
		var qp := q.get_body_position()
		var rel := qp - pp
		var d2 := rel.length_squared()
		var qm := q.mass
		var hl := 0
		var known: int = highlights.get(id, 0)
		if qm >= danger_limit:
			if not g.is_pred:
				g.is_pred = true
				_threats[id] = g
			if g.mass != qm:
				g.mass = qm
				g.span = q.get_wingspan()
				g.radius = q.get_body_radius()
			var qspan := g.span
			# Time-to-contact and threat (time_to_contact and _threat_level,
			# inlined: this runs for every predator every frame).
			var contact := g.radius + pr + qspan * reach_k
			var dist := sqrt(d2)
			var gap := maxf(dist - contact, 0.0)
			var ttc := 0.0
			if gap > 0.0:
				var closing := -rel.dot(q.velocity - pv) / maxf(dist, 1e-6)
				ttc = gap / closing if closing > 0.05 else INF
			var intent := 1.0
			if g.has_intent and q.get(&"target") != p:
				intent = NOT_HUNTING_WEIGHT
			var lv := 0.0
			# In cover: out of play (no threat), highlighted by size only.
			if not CatchRule.is_hidden(q):
				var ttc_term := 0.0
				if ttc < horizon:
					var aim := clampf(q.get_forward().dot(-rel / maxf(dist, 1e-6)), 0.0, 1.0)
					ttc_term = (1.0 - ttc / horizon) * lerpf(unaimed_weight, 1.0, aim)
				var prox := clampf(1.0 - gap / (proximity_spans * qspan), 0.0, 1.0) * proximity_weight
				lv = maxf(ttc_term, prox) * intent
				# An attack is telegraphed from the moment it sets off
				# (warn_level, within warn_range() of the player).
				if intent >= 1.0 and g.has_intent and dist < warn_range(qspan):
					lv = maxf(lv, warn_level)
				if intent >= 1.0:
					g.hunted_at = _now
			# This bird's own smoothed level (see the header).
			var nl := g.level + (lv - g.level) * (a_up if lv > g.level else a_down)
			g.level = clampf(nl, g.level - fall_rate * dt, g.level + rise_rate * dt)
			if lv <= 0.0 and g.level < 0.01:
				g.level = 0.0
			g.raw = lv
			g.ttc = ttc
			g.hunting = intent >= 1.0
			best_raw = maxf(best_raw, lv)
			peak = maxf(peak, g.level)
			if g.hunting or _now - g.hunted_at <= DANGER_MARK_HOLD_S:
				hunt_peak = maxf(hunt_peak, g.level)
			if g.hunting and g.level >= announce_level and lv >= QUIET_LEVEL:
				live_hunters.append(q)
				live_tracks.append(g)
			if q == predator:
				cur = g
			else:
				if rival == null or g.level > rival.level:
					rival = g
					rival_bird = q
				# (A striker's raw threat is at attack strength too, core loop
				# fix round 1: one whose smoothed level alone is - its raw
				# 0.1-0.3, turned away and decaying - took the name back from
				# a live attack the no-mask rule below had named, A -> B -> A
				# through a bird that was not attacking, 3 times an
				# attack-minute in the mirror.)
				if g.hunting and g.level >= announce_level and lv >= announce_level:
					strikers.append(q)
					striker_tracks.append(g)
			# Marked as danger only while it hunts the player (or did within
			# DANGER_MARK_HOLD_S) - a bird that shows no intent counts as
			# hunting (intent_weight) - and a named bird that is not hunting
			# the player (named for passing close: the cue's arrow may point
			# at it) is not marked.
			var r := hl_r * (range_hysteresis if known == 2 else 1.0)
			if d2 <= r * r and _now - g.hunted_at <= DANGER_MARK_HOLD_S:
				hl = 2
		else:
			if g.is_pred:
				# Prey or a peer now (the player grew).
				g.is_pred = false
				_threats.erase(id)
			if qm <= edible_limit:
				# SizeRules.meal_value, inlined (qm <= edible_limit: edible).
				var ratio := qm / pm
				var worth := SizeRules.MEAL_CONVERSION * ratio * smoothstep(SizeRules.MEAL_DUST_RATIO,
						SizeRules.MEAL_FULL_RATIO, ratio)
				if worth >= SizeRules.WORTH_MIN:
					var r := hl_r * (range_hysteresis if known == 1 else 1.0)
					if d2 <= r * r:
						hl = 1
					var tr := tg_r * (target_range_hysteresis if q == target else 1.0)
					var is_lesson: bool = lesson_active and q.get(&"lesson") == true
					if is_lesson:
						tr = maxf(tr, LESSON_RANGE_M)
					# (In cover: out of play - never the target.)
					if d2 <= tr * tr and not CatchRule.is_hidden(q):
						var dist := sqrt(d2)
						var facing := pfwd.dot(rel / maxf(dist, 1e-6))
						if facing >= cos_max or q == target or is_lesson:
							var s := worth * chase_odds(ratio) * prey_ease(q, p) * height_edge(-rel.y, pspan) \
									/ (1.0 + dist / (8.0 * pspan)) * (0.35 + 0.65 * (facing + 1.0) * 0.5)
							if is_lesson:
								s *= LESSON_PREFERENCE
							# Sheltering where the player cannot follow: not a chase.
							# (Only asked of a bird that would matter - the current
							# target, or one that beats the best so far: the refuge
							# query is the pass's most expensive step.)
							if (q == target or s > best_score) and ((refuge_index != null and refuge_index.blocks(qp, pspan))
									or not _in_sight(q, pp, qp, q == target, pspan)):
								pass
							else:
								if q == target:
									cur_target_score = s
									cur_lesson = is_lesson
								if s > best_score:
									best_score = s
									best_prey = q
									best_lesson = is_lesson
		# Re-assert against the model's actual value, not just our cache:
		# another writer (the UI marks its target and threat) must not leave
		# a stale value behind. (The UI writes when the cue events fire, after
		# this pass: GameLoop re-asserts the birds it touched right after
		# emitting - reassert_highlight.)
		if apply_highlights:
			var m := g.model
			if m == null or not is_instance_valid(m):
				m = null
				if _frame - g.model_at >= MODEL_RECHECK:
					g.model_at = _frame
					var mv: Variant = q.get(&"model")
					if mv is Object and is_instance_valid(mv) and "highlight" in mv:
						m = mv
				g.model = m
			if m != null and (hl != known or hl != int(m.get(&"highlight"))):
				m.set(&"highlight", hl)
		if hl != known:
			if hl == 0:
				highlights.erase(id)
			else:
				highlights[id] = hl
	if _recs.size() > n_seen:
		_prune()

	# --- Threat: one named predator, its own level, a sticky name ---
	raw_level = best_raw
	peak_level = peak
	hunt_peak_level = hunt_peak
	var gone := false
	if predator != null and (not is_instance_valid(predator) or not predator.alive \
			or predator.mass < danger_limit or cur == null):
		# Gone (eaten, despawned, outgrown, no longer among the birds): the
		# name moves at once, and the level is the next bird's own - audio
		# and haptics never report a danger that no longer exists.
		predator = null
		cur = null
		gone = true
	var cur_level := cur.level if cur != null else 0.0
	var rival_level := rival.level if rival != null else 0.0
	_quiet_for = _quiet_for + dt if cur_level < QUIET_LEVEL else 0.0
	_challenge_for = _challenge_for + dt if cur != null and rival_level > cur_level + switch_margin else 0.0
	# A real attack the named bird does not strike before is named at once:
	# of the birds hunting the player at attack strength, the one that will
	# strike soonest (then the strongest).
	var strike: _Threat = null
	var strike_bird: Bird = null
	for k in strikers.size():
		var s := striker_tracks[k]
		if _strikes_first(s, cur) and (strike == null or s.ttc < strike.ttc
				or (s.ttc == strike.ttc and s.level > strike.level)):
			strike = s
			strike_bird = strikers[k]
	var take := &""
	var to: _Threat = null
	var to_bird: Bird = null
	if strike != null:
		take = &"attack" if cur != null else (&"gone" if gone else &"new")
		to = strike
		to_bird = strike_bird
	elif rival != null and rival_level > 0.0:
		if cur == null:
			take = &"gone" if gone else &"new"  # nobody named, or the named bird is gone
		elif rival.raw < QUIET_LEVEL:
			pass  # the name never moves to a bird that is no threat right now
		elif cur_level < QUIET_LEVEL and rival_level >= announce_level:
			take = &"attack"  # nothing shown about the named bird; an attack is on
		elif _challenge_for >= switch_hold_s - 1e-9:
			take = &"challenge"  # clearly worse, for long enough
		elif _quiet_for >= switch_hold_s - 1e-9 and rival_level > cur_level:
			take = &"quiet"  # the named bird has stopped being a threat
		to = rival
		to_bird = rival_bird
	if take != &"":
		predator = to_bird
		cur = to
		last_change = take
		# Every change of name starts both clocks again: even among birds too
		# faint to show, the name changes at most every switch_hold_s.
		_challenge_for = 0.0
		_quiet_for = 0.0
	elif gone or (cur != null and cur.level <= 0.0):
		predator = null  # faded out (or gone), and nobody else is a threat
		cur = null
		last_change = &"faded"
	# No live attack is ever masked (core loop fix round 1): a bird hunting
	# the player whose own level AND raw threat right now are both at attack
	# strength (announce_level) and switch_margin or more above the level
	# shown is named - the highest such. (Its raw threat too: a hunter that has made its pass and
	# is flying off still shows its decaying level, and at its proximity floor
	# a raw threat of 0.1-0.25 - it is not the attack; a second hunter
	# stooping in is, test_an_attack_is_named_at_once_behind_a_hunter_that_turned_away.)
	# (The rules above can leave one behind for a few frames: the named
	# hunter's level still rising to its raw threat while another is already
	# higher, or two hunters setting off together and the one striking first
	# named at the lower level - 5 episodes, 0.16 s in the mirror's 10 runs,
	# and 0.03 s in a held-out real-chain run.) Last, so it holds every frame;
	# the name then goes to the bird striking first once their levels are
	# within the margin (_strikes_first).
	var shown := cur.level if cur != null else 0.0
	var unmask: _Threat = null
	var unmask_bird: Bird = null
	for k in live_hunters.size():
		var h := live_tracks[k]
		if live_hunters[k] != predator and minf(h.level, h.raw) >= maxf(announce_level, shown + switch_margin) - 1e-9 \
				and (unmask == null or h.level > unmask.level):
			unmask = h
			unmask_bird = live_hunters[k]
	if unmask != null:
		predator = unmask_bird
		cur = unmask
		last_change = &"attack"
		_challenge_for = 0.0
		_quiet_for = 0.0
	level = cur.level if cur != null else 0.0
	predator_ttc = cur.ttc if cur != null else INF

	# --- Target: sticky with a minimum hold, committed while closing ---
	_target_held += dt
	var cur_valid := target != null and is_instance_valid(target) and cur_target_score >= 0.0
	if cur_valid:
		# The player gaining on its target (see target_commit_s).
		var d := target.get_body_position().distance_to(pp)
		if d < _target_best_d * (1.0 - TARGET_PROGRESS):
			_target_best_d = d
			_target_progress_at = _now
		if _target_hist.is_empty() or _now - _target_hist[-1].x >= 0.1:
			_target_hist.append(Vector2(_now, d))
		else:
			_target_hist[-1] = Vector2(_target_hist[-1].x, d)
		while _target_hist.size() > 1 and _now - _target_hist[1].x >= TARGET_WINDOW_S:
			_target_hist.pop_front()
	# (Against the farthest it has been in the window, not only the window's
	# first sample: any 5% gained within the last TARGET_WINDOW_S counts.)
	var closing := false
	if cur_valid and _target_hist.size() > 1 and _now - _target_hist[0].x >= TARGET_WINDOW_S * 0.5 \
			and pv.length() >= TARGET_CLOSING_SPEED * SizeRules.cruise_speed(pm):
		var far := 0.0
		for h in _target_hist:
			far = maxf(far, h.y)
		closing = _target_hist[-1].y < far * (1.0 - TARGET_PROGRESS)
	target_committed = cur_valid and (closing or _now - _target_progress_at < target_commit_s * sqrt(maxf(body_time, 1.0)))
	if not cur_valid:
		if best_prey != target:
			last_target_change = _why_invalid(target, pp, pm, pspan, tg_r)
			_name_target(best_prey, pp)
		target = best_prey
		target_score = best_score
	elif best_prey != target and ((best_lesson and not cur_lesson) or (not target_committed
			and best_score > cur_target_score * target_switch_ratio and _target_held >= target_min_hold_s)):
		last_target_change = &"lesson" if best_lesson and not cur_lesson else &"preference"
		_name_target(best_prey, pp)
		target = best_prey
		target_score = best_score
	else:
		target_score = cur_target_score

	var mask := 0
	if predator != old_pred or absf(level - old_level) > 1e-6:
		mask |= 1
	if target != old_target:
		mask |= 2
	return mask


## Why the target t stopped being one (diagnostics: last_target_change).
func _why_invalid(t: Bird, pp: Vector3, pm: float, pspan: float, tg_r: float) -> StringName:
	if t == null:
		return &"new"
	if not is_instance_valid(t) or not t.alive:
		return &"gone"
	if CatchRule.is_hidden(t):
		return &"hidden"
	var tp := t.get_body_position()
	if refuge_index != null and refuge_index.blocks(tp, pspan):
		return &"sheltered"
	if SizeRules.meal_value(pm, t.mass) < SizeRules.WORTH_MIN:
		return &"outgrown"
	if tp.distance_to(pp) > tg_r * target_range_hysteresis:
		return &"range"
	var sg: _Sight = _sight.get(t.get_instance_id())
	if sg != null and sg.clutter:
		return &"clutter"
	return &"sight"


## Starts the clocks of a newly named target q (null: none).
func _name_target(q: Bird, pp: Vector3) -> void:
	_target_held = 0.0
	_target_best_d = q.get_body_position().distance_to(pp) if q != null else INF
	_target_progress_at = _now
	_target_hist.clear()


## How catchable prey of mass ratio r (prey / player) is, relative to small
## prey: near-equal birds are nearly as fast and more agile than the player
## and almost never caught in a chase (ChaseLab: ~0-5% at r 0.6 for every
## skill), so the target cue weighs worth by this and points at the best
## meal the player can actually catch - prey around a third of its size,
## not a near-equal (docs/areas/GAMELOOP.md). 1 up to CHASE_EASY_R, falling
## to CHASE_FLOOR at CHASE_HARD_R and beyond. In the valley (fix round 3,
## ~2600 modelled chases) near-equals were caught 2-4% of the time (pigeon
## after pigeon, hawk after hawk) against 10-55% for prey at a tenth to a
## third of the player: with the floor at 1 / EAT_RATIO (round 2) a
## near-equal still scored 0.4 at r 0.6, and its bigger worth made it the
## cue's pick - a pigeon-sized player was pointed at other pigeons 350 times
## for 6 catches.
const CHASE_EASY_R := 0.3
const CHASE_HARD_R := 0.65
const CHASE_FLOOR := 0.05


static func chase_odds(r: float) -> float:
	return lerpf(1.0, CHASE_FLOOR, smoothstep(CHASE_EASY_R, CHASE_HARD_R, r))


## How readily prey comes to a chase through the real flight chain (core
## loop round, the lead's direction: moths are the pellets): a swarm moth
## (duck-typed `pellet`) drifting in open air is taken by flying into it
## (EASE_PELLET); a bird sees the player come, bolts, jinks and heads for
## cover (EASE_BIRD). The cue weighs worth by it: at equal distance a moth
## (worth 5% of a sparrow) is ringed over a wren (worth 32%) only a little
## less often than not, and nearer it is. (Through the real chain,
## integration round 2, a person following the ring caught 4-5% of its
## chases of birds; this round's tuning batches 30-55% of its chases of
## swarm moths and 8-29% of small birds'.) One factor per kind of prey, not
## per moment: a factor that fell as a target started to flee moved the
## ring off it by preference 5 times a minute.
const EASE_PELLET := 1.0
const EASE_BIRD := 0.3


static func prey_ease(q: Bird, _p: Bird = null) -> float:
	return EASE_PELLET if &"pellet" in q else EASE_BIRD


## Height advantage (dy = how far the prey is below the player, m): prey
## below can be dived on, prey well above climbs away from a heavier chaser
## (small birds out-climb big ones) - the same edge the AI's raptors score
## for a stoop. 1 +- HEIGHT_EDGE over +-HEIGHT_EDGE_SPANS wingspans.
const HEIGHT_EDGE := 0.4
const HEIGHT_EDGE_SPANS := 8.0


static func height_edge(dy: float, span: float) -> float:
	return 1.0 + HEIGHT_EDGE * clampf(dy / (HEIGHT_EDGE_SPANS * span), -1.0, 1.0)


## How near (m) a bird hunting the player is shown at warn_level at least
## (a hunter of wingspan q_span).
func warn_range(q_span: float) -> float:
	return maxf(WARN_MIN_M, warn_spans * q_span)


## Open air (m) a target needs round it for a player of wingspan span.
func reach_clear(span: float) -> float:
	return maxf(CLEAR_MIN_M, clear_spans * span)


## Highlight radius (m) for a player of mass pm.
func highlight_range(pm: float) -> float:
	return maxf(highlight_range_spans * SizeRules.wingspan_for_mass(pm), highlight_range_s * SizeRules.cruise_speed(pm))


## Target-cue radius (m) for a player of mass pm.
func target_range(pm: float) -> float:
	return maxf(target_range_spans * SizeRules.wingspan_for_mass(pm), target_range_s * SizeRules.cruise_speed(pm))


## Whether the player at pp can reach prey q at qp in open air: the line
## between them is clear of the world's static geometry, and nothing solid is
## within reach_clear(pspan) of the bird (a crown, a hedge, a wall it
## perches against). Answers are kept for SIGHT_CACHE_S; a target counts as
## reachable for SIGHT_GRACE_S after its last good answer (0: dropped at the
## first bad one). Always true without a `space`.
func _in_sight(q: Bird, pp: Vector3, qp: Vector3, is_target: bool, pspan: float = 0.0) -> bool:
	if space == null:
		return true
	var id := q.get_instance_id()
	var s: _Sight = _sight.get(id)
	if s == null:
		s = _Sight.new()
		_sight[id] = s
	if _now - s.checked_at >= SIGHT_CACHE_S:
		s.checked_at = _now
		var ray := PhysicsRayQueryParameters3D.create(pp, qp, 1)
		s.visible = space.intersect_ray(ray).is_empty()
		s.clutter = false
		if s.visible and not _open_air(qp, reach_clear(pspan) * (TARGET_CLEAR_KEEP if is_target else 1.0)):
			s.visible = false
			s.clutter = true
		if s.visible:
			s.seen_at = _now
	if s.visible:
		return true
	return is_target and _now - s.seen_at < (CLUTTER_GRACE_S if s.clutter else SIGHT_GRACE_S)


## True if a sphere of radius r at pos touches no static world geometry.
func _open_air(pos: Vector3, r: float) -> bool:
	if _clear_q == null:
		_clear_shape = SphereShape3D.new()
		_clear_q = PhysicsShapeQueryParameters3D.new()
		_clear_q.shape = _clear_shape
		_clear_q.collision_mask = 1
		_clear_q.collide_with_areas = false
	_clear_shape.radius = r
	_clear_q.transform = Transform3D(Basis.IDENTITY, pos)
	return space.intersect_shape(_clear_q, 1).is_empty()


## Birds without a model are asked for one again every this many passes.
const MODEL_RECHECK := 30


## Drops the records of birds the last pass did not see alive (dead,
## removed from the registry): their threat, highlight and sight entries.
func _prune() -> void:
	for id: int in _recs.keys():
		var g: _Threat = _recs[id]
		if g.seen != _frame:
			_recs.erase(id)
			_threats.erase(id)
			highlights.erase(id)
			_sight.erase(id)


## Drops bookkeeping for a bird that left the game.
func forget(q: Bird) -> void:
	highlights.erase(q.get_instance_id())
	_threats.erase(q.get_instance_id())
	_recs.erase(q.get_instance_id())
	_sight.erase(q.get_instance_id())
	if q == predator:
		# The next update names the strongest other predator at once.
		predator = null
	if q == target:
		target = null
		last_target_change = &"gone"


## Writes this watch's highlight for q (0 if it has none) onto q's model if
## the model shows something else: GameLoop calls it for the birds the UI's
## threat/target handlers just wrote to, so the loop's classification is
## what every frame ends with (fix round 4 review: the UI unlit a hawk the
## loop marks as danger whenever its level was under 0.1, and BirdModel's
## smoothing showed the flicker).
func reassert_highlight(q: Bird) -> void:
	if q == null or not is_instance_valid(q):
		return
	var want: int = highlights.get(q.get_instance_id(), 0)
	if _get_highlight(q) != want:
		_set_highlight(q, want)


## Sets every highlight this watch wrote back to 0.
func clear_highlights(birds: Array[Bird]) -> void:
	for q in birds:
		if highlights.has(q.get_instance_id()):
			_set_highlight(q, 0)
	highlights.clear()


static func _get_highlight(q: Bird) -> int:
	var m: Variant = q.get(&"model")
	if m is Object and is_instance_valid(m) and "highlight" in m:
		return int(m.get(&"highlight"))
	return 0


static func _set_highlight(q: Bird, value: int) -> void:
	# NpcBird exposes its BirdModel as `model`; mocks may not have one.
	var m: Variant = q.get(&"model")
	if m is Object and is_instance_valid(m) and "highlight" in m:
		m.set(&"highlight", value)
