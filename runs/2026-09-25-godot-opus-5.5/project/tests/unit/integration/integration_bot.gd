extends BotPoseSource
## TEST-ONLY: flight's bot body plus the one gesture it lacks, the dive tuck
## (hands pulled in to the chest, as DesktopPoseSource's Shift does), at a
## human elbow rate. Everything still goes through the real WingInput.

const TUCK_ELBOW := 150.0 * DEG
const ELBOW_RATE := 400.0 * DEG
## ...and (core loop round) turning round on the spot: standing on the
## ground or a perch, a person turns their whole body (torso, head and arms
## - the bird's heading follows the torso there) at this rate. The pilot
## asks for it with `torso_turn` (rad still to turn, + = left); without it
## a bot that had come down facing a wall (a room behind an open window, a
## corner of the village) launched into the wall again and again - two of
## eight Quest-tier runs sat 13-25 minutes by the spawn's street.
const TORSO_RATE := 120.0 * DEG

var _elbow := 0.0


func sample(out: PoseFrame, dt: float) -> void:
	if pilot != null and &"torso_turn" in pilot:
		var left: float = pilot.get(&"torso_turn")
		if absf(left) > 1e-4:
			var step := clampf(left, -TORSO_RATE * dt, TORSO_RATE * dt)
			body.torso_yaw += step
			pilot.set(&"torso_turn", left - step)
	super.sample(out, dt)
	var want := TUCK_ELBOW if pilot != null and bool(pilot.get(&"tuck")) else 0.0
	_elbow = move_toward(_elbow, want, ELBOW_RATE * dt)
	if _elbow > 1e-4:
		for a in body.arms:
			a.elbow = _elbow
			a.dihedral = 0.0
		body.frame(out)
