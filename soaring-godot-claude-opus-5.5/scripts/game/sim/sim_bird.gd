class_name SimBird
extends Bird
## A stand-in bird for game-loop tests, pacing simulations and the game-loop
## dev scene. It flies the AI area's NPC physics (SimFlight, a copy of
## NpcFlight) with the AI's energy budget (AiMirror), so a chase between
## SimBirds is as fair or unfair as one between real NPCs:
##  * level flight is capped at the speed the flapping effort holds (at most
##    the species' sprint, ~1.17-1.32 x cruise), and an NPC's effort is
##    capped by its energy, which a sprint drains in ~10-20 s;
##  * climbing costs speed, diving gains it (up to ~1.55 x cruise spread,
##    max_speed tucked in a stoop); hard turns bleed speed;
##  * turns roll in with the species' lag (a hawk needs ~0.3 s, a sparrow
##    0.1 s), so a big fast hunter overshoots a jinking bird.
## A pilot therefore cannot outrun a hunter by asking for more speed than a
## bird has - the fault the first version of these sims had (level flight up
## to dive speed let the player escape ~99.9% of attacks).
##
## Birds that never fly (most unit tests) just sit where they are put, with
## whatever `velocity` the test gives them.
##
## It deliberately depends only on core contracts (Bird, SizeRules) and the
## game-loop's own mirror of the AI: the real PlayerBird / NpcBird are built
## by other areas in parallel.
##
## Set player_mode BEFORE adding to the tree: Birds registers the player on
## enter. It then offers PlayerBird's respawn()/set_controls_enabled() API.

var player_mode := false
var controls_enabled := true
## 0..1 (AI energy): caps an NPC's flapping effort. The player's arms are
## the only limit on a human's flapping, so the player bird is tireless.
var energy := 1.0
var tireless := false
var respawn_count := 0
## Visual (BirdModel from BirdModels.create, or any Node3D with a
## `highlight` property); optional. NpcBird exposes the same name.
var model: Node3D = null
## Unit direction of flight; the node's basis is kept facing it (beak = -Z).
var heading := Vector3.FORWARD
## Airspeed, m/s.
var speed := 0.0:
	set(v):
		speed = v
		if flight != null:
			flight.speed = maxf(v, 0.01)
## Current flap animation phase for the model.
var flap_phase := 0.0
## What this bird is hunting (as NpcBird.target): the loop reads it for the
## threat cue's intent. SimBrains keeps it in step with its hunts; tests set
## it by hand.
var target: Bird = null
## Scratch state for brains (sim ecosystem / pilot); not used by the loop.
var brain := {}
var flight: SimFlight
## Flat ground height the bird keeps clear of (-INF = open air, no ground).
var ground_y := -INF
## Steering request of the current step (SimBrains fills it, as the AI's
## brain fills its _o_* fields, then applies the overlays and flies it).
var o_dir := Vector3.FORWARD
var o_speed := 9.0
var o_eff := 1.0
var o_fold := 0.0
var o_clear := 1.5
var o_guard := true
## Collide with the world's static geometry (physics layer 1), as the real
## player's flight does (continuous collision; glancing hits slide, head-on
## hits stun briefly), and see obstacles coming (avoid()). The pacing tool
## turns this on for the modelled player in the shipped valley: a pilot that
## flies through houses, trees and cliffs has shortcuts no person has. Off by
## default (open-air tests, the mirror sky), and needs a physics world.
var collide_world := false
## Take-offs from a stall on the ground (player only; diagnostics).
var ground_launches := 0
## Contacts with the world (diagnostics: how many, the last collider hit)
## and what is left of a head-on stun.
var world_hits := 0
var last_hit: Object = null
var stun_left := 0.0

