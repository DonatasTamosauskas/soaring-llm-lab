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
const DURATION: float = 15.0
## Below this the bird has effectively been flown into the ground.
const SURVIVAL_CLEARANCE: float = 12.0

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
var _done: bool = false


func start(player_ref: BirdPlayer, world_ref: WorldBuilder, hand_separation: float) -> void:
	player = player_ref
	world = world_ref
	separation = hand_separation
	player.pose_source = _poses
	_start_altitude = player.altitude()
	print("")
	print("=== Hands-together repro: controllers %.2f m apart ===" % separation)
	print("  t     alt   clearance  span  speed  perched")


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
	if player.perched and _perched_at < 0.0:
		_perched_at = _elapsed

	if fmod(_elapsed, 2.0) < delta:
		print("  %4.1f  %6.1f  %8.1f  %.2f  %5.1f  %s" % [
			_elapsed, player.altitude(), clearance, player.command.span,
			player.airspeed(), str(player.perched)
		])

	if _elapsed >= DURATION:
		_done = true
		_report()


func _report() -> void:
	player.pose_source = Callable()
	var problems: PackedStringArray = []
	if _perched_at >= 0.0:
		problems.append(
			"flown into the ground after %.1fs of simply holding the controllers"
			% _perched_at
		)
	if _worst_clearance < SURVIVAL_CLEARANCE:
		problems.append(
			"came within %.1f m of the terrain" % _worst_clearance
		)
	if _min_span < 0.4:
		problems.append(
			"wings folded to %.2f — a still pose should never command a tuck"
			% _min_span
		)

	print("  span ranged %.2f..%.2f, worst clearance %.1f m, lost %.1f m" % [
		_min_span, _max_span, _worst_clearance, _start_altitude - player.altitude()
	])
	if problems.is_empty():
		print("HANDS REPRO PASS — the bird was still flying after %.0fs" % DURATION)
	else:
		print("HANDS REPRO FAILED:")
		for p: String in problems:
			print("  - %s" % p)
	finished.emit(problems.is_empty())
