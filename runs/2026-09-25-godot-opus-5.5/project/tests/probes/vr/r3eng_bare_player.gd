extends Bird
## TEST-ONLY (round-3 engineering probe): a player Bird with no mode_name(),
## the case VRCalibration.auto_capture_safe() falls back to Game.state for.


func is_player() -> bool:
	return true