var _flight_species := &""
var _col_q: PhysicsShapeQueryParameters3D = null
var _col_shape: SphereShape3D = null
## Touching the world at the end of the last step (a stun needs a new hit),
## and touching something other than the ground (a wall, a trunk: what
## wedges a bird; skimming the ground is not being stuck).
var _in_contact := false
var _against_wall := false
## Share of recent flight spent against a wall (not the ground; low-passed over
## CONTACT_TAU_S), and whether the bird is backing out of a place it is
## wedged in (see stuck()).
var contact_share := 0.0
var escaping := false
## Seconds spent backing out (diagnostics).
var stuck_s := 0.0
## Times the bird was pinned inside geometry and pushed out (see _unpin).
var unpins := 0
var _pin_from := Vector3.INF
var _pin_t := 0.0
## While getting out: the way out (re-looked for every ESCAPE_LOOK_S),
## where it started, and for how long.
var _esc_dir := Vector3.UP
var _esc_from := Vector3.ZERO
var _esc_t := 0.0
var _esc_look := 0.0
## Positions over the last PROGRESS_S (every PROGRESS_DT_S), and the
## farthest of them from here: how far the bird got - grinding along the
## ground or a wall at speed is not stuck, bouncing round a room is.
var _recent := PackedVector3Array()
var _recent_t := 0.0
var _roam := INF

## The collision sphere is this fraction of the body radius (the wings fold
## through gaps the body fits).
const COLLIDE_RADIUS_FRAC := 0.8
## A hit closer to head-on than this (cosine of the angle between the path
## and the surface normal) stuns: speed drops and the bird cannot steer for
## STUN_S, as FlightModel does to the player.
const STUN_COS := 0.7
const STUN_S := 0.5
const STUN_SPEED_KEEP := 0.3
## How far ahead (s of flight) a person looks for obstacles in the way.
const AVOID_LOOK_S := 1.0
## Wedged: touching the world for more than STUCK_SHARE of the last
## ~CONTACT_TAU_S while it has not got further than max(STUCK_ROAM_M, 10
## wingspans) from where it was over the last PROGRESS_S (pressing into the
## wall of a room it flew into, bouncing round the room, a fork of
## branches); free again below FREE_SHARE.
const CONTACT_TAU_S := 1.5
const STUCK_SHARE := 0.3
const FREE_SHARE := 0.1
const PROGRESS_S := 6.0
const PROGRESS_DT_S := 0.5
const STUCK_ROAM_M := 6.0
## Getting out: look round (rays up to ESCAPE_RAY_M) for the most open
## way every ESCAPE_LOOK_S and fly it slowly, until ESCAPE_CLEAR of the
## wedging distance from where it started (and at least ESCAPE_MIN_S), or
## ESCAPE_MAX_S.
const ESCAPE_RAY_M := 25.0
const ESCAPE_LOOK_S := 0.5
const ESCAPE_MIN_S := 1.5
const ESCAPE_MAX_S := 12.0
const ESCAPE_CLEAR := 1.5
## Surfaces facing up more than this (normal.y) are ground, not obstacles.
const GROUND_NORMAL_Y := 0.7
## Pinned: flying, yet not PIN_M further in PIN_S - the sphere is inside
## geometry its casts cannot leave (one fix round 3 valley run sat at the
## foot of a rock for 39 minutes: every cast started in contact and moved
## nothing, and the way-out rays, cast from inside, saw open air). The
## player's own flight pushes its body out of what it is inside; the model
## does the same: it moves to the nearest spot within PIN_SEARCH_M where
## its sphere (x1.5) overlaps nothing.
const PIN_S := 3.0
const PIN_M := 0.05
const PIN_SEARCH_M := 6.0


func _init() -> void:
	_refresh_perf()


func is_player() -> bool:
	return player_mode


func _enter_tree() -> void:
	if player_mode:
		tireless = true
	super()


func get_forward() -> Vector3:
	return heading


