extends TestCase
## VERIFIER PROBE (round 6, experience lens). Not part of the UI suite.
##
## The UI's own notice tests replay flights as [time, flight-path angle,
## speed] with the flight path's azimuth locked to the rig's forward. The
## real game (ui_r6x_real_game_test / real_trace.csv) shows the flight
## path's azimuth in rig space is not locked: a steep zoom after a dive goes
## over the top (heading and facing flip ~180 deg while the view does not),
## and a slow bird crabs or drifts with the breeze (WorldLayout.BREEZE
## ~2.6 m/s). These tests feed such flight directions to the UI through
## core contracts only (Bird.velocity, Bird.get_forward on the kit's mock
## player), the head at rest looking along the rig's forward, and ask the
## player's questions: does the HUD stay in front of me, calm, and is the
## lesson card readable where I look?
##
##   tools/gd.sh ui_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/ui --suite=ui_r6x_experience

const Kit := preload("res://tests/unit/ui/ui_test_kit.gd")
const SDT := 1.0 / 72.0

## [t (s), flight-path azimuth in rig space (deg, + = left), elevation (deg),
## speed (m/s), facing azimuth (deg)] from real_trace.csv, 18-26 s.
const LOOP_TRACE := [
	[0.000, 14.7, -24.9, 9.94, -0.0], [0.028, 14.5, -25.0, 10.08, -0.0], [0.056, 14.4, -25.0, 10.22, -0.0], [0.083, 14.2, -25.0, 10.35, -0.0],
	[0.111, 14.1, -25.1, 10.48, -0.0], [0.139, 14.0, -25.2, 10.62, -0.0], [0.167, 13.8, -25.3, 10.75, -0.0], [0.194, 13.7, -25.4, 10.88, -0.0],
	[0.222, 13.6, -25.5, 11.01, -0.0], [0.250, 13.5, -25.5, 11.12, -0.0], [0.278, 13.4, -25.6, 11.25, -0.0], [0.306, 13.3, -25.7, 11.39, -0.0],
	[0.333, 13.2, -25.8, 11.51, -0.0], [0.361, 13.1, -25.9, 11.63, -0.0], [0.389, 13.0, -26.1, 11.76, -0.0], [0.417, 13.0, -26.2, 11.88, -0.0],
	[0.444, 12.9, -26.3, 12.00, -0.0], [0.472, 12.8, -26.4, 12.11, -0.0], [0.500, 12.7, -26.5, 12.24, -0.0], [0.528, 12.7, -26.7, 12.36, -0.0],
	[0.556, 12.6, -26.8, 12.47, -0.0], [0.583, 12.6, -27.0, 12.59, -0.0], [0.611, 12.5, -27.1, 12.70, -0.0], [0.639, 12.4, -27.0, 12.82, -0.0],
	[0.667, 12.2, -26.1, 12.96, -0.0], [0.694, 11.9, -24.0, 13.14, -0.0], [0.722, 11.5, -21.0, 13.33, -0.0], [0.750, 11.2, -17.6, 13.52, -0.0],
	[0.778, 10.9, -14.1, 13.71, -0.0], [0.806, 10.6, -10.6, 13.89, -0.0], [0.833, 10.4, -7.1, 14.05, -0.0], [0.861, 10.3, -3.7, 14.20, -0.0],
	[0.889, 10.2, -0.3, 14.34, -0.0], [0.917, 10.2, 3.1, 14.46, -0.0], [0.944, 10.2, 6.4, 14.57, -0.0], [0.972, 10.2, 9.8, 14.66, -0.0],
	[1.000, 10.3, 13.0, 14.75, -0.0], [1.028, 10.4, 16.3, 14.83, -0.0], [1.056, 10.6, 19.5, 14.89, -0.0], [1.083, 10.8, 22.7, 14.95, -0.0],
	[1.111, 11.1, 25.8, 14.98, -0.0], [1.139, 11.4, 29.0, 15.01, -0.0], [1.167, 11.8, 32.1, 15.03, -0.0], [1.194, 12.3, 35.3, 15.05, -0.0],
	[1.222, 12.9, 38.4, 15.03, -0.0], [1.250, 13.5, 41.5, 15.01, -0.0], [1.278, 14.3, 44.6, 14.96, -0.0], [1.306, 15.3, 47.7, 14.89, -0.0],
	[1.333, 16.5, 51.0, 14.84, -0.0], [1.361, 17.9, 54.3, 14.75, -0.0], [1.389, 19.8, 57.8, 14.71, -0.0], [1.417, 22.2, 61.4, 14.64, -0.0],
	[1.444, 25.6, 65.0, 14.53, -0.0], [1.472, 30.1, 68.7, 14.48, -0.1], [1.500, 36.3, 72.3, 14.37, -0.6], [1.528, 45.4, 75.7, 14.25, -1.8],
	[1.556, 59.6, 78.5, 14.04, -4.1], [1.583, 80.1, 80.2, 13.87, 173.9], [1.611, 97.8, 80.6, 13.78, 176.1], [1.639, 110.1, 80.5, 13.57, 179.2],
	[1.667, 118.6, 80.3, 13.24, -178.2], [1.694, 124.7, 80.3, 13.18, -176.1], [1.722, 129.4, 80.2, 12.87, -174.4], [1.750, 132.9, 80.2, 12.69, -173.2],
	[1.778, 135.6, 80.2, 12.51, -172.4], [1.806, 137.5, 80.2, 12.28, -172.1], [1.833, 139.0, 80.2, 12.10, -172.2], [1.861, 140.3, 80.3, 11.93, -172.7],
	[1.889, 141.9, 80.4, 11.69, -173.3], [1.917, 143.8, 80.6, 11.57, -174.2], [1.944, 146.1, 80.9, 11.57, -175.2], [1.972, 148.7, 81.1, 11.38, -176.4],
	[2.000, 151.7, 81.4, 11.30, -177.4], [2.028, 154.8, 81.7, 11.22, 1.7], [2.056, 158.0, 81.9, 11.07, 1.0], [2.083, 161.3, 82.2, 10.98, 0.5],
	[2.111, 164.7, 82.4, 10.81, 0.1], [2.139, 164.5, 81.8, 10.80, -92.9], [2.167, 155.3, 78.6, 10.78, -107.9], [2.194, 149.1, 76.3, 10.85, -119.7],
	[2.222, 144.9, 74.5, 10.81, -126.9], [2.250, 142.7, 72.9, 10.75, -130.1], [2.278, 142.0, 71.5, 10.68, -132.8], [2.306, 142.2, 70.2, 10.60, -139.6],
	[2.333, 142.5, 69.0, 10.46, -151.9], [2.361, 142.9, 68.1, 10.35, -165.3], [2.389, 143.7, 67.4, 10.23, -176.1], [2.417, 144.9, 66.8, 10.05, 176.0],
	[2.444, 146.6, 66.3, 9.88, 170.2], [2.472, 148.7, 65.9, 9.70, 165.5], [2.500, 151.2, 65.5, 9.55, 161.8], [2.528, 154.1, 65.0, 9.35, 158.8],
	[2.556, 157.3, 64.5, 9.13, 156.6], [2.583, 160.9, 64.0, 8.97, 155.4], [2.611, 164.7, 63.4, 8.75, 155.0], [2.639, 168.4, 62.7, 8.55, 155.2],
	[2.667, 171.7, 62.0, 8.35, 155.7], [2.694, 174.6, 61.2, 8.16, 156.5], [2.722, 177.1, 60.3, 7.93, 157.5], [2.750, 179.2, 59.4, 7.74, 158.5],
	[2.778, -179.1, 58.5, 7.54, 159.3], [2.806, -177.8, 57.4, 7.33, 159.8], [2.833, -176.9, 56.2, 7.12, 160.2], [2.861, -176.4, 54.8, 6.92, 160.6],
	[2.889, -176.3, 53.3, 6.71, 160.8], [2.917, -176.7, 51.8, 6.52, 160.5], [2.944, -177.5, 50.2, 6.33, 159.7], [2.972, -178.8, 48.5, 6.13, 158.5],
	[3.000, 179.5, 46.8, 5.95, 156.8], [3.028, 177.3, 45.0, 5.76, 154.5], [3.056, 174.7, 43.2, 5.58, 151.7], [3.083, 172.0, 41.4, 5.43, 148.7],
	[3.111, 169.2, 39.6, 5.28, 145.5], [3.139, 166.3, 37.7, 5.16, 142.1], [3.167, 163.3, 35.7, 5.04, 138.8], [3.194, 160.3, 33.6, 4.93, 135.5],
	[3.222, 157.2, 31.4, 4.84, 132.1], [3.250, 154.1, 29.2, 4.77, 128.8], [3.278, 151.0, 26.9, 4.71, 125.5], [3.306, 147.8, 24.6, 4.67, 122.1],
	[3.333, 144.6, 22.4, 4.65, 118.8], [3.361, 141.4, 20.2, 4.66, 115.5], [3.389, 138.0, 18.1, 4.67, 112.1], [3.417, 134.7, 16.0, 4.70, 108.8],
	[3.444, 131.2, 14.1, 4.74, 105.5], [3.472, 127.7, 12.3, 4.81, 102.1], [3.500, 124.1, 10.7, 4.88, 98.8], [3.528, 120.5, 9.2, 4.97, 95.5],
	[3.556, 116.8, 7.9, 5.07, 92.1], [3.583, 113.1, 6.8, 5.19, 88.8], [3.611, 109.4, 5.8, 5.30, 85.5], [3.639, 105.7, 5.0, 5.42, 82.1],
	[3.667, 102.0, 4.3, 5.55, 78.8], [3.694, 98.3, 3.8, 5.68, 75.5], [3.722, 94.6, 3.4, 5.82, 72.1], [3.750, 90.9, 3.1, 5.95, 68.8],
	[3.778, 87.2, 3.0, 6.09, 65.5], [3.806, 83.6, 2.9, 6.22, 62.1], [3.833, 80.0, 2.9, 6.35, 58.8], [3.861, 76.4, 3.0, 6.48, 55.5],
	[3.889, 72.8, 3.1, 6.60, 52.1], [3.917, 69.3, 3.2, 6.72, 48.8], [3.944, 65.8, 3.4, 6.83, 45.5], [3.972, 62.4, 3.6, 6.93, 42.1],
	[4.000, 58.9, 3.8, 7.03, 38.8], [4.028, 55.5, 3.9, 7.12, 35.5], [4.056, 52.1, 4.1, 7.20, 32.1], [4.083, 48.7, 4.2, 7.28, 28.8],
	[4.111, 45.5, 4.3, 7.35, 25.6], [4.139, 42.5, 4.4, 7.42, 22.6], [4.167, 39.6, 4.4, 7.48, 19.8], [4.194, 37.0, 4.4, 7.53, 17.2],
	[4.222, 34.6, 4.4, 7.58, 14.8], [4.250, 32.4, 4.4, 7.63, 12.5], [4.278, 30.3, 4.4, 7.67, 10.5], [4.306, 28.5, 4.3, 7.71, 8.6],
	[4.333, 26.8, 4.2, 7.75, 6.9], [4.361, 25.3, 4.0, 7.78, 5.4], [4.389, 24.1, 3.8, 7.81, 4.1], [4.417, 23.0, 3.6, 7.84, 2.9],
	[4.444, 22.1, 3.4, 7.85, 2.0], [4.472, 21.4, 3.2, 7.87, 1.2], [4.500, 20.9, 3.0, 7.89, 0.6], [4.528, 20.6, 2.7, 7.91, 0.2],
	[4.556, 20.4, 2.5, 7.92, 0.0], [4.583, 20.5, 2.2, 7.94, -0.0], [4.611, 20.6, 2.0, 7.94, -0.0], [4.639, 20.6, 1.7, 7.95, -0.0],
	[4.667, 20.7, 1.5, 7.96, -0.0], [4.694, 20.8, 1.3, 7.96, -0.0], [4.722, 20.9, 1.1, 7.97, -0.0], [4.750, 20.9, 0.8, 7.98, -0.0],
	[4.778, 21.0, 0.7, 7.98, -0.0], [4.806, 21.1, 0.5, 7.98, -0.0], [4.833, 21.2, 0.3, 7.99, -0.0], [4.861, 21.2, 0.1, 7.99, -0.0],
	[4.889, 21.3, -0.1, 7.99, -0.0], [4.917, 21.3, -0.2, 7.99, -0.0], [4.944, 21.4, -0.3, 7.99, -0.0], [4.972, 21.4, -0.5, 7.99, -0.0],
	[5.000, 21.5, -0.6, 7.98, -0.0], [5.028, 21.5, -0.7, 7.98, -0.0], [5.056, 21.6, -0.9, 7.97, -0.0], [5.083, 21.6, -1.1, 7.96, -0.0],
	[5.111, 21.7, -1.2, 7.95, -0.0], [5.139, 21.7, -1.4, 7.94, -0.0], [5.167, 21.7, -1.5, 7.92, -0.0], [5.194, 21.8, -1.6, 7.91, -0.0],
	[5.222, 21.8, -1.8, 7.89, -0.0], [5.250, 21.8, -1.9, 7.87, -0.0], [5.278, 21.8, -2.1, 7.86, -0.0], [5.306, 21.8, -2.3, 7.84, -0.0],
	[5.333, 21.9, -2.4, 7.82, -0.0], [5.361, 21.9, -2.5, 7.80, -0.0], [5.389, 21.8, -2.7, 7.78, -0.0], [5.417, 21.8, -2.8, 7.76, -0.0],
	[5.444, 21.8, -3.0, 7.74, -0.0], [5.472, 21.8, -3.1, 7.72, -0.0], [5.500, 21.8, -3.2, 7.70, -0.0], [5.528, 21.7, -3.3, 7.69, -0.0],
	[5.556, 21.7, -3.4, 7.67, -0.0], [5.583, 21.6, -3.5, 7.65, -0.0], [5.611, 21.6, -3.6, 7.64, -0.0], [5.639, 21.5, -3.8, 7.62, -0.0],
	[5.667, 21.4, -3.9, 7.61, -0.0], [5.694, 21.4, -4.0, 7.59, -0.0], [5.722, 21.3, -4.1, 7.57, -0.0], [5.750, 21.2, -4.3, 7.55, -0.0],
	[5.778, 21.1, -4.4, 7.53, -0.0], [5.806, 21.1, -4.5, 7.52, -0.0], [5.833, 21.0, -4.6, 7.50, -0.0], [5.861, 20.9, -4.7, 7.49, -0.0],
	[5.889, 20.8, -4.8, 7.48, -0.0], [5.917, 20.7, -4.9, 7.46, -0.0], [5.944, 20.6, -5.0, 7.45, -0.0], [5.972, 20.5, -5.0, 7.44, -0.0],
	[6.000, 20.4, -5.0, 7.43, -0.0], [6.028, 20.3, -5.1, 7.42, -0.0], [6.056, 20.1, -5.1, 7.41, -0.0], [6.083, 20.0, -5.1, 7.40, -0.0],
	[6.111, 19.9, -5.1, 7.39, -0.0], [6.139, 19.8, -5.2, 7.38, -0.0], [6.167, 19.7, -5.3, 7.37, -0.0], [6.194, 19.6, -5.4, 7.36, -0.0],
	[6.222, 19.5, -5.5, 7.35, -0.0], [6.250, 19.4, -5.6, 7.35, -0.0], [6.278, 19.3, -5.8, 7.34, -0.0], [6.306, 19.2, -5.9, 7.34, -0.0],
	[6.333, 19.1, -6.0, 7.33, -0.0], [6.361, 19.0, -6.1, 7.32, -0.0], [6.389, 18.9, -6.2, 7.32, -0.0], [6.417, 18.8, -6.4, 7.32, -0.0],
	[6.444, 18.7, -6.5, 7.32, -0.0], [6.472, 18.6, -6.7, 7.32, -0.0], [6.500, 18.5, -6.9, 7.31, -0.0], [6.528, 18.4, -7.0, 7.31, -0.0],
	[6.556, 18.3, -7.2, 7.32, -0.0], [6.583, 18.2, -7.3, 7.32, -0.0], [6.611, 18.0, -7.4, 7.32, -0.0], [6.639, 17.9, -7.5, 7.32, -0.0],
	[6.667, 17.8, -7.6, 7.32, -0.0], [6.694, 17.7, -7.7, 7.33, -0.0], [6.722, 17.6, -7.8, 7.33, -0.0], [6.750, 17.5, -7.8, 7.33, -0.0],
	[6.778, 17.4, -7.9, 7.33, -0.0], [6.806, 17.3, -8.0, 7.33, -0.0], [6.833, 17.2, -8.1, 7.33, -0.0], [6.861, 17.1, -8.1, 7.34, -0.0],
	[6.889, 17.0, -8.2, 7.35, -0.0], [6.917, 16.9, -8.3, 7.35, -0.0], [6.944, 16.9, -8.4, 7.36, -0.0], [6.972, 16.8, -8.4, 7.36, -0.0],
	[7.000, 16.7, -8.5, 7.36, -0.0], [7.028, 16.6, -8.6, 7.37, -0.0], [7.056, 16.5, -8.7, 7.37, -0.0], [7.083, 16.4, -8.9, 7.39, -0.0],
	[7.111, 16.4, -9.0, 7.39, -0.0], [7.139, 16.3, -9.1, 7.39, -0.0], [7.167, 16.2, -9.2, 7.41, -0.0], [7.194, 16.1, -9.3, 7.41, -0.0],
	[7.222, 16.0, -9.5, 7.41, -0.0], [7.250, 16.0, -9.6, 7.41, -0.0], [7.278, 15.9, -9.7, 7.43, -0.0], [7.306, 15.8, -9.8, 7.43, -0.0],
	[7.333, 15.7, -9.9, 7.43, -0.0], [7.361, 15.6, -10.0, 7.44, -0.0], [7.389, 15.6, -10.1, 7.45, -0.0], [7.417, 15.5, -10.2, 7.45, -0.0],
	[7.444, 15.4, -10.3, 7.46, -0.0], [7.472, 15.3, -10.4, 7.46, -0.0], [7.500, 15.3, -10.5, 7.47, -0.0], [7.528, 15.2, -10.6, 7.48, -0.0],
	[7.556, 15.1, -10.7, 7.48, -0.0], [7.583, 15.1, -10.9, 7.49, -0.0], [7.611, 15.0, -11.0, 7.50, -0.0], [7.639, 14.9, -11.1, 7.50, -0.0],
	[7.667, 14.9, -11.2, 7.51, -0.0], [7.694, 14.8, -11.3, 7.52, -0.0], [7.722, 14.7, -11.4, 7.53, -0.0], [7.750, 14.7, -11.6, 7.53, -0.0],
	[7.778, 14.6, -11.7, 7.54, -0.0], [7.806, 14.6, -11.8, 7.55, -0.0], [7.833, 14.5, -11.9, 7.55, -0.0], [7.861, 14.5, -12.1, 7.56, -0.0],
	[7.889, 14.4, -12.2, 7.57, -0.0], [7.917, 14.3, -12.3, 7.57, -0.0], [7.944, 14.3, -12.3, 7.58, -0.0], [7.972, 14.2, -12.4, 7.59, -0.0],
	[8.000, 14.2, -12.5, 7.60, -0.0],
]


