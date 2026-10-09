extends "driver.gd"
## Gameplay capture input for runs/2026-10-03-godot-sol-6.1 (tools/capture_gameplay_godot.sh).
##
## Uses the build's own desktop flight keys (scripts/flight/player.gd, _read_controls):
##   ENTER  launch from the nest menu          SPACE  flap (one flap per press)
##   A / D  bank left / right                   W / S  nose down / nose up
##   SHIFT  tuck the wings (dive, speed)        CTRL   spread the wings as a brake
## The bird starts at the nest (0, 18, 64) facing -Z, a few metres short of the Home Current thermal.
## No patch: with XR off the build already flies on desktop.

#: seconds: 36
#: caption: Scripted flight on desktop, XR off: launch from the nest menu with ENTER, flap with SPACE, bank with A and D, dive with SHIFT, glide over the valley
#: still: 4 | Climbing out of the nest on SPACE flaps
#: still: 11 | Banking over the Sunrise Quarter rooftops with A and D
#: still: 31 | Back over the town after a SHIFT dive and a long D bank
#: poster: 11


func timeline() -> Array:
	return [
		[0.0, "note", "nest menu on screen"],
		[2.5, "tap", KEY_ENTER],                 # launch: the Home Current thermal lifts the bird
		[3.0, "repeat", KEY_SPACE, 2, 0.5],      # two flaps
		[5.0, "hold", KEY_A, 0.9],               # bank left, toward the town quarter
		[6.5, "hold", KEY_W, 1.2],               # nose down toward the rooftops
		[10.0, "hold", KEY_D, 1.0],              # bank right over the town
		[11.5, "hold", KEY_A, 1.0],              # and back left
		[13.0, "repeat", KEY_SPACE, 3, 0.5],     # flap up
		[16.0, "hold", KEY_SHIFT, 1.2],          # tuck: dive for speed
		[17.5, "repeat", KEY_SPACE, 3, 0.45],    # flap back up
		[19.0, "hold", KEY_D, 2.2],              # long right bank, back toward the valley
		[23.0, "hold", KEY_W, 0.8],
		[25.0, "tap", KEY_SPACE],
		[27.0, "hold", KEY_A, 1.2],              # S-turn left, back over the town
		[28.5, "hold", KEY_W, 1.0],              # nose down toward the rooftops
		[30.5, "hold", KEY_D, 1.2],              # and right
		[33.5, "hold", KEY_CTRL, 2.0],           # spread wide: air brake
	]


func report() -> String:
	var main := get_tree().current_scene
	var bird := get_tree().root.find_child("BirdPlayer", true, false) as Node3D
	if bird == null or main == null:
		return ""
	var p := bird.global_position
	var zone: String = main.world.zone_at(p) if main.get("world") else ""
	return "bird (%.0f, %.0f, %.0f) %s, %s" % [p.x, p.y, p.z, main.get("state"), zone]
