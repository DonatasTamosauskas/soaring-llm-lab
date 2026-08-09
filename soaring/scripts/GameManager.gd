extends Node3D

@export var bird_scene: PackedScene
@export var target_bird_count: int = 26
@export var spawn_radius: float = 90.0

@onready var bird_container: Node3D = $Birds
@onready var world_root: Node3D = $World
@onready var player: CharacterBody3D = $BirdPlayer
@onready var hud: CanvasLayer = $HUD

var time_survived: float = 0.0
var birds_eaten: int = 0
var _bird_ps: PackedScene = preload("res://scenes/npc/Bird.tscn")

func _ready():
    # Use assigned scene or fallback
    if bird_scene == null:
        bird_scene = _bird_ps
    # ensure containers exist even if scene edited
    if bird_container == null:
        bird_container = Node3D.new()
        bird_container.name = "Birds"
        add_child(bird_container)
    # spawn birds safely
    for i in range(target_bird_count):
        var b = spawn_bird(false)
        if b == null:
            push_warning("[Soaring] spawn_bird returned null at index %d" % i)
    # connect player signals if present
    if player and player.has_signal("bird_caught"):
        if not player.bird_caught.is_connected(_on_player_ate):
            player.bird_caught.connect(_on_player_ate)
        if not player.player_caught_by.is_connected(_on_player_caught):
            player.player_caught_by.connect(_on_player_caught)
        if not player.size_changed.is_connected(_on_size_changed):
            player.size_changed.connect(_on_size_changed)
    print("[Soaring] GameManager ready — ", target_bird_count, " birds (player present: ", player != null, ")")

func _process(delta):
    if not is_finite(delta) or delta <= 0.0:
        return
    time_survived += delta
    # keep bird count — cap spawn rate so no explosion
    if bird_container == null:
        return
    var alive: int = bird_container.get_child_count()
    if alive < target_bird_count and randf() < 0.018:
        spawn_bird(true)
    # HUD update (all null-safe)
    if hud != null and hud.has_method("update_hud") and player != null:
        var spd: float = 0.0
        if is_instance_valid(player) and player is CharacterBody3D:
            spd = player.velocity.length() if is_finite(player.velocity.length()) else 0.0
        var p_size: float = player.player_size if ("player_size" in player) else 1.0
        var perched: bool = player.is_perched if ("is_perched" in player) else false
        var flaps: int = player.flap_count if ("flap_count" in player) else 0
        hud.update_hud(p_size, birds_eaten, spd, perched, flaps)
    # cloud drift
    if world_root != null and world_root.has_method("drift"):
        world_root.drift(delta)

func spawn_bird(far_from_player: bool) -> Node:
    var src: PackedScene = bird_scene if bird_scene != null else _bird_ps
    if src == null or not src.can_instantiate():
        push_error("[Soaring] bird_scene cannot instantiate")
        return null
    var npc: Node = src.instantiate()
    if npc == null:
        return null
    if bird_container == null or not is_instance_valid(bird_container):
        push_warning("[Soaring] no bird_container, freeing npc")
        npc.queue_free()
        return null
    bird_container.add_child(npc)
    # randomize size distribution: mostly smaller, some bigger
    var roll: float = randf()
    var sz: float
    if roll < 0.48:
        sz = randf_range(0.62, 0.88)
    elif roll < 0.78:
        sz = randf_range(0.88, 1.18)
    elif roll < 0.94:
        sz = randf_range(1.18, 1.52)
    else:
        sz = randf_range(1.52, 1.95)
    if "bird_size" in npc:
        npc.bird_size = sz
    # color variety
    var palettes: Array[Color] = [
        Color(0.89,0.78,0.25), Color(0.82,0.42,0.18), Color(0.35,0.58,0.92),
        Color(0.42,0.82,0.38), Color(0.92,0.38,0.58), Color(0.62,0.62,0.68),
        Color(0.18,0.18,0.18), Color(0.92,0.92,0.88)
    ]
    if "color" in npc:
        npc.color = palettes[randi() % palettes.size()].lerp(Color.WHITE, randf() * 0.22)
    # place — clamp height to world bounds
    var ang: float = randf() * TAU
    var rad: float = randf_range(18.0, spawn_radius)
    var h: float = randf_range(11.0, 41.0)
    var pos: Vector3 = Vector3(cos(ang) * rad, h, sin(ang) * rad)
    if far_from_player and player != null and is_instance_valid(player):
        var tries: int = 0
        while pos.distance_to(player.global_position) < 18.0 and tries < 6:
            ang = randf() * TAU
            rad = randf_range(28.0, spawn_radius + 18.0)
            h = randf_range(11.0, 41.0)
            pos = Vector3(cos(ang) * rad, h, sin(ang) * rad)
            tries += 1
    npc.global_position = pos
    return npc

func _on_player_ate(_v, _new_size):
    birds_eaten += 1

func _on_player_caught(_bigger):
    pass

func _on_size_changed(_s):
    pass

func is_finite(v: float) -> bool:
    return not is_nan(v) and not is_inf(v)
