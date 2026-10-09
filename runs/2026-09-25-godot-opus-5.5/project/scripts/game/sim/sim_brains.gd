class_name SimBrains
extends RefCounted
## NPC behaviour for the game-loop simulations (chase trials, the integrated
## pacing sim, the dev scene): a mirror of the AI area's NpcBrain hunting,
## fleeing and calm-flight rules (AiMirror has every number and where it
## comes from), flown on SimFlight, a copy of the AI's NPC flight physics.
## Copied, not referenced: the game-loop suite must not depend on another
## area's in-progress code.
##
## The mirror is checked against the AI area's own measurement:
## tests/unit/game/danger_test.gd runs SimBrains duels in the AI's duel setup
## (tests/unit/ai/hunt_duel_test.gd) and requires the AI's catch rates. The
## first version of these sims had simpler hunters (no stoop, no pursuit
## guidance, no lunge, a short burst then cruise) on a kinematic flight model
## that let any bird hold dive speeds in level flight: they caught a fleeing
## player about once in 800 attacks and the pacing assumed a harmless sky.
##
## Hunting: pick prey by worth over intercept time (x1.25 for the player),
## stalk at 80% effort until the prey notices, then sprint; lead pursuit when
## far or off course, proportional navigation when on course, extending
## straight when the aim point is inside the turning circle; raptors with
## height fold and stoop; within 1.2 spans the final lunge. Give up after 3
## failed passes, no progress, the species' timeout, exhaustion or range.
## Fleeing: notice within the awareness radius (later from behind and
## above), react after the species' reaction time, sprint away along an
## escape line re-aimed at the reaction rate and held in the final run, and
## on each attack run maybe break sideways (skill x energy) at a moment
## around the strike (timing is the gamble).
## Calm flight: goals in the species' altitude band, gentle climbs, moths
## flutter, soaring species glide when high.
## Every behaviour fills the bird's steering request (o_dir, o_speed, o_eff,
## o_fold, o_clear, o_guard, as the AI's _o_* fields); the ground overlay
## (pull-out-aware clearance) is applied last, then the bird flies it.
##
## State lives in SimBird.brain (a Dictionary).

## Senses run at the AI's engaged think rate.
const SCAN_S := 0.1


# =====================================================================
# One NPC step (the ecosystem and the duel harness both use this)
# =====================================================================

## Advances one NPC by dt: its clock and hunger, its senses (a full scan of
## `birds` when `scan`, else only the pending reaction), then flee > hunt >
## calm flight around `home` (within `radius`). Returns "" or, when a hunt
## ended without a catch this step, the AI's give-up reason.
static func step_npc(b: SimBird, dt: float, rng: RandomNumberGenerator, scan: bool, birds: Array[Bird],
		home: Vector3, radius: float, can_hunt: bool = true, can_flee: bool = true) -> String:
	var st := b.brain
	var now: float = float(st.get("t", 0.0)) + dt
	st["t"] = now
	st["hunger"] = minf(1.0, float(st.get("hunger", 0.0)) + AiMirror.hunger_rate(b.species) * dt)
	var pick: Bird = null
	if scan:
		pick = _scan(b, birds, now, can_hunt and st.get("prey") == null, can_flee)
	elif can_flee:
		react(b, now)
	var threat: Bird = st.get("threat") if can_flee else null
	if threat != null and is_instance_valid(threat) and threat.alive:
		if st.get("prey") != null:
			give_up(b, now)
		flee(b, threat, dt, rng)
		return ""
	var ended := ""
	if st.get("prey") != null:
		ended = hunt_status(b, dt)
		if ended != "":
			give_up(b, now)
	elif pick != null:
		start_hunt(b, pick)
	var prey: Bird = st.get("prey")
	if prey != null:
		hunt(b, prey, dt)
	else:
		wander(b, dt, rng, home, radius)
	return ended


