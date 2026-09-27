extends Node
## Measurement tool (not a test): runs the AI area's real Ecosystem in its
## test world around a mock player and reports the numbers the game-loop's
## AI mirror (scripts/game/sim/ai_mirror.gd) needs but the AI area does not
## publish: the energy calm birds carry and the energy prey have when they
## start fleeing (which decides how long they can sprint), and how often
## hunters go for the player. A snapshot, like the rest of AiMirror: it
## reads the AI's in-progress code once; nothing in the game-loop suite
## depends on it.
##
##   tools/gd.sh gameloop --headless res://tests/shots/gameloop_ai_snapshot.tscn -- [--seconds=240] [--player_mass=0.1]

const MockPlayer := preload("res://tests/unit/ai/mock_player.gd")
const EcoScene := preload("res://scenes/ai/ecosystem.tscn")
const DT := 1.0 / 36.0

var _flee_e: Array[float] = []
var _hunt_player := 0
var _player: Bird


func _ready() -> void:
	var args := Paths.user_args()
	var seconds := float(args.get("seconds", "240"))
	var w := AiTestWorld.new()
	w.world_seed = 1
	w.with_visuals = false
	w.with_environment = false
	add_child(w)
	for i in 3:
		await get_tree().physics_frame
	var p := MockPlayer.new()
	p.mass = float(args.get("player_mass", "0.1"))
	p.moving = true
	p.path_center = Vector3.ZERO
	p.path_radius = 80.0
	p.path_height = 25.0
	p.speed = SizeRules.performance(p.mass)["cruise"]
	p.protect_s = 5.0
	add_child(p)
	p.step(0.0)
	_player = p
	Game.state = Game.State.PLAYING
	var eco := EcoScene.instantiate() as Ecosystem
	eco.auto_step = false
	eco.max_npcs = 60
	eco.rng_seed = int(args.get("seed", "3"))
	eco.npc_spawned.connect(_on_spawned)
	add_child(eco)
	for i in 5:
		await get_tree().physics_frame
	var calm: Array[float] = []
	var all: Array[float] = []
	var n := int(seconds / DT)
	for i in n:
		p.step(DT)
		eco.step(DT)
		if i % int(2.0 / DT) == 0 and i * DT > 30.0:
			for b in Birds.all():
				var nb := b as NpcBird
				if nb == null or not nb.alive:
					continue
				all.append(nb.energy)
				if not nb.is_engaged():
					calm.append(nb.energy)
		if i % 3000 == 0:
			await get_tree().process_frame
	print("[gameloop] AI snapshot: player %.3f kg, %.0f s" % [p.mass, seconds])
	print("[gameloop]   calm energy  %s" % _q(calm))
	print("[gameloop]   all energy   %s" % _q(all))
	print("[gameloop]   flee-start energy %s (n=%d)" % [_q(_flee_e), _flee_e.size()])
	print("[gameloop]   hunts on the player %.2f / min" % (_hunt_player / ((seconds - 0.0) / 60.0)))
	get_tree().quit(0)


func _on_spawned(npc: NpcBird) -> void:
	if not npc.behaviour.is_connected(_on_behaviour):
		npc.behaviour.connect(_on_behaviour)


func _on_behaviour(b: NpcBird, what: StringName) -> void:
	if what == &"flee":
		_flee_e.append(b.energy)
	elif what == &"hunt" and b.target == _player:
		_hunt_player += 1


static func _q(xs: Array[float]) -> String:
	if xs.is_empty():
		return "-"
	var s := xs.duplicate()
	s.sort()
	var m := 0.0
	for x in s:
		m += x
	return "mean %.2f q10 %.2f q25 %.2f median %.2f q75 %.2f q90 %.2f" % [m / s.size(), s[s.size() / 10], s[s.size() / 4],
		s[s.size() / 2], s[(3 * s.size()) / 4], s[(9 * s.size()) / 10]]