func _synthetic(k: Kit) -> void:
	k.ui.set_process(false)
	k.ui.hud.set_process(false)
	k.ui.indicators.set_process(false)


func _frame(k: Kit, dt: float = SDT) -> void:
	k.ui.hud_panel.follow(dt)
	k.ui.indicators.step(dt)
	k.ui.hud.make_way(k.ui.hud_protected_directions(), dt)
	k.ui.hud.advance(dt)


func _notice_opacity(k: Kit) -> float:
	var p := k.ui.hud_panel
	if not p.is_band_visible(HUD.BAND_NOTICE) or k.ui.hud.band_plates(HUD.BAND_NOTICE).is_empty():
		return 0.0
	return p.band_alpha(HUD.BAND_NOTICE)


func _ecc(k: Kit, labels: Array[Label], gaze: Vector3) -> float:
	var worst := 0.0
	for lbl: Label in labels:
		if lbl == null or not lbl.is_visible_in_tree() or lbl.text == "":
			continue
		var f := lbl.get_theme_font(&"font")
		var w := f.get_string_size(lbl.text, HORIZONTAL_ALIGNMENT_LEFT, -1, lbl.get_theme_font_size(&"font_size")).x
		var r := lbl.get_global_rect()
		var x0 := r.position.x
		if lbl.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER:
			x0 = r.get_center().x - w * 0.5
		for x: float in [x0, x0 + w * 0.5, x0 + w]:
			var d := k.ui.hud_panel.pixel_to_world(Vector2(x, r.get_center().y)) - k.cam.global_position
			worst = maxf(worst, rad_to_deg(gaze.angle_to(d)))
	return worst