## One pass over every bird: the worst threat (with the reaction logic) and,
## if `want_prey`, the prey b would start hunting now (or null).
static func _scan(b: SimBird, birds: Array[Bird], now: float, want_prey: bool, can_flee: bool) -> Bird:
	var st := b.brain
	var threat: Bird = st.get("threat")
	if threat != null and (not is_instance_valid(threat) or not threat.alive or threat.mass < b.mass * SizeRules.EAT_RATIO):
		threat = null
	var alert := threat != null
	var bp := b.global_position
	var eater := b.mass * SizeRules.EAT_RATIO
	var edible := b.mass / SizeRules.EAT_RATIO
	var hunt_r := AiMirror.hunt_range_m(b.species)
	var search_r := hunt_r * AiMirror.SEARCH_RANGE
	var near: Bird = null
	var near_d2 := search_r * search_r
	var cool: Dictionary = st.get("cooldown", {})
	want_prey = want_prey and AiMirror.hunt_drive(b.species) > 0.0 and float(st.get("hunger", 0.0)) > 0.25 \
			and b.energy > AiMirror.HUNT_MIN_ENERGY
	var best: Bird = null
	var best_lv := 0.0
	var prey: Bird = null
	var prey_s := 0.0
	for o in birds:
		if o == b or not o.alive:
			continue
		var om := o.mass
		if om >= eater:
			if can_flee:
				var lv := threat_level(b, o, o.get_body_position() - bp, alert)
				if lv > best_lv:
					best_lv = lv
					best = o
		elif want_prey and om <= edible:
			var rel := o.get_body_position() - bp
			if absf(rel.x) > search_r or absf(rel.z) > search_r:
				continue
			if not cool.is_empty() and float(cool.get(o.get_instance_id(), -1.0)) > now:
				continue
			var d2 := rel.length_squared()
			if d2 < near_d2 and SizeRules.is_worthwhile(b.mass, om) \
					and not (o.is_player() and bool(o.get_meta(&"npc_ignore", false))):
				near_d2 = d2
				near = o
			if d2 > hunt_r * hunt_r:
				continue
			var sc := prey_score(b, o, rel)
			if sc > prey_s:
				prey_s = sc
				prey = o
	if can_flee:
		if best != null and best_lv >= AiMirror.FLEE_LEVEL:
			st["calm_since"] = now
			if threat != null:
				threat = best
			elif st.get("cand") != best:
				st["cand"] = best
				st["cand_at"] = now
			elif now - float(st.get("cand_at", now)) >= AiMirror.reaction_s(b.species) - 1e-4:
				threat = best
				st["cand"] = null
		else:
			st["cand"] = null
			if threat != null and now - float(st.get("calm_since", now)) >= AiMirror.CALM_S:
				threat = null
		st["threat"] = threat
	if prey != null and wants_hunt(b, prey_s):
		return prey
	# Hungry with nothing to hunt in range: go looking (AI _choose): head for
	# the nearest worthwhile prey within SEARCH_RANGE x the hunting range,
	# a little above it (well above for a stooper).
	if want_prey and near != null and float(st.get("hunger", 0.0)) > AiMirror.SEARCH_HUNGER \
			and b.energy > AiMirror.SEARCH_ENERGY and now >= float(st.get("search_at", 0.0)):
		st["search_at"] = now + AiMirror.SEARCH_COOL_S
		var band: Array = AiMirror.ALT.get(b.species, AiMirror.ALT[&"sparrow"])
		st["goal"] = near.get_body_position() + Vector3.UP * (float(band[0]) * 0.5 + (15.0 if AiMirror.stoops(b.species) else 3.0))
		st["goal_t"] = 0.0
		st["goal_life"] = AiMirror.SEARCH_GOAL_S
	return null


# =====================================================================
# Senses
# =====================================================================

## Threat level of `o` to `b` by the AI's rule (0 = none; flee at
## AiMirror.FLEE_LEVEL): a hunter chasing b is fled on sight, one hunting
## nearby when it gets close, a passing one is not fled; the player's intent
## is unknowable, so an approaching player counts as hunting.
static func threat_level(b: SimBird, o: Bird, rel: Vector3, alert: bool) -> float:
	var d := rel.length()
	var aw := AiMirror.awareness_m(b.species) * (AiMirror.VIGILANCE if alert else 1.0)
	if d > aw:
		return 0.0
	var eff := aw
	if d > 1e-4:
		var fwd := b.velocity.normalized() if b.velocity.length_squared() > 0.01 else b.get_forward()
		var behind := fwd.dot(rel) < -0.5 * d
		if behind and rel.y > d * 0.4:
			eff *= AiMirror.BEHIND_ABOVE
		elif behind:
			eff *= AiMirror.BEHIND
		elif rel.y > d * 0.5:
			eff *= AiMirror.ABOVE
	if d > eff:
		return 0.0
	var prox := 1.0 - d / eff
	var approaching := d > 0.01 and -(o.velocity - b.velocity).dot(rel) / d > 1.0
	var so := o as SimBird
	if o.is_player():
		return prox + (0.35 if approaching else 0.0) + 0.1
	if so != null:
		if so.brain.get("prey") == b:
			return 1.0 + prox
		if so.brain.get("prey") != null:
			return prox + (0.3 if approaching else 0.0)
	return prox - 0.6


