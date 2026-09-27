extends Node
## Global signal bus (autoload "Events").
##
## Areas talk through these signals instead of holding references to each
## other. Emit semantic facts ("the player flapped"), never presentation
## ("play sound X"): audio, haptics and UI each decide how to present them.
## See docs/ARCHITECTURE.md for who emits what.

# --- Game flow (emitted by Game autoload / GameLoop) ---
signal game_state_changed(new_state: int, old_state: int)
signal run_started()
signal run_ended(summary: Dictionary)

# --- Birds (emitted by whoever spawns/removes; GameLoop for catches) ---
signal bird_spawned(bird: Bird)
signal bird_removed(bird: Bird)
## predator ate prey. Emitted once per catch by GameLoop, which owns the rule.
signal bird_caught(predator: Bird, prey: Bird)

# --- Player (emitted by the player rig / GameLoop) ---
signal player_spawned(player: Bird)
signal player_caught(predator: Bird)
signal player_grew(old_mass: float, new_mass: float, tier: int)
signal player_tier_changed(old_tier: int, new_tier: int)
## side: -1 left wing, 1 right wing, 0 both. strength 0..1.
signal player_flapped(side: int, strength: float)
signal player_collided(impact_speed: float, normal: Vector3)
signal player_perched(perch_position: Vector3)
signal player_took_off()
signal player_stalled()
## 0 = nothing hunting you, 1 = something big is about to catch you.
signal threat_changed(level: float, predator: Bird)
## The closest edible bird the player is closing on (null when none).
signal target_changed(prey: Bird)

# --- UI / input ---
signal menu_requested()
signal recenter_requested()
signal settings_changed(key: String, value: Variant)
