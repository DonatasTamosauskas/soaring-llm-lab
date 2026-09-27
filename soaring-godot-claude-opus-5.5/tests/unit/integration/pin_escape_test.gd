extends TestCase
## A flying bird is never pinned against the valley's rock (core loop fix
## round 1: through the real flight chain an eagle hung at 1.3 m/s against
## the west cliff under its overhang - AGL fixed, "flying", not stalled -
## for the last 10 minutes of a held-out run, and a hawk for 4 minutes at
## another spot of the same cliff; every unstick try of the person pilot,
## nose-down drop-outs included, failed). The real PlayerBird is put at
## those spots moving slowly into the face, flown with still wings, or with
## a steady bank away: it gets clear (more than 2 m from where it was put,
## and out of contact) within 3 s.

const PLAYER := preload("res://scenes/player/player.tscn")
const WORLD := preload("res://scenes/world/world.tscn")
const DT := 1.0 / 72.0

## [species, where, velocity into the face] - the pinned spots of the
## held-out runs (cl3_hold full 303, vcl1_hold quest 405).
const SPOTS := [
	[&"eagle", Vector3(-458.0, 54.6, 86.3), Vector3(-2.6, 0.0, 0.5)],
	[&"hawk", Vector3(-452.8, 36.5, 14.4), Vector3(-2.0, 0.0, 0.3)],
]

var world: World


func before_all() -> void:
	world = WORLD.instantiate() as World
	if &"with_environment" in world:
		world.set(&"with_environment", false)
	add_child(world)
	await wait_frames(3)


func after_all() -> void:
	if world != null and is_instance_valid(world):
		remove_child(world)
		world.free()
	await wait_frames(2)


## Flies a PlayerBird of species sp from `at` with velocity v for secs;
## bank: the arms' roll (0 = still wings). Returns [seconds until clear
## (-1: never), final distance from the start, trace lines].
func _fly(sp: StringName, at: Vector3, v: Vector3, bank: float, secs: float) -> Array:
	var body := HumanPoseModel.new(1)
	var src := ScriptedPoseSource.new(body, func(_tick: int, _t: float, b: HumanPoseModel) -> void:
		b.set_airplane()
		if bank != 0.0:
			b.synth(0.0, bank, 1.0, null))
	var p := PLAYER.instantiate() as PlayerBird
	p.auto_process = false
	p.use_settings = false
	p.default_source = &"none"
	p.mass = FlightParams.species_mass(sp)
	add_child(p)
	p.auto_calibrate = false
	p.set_pose_source(src)
	p.start_flying(at, atan2(-v.x, -v.z))
	p.model.velocity = v
	var start := p.model.position
	var clear_at := -1.0
	var trace: Array[String] = []
	for i in int(secs / DT):
		p.tick(DT)
		var m := p.model
		if i % 36 == 0:
			trace.append("t=%.1f pos=%s vel=%s air=%.2f wind=%s %s" % [i * DT, m.position.snapped(Vector3.ONE * 0.01),
					m.velocity.snapped(Vector3.ONE * 0.01), m.airspeed(), world.get_wind(m.position).snapped(Vector3.ONE * 0.1),
					p.mode_name()])
		if clear_at < 0.0 and m.position.distance_to(start) > 2.0:
			clear_at = (i + 1) * DT
	var moved := p.model.position.distance_to(start)
	src.driver = Callable()
	src.body = null
	remove_child(p)
	p.free()
	return [clear_at, moved, trace]


func test_a_bird_pressed_into_the_cliff_gets_clear() -> void:
	for s: Array in SPOTS:
		for bank: float in [0.0, 0.6]:
			var r := _fly(s[0], s[1], s[2], bank, 6.0)
			var tag := "%s at %s, %s" % [s[0], s[1], "still wings" if bank == 0.0 else "banking away"]
			print("[gameloop] %s: clear after %.2f s, moved %.1f m\n  %s" % [tag, r[0], r[1], "\n  ".join(r[2])])
			metric("pin_%s_%s" % [s[0], "still" if bank == 0.0 else "bank"], {"clear_s": r[0], "moved_m": r[1]})
			check(float(r[0]) >= 0.0 and float(r[0]) <= 3.0, "%s: more than 2 m clear within 3 s (%.2f s; %.1f m in 6 s)" % [tag, r[0], r[1]])