## Between scans: a candidate whose reaction time has run out becomes the
## threat (the AI forces a think at exactly that moment).
static func react(b: SimBird, now: float) -> void:
	var st := b.brain
	var cand: Bird = st.get("cand")
	if cand == null or st.get("threat") != null:
		return
	if not is_instance_valid(cand) or not cand.alive:
		st["cand"] = null
		return
	if now - float(st.get("cand_at", now)) >= AiMirror.reaction_s(b.species) - 1e-4:
		st["threat"] = cand
		st["cand"] = null
		st["calm_since"] = now


## How attractive prey `o` is to hunter b at offset rel (AI _best_prey),
## 0 if b would not hunt it.
static func prey_score(b: SimBird, o: Bird, rel: Vector3) -> float:
	if not SizeRules.is_worthwhile(b.mass, o.mass):
		return 0.0
	if o.is_player() and bool(o.get_meta(&"npc_ignore", false)):
		return 0.0
	var d := rel.length()
	if d > AiMirror.hunt_range_m(b.species):
		return 0.0
	var closing := b.sprint_speed() - (o.velocity.dot(rel / d) if d > 0.01 else 0.0)
	if closing < 0.5:
		return 0.0
	var s := sqrt(o.mass / b.mass) / (1.0 + d / closing / 5.0)
	var so := o as SimBird
	if so != null and so.brain.get("flock", false) and so.brain.get("threat") == null and so.brain.get("prey") == null:
		s *= AiMirror.FLOCK_CONFUSION  # a flock confuses a hunter
	if AiMirror.stoops(b.species) and rel.y < -8.0:
		s *= 1.3
	if o.is_player():
		s *= AiMirror.PLAYER_INTEREST
	return s


## Does b want to hunt now, with this best prey score (AI utility)?
static func wants_hunt(b: SimBird, score: float) -> bool:
	var drive := AiMirror.hunt_drive(b.species)
	var hunger := float(b.brain.get("hunger", 0.0))
	if drive <= 0.0 or hunger <= 0.25 or b.energy <= AiMirror.HUNT_MIN_ENERGY or score <= 0.0:
		return false
	var u := drive * smoothstep(0.25, 0.75, hunger) * score * 1.6
	if b.brain.get("flock", false):
		u *= AiMirror.FLOCK_HUNT  # a flocked bird stays with its flock
	return u > AiMirror.hunt_utility_min


# =====================================================================
# Hunting
# =====================================================================

## Commits b to hunting `prey` (resets the give-up bookkeeping).
static func start_hunt(b: SimBird, prey: Bird) -> void:
	var st := b.brain
	st["prey"] = prey
	b.target = prey
	st["hunt_t"] = 0.0
	st["prev_d"] = -1.0
	st["closing"] = 0.0
	st["slow_t"] = 0.0
	st["passes"] = 0
	st["in_pass"] = false
	st["chase_t0"] = -1.0
	st["stoop"] = false
	var d := prey.get_body_position().distance_to(b.global_position)
	var closing := maxf(b.sprint_speed() - prey.velocity.length(), 2.0)
	st["budget"] = clampf(d / closing * 2.0 + 6.0, 10.0, 40.0)


## Has the prey noticed its hunter? (NPC prey: it flees from it. The player:
## unknowable - the AI's hunters never assume it, so their patience is the
## approach budget plus the species' timeout.)
static func noticed_by(prey: Bird, hunter: Bird) -> bool:
	var sp := prey as SimBird
	return sp != null and not prey.is_player() and sp.brain.get("threat") == hunter