func _start(k: Kit) -> void:
	k.setup(self, true)
	await k.settle(self, 3)
	k.gl.start_run()
	await k.settle(self, 4)
	_synthetic(k)
	k.player.velocity = Vector3(0, 0, -9)
	k.player.global_basis = Basis.IDENTITY
	k.set_head(Vector3(0, Kit.EYE, 0), 0.0)
	for i in 30:
		_frame(k)


## Drive the flight direction with `fn(t) -> [vel_world, forward_yaw_deg]`
## for `seconds`; the head stays at rest along the rig's forward.
func _run(k: Kit, seconds: float, fn: Callable) -> Dictionary:
	var hud := k.ui.hud
	var t := 0.0
	var yaw_max := 0.0
	var over45 := 0.0
	var travel := 0.0
	var prev := rad_to_deg(k.ui.hud_panel.panel_yaw())
	var shown := 0.0
	var in_view := 0.0
	var fades := 0
	var was_faded := false
	var moves0 := hud.move_count
	var ecc_max := 0.0
	while t < seconds:
		var s: Array = fn.call(t)
		k.player.velocity = s[0]
		k.player.global_basis = Basis(Vector3.UP, deg_to_rad(float(s[1])))
		_frame(k)
		t += SDT
		var y := rad_to_deg(k.ui.hud_panel.panel_yaw())
		yaw_max = maxf(yaw_max, absf(y))
		if absf(y) > 45.0:
			over45 += SDT
		travel += absf(wrapf(y - prev, -180.0, 180.0))
		prev = y
		var op := _notice_opacity(k)
		if op > 0.0 and hud.lesson_visible():
			shown += SDT
			var faded := op < HUD.READABLE_ALPHA
			if faded and not was_faded:
				fades += 1
			was_faded = faded
			var e := _ecc(k, hud.lesson_labels(), -k.cam.global_basis.z)
			ecc_max = maxf(ecc_max, e)
			if not faded and e <= 45.0:
				in_view += SDT
	return {"seconds": snappedf(seconds, 0.01), "hud_yaw_max_deg": snappedf(yaw_max, 0.1),
		"hud_over_45deg_s": snappedf(over45, 0.01), "hud_travel_deg": snappedf(travel, 0.1),
		"card_in_view_frac": snappedf(in_view / maxf(shown, 1e-3), 0.001), "card_words_max_from_gaze_deg": snappedf(ecc_max, 0.1),
		"fades": fades, "moves": hud.move_count - moves0, "peak_follow_speed_deg_s": snappedf(k.ui.hud_panel.peak_follow_speed, 0.1)}


