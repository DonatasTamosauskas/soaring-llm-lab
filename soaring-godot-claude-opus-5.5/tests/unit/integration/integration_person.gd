extends RefCounted
## TEST-ONLY: a competent person playing the whole game through the real
## chain (integration round 2: the verifiers measured the brief's pacing with
## pilots that follow the target cue and nothing else - they never evaded,
## cruised 30 m up where crows patrol, flew into houses and stayed there -
## while the game loop's pacing evidence models a competent person who
## does all of that as a person would; the two disagreed 3x).
##
## This is the game loop's modelled competent player (SimPilot, skill
## "competent", and IntegratedSim's chase rules), flying the real PlayerBird
## through the real chain: every decision below is SimPilot's / IntegratedSim's,
## and the flying is integration's chase pilot (a person's 0.22 s tracking
## delay, an under-led intercept, a glide in the last second) through
## flight's BotPoseSource arm motion and the real WingInput. Nothing is
## staged or pinned: the real sky, the game's own catch assist and rules.
##
##  * aware of a threat (SimPilot.aware_of, the same code): the threat cue at
##    >= 0.31 (what the HUD arrow, the haptics and the predator's call follow),
##    or a bird the loop marks as dangerous in view coming at it (<= 3 s):
##    evades - sprints away from where the attacker is heading, re-aimed as
##    fast as it reacts, and breaks hard across each attack run at the
##    moment it would strike, if it sees the run coming (p 0.8, timing
##    error 0.15 s) - SimPilot.evade;
##  * otherwise hunts: keeps the bird it is on while it can see it, else
##    takes the HUD's target cue if it can see that bird, else the most
##    promising bird it can see (IntegratedSim._choose_target); sometimes
##    first works round behind and above an unaware bird (stalk 0.25); drops
##    a chase that stops closing, one out of sight for a second, and gives
##    up after 15 s x body time of running (IntegratedSim);
##  * otherwise searches: flies towards the nearest worthwhile bird it can
##    see (>= 5 px), or back towards the middle near the valley's edge, at
##    the height band its species lives in (SimPilot.search / cruise);
##  * sees obstacles ahead and steers round them (integration_person_pilot);
##    if wedged anyway (3 s without getting 1 m further), it backs out and
##    climbs away, as a person would.

const PersonPilot := preload("res://tests/unit/integration/integration_person_pilot.gd")
const LOS_LOST_S := IntegratedSim.LOS_LOST_S
const NO_PROGRESS_S := IntegratedSim.NO_PROGRESS_S
const CHASE_RANGE_SPANS := IntegratedSim.CHASE_RANGE_SPANS
const CHASE_RANGE_S := IntegratedSim.CHASE_RANGE_S
const VIS_ANGLE := IntegratedSim.VIS_ANGLE

var main: GameMain
var kit: RefCounted
var pilot: PersonPilot
var sim: SimPilot
var skill: Dictionary
var rng := RandomNumberGenerator.new()

var prey: Bird = null
var prey_id := 0
var ignore := {}
var _now := 0.0
var _target_t := 0.0
var _unseen_t := 0.0
var _progress_d := INF
var _progress_t := 0.0
var _stalk_of: Bird = null
var _stalking := false
# Evasion state (SimPilot.evade).
var _flee_dir := Vector3.ZERO
var _flee_next := 0.0
var _run := false
var _run_break := false
var _break_at := 0.0
var _break_left := 0.0
var _break_side := Vector3.ZERO
var _hist: Array = []
var _hist_of: Bird = null

## What the person did (seconds) and how chases ended.
var evading_s := 0.0
var chasing_s := 0.0
var searching_s := 0.0
var cruising_s := 0.0
var chases := 0
var chase_ends := {}
var chase_log: Array = []
var _chase_start := {}
var _eaten := {}
var mode := &"cruise"


func _init(p_kit: RefCounted, seed_value: int, skill_name: StringName = &"competent") -> void:
	kit = p_kit
	main = kit.get(&"main")
	sim = SimPilot.new(skill_name, seed_value * 31 + 7)
	skill = sim.skill
	rng.seed = seed_value * 7919 + 13
	kit.call(&"fly_bot", seed_value, PersonPilot)
	pilot = kit.get(&"pilot")
	kit.set(&"nav", &"heading")
	Events.bird_caught.connect(_on_caught)


func release() -> void:
	if Events.bird_caught.is_connected(_on_caught):
		Events.bird_caught.disconnect(_on_caught)


func _on_caught(pred: Bird, q: Bird) -> void:
	if pred == main.player:
		_eaten[q.get_instance_id()] = true