## Give-up rules (AI _hunt_ok). Returns "" while the hunt goes on, else why
## it ended; call once per step while hunting.
static func hunt_status(b: SimBird, dt: float) -> String:
	var st := b.brain
	var t: Bird = st.get("prey")
	if t == null or not is_instance_valid(t) or not t.alive or not SizeRules.can_eat(b.mass, t.mass):
		return "gone"
	if t.is_player() and bool(t.get_meta(&"npc_ignore", false)):
		return "protected"
	var ht: float = float(st.get("hunt_t", 0.0)) + dt
	st["hunt_t"] = ht
	var d := t.get_body_position().distance_to(b.global_position)
	var prev: float = st.get("prev_d", -1.0)
	var closing: float = st.get("closing", 0.0)
	if prev >= 0.0:
		# The AI smooths closing speed by 0.25 per 0.1 s think.
		closing = lerpf(closing, (prev - d) / dt, clampf(0.25 * dt / 0.1, 0.0, 1.0))
	st["closing"] = closing
	st["prev_d"] = d
	var strike := AiMirror.strike_reach(b.get_wingspan()) * 2.0
	if d < strike:
		st["in_pass"] = true
	elif st.get("in_pass", false) and d > strike * 3.0:
		st["in_pass"] = false
		st["passes"] = int(st.get("passes", 0)) + 1
	if int(st.get("passes", 0)) >= AiMirror.PASSES:
		return "passes"
	var slow: float = st.get("slow_t", 0.0)
	if closing < 0.3 and d > strike * 3.0 and not st.get("stoop", false):
		slow += dt
	else:
		slow = maxf(slow - dt, 0.0)
	st["slow_t"] = slow
	if slow > maxf(3.0, TAU / b.turn_rate_now() + 1.5):
		return "no_progress"
	if noticed_by(t, b) and float(st.get("chase_t0", -1.0)) < 0.0:
		st["chase_t0"] = ht
	var t0: float = st.get("chase_t0", -1.0)
	var timeout := AiMirror.hunt_timeout_s(b.species)
	if t0 >= 0.0:
		if ht - t0 > timeout:
			return "timeout"
	elif ht > float(st.get("budget", 20.0)) + (timeout if t.is_player() else 0.0):
		return "timeout"
	if b.energy < AiMirror.TIRED:
		return "tired"
	if d > AiMirror.hunt_range_m(b.species) * AiMirror.RANGE_GIVE_UP:
		return "range"
	return ""


## Ends a hunt without a catch: that prey is left alone for a while.
static func give_up(b: SimBird, now: float) -> void:
	var st := b.brain
	var t: Bird = st.get("prey")
	if t != null and is_instance_valid(t):
		var cd: Dictionary = st.get("cooldown", {})
		cd[t.get_instance_id()] = now + AiMirror.GIVE_UP_COOLDOWN_S
		st["cooldown"] = cd
	st["prey"] = null
	st["stoop"] = false
	b.target = null


## One step of pursuit of `prey` (AI _steer_hunt / _steer_stoop, overlays,
## then the lunge). `_lead` is accepted for older callers and ignored:
## guidance is the AI's.
static func hunt(b: SimBird, prey: Bird, dt: float, _lead: float = 0.7) -> void:
	_steer_hunt(b, prey)
	_fly(b, dt)
	lunge(b, prey, dt)


static func _steer_hunt(b: SimBird, prey: Bird) -> void:
	var st := b.brain
	var p := b.global_position
	var tp := prey.get_body_position()
	var rel := tp - p
	var d := rel.length()
	var dh := -rel.y
	var hd := Vector2(rel.x, rel.z).length()
	var stooping: bool = st.get("stoop", false)
	if not stooping:
		# (The AI also requires the prey to be > 3 m above the ground.)
		if AiMirror.stoops(b.species) and dh > AiMirror.STOOP_DH and hd < dh * AiMirror.STOOP_HD \
				and tp.y - b.ground_y > 3.0:
			stooping = true
			st["stoop_best"] = INF
	else:
		var best: float = minf(float(st.get("stoop_best", INF)), d)
		st["stoop_best"] = best
		if dh < 0.5 or (d > best + 5.0 and best < AiMirror.STOOP_PASS_M):
			stooping = false
	st["stoop"] = stooping
	_begin(b)
	if stooping:
		b.o_dir = pursue(b, prey, maxf(b.speed, b.cruise_speed()), 4.0)
		b.o_speed = b.max_speed()
		b.o_eff = 0.4
		# Tucked for speed while far and steep; open up near the prey to steer.
		var steep := -b.o_dir.normalized().y
		var r_v := b.speed / maxf(b.turn_rate_now(), 0.2)
		b.o_fold = 1.0 if steep > 0.35 and d > b.speed * 0.5 + r_v * 0.25 else 0.35
		b.o_clear = 1.2 + b.get_body_radius()
	else:
		b.o_dir = pursue(b, prey, maxf(b.speed, b.cruise_speed() * 1.15), 3.0)
		b.o_speed = b.max_speed()
		b.o_eff = 1.0
		if not noticed_by(prey, b) and d > maxf(25.0, AiMirror.awareness_m(prey.species) * 1.1):
			b.o_eff = AiMirror.STALK_EFFORT
		var up := b.o_dir.normalized().y
		if up > 0.1:
			# Prey above: trade speed for height rather than sprint underneath.
			b.o_speed = lerpf(b.max_speed(), b.cruise_speed(), clampf((up - 0.1) / 0.3, 0.0, 1.0))
		b.o_clear = 0.6 + b.get_body_radius()


