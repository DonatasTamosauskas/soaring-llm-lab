class_name SimPilot
extends RefCounted
## A stand-in for a human flying the player bird, at three skill levels, for
## the pacing simulations. It flies a SimBird (the NPC physics at the
## player's size: no faster than a bird of that size can fly), perceives
## targets with a reaction delay, steers with arm-like noise and only uses
## part of the turn envelope, keeps clear of the ground like any bird, and
## notices threats through the same ThreatWatch cues the HUD/audio/haptics
## give a real player.
##
## The numbers are deliberately conservative guesses about people in VR, not
## tuned to hit the pacing targets: see docs/areas/GAMELOOP.md.

const SKILLS := {
	&"novice": {
		"react_s": 0.3,  # tracking delay (perception to steering)
		"lead": 0.35,  # 0 = aims at where the prey is, 1 = full intercept
		"turn_use": 0.7,  # fraction of the envelope's turn rate used
		"speed": 1.25,  # chase speed, x cruise (beginners flap hard)
		"noise_deg": 6.0,  # steering wobble (arm jitter), 1 sigma
		"cue_level": 0.6,  # reacts to the threat cue (any direction) at this level
		"aware_view_ttc": 2.0,  # ...and to a red-highlighted bird in view coming at it
		"break_p": 0.45,  # sees an attack run coming and breaks across it
		"break_sd": 0.3,  # timing error of the break (s, 1 sigma)
		"give_up_s": 16.0,  # keeps chasing a prey this long (x time_scale)
		"stalk": 0.1,  # chance of setting up an attack from behind and above
	},
	&"competent": {
		"react_s": 0.22,
		"lead": 0.7,
		"turn_use": 0.85,
		"speed": 1.27,
		"noise_deg": 3.5,
		"cue_level": 0.31,
		"aware_view_ttc": 3.0,
		"break_p": 0.8,
		"break_sd": 0.15,
		"give_up_s": 15.0,
		"stalk": 0.25,
	},
	&"expert": {
		"react_s": 0.17,
		"lead": 0.9,
		"turn_use": 0.92,
		"speed": 1.32,
		"noise_deg": 2.5,
		"cue_level": 0.3,
		"aware_view_ttc": 3.0,
		"break_p": 0.92,
		"break_sd": 0.08,
		"give_up_s": 14.0,
		"stalk": 0.35,
	},
}

## Evasion, as a person does it: sprint away along an escape line (re-aimed
## every couple of reaction times, held in the final run), and on each attack
## run break hard across the attacker's path at the moment it would strike -
## if the pilot sees the run coming (break_p) and with a timing error
## (break_sd). Too early and it re-aims, too late and the talons are there:
## the same gamble the AI's prey take (SimBrains.flee).
## Longest a pilot looks ahead when leading a target (x body time).
const LEAD_MAX_S := 1.0

## A pilot stoops on prey at least this many wingspans below it.
const STOOP_SPANS := 8.0

const BREAK_AT_S := 0.4
const BREAK_LEN_S := 0.45
## ...and keep turning while the attacker is within this many of its spans.
const TURN_FIGHT_SPANS := 3.0

var skill_name: StringName
var skill: Dictionary
var rng: RandomNumberGenerator
var _noise := 0.0
## Delayed perception: ring of [time, pos, vel] of the tracked bird.
var _hist: Array = []
var _hist_of: Bird = null
var _clock := 0.0
var _flee_dir := Vector3.ZERO
var _flee_next := 0.0
var _run := false
var _run_break := false
var _break_at := 0.0
var _break_left := 0.0
var _break_side := Vector3.ZERO
var _stalk_of: Bird = null
var _stalking := false


func _init(p_skill: StringName = &"competent", seed_: int = 1) -> void:
	skill_name = p_skill
	skill = SKILLS[p_skill]
	rng = RandomNumberGenerator.new()
	rng.seed = seed_


