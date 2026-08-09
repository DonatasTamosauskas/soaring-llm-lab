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

func _ready():
    # spawn birds
    for i in range(target_bird_count):
        spawn_bird(false)
    # connect player signals if present
    if player and player.has_signal("bird_caught"):
        player.bird_caught.connect(_on_player_ate)
        player.player_caught_by.connect(_on_player_caught)
        player.size_changed.connect(_on_size_changed)
    # timer to keep count
    print("[Soaring] GameManager ready — ", target_bird_count, " birds")

func _process(delta):
    time_survived += delta
    # keep bird count
    var alive = bird_container.get_child_count()
    if alive < target_bird_count and randf() < 0.018:
        spawn_bird(true)
    # HUD update
    if hud and hud.has_method("update_hud"):
        var spd = 0.0
        if player and player is CharacterBody3D:
            spd = player.velocity.length()
        hud.update_hud(player.player_size if player and "player_size" in player else 1.0, birds_eaten, spd, player.is_perched if player and "is_perched" in player else false, player.flap_count if player and "flap_count" in player else 0)
    # cloud drift
    if world_root and world_root.has_method("drift"):
        world_root.drift(delta)

func spawn_bird(far_from_player: bool):
    var npc = preload("res://scenes/npc/Bird.tscn").instantiate()
    bird_container.add_child(npc)
    # randomize size distribution: mostly smaller, some bigger
    var roll = randf()
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
    var palettes = [
        Color(0.89,0.78,0.25), Color(0.82,0.42,0.18), Color(0.35,0.58,0.92),
        Color(0.42,0.82,0.38), Color(0.92,0.38,0.58), Color(0.62,0.62,0.68),
        Color(0.18,0.18,0.18), Color(0.92,0.92,0.88)
    ]
    if "color" in npc:
        npc.color = palettes[randi()%palettes.size()].lerp(Color.WHITE, randf()*0.22)
    # place
    var ang = randf()*TAU
    var rad = randf_range(18, spawn_radius)
    var h = randf_range(11, 41)
    var pos = Vector3(cos(ang)*rad, h, sin(ang)*rad)
    if far_from_player and player:
        # ensure not in player's face
        var tries=0
        while pos.distance_to(player.global_position) < 18 and tries<6:
            ang = randf()*TAU; rad = randf_range(28, spawn_radius+18)
            pos = Vector3(cos(ang)*rad, h, sin(ang)*rad)
            tries+=1
    npc.global_position = pos
    # wire eaten callback to count
    # bird will respawn itself; we monitor via signal not needed
    return npc

func _on_player_ate(_v, _new_size):
    birds_eaten += 1

func _on_player_caught(_bigger):
    # camera shake handled in player
    pass

func _on_size_changed(_s):
    pass