## Pursuit guidance (AI _pursue): lead pursuit towards the intercept point
## when far off or pointing away (extending straight while the aim point is
## inside the turning circle), proportional navigation once on course.
static func pursue(b: SimBird, t: Bird, s: float, max_tgo: float) -> Vector3:
	var p := b.global_position
	var tp := t.get_body_position()
	var r := tp - p
	var d2 := maxf(r.length_squared(), 1e-4)
	var v := b.velocity
	var vl := v.length()
	var tv := t.velocity
	var lead := tp + tv * minf(intercept_time(r, tv, s), max_tgo)
	if vl < 0.5:
		return lead - p
	var my := v / vl
	var cos_a := my.dot(r / sqrt(d2))
	var closing := -(tv - v).dot(r) / sqrt(d2)
	if cos_a < 0.5 or closing <= 0.0:
		var h := Vector3(my.x, 0.0, my.z)
		if h.length_squared() > 1e-4:
			h = h.normalized()
			var right := h.cross(Vector3.UP)
			var to_aim := lead - p
			var side := 1.0 if to_aim.dot(right) >= 0.0 else -1.0
			var r_t := vl / maxf(b.turn_rate_now(), 0.1)
			var c := p + right * side * r_t
			var off := Vector2(lead.x - c.x, lead.z - c.z).length()
			if off < r_t * 0.95:
				return h + Vector3.UP * clampf(to_aim.y / maxf(r_t, 1.0), -0.3, 0.3)
		return lead - p
	var los_rate := r.cross(tv - v) / d2
	var w := los_rate * AiMirror.PN_GAIN
	return my + w.cross(my) / maxf(b.flight.heading_gain, 1.0)


## Time for a pursuer at speed s to meet a target at offset rel moving at tv.
static func intercept_time(rel: Vector3, tv: Vector3, s: float) -> float:
	var a := tv.length_squared() - s * s
	var bq := 2.0 * rel.dot(tv)
	var c := rel.length_squared()
	var t := -1.0
	if absf(a) < 1e-6:
		if bq < 0.0:
			t = -c / bq
	else:
		var disc := bq * bq - 4.0 * a * c
		if disc >= 0.0:
			var sq := sqrt(disc)
			var t1 := (-bq - sq) / (2.0 * a)
			var t2 := (-bq + sq) / (2.0 * a)
			if t1 > 0.0 and t2 > 0.0:
				t = minf(t1, t2)
			else:
				t = maxf(t1, t2)
	if t <= 0.0:
		t = sqrt(c) / maxf(s, 1.0)
	return t


## The final lunge (AI NpcBird._strike): within strike reach, with the prey
## ahead, the hunter throws its body sideways towards it at a limited speed.
## It fixes the last few centimetres flight control cannot, not a jink.
static func lunge(b: SimBird, prey: Bird, dt: float) -> void:
	var span := b.get_wingspan()
	var np := b.global_position
	var tp := prey.get_body_position() + prey.velocity * dt
	var rel := tp - np
	var d := rel.length()
	var vl := b.velocity.length()
	if d > AiMirror.strike_reach(span) or vl < 0.5:
		return
	var vdir := b.velocity / vl
	var along := rel.dot(vdir)
	if along < -b.get_body_radius():
		return
	var lat := rel - vdir * maxf(along, 0.0)
	b.global_position = np + lat.limit_length(AiMirror.strike_speed(span, b.mass) * dt)


# =====================================================================
# Fleeing
# =====================================================================

