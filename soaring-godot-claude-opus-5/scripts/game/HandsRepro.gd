class_name HandsRepro
extends Node

## Reproduces, locally and headlessly, what a player experiences when they put
## a headset on and hold the controllers a given distance apart.
##
## Drives the real [BirdPlayer] through the real [WingInput] with synthetic
## controller poses, in the real world, with real collisions — the whole chain
## a headset exercises, minus the headset. Built after a bug reached a Quest
## where holding the controllers naturally flew the bird into the ground in four
## seconds: every existing test covered [WingInput] alone, so nothing covered
## the path the player actually touches.
##
##   godot --headless --xr-mode off -- --hands=0.25

signal finished(passed: bool)

const HEAD_HEIGHT: float = 1.62
## How long to hold the pose before judging the outcome.
##
## A full minute, not fifteen seconds. The short version passed while the real
## failure was still unfolding: a bird with no input never banks, so it glides
## dead straight, and it takes about forty seconds to leave the populated part
## of the map entirely and end up over featureless ground with nothing in sight.
const DURATION: float = 60.0
## Below this the bird has effectively been flown into the ground.
const SURVIVAL_CLEARANCE: float = 12.0
## Furthest the nearest landmark may be before the player is, for all practical
## purposes, staring at an empty green field.
const MAX_LANDMARK_DISTANCE: float = 260.0

var player: BirdPlayer
var world: WorldBuilder

## Metres between the two controllers.
var separation: float = 0.25

var _elapsed: float = 0.0
var _start_altitude: float = 0.0
var _worst_clearance: float = INF
var _min_span: float = INF
var _max_span: float = -INF
var _perched_at: float = -1.0
var _worst_landmark: float = 0.0
var _grounded_time: float = 0.0
var _done: bool = false


func start(player_ref: BirdPlayer, world_ref: WorldBuilder, hand_separation: float) -> void:
	player = player_ref
	world = world_ref
	separation = hand_separation
	player.pose_source = _poses
	_start_altitude = player.altitude()
	print("")
	print("=== Hands-together repro: controllers %.2f m apart ===" % separation)
	print("  t     alt   clearance  span  speed  perched  landmark  from centre")


## A still, relaxed pose: hands out in front at chest height, [member
## separation] apart, palms down. Exactly what someone does when they pick up
## two controllers and wait to see what happens.
func _poses() -> Array:
	var head := Transform3D(Basis.IDENTITY, Vector3(0.0, HEAD_HEIGHT, 0.0))
	var half: float = separation * 0.5
	var left := Transform3D(Basis.IDENTITY, Vector3(-half, HEAD_HEIGHT - 0.25, -0.25))
	var right := Transform3D(Basis.IDENTITY, Vector3(half, HEAD_HEIGHT - 0.25, -0.25))
	return [head, left, right]


func _physics_process(delta: float) -> void:
	if player == null or _done:
		return
	_elapsed += delta

	var ground: float = world.height_at(player.global_position.x, player.global_position.z)
	var clearance: float = player.global_position.y - ground
	_worst_clearance = minf(_worst_clearance, clearance)
	_min_span = minf(_min_span, player.command.span)
	_max_span = maxf(_max_span, player.command.span)
	if player.perched:
		_grounded_time += delta
		if _perched_at < 0.0:
			_perched_at = _elapsed

	if fmod(_elapsed, 5.0) < delta:
		var landmark: float = _nearest_landmark()
		_worst_landmark = maxf(_worst_landmark, landmark)
		print("  %4.1f  %6.1f  %8.1f  %.2f  %5.1f  %s  %6.1f  %5.0f" % [
			_elapsed, player.altitude(), clearance, player.command.span,
			player.airspeed(), str(player.perched), landmark,
			Vector2(player.global_position.x, player.global_position.z).length()
		])

	if _elapsed >= DURATION:
		_done = true
		_report()


## Distance to the closest thing worth looking at. Uses the world's published
## perch points, which sit on every branch, ledge, wire and arch — a good proxy
## for "is there any scenery here at all".
func _nearest_landmark() -> float:
	var best: float = INF
	var here: Vector3 = player.global_position
	for i in range(0, world.perch_points.size(), 7):
		best = minf(best, here.distance_to(world.perch_points[i]))
	return best


func _report() -> void:
	player.pose_source = Callable()
	var problems: PackedStringArray = []
	# Touching down is not a failure — a glide has to end somewhere, and the
	# novice rescue puts them back up. Being *stranded* is the failure, and so is
	# spending the session on your face in a field.
	if player.perched:
		problems.append("still stranded on the ground at the end of the run")
	var grounded_fraction: float = _grounded_time / maxf(_elapsed, 0.001)
	if grounded_fraction > 0.25:
		problems.append(
			"spent %.0f%% of the run on the ground" % (grounded_fraction * 100.0)
		)
	if _min_span < 0.4:
		problems.append(
			"wings folded to %.2f — a still pose should never command a tuck"
			% _min_span
		)
	if _worst_landmark > MAX_LANDMARK_DISTANCE:
		problems.append(
			"flew out of the world — nearest landmark reached %.0f m, leaving nothing"
			% _worst_landmark + " to look at but ground and sky"
		)

	print("  span %.2f..%.2f, furthest landmark %.0f m, %.0f%% of the run grounded" % [
		_min_span, _max_span, _worst_landmark,
		100.0 * _grounded_time / maxf(_elapsed, 0.001)
	])
	if problems.is_empty():
		print("HANDS REPRO PASS — the bird was still flying after %.0fs" % DURATION)
	else:
		print("HANDS REPRO FAILED:")
		for p: String in problems:
			print("  - %s" % p)
	finished.emit(problems.is_empty())