## What the pilot believes about `b` (react_s old), extrapolated by skill.
func perceive(b: Bird, dt: float) -> Array:
	_clock += dt
	if b != _hist_of:
		_hist.clear()
		_hist_of = b
	_hist.append([_clock, b.get_body_position(), b.velocity])
	var react: float = skill["react_s"]
	while _hist.size() > 2 and float(_hist[1][0]) <= _clock - react:
		_hist.pop_front()
	var h: Array = _hist[0]
	# Skilled pilots extrapolate what they saw (they anticipate); novices don't.
	var ext := react * float(skill["lead"])
	return [h[1] + h[2] * ext, h[2]]


## Who `b` is fleeing from (null if nobody): the sims' brain, or the
## `threat` property a bird exposes (the AI's NpcBird has one).
static func fleeing_from(b: Bird) -> Bird:
	if b is SimBird:
		return (b as SimBird).brain.get("threat")
	var t: Variant = b.get(&"threat")
	return t as Bird if t is Bird and is_instance_valid(t) else null


## Chase `prey`. With the skill's `stalk` chance per chase the pilot first
## works round behind and above an unaware prey (where birds see an attacker
## latest: AiMirror.BEHIND_ABOVE), then dives in; once the prey has noticed
## it is a straight chase. Returns the desired direction flown.
func hunt(p: SimBird, prey: Bird, dt: float) -> Vector3:
	_calm_down()
	if prey != _stalk_of:
		_stalk_of = prey
		_stalking = rng.randf() < float(skill["stalk"])
	if _stalking:
		var noticed: bool = fleeing_from(prey) == p
		var qp := prey.get_body_position()
		var aw := AiMirror.awareness_m(prey.species)
		var qf := prey.velocity.normalized() if prey.velocity.length_squared() > 0.01 else prey.get_forward()
		var set_point := qp - qf * aw * 0.45 + Vector3.UP * aw * 0.3
		var to_set := set_point - p.get_body_position()
		if not noticed and to_set.length() > aw * 0.25 and p.get_body_position().distance_to(qp) > aw * 0.5:
			var w := _wobble(to_set.normalized(), dt)
			_go(p, w, p.cruise_speed() * float(skill["speed"]), dt, true)
			return w
		_stalking = false  # in position (or seen): go
	var seen := perceive(prey, dt)
	var pos: Vector3 = seen[0]
	var vel: Vector3 = seen[1]
	var to := pos - p.get_body_position()
	var own := maxf(p.speed, p.cruise_speed())
	var closing := maxf(own - vel.dot(to.normalized()), own * 0.25)
	# People lead a target by a moment, not by where it will be in several
	# seconds (and neither do the AI's hunters: their pursuit caps it at 3 s):
	# the horizon is capped at LEAD_MAX_S body-seconds.
	var t_int := minf(to.length() / closing, LEAD_MAX_S * p.time_scale())
	var aim := to + vel * t_int * float(skill["lead"])
	var want := _wobble(aim.normalized(), dt)
	# With height on the prey, fold and dive at it (the stoop every bird
	# can do and the flight model allows: tucked wings trade height for
	# speed), opening up again close in to steer - the AI raptors' rule
	# (AiMirror.STOOP_*), in body lengths so it serves a sparrow too.
	var dh := -to.y
	var hd := Vector2(to.x, to.z).length()
	var fold := 0.0
	if dh > STOOP_SPANS * p.get_wingspan() and hd < dh * AiMirror.STOOP_HD:
		var r_v := p.speed / maxf(p.turn_rate_now(), 0.2)
		fold = 1.0 if -want.y > 0.35 and to.length() > p.speed * 0.5 + r_v * 0.25 else 0.35
	_go(p, want, p.cruise_speed() * float(skill["speed"]) if fold == 0.0 else p.max_speed(), dt, true, fold)
	return want