## One physics tick of decisions (call once per tick while the run is on).
func step(dt: float) -> void:
	_now += dt
	var p := main.player
	var loop := main.game_loop
	for id: int in ignore.keys():
		if float(ignore[id]) < _now:
			ignore.erase(id)
	if Game.state != Game.State.PLAYING or not p.alive:
		if prey_id != 0:
			_end_chase("player_caught" if Game.state == Game.State.CAUGHT else "paused")
		_calm_down()
		return
	var pp := p.get_body_position()
	if prey_id != 0 and (not is_instance_valid(prey) or not prey.is_inside_tree()):
		_end_chase("caught" if _eaten.has(prey_id) else "gone")
	# Wedged: the pilot backs out and climbs away by itself
	# (integration_person_pilot.gd); a chase it was on is given up. Standing
	# on the ground or a perch meanwhile (come down facing a wall), the
	# person first turns round on the spot to face the way out, as anyone
	# would (core loop round: the bot never turned, and launched into the
	# wall again and again).
	if pilot.unsticking:
		var tel_mode := String(p.telemetry().get("mode", ""))
		if (tel_mode == "grounded" or tel_mode == "perched") and absf(pilot.torso_turn) < 1e-3:
			var d: Vector3 = pilot.get(&"_unstick_dir")
			if Vector2(d.x, d.z).length() > 0.1:
				var want := atan2(-d.x, -d.z)
				var turn := wrapf(want - p.model.heading(), -PI, PI)
				if absf(turn) > deg_to_rad(20.0):
					pilot.torso_turn = turn
		mode = &"unstick"
		if prey_id != 0:
			ignore[prey_id] = _now + 5.0
			_end_chase("wedged")
		return
	# Aware of a threat (the game loop's own person model reads the cues).
	if sim.aware_of(loop.watch, p) and _ok(sim.threat):
		mode = &"evade"
		evading_s += dt
		_evade(p, sim.threat, dt)
		return
	_break_left = 0.0
	_run = false
	_flee_dir = Vector3.ZERO
	var want := _choose_target(p, loop)
	if want != prey:
		if prey_id != 0:
			var why := "lost"
			if _eaten.has(prey_id):
				why = "caught"
			elif not is_instance_valid(prey) or not prey.alive:
				why = "gone"
			elif loop.is_sheltered(prey, p.get_wingspan()):
				why = "sheltered"
			_end_chase(why)
		if want != null:
			_start_chase(want, p)
	if prey != null:
		_unseen_t = 0.0 if _sees(pp, prey.get_body_position()) else _unseen_t + dt
		if _unseen_t > LOS_LOST_S:
			ignore[prey_id] = _now + 5.0
			_end_chase("out_of_sight")
	if prey != null:
		var running := SimPilot.fleeing_from(prey) == p
		_target_t += dt if running else dt * 0.5
		chasing_s += dt
		var dnow := prey.get_body_position().distance_to(pp)
		if dnow < _progress_d * 0.9:
			_progress_d = dnow
			_progress_t = 0.0
		else:
			_progress_t += dt
		if running and _progress_t > NO_PROGRESS_S * SizeRules.time_scale(p.mass):
			_target_t = INF
		var gap := dnow - loop.rule.contact_distance(p.get_body_radius(), p.get_wingspan(), true, prey.get_body_radius())
		_chase_start["min_gap"] = minf(float(_chase_start.get("min_gap", INF)), gap / p.get_wingspan())
		if _target_t > float(skill["give_up_s"]) * SizeRules.time_scale(p.mass):
			ignore[prey_id] = _now + 5.0
			_end_chase("gave_up")
		else:
			mode = &"hunt"
			_hunt(p, dt)
			return
	# Nothing to chase: search, as a person looks for prey.
	var bounds := main.world.bounds_radius if main.world != null else INF
	var seen := _nearest_prey(p, loop)
	if Vector2(pp.x, pp.z).length() > bounds * 0.75:
		mode = &"search"
		searching_s += dt
		_fly_to(Vector3(0.0, pp.y, 0.0), p)
	elif seen != null:
		mode = &"search"
		searching_s += dt
		_fly_to(seen.get_body_position(), p)
	else:
		mode = &"cruise"
		cruising_s += dt
		var v := p.velocity
		var h := Vector3(v.x, 0.0, v.z)
		if h.length() < 0.5:
			h = p.get_forward()
			h.y = 0.0
		_fly_to(pp + h.normalized() * 60.0, p)


# --- hunting -------------------------------------------------------------------

