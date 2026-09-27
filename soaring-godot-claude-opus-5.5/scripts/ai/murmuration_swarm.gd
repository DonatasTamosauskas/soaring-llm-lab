class_name MurmurationSwarm
extends Node3D
## The murmuration's mass (integration round 2, the experience verifier: "8-13
## birds, a small flock rather than a murmuration" - the NPC budget, 60 on the
## desktop and 28 on the Quest, leaves the brief's signature sky life a
## handful of starlings, and the danger marks were most of what showed of
## it). Visual-only starlings wheel round the murmuration flock's own NPCs:
## BirdModels (the birds area's models, batched by BirdBatch like any bird)
## with no Bird, brain, flight or physics - never in Birds, never prey,
## threat, target or highlighted, never caught, no collisions. They cost a
## transform and a wingbeat each per tick.
##
## The motion is a murmuration's, cheaply: every bird keeps a place in a
## flattened cloud round the flock's centroid (its slot, fixed per bird);
## the cloud turns about a slowly wandering axis, breathes (its size pulses
## in a wave that runs through it) and stretches along the flock's travel,
## so the mass wheels and ripples the way the real flock's boids do, without
## a neighbour search. Headings follow each bird's own motion (a wing
## banks into its turn). Hidden, and parked, while there is no flying
## murmuration.

## Visual birds per NPC of the budget (45 at 60 NPCs, 21 at the Quest's
## 28, 16 at the governor's floor), within SIZE_MIN..SIZE_MAX. Each costs
## ~3 us of BirdBatch's draw sync and ~1 us of this step a frame on the M1
## (the Quest tier's 21: ~0.09 ms, x3-4 on the headset).
const PER_NPC := 0.75
const SIZE_MIN := 16
const SIZE_MAX := 45
## The cloud: radius (m) round the centroid, flattening, breathing.
const RADIUS := 4.5
const FLATTEN := 0.45
const BREATHE := 0.25
## Turn rate of the cloud (rad/s) and how fast its axis wanders.
const SPIN := 0.45
const AXIS_WANDER := 0.13
## A new flock position further than this from the last (m) is a respawn:
## the swarm snaps there instead of flying 200 m in one tick.
const JUMP_M := 60.0

var size := 0
var models: Array[BirdModel] = []
var _slot: PackedVector3Array = PackedVector3Array()
var _phase: PackedFloat32Array = PackedFloat32Array()
var _pos: PackedVector3Array = PackedVector3Array()
var _vel: PackedVector3Array = PackedVector3Array()
var _t := 0.0
var _c := Vector3.INF
var _cv := Vector3.ZERO
var _rng := RandomNumberGenerator.new()
var _span := 0.4


func _init(p_size: int = SIZE_MAX, seed_value: int = 7) -> void:
	name = "MurmurationSwarm"
	_rng.seed = seed_value
	_span = SizeRules.wingspan_for_mass(float(SizeRules.species_data(&"starling").get("mass", 0.1)))
	resize(p_size)
	visible = false


static func size_for_budget(max_npcs: int) -> int:
	return clampi(int(round(max_npcs * PER_NPC)), SIZE_MIN, SIZE_MAX)


## Sets the number of birds (the budget changed).
func resize(n: int) -> void:
	n = maxi(n, 0)
	while models.size() > n:
		var m: BirdModel = models.pop_back()
		m.queue_free()
	_slot.resize(n)
	_phase.resize(n)
	_pos.resize(n)
	_vel.resize(n)
	for i in range(models.size(), n):
		var m := BirdModels.create(&"starling")
		m.name = "Swarm_%d" % i
		m.scale = Vector3.ONE * _span
		add_child(m)
		models.append(m)
		# A slot in the unit ball (uniform in volume), and a phase.
		var d := Vector3(_rng.randfn(), _rng.randfn(), _rng.randfn()).normalized()
		_slot[i] = d * pow(_rng.randf(), 1.0 / 3.0)
		_phase[i] = _rng.randf() * TAU
		_pos[i] = Vector3.INF
		_vel[i] = Vector3.ZERO
	size = n


## One tick. `flock`: the murmuration (null or not flying: the swarm hides).
func step(dt: float, flock: FlockGroup) -> void:
	var flying := flock != null and flock.size() > 0 and flock.mood == FlockGroup.Mood.FLY
	if not flying or dt <= 0.0:
		if visible:
			visible = false
			_c = Vector3.INF
		return
	_t += dt
	var c := flock.centroid()
	if _c == Vector3.INF or c.distance_to(_c) > JUMP_M:
		_c = c
		_cv = Vector3.ZERO
		for i in size:
			_pos[i] = Vector3.INF
	else:
		var v := (c - _c) / dt
		_cv = _cv.lerp(v, 1.0 - exp(-dt / 0.6))
		_c = c
	visible = true
	# The cloud's orientation: spinning about an axis that wanders round the
	# vertical, stretched along the travel.
	var axis := Vector3(sin(_t * AXIS_WANDER) * 0.6, 1.0, cos(_t * AXIS_WANDER * 1.3) * 0.6).normalized()
	var rot := Basis(axis, _t * SPIN)
	var travel := Vector3(_cv.x, 0.0, _cv.z)
	var along := travel.normalized() if travel.length() > 0.5 else Vector3.FORWARD
	var stretch := 1.0 + clampf(travel.length() / 15.0, 0.0, 0.4)
	for i in size:
		var s := rot * _slot[i]
		s.y *= FLATTEN
		# Stretched along the travel.
		var a := s.dot(along)
		s += along * a * (stretch - 1.0)
		# A wave of breathing through the mass.
		var r := RADIUS * (1.0 + BREATHE * sin(_t * 1.1 + _phase[i] + a * 2.0))
		var want := _c + s * r
		var p := _pos[i]
		if p == Vector3.INF:
			p = want
			_vel[i] = _cv
		# Each bird chases its moving slot (a critically damped follow):
		# the mass flows rather than moving as a rigid body.
		var nv := _vel[i].lerp((want - p) * 2.2 + _cv, 1.0 - exp(-dt / 0.35))
		var acc := (nv - _vel[i]) / dt
		_vel[i] = nv
		p += nv * dt
		_pos[i] = p
		var m := models[i]
		var sp := nv.length()
		var fwd := nv / sp if sp > 0.3 else along
		var up := Vector3.UP if absf(fwd.y) < 0.95 else Vector3.BACK
		m.global_transform = Transform3D(Basis.looking_at(fwd, up).scaled(Vector3.ONE * _span), p)
		m.flap_phase = fmod(m.flap_phase + dt * 11.0, TAU)
		m.flap_amount = 0.55 + 0.35 * sin(_t * 0.9 + _phase[i])
		var lat := acc - fwd * acc.dot(fwd)
		m.bank = clampf(-lat.dot(fwd.cross(Vector3.UP)) / 20.0, -0.9, 0.9)


## Birds shown right now (0 when hidden).
func shown() -> int:
	return size if visible else 0


## Positions (tests).
func positions() -> PackedVector3Array:
	return _pos
