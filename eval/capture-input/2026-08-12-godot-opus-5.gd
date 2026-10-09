extends "driver.gd"
## Gameplay capture input for runs/2026-08-12-godot-opus-5 (tools/capture_gameplay_godot.sh).
##
## Uses the build's own desktop input map (project.godot [input], read in
## scripts/player/BirdPlayer.gd, _gather_desktop_command):
##   SPACE  flap (wingbeats while held)    A / D  bank left / right
##   W / S  pitch down / up                SHIFT  tuck the wings (dive)
## The main menu is a panel in the 3D view that follows the mouse every frame (GameMenu._process), so
## its keyboard navigation is overridden by the pointer; the timeline clicks FLY with the mouse
## instead, at (640, 392) in the 1280x720 window, where the start-up capture shows it.
## The bird starts gliding 190 m above the valley floor at the world origin.
## No patch: with XR off the build already flies on desktop.

#: seconds: 36
#: caption: Scripted flight on desktop, XR off, from a fresh first launch: FLY clicked in the main menu, then SPACE wingbeats, W and SHIFT dives from 190 m down over the town, and A and D banks between its towers; the lines above the HUD are the game's first-launch coaching, and the dark ring in turns is its comfort vignette
#: still: 6 | Wingbeats over the town at 210 m, under the game's coaching line
#: still: 13 | Over the town at 131 m after the W and SHIFT dive
#: still: 27 | Banking past a tower at 131 m
#: poster: 27


func timeline() -> Array:
	return [
		[0.0, "note", "main menu on screen"],
		[3.0, "click", 640, 392],                # FLY
		[4.0, "hold", KEY_SPACE, 1.0],           # wingbeats
		[5.5, "hold", KEY_A, 1.5],               # bank left, toward the towers
		[7.5, "hold", KEY_W, 3.5],               # nose down: dive toward the town
		[7.5, "hold", KEY_SHIFT, 2.5],           # wings tucked for speed
		[11.0, "hold", KEY_S, 1.0],              # pull out of the dive
		[12.5, "hold", KEY_SPACE, 1.5],          # wingbeats to hold height
		[14.5, "hold", KEY_D, 2.0],              # bank right
		[17.0, "hold", KEY_SPACE, 1.0],
		[18.5, "hold", KEY_A, 2.5],              # long left bank
		[21.5, "hold", KEY_W, 1.5],              # lower again
		[23.5, "hold", KEY_SPACE, 1.5],
		[25.5, "hold", KEY_D, 1.5],              # S-turn
		[27.5, "hold", KEY_SPACE, 1.0],
		[29.0, "hold", KEY_A, 1.5],
		[31.0, "hold", KEY_W, 1.0],
		[33.0, "hold", KEY_SPACE, 1.5],
	]


func report() -> String:
	var main := get_tree().current_scene
	if main == null or main.get("player") == null:
		return ""
	var p: Vector3 = main.player.global_position
	var ground: float = main.world.height_at(p.x, p.z)
	return "bird (%.0f, %.0f, %.0f) %.0f m above ground, menu open %s, score %s" % [
		p.x, p.y, p.z, p.y - ground, main.menu.is_open, main.manager.score]
