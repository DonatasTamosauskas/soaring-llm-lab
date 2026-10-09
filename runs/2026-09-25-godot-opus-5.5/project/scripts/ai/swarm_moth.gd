class_name SwarmMoth
extends Bird
## One moth of a MothSwarm: the sky's "pellets" (core loop round, the lead's
## direction: "agar.io in the sky - moths and similar tiny prey are the
## pellets: plentiful, slow, drifting in open air in loose swarms along the
## player's likely paths, barely fleeing").
##
## A real Bird (in the Birds registry, caught through GameLoop's catch rule
## like any other, eaten by NPC wrens and sparrows too, ringed by the target
## cue) without a brain or a flight model: its swarm moves it (MothSwarm.step
## - a slot in a loose cloud round the swarm's drifting centre, a flutter,
## and a short dart away from a bird about to take it), so a moth costs a
## transform and a wingbeat a tick, not an NpcBird's think and steer. Swarms
## are placed in open air (clear of the world's geometry by more than their
## size), so a moth needs no collision of its own.

## The swarm it flutters in (null once it has left it: eaten or recycled).
var swarm: Node = null
var model: BirdModel = null
## Never in cover (the catch rule, the target cue and the AI read `hidden`).
var hidden := false
## A pellet: the target cue rates it as easy prey (ThreatWatch.prey_ease).
var pellet := true
## One of the catch lesson's moths (MothSwarm.lesson): while the lesson runs
## the target cue prefers it and looks for it further out (ThreatWatch).
var lesson := false
## The bird it is darting away from (SimPilot.fleeing_from reads `threat`:
## the person model's "has the prey noticed me?").
var threat: Bird = null

## Its place in the swarm's cloud (unit ball), flutter phases, and state.
var slot := Vector3.ZERO
var phase := Vector3.ZERO
var dart_left := 0.0
var dart_dir := Vector3.ZERO
var dart_cool := 0.0
## Seconds a predator has been close (the moth's reaction time runs on it).
var noticed_for := 0.0
var _flap := 0.0


func _init() -> void:
	species = &"moth"


func setup(p_mass: float, p_slot: Vector3, p_phase: Vector3) -> void:
	species = &"moth"
	mass = p_mass
	slot = p_slot
	phase = p_phase
	alive = true
	visible = true
	threat = null
	dart_left = 0.0
	dart_cool = 0.0
	noticed_for = 0.0
	velocity = Vector3.ZERO
	if model == null:
		model = BirdModels.create(&"moth")
		add_child(model)
	model.scale = Vector3.ONE * get_wingspan()
	model.perched = false
	model.wing_fold = 0.0
	model.flap_amount = 0.9


## Place the body and animate it (the swarm calls this every tick).
func place(pos: Vector3, vel: Vector3, dt: float) -> void:
	velocity = vel
	var sp := vel.length()
	var fwd := vel / sp if sp > 0.2 else -global_basis.z
	if absf(fwd.y) > 0.97:
		fwd = Vector3(fwd.x, 0.0, fwd.z).normalized() if Vector2(fwd.x, fwd.z).length() > 1e-3 else Vector3.FORWARD
	global_transform = Transform3D(Basis.looking_at(fwd, Vector3.UP), pos)
	if model:
		_flap = fposmod(_flap + dt * SpeciesProfile.flap_hz(mass), 1.0)
		model.flap_phase = _flap
		model.flap_amount = 0.9


func on_caught(by: Bird) -> void:
	if not visible and not alive:
		return
	alive = false
	visible = false
	threat = null
	if swarm != null and is_instance_valid(swarm) and swarm.has_method(&"on_moth_caught"):
		swarm.call(&"on_moth_caught", self, by)
	elif is_inside_tree():
		# Let this frame's listeners (VFX, audio, the game loop) read it first.
		get_tree().create_timer(0.5, false).timeout.connect(queue_free)