## One step of escape from `threat` (AI _steer_flee without cover or
## flocks): flat out along an escape line re-aimed at the reaction rate and
## held in the final run; on each attack run a timed break sideways, if the
## bird sees it coming (jink skill x energy).
static func flee(b: SimBird, threat: Bird, dt: float, rng: RandomNumberGenerator) -> void:
	var st := b.brain
	var now: float = float(st.get("t", 0.0))
	var tp := threat.get_body_position()
	var tv := threat.velocity
	var rel := b.global_position - (tp + tv * 0.3)
	var d := maxf(rel.length(), 0.01)
	var away := rel / d
	away.y *= 0.35
	# NB: the AI's own sign, kept on purpose. rel points from the threat to
	# the prey, so this is positive only while the threat is *receding*: the
	# AI's prey (npc_brain.gd _steer_flee, 2026-09-25) never hold the line or
	# jink on the attack run itself, only after a pass. The duel rates the
	# mirror is validated against were measured with this behaviour; reported
	# to the AI area (docs/areas/GAMELOOP.md). If it is fixed there, fix it
	# here and re-run the duels and the pacing tool.
	var closing := (tv - b.velocity).dot(-rel / d)
	var ttc0 := d / maxf(closing, 0.1)
	var final_run := closing > 0.0 and ttc0 < AiMirror.FINAL_RUN_S
	var flee_dir: Vector3 = st.get("flee_dir", Vector3.ZERO)
	if flee_dir == Vector3.ZERO or (not final_run and now >= float(st.get("flee_next", 0.0))):
		flee_dir = away.normalized()
		st["flee_dir"] = flee_dir
		st["flee_next"] = now + AiMirror.reaction_s(b.species)
	var desired := flee_dir
	var reach := AiMirror.strike_reach(threat.get_wingspan())
	var ttc := maxf(d - reach, 0.0) / maxf(closing, 0.1)
	var jink_at: float = st.get("jink_at", -1.0)
	var jink_t: float = float(st.get("jink_t", 0.0)) - dt
	if closing > 0.5 and ttc < AiMirror.JINK_WINDOW_S:
		if jink_at < 0.0:
			var skill := AiMirror.jink(b.species)
			st["run_jink"] = rng.randf() < skill * (0.55 + 0.45 * b.energy)
			jink_at = AiMirror.JINK_AT + (rng.randf() - 0.5) * (1.3 - skill)
		if st.get("run_jink", false) and ttc < jink_at and jink_t <= 0.0:
			var u := tv / maxf(tv.length(), 0.1)
			var lat := rel - u * rel.dot(u)
			lat.y *= 0.3
			if lat.length() < 0.05:
				lat = u.cross(Vector3.UP) * (1.0 if rng.randf() < 0.5 else -1.0)
			st["jink_dir"] = lat.normalized() + Vector3.DOWN * rng.randf_range(0.0, 0.35) - u * 0.25
			jink_t = rng.randf_range(0.3, 0.5)
			st["run_jink"] = false
	elif ttc > AiMirror.JINK_RESET_S or closing <= 0.0:
		jink_at = -1.0
	st["jink_at"] = jink_at
	st["jink_t"] = jink_t
	if jink_t > 0.0:
		desired = st.get("jink_dir", desired)
	_begin(b)
	b.o_dir = desired
	b.o_speed = b.max_speed()
	b.o_eff = 1.0
	b.o_clear = 0.8 + b.get_body_radius()
	_fly(b, dt)


# =====================================================================
# Calm flight
# =====================================================================

## Calm flight recovers energy (the AI's calm birds glide, soar and perch;
## AiMirror.CALM_RECOVERY* reproduce its measured energy distribution).
static func rest(b: SimBird, dt: float) -> void:
	var k := AiMirror.CALM_RECOVERY_LOW if b.energy < AiMirror.LOW_ENERGY else AiMirror.CALM_RECOVERY
	b.energy = minf(1.0, b.energy + k * dt)
	b.brain.erase("flee_dir")
	b.brain["jink_at"] = -1.0


