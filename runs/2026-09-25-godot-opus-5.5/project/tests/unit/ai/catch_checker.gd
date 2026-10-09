extends RefCounted
## TEST-ONLY stand-in for GameLoop's catch rule (the gameloop area owns the
## real one; scripts/ai never decides catches).
##
## Mirrors the contract in docs/ARCHITECTURE.md: a predator catches prey when
## Bird.can_eat(prey) and their bodies touch (centre distance <= sum of body
## radii) - then prey.on_caught(predator) and predator.on_ate(prey, gain).
## A player marked protected (meta npc_ignore, as GameLoop does after a
## respawn) is not caught, and neither is a bird hidden in cover (`hidden`,
## as GameLoop's CatchRule.is_hidden).
## Contact is swept over the tick (closest approach of the two straight
## segments), so a fast bird cannot tunnel through a small one between ticks;
## `swept = false` gives the naive per-tick point check for comparison.
## `reach` adds a margin as a fraction of the predator's wingspan (0 = the
## strict contract; the real GameLoop adds a small talon reach).
##
## Broadphase: every 0.25 s the pairs that could possibly touch before the
## next rebuild (by their max speeds) become candidates; only those are
## tested each tick.

var swept := true
var reach := 0.0
## [{t, predator, prey, pred_species, prey_species, position}]
var catches: Array = []
var t := 0.0

var _prev := {}
var _cands: Array = []
var _rebuild := 0.0
var _vmax := {}


func reset() -> void:
	catches.clear()
	_prev.clear()
	_cands.clear()
	_rebuild = 0.0
	t = 0.0


func _vmax_of(b: Bird) -> float:
	var id := b.get_instance_id()
	if not _vmax.has(id):
		_vmax[id] = float(SizeRules.performance(b.mass)["max_speed"]) + 3.0
	return _vmax[id]


## Call once per simulation tick, after every bird has moved.
func step(dt: float) -> void:
	t += dt
	var birds := Birds.all()
	_rebuild -= dt
	if _rebuild <= 0.0:
		_rebuild = 0.25
		_cands.clear()
		for i in birds.size():
			var a := birds[i]
			if not a.alive:
				continue
			var pa := a.get_body_position()
			for j in range(i + 1, birds.size()):
				var c := birds[j]
				if not c.alive:
					continue
				var ac := SizeRules.can_eat(a.mass, c.mass)
				var ca := SizeRules.can_eat(c.mass, a.mass)
				if not ac and not ca:
					continue
				var lim := (_vmax_of(a) + _vmax_of(c)) * 0.3 + a.get_body_radius() + c.get_body_radius() \
						+ reach * maxf(a.get_wingspan(), c.get_wingspan()) + 1.0
				if pa.distance_squared_to(c.get_body_position()) < lim * lim:
					_cands.append([a, c] if ac else [c, a])
	for pair in _cands:
		var pred: Bird = pair[0]
		var prey: Bird = pair[1]
		if not is_instance_valid(pred) or not is_instance_valid(prey) or not pred.alive or not prey.alive:
			continue
		if not pred.can_eat(prey):
			continue
		# A protected player (GameLoop's respawn protection, meta npc_ignore)
		# cannot be caught.
		if prey.is_player() and bool(prey.get_meta(&"npc_ignore", false)):
			continue
		# Birds in cover are out of play (GameLoop's CatchRule.is_hidden).
		if _hidden(pred) or _hidden(prey):
			continue
		var p1 := pred.get_body_position()
		var q1 := prey.get_body_position()
		var p0: Vector3 = _prev.get(pred.get_instance_id(), p1)
		var q0: Vector3 = _prev.get(prey.get_instance_id(), q1)
		var contact := pred.get_body_radius() + prey.get_body_radius() + reach * pred.get_wingspan()
		if _touch(p0, p1, q0, q1, contact):
			prey.on_caught(pred)
			pred.on_ate(prey, prey.mass * 0.5)
			catches.append({"t": t, "predator": pred, "prey": prey,
				"pred_species": pred.species, "prey_species": prey.species, "position": q1})
	for b in birds:
		_prev[b.get_instance_id()] = b.get_body_position()


static func _hidden(b: Object) -> bool:
	var h: Variant = b.get(&"hidden")
	return h is bool and h


func _touch(p0: Vector3, p1: Vector3, q0: Vector3, q1: Vector3, contact: float) -> bool:
	if not swept:
		return p1.distance_to(q1) <= contact
	var d0 := q0 - p0
	var dv := (q1 - q0) - (p1 - p0)
	var a := dv.length_squared()
	var s := 1.0
	if a > 1e-12:
		s = clampf(-d0.dot(dv) / a, 0.0, 1.0)
	return (d0 + dv * s).length() <= contact


func count_by_predator() -> Dictionary:
	var out := {}
	for c in catches:
		var k := String(c["pred_species"])
		out[k] = out.get(k, 0) + 1
	return out