func respawn(xf: Transform3D) -> void:
	global_transform = xf
	var f := -xf.basis.z
	f.y = 0.0
	heading = f.normalized() if f.length_squared() > 1e-6 else Vector3.FORWARD
	# Launching off the perch: flying speed straight away.
	speed = cruise_speed() * 0.8
	flight.set_velocity(heading * speed)
	velocity = Vector3.ZERO
	respawn_count += 1
	# A new place: nothing of the old one's contacts or way out applies.
	_pin_from = Vector3.INF
	_pin_t = 0.0
	_recent.clear()
	_roam = INF
	escaping = false
	contact_share = 0.0
	_in_contact = false
	_against_wall = false
	stun_left = 0.0
	_orient()


func set_controls_enabled(on: bool) -> void:
	controls_enabled = on


## A meal (the loop calls this on the eater): like the AI's NPCs, a fed bird
## is no longer hungry, regains energy and stops hunting.
func on_ate(_prey: Bird, _mass_gained: float) -> void:
	energy = minf(1.0, energy + AiMirror.MEAL_ENERGY)
	brain["hunger"] = 0.0
	brain["prey"] = null
	target = null
	brain["stoop"] = false


func cruise_speed() -> float:
	return flight.cruise


func max_speed() -> float:
	return flight.max_speed


func min_speed() -> float:
	return flight.min_speed


## Fastest level flight at full effort (m/s).
func sprint_speed() -> float:
	return flight.sprint


## Fastest level flight at effort `e`, capped by energy for NPCs (m/s).
func level_speed(e: float = 1.0) -> float:
	return flight.level_speed(e if tireless else minf(e, _effort_cap()))


## Flapping effort of the last step (0..1).
func effort() -> float:
	return flight.effort


## How slow this bird's life is relative to a sparrow's: body lengths per
## second shrink as birds grow (span grows faster than cruise speed), so a
## chase between eagles takes longer in seconds than one between sparrows.
func time_scale() -> float:
	return SizeRules.time_scale(mass)


## Max turn rate (rad/s) at the current speed (the AI's load-factor limit).
func turn_rate_now() -> float:
	return flight.max_turn_rate(maxf(speed, 0.5))


## Points the bird (and its flight path) along dir, keeping its speed.
func set_heading(dir: Vector3) -> void:
	if dir.length_squared() > 1e-8:
		heading = dir.normalized()
		flight.set_velocity(heading * maxf(speed, 0.01))
		_orient()


## One flight step towards desired_dir at target_speed: SimFlight with the
## effort capped at max_effort (and by energy for NPCs), wings tucked by
## `fold` (1 = a stoop's full tuck). turn_use < 1 models a pilot who cannot
## use the whole turn envelope. Then move, spend energy, animate.
func fly(desired_dir: Vector3, target_speed: float, dt: float, turn_use: float = 1.0,
		max_effort: float = 1.0, fold: float = 0.0) -> void:
	if species != _flight_species:
		_refresh_perf()
	flight.speed = maxf(speed, 0.01)
	var cap := max_effort if tireless else minf(max_effort, _effort_cap())
	flight.turn_scale = turn_use
	var want := desired_dir if desired_dir.length_squared() > 1e-8 else heading
	if stun_left > 0.0:
		# Stunned by a head-on hit: no steering until it wears off.
		stun_left -= dt
		want = heading
	flight.step(dt, want, target_speed, cap, fold)
	speed = flight.speed
	heading = flight.dir()
	velocity = flight.air_velocity()
	if collide_world and is_inside_tree():
		_move_colliding(velocity * dt)
		_track_contact(dt)
		_check_pinned(dt)
	else:
		position += velocity * dt
	if position.y < ground_y + 0.05:
		# The AI's safety clamp: never below the ground, nose up again.
		position.y = ground_y + 0.05
		flight.gamma = maxf(flight.gamma, 0.1)
		flight.q = 0.0
		if player_mode and flight.speed < flight.min_speed:
			# Stalled on the ground (or the lake): a stall drops the nose to
			# regain speed, the ground forbids it, and the bird would crawl
			# along at a third of its stall speed for the rest of the run (a
			# calibration run spent 48 minutes so). A person flaps hard and
			# takes off, as the AI's NPCs launch off a perch.
			var f := Vector3(heading.x, 0.0, heading.z)
			f = f.normalized() if f.length_squared() > 1e-6 else Vector3.FORWARD
			flight.set_velocity((f * cos(0.3) + Vector3.UP * sin(0.3)) * flight.min_speed * 1.05)
			flight.effort = 1.0
			speed = flight.speed
			ground_launches += 1
		heading = flight.dir()
		velocity = flight.air_velocity()
	if not tireless:
		# The AI's metabolism: flapping drains, gliding regains a little.
		var e := flight.effort
		var gain := AiMirror.GLIDE_GAIN if e < 0.05 else 0.0
		energy = clampf(energy + (gain - AiMirror.drain(e)) * dt, 0.0, 1.0)
	flap_phase = fmod(flap_phase + dt * (3.0 + 6.0 / maxf(get_wingspan(), 0.1) * 0.25), 1.0)
	_orient()
	_animate_model()


