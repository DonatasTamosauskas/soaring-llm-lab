extends "driver.gd"
## Gameplay capture input for runs/2026-09-25-godot-opus-5.5 (tools/capture_gameplay_godot.sh).
##
## Uses the build's own desktop controls, which move virtual arms through the same wing input as a
## headset (scripts/flight/pose_sources/desktop_pose_source.gd):
##   ENTER  Play (the focused main-menu button)   SPACE  flap (strokes while held)
##   A / D  roll left / right                     W / S  wrists down / up (pitch)
##   SHIFT  hands to the chest (tuck, dive)
## Not its SimPilot or --harness shots: the same kind of key timeline as the other builds.
## The bird waits on the spawn perch until the first flap. No patch.

#: seconds: 36
#: caption: Scripted flight on desktop, XR off, from a fresh first launch: Play from the main menu with ENTER, take off from the perch with SPACE flaps, then W for speed, A and D rolls, a SHIFT dive and more flaps; the game's first-flight lessons at the top advance as the input does what they ask
#: still: 6.5 | Taking off from the spawn perch with SPACE, while the game's lesson asks for exactly that
#: still: 14 | Gliding past the village church; the tutorial counts the glide
#: still: 25 | Over the lake and fields after A and D rolls
#: poster: 14


func timeline() -> Array:
	return [
		[0.0, "note", "main menu (up after about 2 s of loading)"],
		[3.0, "tap", KEY_ENTER],                 # Play
		[4.0, "hold", KEY_SPACE, 3.0],           # flap off the perch and climb
		[7.5, "hold", KEY_W, 2.0],               # wrists down: nose down for speed
		[10.0, "hold", KEY_A, 1.2],              # roll left
		[12.0, "hold", KEY_SPACE, 2.0],          # flap with the wrists down: forward, not up
		[12.0, "hold", KEY_W, 2.0],
		[15.0, "hold", KEY_D, 1.2],              # roll right
		[17.0, "hold", KEY_SPACE, 2.0],
		[17.0, "hold", KEY_W, 2.0],
		[20.0, "hold", KEY_A, 1.5],              # roll left
		[22.5, "hold", KEY_SPACE, 2.0],
		[22.5, "hold", KEY_W, 2.0],
		[25.5, "hold", KEY_D, 1.5],              # roll right
		[27.5, "hold", KEY_SHIFT, 1.0],          # tuck: short dive
		[29.0, "hold", KEY_SPACE, 2.0],
		[29.0, "hold", KEY_W, 2.0],
		[32.0, "hold", KEY_A, 1.5],
		[34.0, "hold", KEY_W, 1.5],
	]


func report() -> String:
	var game := get_node_or_null("/root/Game")
	var main := get_tree().current_scene
	var bird := main.get_node_or_null("Player") if main else null
	var text := "state %s" % (game.state_name() if game else "?")
	if bird and bird.has_method("telemetry"):
		var t: Dictionary = bird.telemetry()
		var p: Vector3 = bird.global_position
		text += " bird (%.0f, %.0f, %.0f) %.0f m up, %.1f m/s, flapping %s, perched %s" % [
			p.x, p.y, p.z, t.get("altitude_agl", 0.0), t.get("airspeed", 0.0), t.get("flapping"), t.get("perched")]
	return text