## Evade `threat` (the predator ThreatWatch names). Breaks across its path
## when close if the skill knows how, otherwise just flees straight.
func evade(p: SimBird, threat: Bird, dt: float) -> void:
	var seen := perceive(threat, dt)
	var tp: Vector3 = seen[0]
	var tv: Vector3 = seen[1]
	var pp := p.get_body_position()
	var rel := pp - tp
	var d := maxf(rel.length(), 1e-4)
	var away := rel / d
	away.y *= 0.35
	# Rate at which the gap shrinks (positive while the attacker comes on).
	var closing := (tv - p.velocity).dot(rel / d)
	# Steer away from where the attacker is heading (0.3 s ahead), re-aimed
	# as fast as the pilot reacts (the perception is already react_s old).
	var ahead := pp - (tp + tv * 0.3)
	ahead.y *= 0.35
	if _flee_dir == Vector3.ZERO or _clock >= _flee_next:
		_flee_dir = ahead.normalized() if ahead.length_squared() > 1e-6 else away.normalized()
		_flee_next = _clock + float(skill["react_s"])
	var want := _flee_dir
	var reach := AiMirror.strike_reach(threat.get_wingspan())
	var tts := maxf(d - reach, 0.0) / maxf(closing, 0.1)
	if closing > 0.5 and tts < 1.6:
		if not _run:
			# A new attack run: will this pilot see it coming, and when?
			_run = true
			_run_break = rng.randf() < float(skill["break_p"])
			_break_at = float(skill.get("break_at", BREAK_AT_S)) + rng.randfn(0.0, float(skill["break_sd"]))
		if _run_break and tts < _break_at and _break_left <= 0.0:
			# Break to the side the pilot is already on (the attacker's wider
			# turn overshoots), a little down and back against its line.
			var u := tv / maxf(tv.length(), 0.1)
			var lat := rel - u * rel.dot(u)
			lat.y = 0.0
			if lat.length() < 0.05:
				lat = u.cross(Vector3.UP) * (1.0 if rng.randf() < 0.5 else -1.0)
			_break_side = lat.normalized()
			_break_left = BREAK_LEN_S
			_run_break = false
	elif tts > 2.5 or closing <= 0.0:
		_run = false
	if _break_left > 0.0:
		# Keep turning hard while the attacker is on top of the pilot (a turn
		# fight inside its turning circle), at least BREAK_LEN_S.
		_break_left -= dt
		if d < TURN_FIGHT_SPANS * threat.get_wingspan() and _break_left <= 0.0:
			_break_left = dt
		var u2 := tv / maxf(tv.length(), 0.1)
		var side := _break_side - u2 * _break_side.dot(u2)
		if side.length_squared() < 1e-4:
			side = _break_side
		var dive := 0.35 if skill_name == &"expert" else 0.2
		want = side.normalized() + Vector3.DOWN * dive - u2 * 0.25
	want = _wobble(want.normalized(), dt)
	_go(p, want, p.max_speed(), dt)


## Cruise between chases: level out, and drift back into the band of
## heights the player's species (and so its prey and peers) lives in - a
## person does not skim the ground or climb out of the action for no reason.
func cruise(p: SimBird, dt: float) -> void:
	_calm_down()
	var h := p.heading
	h.y *= 0.2
	if is_finite(p.ground_y):
		var band: Array = AiMirror.ALT.get(p.species, AiMirror.ALT[&"sparrow"])
		var agl := p.global_position.y - p.ground_y
		var lo := float(band[0]) + 3.0
		var hi := maxf(float(band[1]), lo + 5.0)
		if agl < lo:
			h.y = 0.18
		elif agl > hi:
			h.y = -0.12
	_go(p, _wobble(h.normalized(), dt), p.cruise_speed(), dt)


## No bird in reach: fly towards where birds are (at cruise, in the band of
## heights of the player's species), as a person looks for prey.
func search(p: SimBird, toward: Vector3, dt: float) -> void:
	_calm_down()
	var to := toward - p.get_body_position()
	to.y = 0.0
	var h := to.normalized() if to.length_squared() > 1e-4 else p.heading
	if is_finite(p.ground_y):
		var band: Array = AiMirror.ALT.get(p.species, AiMirror.ALT[&"sparrow"])
		var agl := p.global_position.y - p.ground_y
		h.y = 0.18 if agl < float(band[0]) + 3.0 else (-0.12 if agl > maxf(float(band[1]), float(band[0]) + 8.0) else 0.0)
	_go(p, _wobble(h.normalized(), dt), p.cruise_speed(), dt)


## Not evading any more: the next evasion starts a fresh escape line.
func _calm_down() -> void:
	_flee_dir = Vector3.ZERO
	_run = false
	_break_left = 0.0


