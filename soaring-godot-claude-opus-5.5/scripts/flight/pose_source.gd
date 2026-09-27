class_name PoseSource
extends RefCounted
## Where head and hand poses come from (FLIGHT_SPEC §3.1). Swappable:
## XRPoseSource (headset / simulator), ScriptedPoseSource (tests, replays),
## ReplayPoseSource, DesktopPoseSource (keyboard and mouse), BotPoseSource
## (the autopilot moving virtual arms) and HybridPoseSource (XR head,
## synthetic hands). Every one feeds the SAME WingInput: nothing but
## WingInput ever turns poses into flight commands.


## Fill `out` in place for this physics tick. Never allocate per tick.
func sample(_out: PoseFrame, _dt: float) -> void:
	pass


## True for synthetic sources: PlayerBird then writes the poses into the
## XRCamera3D / XRController3D nodes (scaled by world_scale) so wings, UI
## rays and screenshots look as they would in a headset.
func drives_nodes() -> bool:
	return false


## Called on respawn / when the source is attached.
func reset() -> void:
	pass


## Optional: forwarded input events (desktop mouse look, wheel).
func handle_input(_event: InputEvent) -> void:
	pass


## Optional human-readable description for logs and overlays.
func describe() -> String:
	return get_script().get_global_name() if get_script() else "PoseSource"
