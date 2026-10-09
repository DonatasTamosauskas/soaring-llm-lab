extends "driver.gd"
## Gameplay capture input for runs/2026-08-09-godot-prime-muse-1.2 (tools/capture_gameplay_godot.sh).
##
## Uses the build's own desktop fallback (scripts/BirdPlayer.gd, _physics_process and _input):
##   SPACE  flap (held: one flap every 0.24 s)   Q / E  bank (simulated hands, one up, one down)
##   W / S  pitch the head down / up (dive, climb)
##   mouse  steering direction for flaps (it does not turn the view)
## There is no menu: the bird starts in the air at (0, 18, 0).
## Needs eval/capture-input/2026-08-09-godot-prime-muse-1.2.patch, which stops the desktop fallback
## from handing the window to XR; without it the window draws nothing.
## Reruns are not identical. The NPC birds are placed and steered with Godot's unseeded global random
## generator, and touching a bigger one shrinks the player (size 1.00 to 0.70 here), which changes its
## lift. Overriding random_seed() (see driver.gd) makes it repeatable, but the flight then differs from
## the published take. This build also reads real mouse motion over its window without capturing the
## cursor, so the pointer must stay off the window while it records.

#: seconds: 36
#: caption: Scripted flight on desktop, XR off, with the headset hand-off disabled: SPACE flaps, Q and E banks (this build also counts each bank key as a wing-stroke, so banks climb), long W dives and a mouse turn, from the start position in the air; the white capsule with pale wings ahead is the player's own bird, which this build's desktop camera sits behind, and the haze above about 60 m is its fog
#: still: 1.5 | Starting over the houses on a SPACE flap
#: still: 9 | Banking with Q low over the houses
#: still: 12.7 | Wings spread in a bank; the HUD shows size, flaps, airspeed and flight state
#: poster: 9


func timeline() -> Array:
	# This build counts the simulated hands jumping on a Q or E press or release as a wing-stroke, so
	# every bank also flaps and climbs. Long W dives between banks and few SPACE flaps keep the bird
	# low enough for the world to stay in view.
	return [
		[0.0, "note", "the bird starts in the air"],
		[0.5, "hold", KEY_SPACE, 0.25],          # one flap
		[2.0, "hold", KEY_E, 1.5],               # bank
		[4.0, "hold", KEY_W, 3.0],               # dive
		[7.5, "hold", KEY_Q, 2.0],               # bank the other way
		[10.0, "hold", KEY_W, 3.0],
		[13.5, "hold", KEY_SPACE, 0.25],
		[14.5, "hold", KEY_E, 2.0],
		[17.0, "hold", KEY_W, 3.0],
		[20.5, "mouse", 400, 0, 1.5],            # turn the steering direction right
		[22.5, "hold", KEY_Q, 2.0],
		[25.0, "hold", KEY_W, 3.0],
		[28.5, "hold", KEY_E, 2.0],
		[31.0, "hold", KEY_W, 3.0],
		[34.5, "hold", KEY_SPACE, 0.25],         # a last flap
	]


func report() -> String:
	var main := get_tree().current_scene
	var bird := main.get_node_or_null("BirdPlayer") as CharacterBody3D if main else null
	if bird == null:
		return ""
	var p := bird.global_position
	return "bird (%.0f, %.0f, %.0f) %.1f m/s, perched %s, size %.2f, score %s" % [
		p.x, p.y, p.z, bird.velocity.length(), bird.is_perched, bird.player_size, bird.score]