## IntegratedSim._choose_target: stay on the bird it is on while it can see
## it; else the HUD's target cue if it can see that bird; else the most
## promising bird it can see.
func _choose_target(p: PlayerBird, loop: GameLoop) -> Bird:
	var pp := p.get_body_position()
	var span := p.get_wingspan()
	if prey != null and _ok(prey) and SizeRules.is_worthwhile(p.mass, prey.mass) \
			and prey.get_wingspan() / maxf(prey.get_body_position().distance_to(pp), 0.01) >= VIS_ANGLE * 0.6 \
			and not loop.is_sheltered(prey, span):
		return prey
	var w := loop.watch.target
	if w != null and _ok(w) and float(ignore.get(w.get_instance_id(), -1.0)) < _now \
			and _sees(pp, w.get_body_position()):
		return w
	var best: Bird = null
	var best_s := 0.0
	var chase_r := maxf(CHASE_RANGE_SPANS * span, CHASE_RANGE_S * SizeRules.cruise_speed(p.mass))
	for b in Birds.all():
		if b == p or not _ok(b) or not SizeRules.is_worthwhile(p.mass, b.mass):
			continue
		if float(ignore.get(b.get_instance_id(), -1.0)) >= _now or loop.is_sheltered(b, span):
			continue
		var d := b.get_body_position().distance_to(pp)
		if b.get_wingspan() / maxf(d, 0.01) < VIS_ANGLE or d > chase_r:
			continue
		var sc := SizeRules.meal_worth(p.mass, b.mass) * ThreatWatch.chase_odds(b.mass / p.mass) \
				* ThreatWatch.height_edge(pp.y - b.get_body_position().y, span) / (1.0 + d / (20.0 * span))
		if sc > best_s and _sees(pp, b.get_body_position()):
			best_s = sc
			best = b
	return best


func _start_chase(b: Bird, p: PlayerBird) -> void:
	prey = b
	prey_id = b.get_instance_id()
	_target_t = 0.0
	_unseen_t = 0.0
	_progress_d = INF
	_progress_t = 0.0
	chases += 1
	_chase_start = {"t": snappedf(Game.run_time, 0.1), "species": String(b.species), "pm": snappedf(p.mass * 1000.0, 0.1),
		"d0": snappedf(b.get_body_position().distance_to(p.get_body_position()), 0.1),
		"fleeing": SimPilot.fleeing_from(b) != null}
	if _stalk_of != b:
		_stalk_of = b
		_stalking = rng.randf() < float(skill["stalk"])


func _end_chase(why: String) -> void:
	chase_ends[why] = int(chase_ends.get(why, 0)) + 1
	if not _chase_start.is_empty():
		var rec := _chase_start.duplicate()
		rec["end"] = why
		rec["s"] = snappedf(Game.run_time - float(rec["t"]), 0.1)
		if is_finite(float(rec.get("min_gap", INF))):
			rec["min_gap"] = snappedf(float(rec["min_gap"]), 0.01)
		else:
			rec.erase("min_gap")
		chase_log.append(rec)
	_chase_start = {}
	prey = null
	prey_id = 0
	pilot.stop_chase()


## SimPilot.hunt through the chase pilot: stalk an unaware bird from behind
## and above first (sometimes), then the intercept.
func _hunt(p: PlayerBird, _dt: float) -> void:
	if _stalking:
		var noticed := SimPilot.fleeing_from(prey) == p
		var qp := prey.get_body_position()
		var aw := AiMirror.awareness_m(prey.species)
		var qf := prey.velocity.normalized() if prey.velocity.length_squared() > 0.01 else prey.get_forward()
		var set_point := qp - qf * aw * 0.45 + Vector3.UP * aw * 0.3
		var pp := p.get_body_position()
		if not noticed and set_point.distance_to(pp) > aw * 0.25 and pp.distance_to(qp) > aw * 0.5:
			if pilot.prey != null:
				pilot.stop_chase()
			pilot.target = set_point
			pilot.chase = true
			pilot.k_vc = float(skill["speed"])
			return
		_stalking = false
	if pilot.prey != prey:
		pilot.chase_prey(prey)


# --- evading -------------------------------------------------------------------