## Moves by `motion` unless the world's static geometry is in the way: then
## up to the surface and on along it (up to three contacts a step, like
## move_and_slide), losing the speed into the surface; a new hit closer to
## head-on than STUN_COS also stuns.
func _move_colliding(motion: Vector3) -> void:
	var space := get_world_3d().direct_space_state
	if _col_q == null:
		_col_shape = SphereShape3D.new()
		_col_q = PhysicsShapeQueryParameters3D.new()
		_col_q.shape = _col_shape
		_col_q.collision_mask = 1
	_col_shape.radius = maxf(get_body_radius() * COLLIDE_RADIUS_FRAC, 0.005)
	var pos := global_position
	var rest := motion
	var v := velocity
	var touched := false
	var wall := false
	for i in 3:
		if rest.length_squared() < 1e-12:
			break
		_col_q.transform = Transform3D(Basis.IDENTITY, pos)
		_col_q.motion = rest
		var frac := space.cast_motion(_col_q)
		if frac.size() < 2 or frac[1] >= 1.0:
			pos += rest
			break
		# The surface: rest info just past the safe point.
		_col_q.transform = Transform3D(Basis.IDENTITY, pos + rest * frac[1])
		_col_q.motion = Vector3.ZERO
		var info := space.get_rest_info(_col_q)
		var n: Vector3 = info.get("normal", Vector3.ZERO)
		if n == Vector3.ZERO:
			n = -rest.normalized()
		if frac[0] <= 0.0 and rest.dot(n) >= 0.0:
			# Starting in contact (e.g. launching off a perch), moving away.
			pos += rest
			break
		pos += rest * frac[0] + n * 0.001
		rest *= 1.0 - frac[0]
		rest -= n * minf(rest.dot(n), 0.0)
		var vn := v.dot(n)
		wall = wall or n.y <= GROUND_NORMAL_Y
		if vn < 0.0:
			if not touched:
				touched = true
				world_hits += 1
				last_hit = instance_from_id(int(info.get("collider_id", 0)))
				if not _in_contact and -vn / maxf(v.length(), 1e-3) > STUN_COS:
					stun_left = STUN_S
					v *= STUN_SPEED_KEEP
					vn *= STUN_SPEED_KEEP
					rest *= STUN_SPEED_KEEP
			v -= n * vn
	global_position = pos
	_in_contact = touched
	_against_wall = wall
	if touched:
		if v.length_squared() < 1e-6:
			v = heading * 0.01
		flight.set_velocity(v)
		speed = flight.speed
		heading = flight.dir()
		velocity = flight.air_velocity()