## Flies the player's bird along `want` through the ground overlay (the
## same pull-out-aware clearance every NPC keeps: skimming the ground like an
## AI hunter in a chase, a little higher otherwise), steering round what is
## in the way in a world with geometry (SimBird.avoid).
func _go(p: SimBird, want: Vector3, speed: float, dt: float, chasing: bool = false, fold: float = 0.0) -> void:
	if p.collide_world and p.escaping:
		# Wedged (a room, a fork of branches): out the most open way, at an
		# easy speed (a tight turn needs little speed, a stall none).
		want = p.escape_dir()
		fold = 0.0
		speed = lerpf(p.min_speed(), p.cruise_speed(), 0.5)
	elif p.collide_world and want.length_squared() > 1e-8:
		var round_it := p.avoid(want)
		if round_it.dot(want.normalized()) < 0.99:
			want = round_it
			fold = 0.0  # steering round something: wings open
	p.o_dir = want.normalized() if want.length_squared() > 1e-8 else p.heading
	p.o_speed = speed
	p.o_eff = 1.0
	p.o_fold = fold
	p.o_clear = 0.6 + p.get_body_radius() if chasing else maxf(1.5, 2.0 * p.get_wingspan())
	p.o_guard = true
	SimBrains.ground_guard(p)
	p.fly(p.o_dir, p.o_speed, dt, float(skill["turn_use"]), p.o_eff, p.o_fold)


## The predator the pilot is reacting to (set by aware_of).
var threat: Bird = null

## Half-angle of what a person sees in the headset (Quest Pro ~106 deg wide).
const VIEW_HALF_DEG := 53.0


## Is the pilot reacting to a threat, from what the game shows a player:
## the threat cue (ThreatWatch.level: audio / haptics / HUD, from any
## direction) once it is loud enough for this skill (with the default
## 3.5 s cue horizon that is a time-to-contact of ~1.4 s for a novice,
## 2.4 s competent, 3 s expert for an aimed attacker - so the cue's horizon
## is a real lever), or a bird the loop highlights as dangerous, in view and
## coming at the player, sooner (people see an attack from the front
## coming). A big bird merely cruising nearby is not an attack. Sets `threat`.
func aware_of(watch: ThreatWatch, p: Bird) -> bool:
	threat = null
	if watch.predator != null and is_instance_valid(watch.predator) and watch.level >= float(skill["cue_level"]):
		threat = watch.predator
		return true
	var pp := p.get_body_position()
	var fwd := p.get_forward()
	var cos_view := cos(deg_to_rad(VIEW_HALF_DEG))
	var horizon := float(skill["aware_view_ttc"])
	var best := INF
	for id: int in watch.highlights:
		if int(watch.highlights[id]) != 2:
			continue
		var q := instance_from_id(id) as Bird
		if q == null or not q.alive:
			continue
		var rel := q.get_body_position() - pp
		var d := rel.length()
		if d < 1e-3 or fwd.dot(rel / d) < cos_view:
			continue
		# Coming at the player, not just flying by (and, like the cue, read as
		# hunting it when the bird shows that).
		if q.get_forward().dot(-rel / d) < cos(deg_to_rad(35.0)) or ThreatWatch.intent_weight(q, p) < 1.0:
			continue
		var ttc := ThreatWatch.time_to_contact(pp, p.velocity, q.get_body_position(), q.velocity, 0.0)
		if ttc < best:
			best = ttc
			threat = q
	return best <= horizon


## Would this pilot chase this bird? Every skill follows the HUD's
## worthwhile-prey cues (SizeRules.is_worthwhile); skills differ in how
## they fly the chase, not in what they chase.
func wants(p: Bird, q: Bird) -> bool:
	return SizeRules.is_worthwhile(p.mass, q.mass)


## Ornstein-Uhlenbeck wobble about the yaw axis: arm jitter and imprecise
## banking, correlated over ~0.5 s like real steering errors.
func _wobble(dir: Vector3, dt: float) -> Vector3:
	var sigma := deg_to_rad(float(skill["noise_deg"]))
	var tau := 0.5
	_noise += (-_noise / tau) * dt + sigma * sqrt(2.0 * dt / tau) * rng.randfn(0.0, 1.0)
	return dir.rotated(Vector3.UP, _noise)