## Calm flight (AI _steer_wander): towards goals picked within `radius` of
## `home` (horizontally) at a height in the species' altitude band above the
## ground (or around home's height in open air), climbing gently, never flat
## out; moths flutter; soaring species glide when high.
static func wander(b: SimBird, dt: float, rng: RandomNumberGenerator, home: Vector3, radius: float) -> void:
	var st := b.brain
	var gt: float = float(st.get("goal_t", 0.0)) + dt
	var goal: Vector3 = st.get("goal", Vector3.INF)
	var p := b.global_position
	if goal == Vector3.INF or gt > float(st.get("goal_life", 0.0)) or Vector2(goal.x - p.x, goal.z - p.z).length() < 12.0 \
			or (Vector2(goal.x - home.x, goal.z - home.z).length() > radius * 1.5 and gt > AiMirror.SEARCH_GOAL_S):
		var a := rng.randf() * TAU
		var r := sqrt(rng.randf()) * radius
		goal = Vector3(home.x + cos(a) * r, 0.0, home.z + sin(a) * r)
		var band: Array = AiMirror.ALT.get(b.species, AiMirror.ALT[&"sparrow"])
		if is_finite(b.ground_y):
			goal.y = b.ground_y + rng.randf_range(float(band[0]), float(band[1]))
		else:
			goal.y = home.y + rng.randf_range(-5.0, 5.0)
		gt = 0.0
		st["goal"] = goal
		st["goal_life"] = rng.randf_range(20.0, 40.0)
	st["goal_t"] = gt
	_begin(b)
	var dir := goal - p
	var erratic := AiMirror.erratic(b.species)
	if erratic > 0.0:
		# Moths flutter: a new random wobble a few times a second.
		if rng.randf() < 1.7 * dt:
			st["jitter"] = Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.6, 0.6), rng.randf_range(-1, 1))
		dir = dir.normalized() + (st.get("jitter", Vector3.ZERO) as Vector3) * erratic * 0.75
	# Travelling birds cruise: climb at a gentle angle, never flat out.
	var h := Vector2(dir.x, dir.z).length()
	if h > 1e-4:
		dir.y = clampf(dir.y, -h * 0.5, h * 0.22)
	b.o_dir = dir
	b.o_eff = 0.75
	if AiMirror.soars(b.species) and b.global_position.y - b.ground_y > float(AiMirror.ALT[b.species][0]) + 10.0 \
			and (goal - p).y < 5.0:
		# Soaring birds glide between thermals and flap only when low.
		b.o_eff = 0.12
		b.o_speed = b.flight.v_md
	_fly(b, dt)
	rest(b, dt)


# =====================================================================
# Steering plumbing
# =====================================================================

## Default steering request (the AI's _steer preamble).
static func _begin(b: SimBird) -> void:
	b.o_dir = b.heading
	b.o_speed = b.cruise_speed()
	b.o_eff = 1.0
	b.o_fold = 0.0
	b.o_clear = maxf(float(AiMirror.ALT.get(b.species, [3.0])[0]) * 0.5, 1.5)
	b.o_guard = true


## Applies the overlays to the steering request and flies it.
static func _fly(b: SimBird, dt: float) -> void:
	if b.o_dir.length_squared() < 1e-8:
		b.o_dir = b.heading
	b.o_dir = b.o_dir.normalized()
	ground_guard(b)
	b.fly(b.o_dir, b.o_speed, dt, 1.0, b.o_eff, b.o_fold)


## The AI's ground overlay: keep the pull-out height at the current speed
## and dive angle plus the clearance above the ground; pull up (flat out,
## wings open) when short of it, flatten a descent when close.
static func ground_guard(b: SimBird) -> void:
	if not b.o_guard or not is_finite(b.ground_y):
		return
	var v := b.velocity
	var sp := maxf(b.speed, 0.1)
	var agl := b.global_position.y - b.ground_y
	var vl := maxf(v.length(), 0.1)
	var sin_g := clampf(v.y / vl, -1.0, 1.0)
	var lost := 0.0
	if sin_g < 0.0:
		var r_v := sp / maxf(b.turn_rate_now(), 0.2)
		lost = r_v * (1.0 - sqrt(1.0 - sin_g * sin_g)) + (-v.y) * 0.35
	var margin := agl - lost - b.o_clear
	if margin < 0.0:
		var h := Vector3(b.o_dir.x, 0.0, b.o_dir.z)
		if h.length_squared() < 1e-4:
			h = Vector3(v.x, 0.0, v.z)
		if h.length_squared() < 1e-4:
			h = Vector3.FORWARD
		b.o_dir = (h.normalized() + Vector3.UP * clampf(-margin / maxf(b.o_clear, 1.0), 0.35, 1.5)).normalized()
		b.o_fold = 0.0
		b.o_eff = 1.0
	elif margin < b.o_clear * 2.0 and b.o_dir.y < 0.0:
		b.o_dir.y *= margin / (b.o_clear * 2.0)
		b.o_dir = b.o_dir.normalized()