func _sample_trace(t: float) -> Array:
	var i := clampi(int(t / (2.0 / 72.0)), 0, LOOP_TRACE.size() - 1)
	var r: Array = LOOP_TRACE[i]
	var yaw := deg_to_rad(float(r[1]))
	var el := deg_to_rad(float(r[2]))
	var v := Basis(Vector3.UP, yaw) * Vector3(0.0, sin(el), -cos(el)) * float(r[3])
	return [v, float(r[4])]


func test_a_zoom_over_the_top_after_a_dive_from_the_real_game() -> void:
	# 8 s of the real game's tutorial (dive lesson -> pull-up -> the catch
	# lesson), as the rig saw it: the flight direction's azimuth, elevation
	# and speed, and where the bird faced. The zoom reaches 81 deg; the
	# horizontal velocity and the facing flip behind the player for ~2 s.
	var k := Kit.new()
	await _start(k)
	check(k.ui.hud.lesson_visible(), "a lesson card is up")
	k.ui.hud_panel.peak_follow_speed = 0.0
	var r := await _run(k, float(LOOP_TRACE.size()) * 2.0 / 72.0, _sample_trace)
	metric("zoom_over_the_top", r)
	print("[ui-verify] zoom over the top: %s" % JSON.stringify(r))
	lt(float(r["hud_yaw_max_deg"]), 60.0, "the HUD stays in front of a player looking ahead (max %.1f deg from the rig's forward)" % float(r["hud_yaw_max_deg"]))
	lt(float(r["hud_over_45deg_s"]), 0.5, "the HUD is not swung out of view (%.2f s past 45 deg)" % float(r["hud_over_45deg_s"]))
	gt(float(r["card_in_view_frac"]), 0.8, "the lesson card stays readable where the player looks (%.3f)" % float(r["card_in_view_frac"]))
	k.teardown()
	await wait_frames(2)


