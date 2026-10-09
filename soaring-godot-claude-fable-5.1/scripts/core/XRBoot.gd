class_name XRBoot
extends RefCounted

## Brings up OpenXR if a runtime is present, otherwise leaves the viewport as a
## flat desktop window. Returns true when the headset (or simulator) is live.
static func start(viewport: Viewport) -> bool:
	var xr: XRInterface = XRServer.find_interface("OpenXR")
	if xr == null:
		print("[XRBoot] no OpenXR interface registered; desktop mode")
		return false
	if not xr.is_initialized() and not xr.initialize():
		print("[XRBoot] OpenXR failed to initialise; desktop mode")
		return false
	viewport.use_xr = true
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	print("[XRBoot] OpenXR live: %s" % xr.get_name())
	return true