func _track_contact(dt: float) -> void:
	contact_share += ((1.0 if _against_wall else 0.0) - contact_share) * minf(dt / CONTACT_TAU_S, 1.0)
	_recent_t -= dt
	if _recent_t <= 0.0:
		_recent_t = PROGRESS_DT_S
		_recent.append(global_position)
		if _recent.size() > int(PROGRESS_S / PROGRESS_DT_S) + 1:
			_recent.remove_at(0)
		_roam = 0.0 if _recent.size() > int(PROGRESS_S / PROGRESS_DT_S) else INF
		if is_finite(_roam):
			for q in _recent:
				_roam = maxf(_roam, q.distance_to(global_position))
	var wedge := maxf(STUCK_ROAM_M, 10.0 * get_wingspan())
	if escaping:
		stuck_s += dt
		_esc_t += dt
		_esc_look -= dt
		if _esc_look <= 0.0:
			_esc_look = ESCAPE_LOOK_S
			_esc_dir = _most_open_dir()
		if (_esc_t >= ESCAPE_MIN_S and global_position.distance_to(_esc_from) > wedge * ESCAPE_CLEAR) \
				or _esc_t > ESCAPE_MAX_S:
			escaping = false
			contact_share = 0.0
			_recent.clear()
			_roam = INF
	elif contact_share > STUCK_SHARE and _roam < wedge:
		escaping = true
		_esc_t = 0.0
		_esc_look = 0.0
		_esc_from = global_position


func _check_pinned(dt: float) -> void:
	if _pin_from == Vector3.INF or global_position.distance_to(_pin_from) > PIN_M:
		_pin_from = global_position
		_pin_t = 0.0
		return
	_pin_t += dt
	if _pin_t < PIN_S:
		return
	_unpin()
	_pin_from = global_position
	_pin_t = 0.0


## Moves the bird to the nearest free spot (see PIN_S) and launches it from
## there; tells the game loop it jumped (not a swept flight path).
func _unpin() -> void:
	var space := get_world_3d().direct_space_state
	var q := PhysicsShapeQueryParameters3D.new()
	var sh := SphereShape3D.new()
	sh.radius = maxf(get_body_radius() * COLLIDE_RADIUS_FRAC * 1.5, 0.01)
	q.shape = sh
	q.collision_mask = 1
	var here := global_position
	var dirs: Array[Vector3] = [Vector3.UP]
	for el in [0.5, 0.0, -0.5]:
		for k in 8:
			var a := TAU * k / 8.0
			dirs.append(Vector3(sin(a) * cos(el), sin(el), cos(a) * cos(el)))
	for r in [0.5, 1.0, 2.0, 3.0, 4.5, PIN_SEARCH_M]:
		for d in dirs:
			var p: Vector3 = here + d * float(r)
			q.transform = Transform3D(Basis.IDENTITY, p)
			if space.intersect_shape(q, 1).is_empty():
				global_position = p
				unpins += 1
				escaping = false
				contact_share = 0.0
				_recent.clear()
				_roam = INF
				_in_contact = false
				_against_wall = false
				var f := Vector3(heading.x, 0.0, heading.z)
				f = f.normalized() if f.length_squared() > 1e-6 else Vector3.FORWARD
				flight.set_velocity((f * cos(0.3) + Vector3.UP * sin(0.3)) * flight.min_speed * 1.05)
				speed = flight.speed
				heading = flight.dir()
				velocity = flight.air_velocity()
				var gl := GameLoop.find(get_tree())
				if gl != null:
					gl.teleported(self)
				return


## The way out of where the bird is wedged: of 26 directions round it, the
## one with the most free air (to ESCAPE_RAY_M), as a person looks for the
## window of a room they flew into or the gap in a canopy.
func _most_open_dir() -> Vector3:
	var space := get_world_3d().direct_space_state
	var here := global_position
	var best := Vector3.UP
	var best_d := -1.0
	for el in [-0.5, 0.0, 0.5]:
		for k in 8:
			var a := TAU * k / 8.0
			var d := Vector3(sin(a) * cos(el), sin(el), cos(a) * cos(el))
			var free := _free_along(space, here, d)
			if free > best_d + 0.01:
				best_d = free
				best = d
	for d: Vector3 in [Vector3.UP, Vector3.DOWN]:
		var free := _free_along(space, here, d)
		if free > best_d + 0.01:
			best_d = free
			best = d
	return best


