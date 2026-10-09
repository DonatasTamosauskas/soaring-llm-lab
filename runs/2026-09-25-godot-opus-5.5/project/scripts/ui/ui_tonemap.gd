class_name UITonemap
extends RefCounted
## Keeps VR panel colours true under the world's tonemapper.
##
## On desktop the UI is a 2D overlay composited after tonemapping, so it
## shows the palette exactly. In VR the panels are unshaded 3D quads, and the
## Environment's tonemapper (the world uses Filmic, white 6) squeezes them:
## cream text drops to ~84 % grey and the sunflower accent turns khaki,
## costing contrast. So panel shaders pre-apply the *inverse* tonemap curve,
## sampled from a small LUT built here for the active Environment; after the
## real tonemapper runs, the headset shows the designed colours (verified from
## rendered pixels in tests/shots/ui_shots.gd).
##
## Exact for LINEAR, REINHARD and FILMIC (the curves below mirror Godot
## 4.7's tonemap shader). ACES and AgX mix channels, so no per-channel
## inverse exists; they get no compensation (identity).
##
## The Mobile renderer (Quest) stores 3D colour in a range-limited buffer
## that clips at MOBILE_MAX_INPUT before tonemapping, so colours that would
## need more are unreachable there; the model clamps the same way (measured
## in the simulator: Filmic white 6 tops out at sRGB 235).

const LUT_SIZE := 256
const MOBILE_MAX_INPUT := 2.0


## Godot's tonemap curve for one linear channel (exposure already applied).
static func forward(x: float, mode: int, white: float) -> float:
	x = maxf(x, 0.0)
	match mode:
		Environment.TONE_MAPPER_LINEAR:
			return x
		Environment.TONE_MAPPER_REINHARDT:
			var w2 := white * white
			return (x * (1.0 + x / w2)) / (1.0 + x)
		Environment.TONE_MAPPER_FILMIC:
			return _filmic(x) / _filmic(white)
	return x


static func _filmic(x: float) -> float:
	const BIAS := 2.0
	const A := 0.22 * BIAS * BIAS
	const B := 0.30 * BIAS
	const C := 0.10
	const D := 0.20
	const E := 0.01
	const F := 0.30
	return ((x * (A * x + C * B) + D * E) / (x * (A * x + B) + D * F)) - E / F


static func supported(mode: int) -> bool:
	return mode in [Environment.TONE_MAPPER_LINEAR, Environment.TONE_MAPPER_REINHARDT, Environment.TONE_MAPPER_FILMIC]


## Linear input x (before exposure) that the tonemapper maps to linear t,
## limited to what the renderer's colour buffer can hold.
static func inverse(t: float, mode: int, white: float, exposure: float, max_input: float = INF) -> float:
	if not supported(mode):
		return t
	t = clampf(t, 0.0, 1.0)
	# The curves are monotonic: bisection is exact enough and mode-agnostic.
	var lo := 0.0
	var hi := maxf(white, 1.0) * 1.0001
	for i in 48:
		var mid := (lo + hi) * 0.5
		if forward(mid, mode, white) < t:
			lo = mid
		else:
			hi = mid
	return minf((lo + hi) * 0.5, max_input) / maxf(exposure, 1e-4)


## Tonemap settings of an Environment (null = no tonemapping), plus the
## colour-buffer ceiling of the active renderer.
static func params(env: Environment) -> Dictionary:
	var ceiling := MOBILE_MAX_INPUT if RenderingServer.get_current_rendering_method() == "mobile" else INF
	if env == null:
		return {"mode": Environment.TONE_MAPPER_LINEAR, "white": 1.0, "exposure": 1.0, "max_input": ceiling}
	return {"mode": env.tonemap_mode, "white": env.tonemap_white, "exposure": env.tonemap_exposure, "max_input": ceiling}


## LUT indexed by sqrt(target linear) (finer steps in the darks, where the
## panel colours live), storing the input / `scale`. Returns [texture, scale].
static func build_lut(p: Dictionary) -> Array:
	var mx: float = p.get("max_input", INF)
	var scale := maxf(inverse(1.0, p["mode"], p["white"], p["exposure"], mx), 1e-4)
	var img := Image.create(LUT_SIZE, 1, false, Image.FORMAT_RF)
	for i in LUT_SIZE:
		var u := i / float(LUT_SIZE - 1)
		var x := inverse(u * u, p["mode"], p["white"], p["exposure"], mx)
		img.set_pixel(i, 0, Color(x / scale, 0, 0))
	return [ImageTexture.create_from_image(img), scale]


## An sRGB colour that, drawn unshaded, reaches the screen as `c` after the
## tonemapper (for the pointer and cue meshes). May exceed 1 (HDR).
static func compensate(c: Color, p: Dictionary) -> Color:
	var lin := c.srgb_to_linear()
	var mx: float = p.get("max_input", INF)
	var out := Color(
		inverse(lin.r, p["mode"], p["white"], p["exposure"], mx),
		inverse(lin.g, p["mode"], p["white"], p["exposure"], mx),
		inverse(lin.b, p["mode"], p["white"], p["exposure"], mx), c.a)
	return out.linear_to_srgb()


## What the tonemapper does to an sRGB colour drawn unshaded (for tests).
static func apply(c: Color, p: Dictionary) -> Color:
	var lin := c.srgb_to_linear()
	var e: float = p["exposure"]
	var mx: float = p.get("max_input", INF)
	return Color(forward(minf(lin.r * e, mx), p["mode"], p["white"]), forward(minf(lin.g * e, mx), p["mode"], p["white"]),
		forward(minf(lin.b * e, mx), p["mode"], p["white"]), c.a).linear_to_srgb()


## The Environment the 3D view is rendered with.
static func active_environment(vp: Viewport) -> Environment:
	if vp == null:
		return null
	var cam := vp.get_camera_3d()
	if cam and cam.environment:
		return cam.environment
	var w := vp.find_world_3d()
	if w:
		return w.environment if w.environment else w.fallback_environment
	return null