## SimPilot.evade: sprint away from where the attacker is heading, re-aimed
## as fast as the person reacts, and break hard across each attack run at
## the moment it would strike (if the person sees it coming).
func _evade(p: PlayerBird, threat: Bird, dt: float) -> void:
	if prey_id != 0 and pilot.prey != null:
		pilot.stop_chase()
	var seen := _perceive(threat, dt)
	var tp: Vector3 = seen[0]
	var tv: Vector3 = seen[1]
	var pp := p.get_body_position()
	var rel := pp - tp
	var d := maxf(rel.length(), 1e-4)
	var away := rel / d
	away.y *= 0.35
	var closing := (tv - p.velocity).dot(rel / d)
	var ahead := pp - (tp + tv * 0.3)
	ahead.y *= 0.35
	if _flee_dir == Vector3.ZERO or _now >= _flee_next:
		_flee_dir = ahead.normalized() if ahead.length_squared() > 1e-6 else away.normalized()
		_flee_next = _now + float(skill["react_s"])
	var want := _flee_dir
	var reach := AiMirror.strike_reach(threat.get_wingspan())
	var tts := maxf(d - reach, 0.0) / maxf(closing, 0.1)
	if closing > 0.5 and tts < 1.6:
		if not _run:
			_run = true
			_run_break = rng.randf() < float(skill["break_p"])
			_break_at = SimPilot.BREAK_AT_S + rng.randfn(0.0, float(skill["break_sd"]))
		if _run_break and tts < _break_at and _break_left <= 0.0:
			var u := tv / maxf(tv.length(), 0.1)
			var lat := rel - u * rel.dot(u)
			lat.y = 0.0
			if lat.length() < 0.05:
				lat = u.cross(Vector3.UP) * (1.0 if rng.randf() < 0.5 else -1.0)
			_break_side = lat.normalized()
			_break_left = SimPilot.BREAK_LEN_S
			_run_break = false
	elif tts > 2.5 or closing <= 0.0:
		_run = false
	if _break_left > 0.0:
		_break_left -= dt
		if d < SimPilot.TURN_FIGHT_SPANS * threat.get_wingspan() and _break_left <= 0.0:
			_break_left = dt
		var u2 := tv / maxf(tv.length(), 0.1)
		var side := _break_side - u2 * _break_side.dot(u2)
		if side.length_squared() < 1e-4:
			side = _break_side
		want = side.normalized() + Vector3.DOWN * 0.2 - u2 * 0.25
	_fly_dir(want.normalized(), SPRINT_VC_EVADE, true)


const SPRINT_VC_EVADE := 1.35


## What the person believes about `b` (react_s old, extrapolated by skill).
func _perceive(b: Bird, _dt: float) -> Array:
	if b != _hist_of:
		_hist.clear()
		_hist_of = b
	_hist.append([_now, b.get_body_position(), b.velocity])
	var react: float = skill["react_s"]
	while _hist.size() > 2 and float(_hist[1][0]) <= _now - react:
		_hist.pop_front()
	var h: Array = _hist[0]
	var ext := react * float(skill["lead"])
	return [h[1] + h[2] * ext, h[2]]


func _calm_down() -> void:
	_flee_dir = Vector3.ZERO
	_run = false
	_break_left = 0.0


# --- flying without a prey -------------------------------------------------------

## The nearest worthwhile bird the person can see (any distance, >= 5 px).
func _nearest_prey(p: PlayerBird, loop: GameLoop) -> Bird:
	var pp := p.get_body_position()
	var best: Bird = null
	var best_d := INF
	for b in Birds.all():
		if b == p or not _ok(b) or not SizeRules.is_worthwhile(p.mass, b.mass) or loop.is_sheltered(b, p.get_wingspan()):
			continue
		var d := b.get_body_position().distance_to(pp)
		if d < best_d and b.get_wingspan() / maxf(d, 0.01) >= VIS_ANGLE:
			best_d = d
			best = b
	return best


## Towards `goal` at cruise, at the height band the player's species lives
## in (SimPilot.cruise / search: AiMirror.ALT).
func _fly_to(goal: Vector3, p: PlayerBird) -> void:
	if pilot.prey != null:
		pilot.stop_chase()
	var band: Array = AiMirror.ALT.get(p.species, AiMirror.ALT[&"sparrow"])
	var lo := float(band[0]) + 3.0
	var hi := maxf(float(band[1]), lo + 5.0)
	pilot.agl = 0.5 * (lo + hi)
	pilot.chase = false
	pilot.k_vc = 1.0
	pilot.target = Vector3(goal.x, INF, goal.z)


## Along `dir` (y: climb or dive) at `vc` x cruise; `hold_height` flies the
## direction's height too.
func _fly_dir(dir: Vector3, vc: float, hold_height: bool) -> void:
	if pilot.prey != null:
		pilot.stop_chase()
	var pp := main.player.get_body_position()
	pilot.target = pp + dir * 40.0
	pilot.chase = hold_height
	pilot.k_vc = vc


## Alive and in the scene (a bird the Ecosystem removed may linger a frame
## before it is freed; its transform is then not readable).
static func _ok(b: Bird) -> bool:
	return b != null and is_instance_valid(b) and b.alive and b.is_inside_tree()


func _sees(from: Vector3, to: Vector3) -> bool:
	var q := PhysicsRayQueryParameters3D.create(from, to, 1)
	return pilot.space.intersect_ray(q).is_empty()


func summary() -> Dictionary:
	return {"evading_s": snappedf(evading_s, 0.1), "chasing_s": snappedf(chasing_s, 0.1),
		"searching_s": snappedf(searching_s, 0.1), "cruising_s": snappedf(cruising_s, 0.1), "unsticks": pilot.unsticks, "room_exits": pilot.room_exits,
		"chases": chases, "chase_ends": chase_ends, "avoid_ticks": pilot.avoid_ticks}