func _free_along(space: PhysicsDirectSpaceState3D, from: Vector3, dir: Vector3) -> float:
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, from + dir * ESCAPE_RAY_M, 1))
	return ESCAPE_RAY_M if hit.is_empty() else from.distance_to(hit["position"])


## The way out while escaping (see _most_open_dir).
func escape_dir() -> Vector3:
	return _esc_dir


## Whether the bird can see `pos` (no static geometry in between). Always
## true in open air (collide_world off).
func sees(pos: Vector3) -> bool:
	if not collide_world or not is_inside_tree():
		return true
	var q := PhysicsRayQueryParameters3D.create(global_position, pos, 1)
	return get_world_3d().direct_space_state.intersect_ray(q).is_empty()


## A person sees an obstacle in the flight path and steers round it: a ray
## AVOID_LOOK_S of flight ahead; when it hits, the wanted direction loses its
## part into the surface and turns away from it and up, the harder the
## nearer. No-op unless collide_world.
func avoid(want: Vector3) -> Vector3:
	if not collide_world or not is_inside_tree():
		return want
	var look := clampf(maxf(speed, cruise_speed()) * AVOID_LOOK_S, 3.0 * get_wingspan() + 1.0, 30.0)
	var from := global_position
	var space := get_world_3d().direct_space_state
	var out := want.normalized()
	# Where the bird is going, and where the pilot wants to go.
	var vdir := velocity.normalized() if velocity.length_squared() > 0.01 else heading
	for dir: Vector3 in [vdir, out]:
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, from + dir * look, 1))
		if hit.is_empty():
			continue
		var n: Vector3 = hit["normal"]
		if n.y > GROUND_NORMAL_Y:
			# Ground-like (terrain, a roof): the ground guard keeps the bird's
			# clearance above the ground (SimBrains.ground_guard, pull-out
			# aware); seen here too it would stop every stoop on prey near
			# the ground.
			continue
		var urgency := clampf(1.0 - from.distance_to(hit["position"]) / look, 0.0, 1.0)
		out -= n * minf(out.dot(n), 0.0)
		out += (n * 0.5 + Vector3.UP).normalized() * (0.3 + urgency * 1.7)
		out = out.normalized() if out.length_squared() > 1e-8 else Vector3.UP
	return out


func attach_model() -> void:
	if model != null:
		return
	model = BirdModels.create(species)
	add_child(model)
	_scale_model()


func _on_mass_changed() -> void:
	_refresh_perf()
	_scale_model()


## The AI's effort cap from energy (the floor is what level flight needs).
func _effort_cap() -> float:
	return clampf(0.35 + energy * 1.5, minf(flight.p_min_frac + 0.2, 1.0), 1.0)


func _refresh_perf() -> void:
	var v := heading * maxf(speed, 0.01)
	if flight == null:
		flight = SimFlight.new(mass, AiMirror.glide_ratio(species))
	else:
		flight.configure(mass, AiMirror.glide_ratio(species))
	_flight_species = species
	flight.set_velocity(v)
	flight.speed = maxf(speed, 0.01)


func _scale_model() -> void:
	if model != null:
		model.scale = Vector3.ONE * get_wingspan()


func _orient() -> void:
	if heading.length_squared() < 1e-8:
		return
	var up := Vector3.UP if absf(heading.y) < 0.99 else Vector3.BACK
	basis = Basis.looking_at(heading, up)


func _animate_model() -> void:
	if model == null or not "flap_phase" in model:
		return
	model.set(&"flap_phase", flap_phase)
	model.set(&"flap_amount", clampf(flight.effort * 1.2, 0.2, 1.0))
	model.set(&"wing_fold", flight.fold)
