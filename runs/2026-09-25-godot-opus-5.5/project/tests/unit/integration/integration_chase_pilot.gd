extends "res://tests/unit/integration/integration_pilot.gd"
## TEST-ONLY: a competent person chasing a bird through the real chain
## (integration round 1; the experience verifier's finding that the stock
## pilot - pure pursuit at where the bird is, flapping all the way in - never
## caught a fleeing wren). It sets only the pilot's commands; flight's
## BotPoseSource turns them into human arm motion and the real WingInput
## reads them, as before.
##
## What a competent player does, and nothing a person cannot:
##  * sees the bird REACT_S late (a person's tracking delay; the game loop's
##    modelled competent player uses 0.22 s);
##  * flies at where the bird will be: the intercept of its seen velocity
##    with the player's speed, LEAD of the way (a person under-leads),
##    never more than LEAD_MAX_S ahead;
##  * turns hard at it: a shorter L1 look-ahead than cruising (K_L1_CHASE);
##  * sprints: asks for SPRINT_VC x its cruise speed (the base pilot flies
##    speed on the wrists' pitch and height on the flap effort, so this
##    noses down and flaps harder; the verifier's lead pursuit did the
##    same);
##  * holds the bird's height and, in the last GLIDE_S before contact,
##    stops flapping and glides in (a wingbeat moves the body up and down
##    more than a small bird's reach; the gap course's pilot does the same);
##  * gives up nothing: the caller decides when a chase is over.

const REACT_S := 0.22
const LEAD := 0.8
const LEAD_MAX_S := 2.0
const K_L1_CHASE := 0.7
const GLIDE_S := 1.0
const SPRINT_VC := 1.35
## Glide in only when the bird is this close to the player's height (m, in
## body spans: a big bird's reach is bigger).
const GLIDE_DH_SPANS := 4.0

## The bird being chased (a Bird; null: fly as the base pilot).
var prey: Node3D = null
## Diagnostics.
var gliding := false
var tgo := INF

var _t := 0.0
var _seen: Array = []


func chase_prey(b: Node3D) -> void:
	prey = b
	_seen.clear()
	k_l1 = K_L1_CHASE
	k_vc = SPRINT_VC
	chase = true


func stop_chase() -> void:
	prey = null
	_seen.clear()
	k_l1 = 1.3
	k_vc = 1.0
	chase = false
	target = Vector3.INF
	gliding = false


func update(pos: Vector3, vel_raw: Vector3, airspeed: float, dt: float) -> void:
	_t += dt
	gliding = false
	tgo = INF
	# (A bird the Ecosystem removed lingers a frame before it is freed: out
	# of the tree its transform is not readable.)
	if prey == null or not is_instance_valid(prey) or not prey.is_inside_tree():
		super.update(pos, vel_raw, airspeed, dt)
		return
	var bp: Vector3 = prey.call(&"get_body_position") if prey.has_method(&"get_body_position") else prey.global_position
	var bv: Vector3 = prey.get(&"velocity") if prey.get(&"velocity") is Vector3 else Vector3.ZERO
	_seen.append([_t, bp, bv])
	while _seen.size() > 1 and float(_seen[1][0]) <= _t - REACT_S:
		_seen.pop_front()
	var sp: Vector3 = _seen[0][1]
	var sv: Vector3 = _seen[0][2]
	# (What the delay hides, a person extrapolates from what they saw.)
	var age := _t - float(_seen[0][0])
	sp += sv * age
	var rel := sp - pos
	var speed := maxf(vel_raw.length(), 1.0)
	# Intercept time: |rel + sv t| = speed t.
	var a := sv.dot(sv) - speed * speed
	var b := 2.0 * rel.dot(sv)
	var c := rel.dot(rel)
	var t_int := rel.length() / speed
	if absf(a) > 1e-4:
		var disc := b * b - 4.0 * a * c
		if disc >= 0.0:
			var r1 := (-b - sqrt(disc)) / (2.0 * a)
			var r2 := (-b + sqrt(disc)) / (2.0 * a)
			var best := INF
			for r in [r1, r2]:
				if r > 0.0 and r < best:
					best = r
			if best < INF:
				t_int = best
	t_int = minf(t_int, LEAD_MAX_S)
	target = sp + sv * t_int * LEAD
	chase = true
	super.update(pos, vel_raw, airspeed, dt)
	# The final glide: no wingbeat in the last moment.
	var closing := -(sv - vel_raw).dot(rel / maxf(rel.length(), 1e-3))
	tgo = rel.length() / maxf(closing, 0.5)
	if tgo < GLIDE_S and absf(rel.y) < GLIDE_DH_SPANS * params.span:
		flapping = false
		effort = 0.0
		gliding = true
