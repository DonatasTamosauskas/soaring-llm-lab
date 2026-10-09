extends Node
## Every live Bird, for spatial queries (autoload "Birds").
##
## Birds register themselves in _enter_tree. AI, the game loop, HUD and audio
## query here instead of walking the scene tree.

var _birds: Array[Bird] = []
var _player: Bird = null


func register(b: Bird) -> void:
	if b in _birds:
		return
	_birds.append(b)
	if b.is_player():
		_player = b
	Events.bird_spawned.emit(b)


func unregister(b: Bird) -> void:
	var i := _birds.find(b)
	if i < 0:
		return
	_birds.remove_at(i)
	if b == _player:
		_player = null
	Events.bird_removed.emit(b)


func all() -> Array[Bird]:
	return _birds


func player() -> Bird:
	return _player


func count() -> int:
	return _birds.size()


## Live birds whose body is within radius of pos, excluding `exclude`.
func nearby(pos: Vector3, radius: float, exclude: Bird = null) -> Array[Bird]:
	var out: Array[Bird] = []
	var r2 := radius * radius
	for b in _birds:
		if b == exclude or not b.alive:
			continue
		if b.get_body_position().distance_squared_to(pos) <= r2:
			out.append(b)
	return out


## Nearest live bird to pos satisfying `filter` (Callable(Bird) -> bool).
func nearest(pos: Vector3, max_radius: float, filter: Callable = Callable(), exclude: Bird = null) -> Bird:
	var best: Bird = null
	var best_d2 := max_radius * max_radius
	for b in _birds:
		if b == exclude or not b.alive:
			continue
		var d2 := b.get_body_position().distance_squared_to(pos)
		if d2 < best_d2 and (not filter.is_valid() or filter.call(b)):
			best = b
			best_d2 = d2
	return best