func test_b_a_hovering_sparrow_drifting_back_in_the_breeze() -> void:
	# A sparrow flapping hard to hover (DESIGN: small birds are hover-capable)
	# into the 2.6 m/s breeze, slowly losing ground: 0.8 m/s backwards with a
	# little wander, facing forward all along.
	var k := Kit.new()
	await _start(k)
	var fn := func(t: float) -> Array:
		var wander := deg_to_rad(20.0 * sin(t * 0.7))
		var v := Basis(Vector3.UP, wander) * Vector3(0.0, 0.1 * sin(t * 3.0), 0.8)
		return [v, 0.0]
	var r := await _run(k, 8.0, fn)
	metric("hover_drifting_back", r)
	print("[ui-verify] hover drifting back: %s" % JSON.stringify(r))
	lt(float(r["hud_yaw_max_deg"]), 60.0, "the HUD stays in front of a hovering player (max %.1f deg)" % float(r["hud_yaw_max_deg"]))
	gt(float(r["card_in_view_frac"]), 0.8, "the lesson card stays in view (%.3f)" % float(r["card_in_view_frac"]))
	k.teardown()
	await wait_frames(2)


func test_c_a_slow_sparrow_crabbing_in_the_breeze() -> void:
	# Climbing slowly out of the perch at 3 m/s airspeed across the 2.6 m/s
	# breeze: the ground track is ~40 deg off where the bird (and the
	# player's body) faces.
	var k := Kit.new()
	await _start(k)
	var fn := func(_t: float) -> Array:
		var air := Vector3(0.0, 0.0, -3.0)
		var wind := Vector3(2.6, 0.0, 0.0)
		return [air + wind + Vector3(0.0, 1.5, 0.0), 0.0]
	var r := await _run(k, 6.0, fn)
	metric("slow_crab", r)
	print("[ui-verify] slow crab: %s" % JSON.stringify(r))
	gt(float(r["card_in_view_frac"]), 0.8, "crabbing, the lesson card stays in view of a player facing forward (%.3f)" % float(r["card_in_view_frac"]))
	k.teardown()
	await wait_frames(2)
