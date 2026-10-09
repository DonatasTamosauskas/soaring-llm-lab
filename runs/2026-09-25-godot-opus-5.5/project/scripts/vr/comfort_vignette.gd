class_name ComfortVignette
extends MeshInstance3D
## Comfort vignette: a dark ring that closes in on the periphery during
## motion the body does not feel: fast view turns (the rig's yaw rate),
## speed beyond the bird's own cruise (dives, boosts) and sustained linear
## accelerations near surfaces (strength: VignetteModel, scaled by Settings
## "comfort_vignette"; 0 turns it off completely). Steady cruise keeps the
## full view wherever it is flown.
##
## Fix round 4 (a verifier's probes, then the lead's direction): round 3's
## optic-flow term (speed / nearest surface on 3 single rays, forgotten the
## tick a ray missed) and its per-tick proximity made the ring pulse
## 0 <-> 0.38-0.42 about once a second in STEADY flight over the orchard
## rows and through the forest, and flash on each post of a fence line: a
## peripheral flicker, in the brief's signature places. The one geometry
## input left, how near a surface is to see an acceleration by, is a slow
## quantity: each probe ray's nearest hit is held for PROX_HOLD, and the
## proximity is low-passed with PROX_TAU, so it cannot swing faster than
## ~1/PROX_TAU and a row of trees or posts reads as one steady surface.
## Fix round 5 (the experience verifier: DESIGN asks for a speed vignette,
## round 4 had none): the speed term is the smoothed rig speed over the
## bird's cruise speed (speed_ratio), which no surface moves.
##
## Attach as a child of the XRCamera3D. The ring is drawn in VIEW space
## (skip_vertex_transform), so each eye gets it centred on its own optical
## axis at a fixed angular aperture: independent of world_scale, the near
## plane and the IPD. Only the ring is geometry (the clear centre costs no
## fragments) and the node hides itself at strength 0 (zero draw calls).
## One draw call when visible.
##
## Motion is measured on `origin` (the XROrigin3D): its world motion is the
## artificial (flight) motion only; the player's own head movement never
## moves it (PlayerBird displaces the body by the head delta and offsets the
## origin back), and physical head motion causes no visual-vestibular
## mismatch.

## Inner edge of the clear view (deg from the gaze axis) at the lowest and
## at full strength, width of the soft edge, and the outer rim.
const OPEN_DEG := 55.0
const CLOSED_DEG := 24.0
const FEATHER_DEG := 20.0
const OUTER_DEG := 85.0
const SEGMENTS := 48
## Radial ring positions (0 = inner edge .. 1 = outer rim); denser where
## the soft edge lives.
const RINGS := [0.0, 0.06, 0.12, 0.2, 0.3, 0.45, 0.65, 1.0]
## The ring's view-space depth, in near planes (must sit beyond near).
const DEPTH_NEAR := 2.0
## Render layer bit the vignette uses (20); cameras that must not see it
## (spectators) can drop it from their cull mask.
const LAYER := 1 << 19
## Rig motion that cannot be flight: a move faster than this (m/s) or a yaw
## step faster than this (rad/s: 3x flight's 240°/s comfort cap, enforced in
## its physics, FLIGHT_SPEC C3) is a teleport, respawn or recenter re-aim.
const JUMP_SPEED := 250.0
const JUMP_YAW_RATE := deg_to_rad(720.0)
## The acceleration term averages over one wingbeat (fix round 2): the
## rig's surge and heave oscillate with every stroke, and a 0.1 s low-pass
## let a sparrow's ordinary flapping climb hold the view at 0.22-0.29 and
## pulse it on every beat while hovering. The mean acceleration over a
## window T is exactly (v(t) - v(t - T)) / T, so with T = the stroke period
## (PlayerBird.wing_state().stroke_period, flight's own measure) a periodic
## beat cancels and only a sustained surge, dive or flare is left. Without
## a stroke period (no flight in the scene) T = ACCEL_WINDOW, a typical
## human stroke. On flight's real PlayerBird, steady flapping of every kind
## now reads 0.000-0.004 (tests/sim/flight_rig).
const ACCEL_WINDOW := 0.8
const ACCEL_WINDOW_MIN := 0.3
const ACCEL_WINDOW_MAX := 1.5
## Then a second, fixed box of SMOOTH_WINDOW over that: flight's stroke
## period is an estimate (it converges over the first 2-3 strokes after a
## pause, from its idle 0.3 s), and while it is off the first box leaves
## part of the beat; the second attenuates that residue ~4x more at the
## cost of SMOOTH_WINDOW / 2 of extra delay for a real surge.
const SMOOTH_WINDOW := 0.5
const RING := 256
## The player's body span in perceived metres (arm span + drawn wingtips,
## FLIGHT_SPEC §11.4): the unit "body sizes" are judged in.
const BODY_SPAN := 1.7
## The acceleration term counts in full with a surface within
## ACCEL_NEAR_SPANS body spans (the probe rays: sides, below, ahead), and
## not at all beyond ACCEL_FAR_SPANS (the rays' reach, 8 spans:
## FLIGHT_SPEC §11.4's "≤ 8 wingspans"). Stereo depth and motion parallax
## of body-sized things fade out over that range; beyond it an acceleration
## changes the visible flow by less than a/(13.6 m perceived), under
## 0.5 rad/s² for the term's 6 m/s² threshold. Fix round 3.
const ACCEL_NEAR_SPANS := 3.0
const ACCEL_FAR_SPANS := 8.0
## How long a probe ray's nearest hit is remembered (s), and the proximity's
## low-pass time constant (s). Fix round 4: a ray that hits a tree, a post
## or a roof and then misses the gap no longer forgets the surface; objects
## passing at up to 1/PROX_HOLD per second (a tree every 13 m at a
## sparrow's 9 m/s, a post every 2.5 m) read as one steady surface, and the
## proximity moves by at most ~1/PROX_TAU per second.
const PROX_HOLD := 1.5
const PROX_TAU := 1.0
## Probe directions (rig yaw frame; x right, -z forward): right, left,
## down, ahead, ahead-down; cast one per tick in PROBE_ORDER. The sides
## come round every 3 ticks: a trunk or post abeam is in a side ray's line
## for only ~2 ticks (0.3 m at 9 m/s), while what lies below or ahead stays
## there for many.
const PROBE_DIRS: Array[Vector3] = [Vector3.RIGHT, Vector3.LEFT, Vector3.DOWN, Vector3.FORWARD, Vector3(0.0, -0.7071068, -0.7071068)]
const PROBE_ORDER: Array[int] = [0, 1, 2, 0, 1, 3, 0, 1, 4]
## Ticks between two probes of the same side (PROBE_ORDER).
const SIDE_EVERY := 3
## The speed term's input is smoothed by two low-passes of SPEED_TAU (s)
## in a row: a flap's surge (+-5 % of the speed at 1-1.6 Hz) is cut 6-20x
## and a single odd tick never reaches the ring, while a dive (seconds
## long) shows within ~0.7 s.
const SPEED_TAU := 0.35
## Ticks between two reads of the player's mass (the cruise speed moves
## only when the bird grows).
const CRUISE_EVERY := 30

const SHADER_CODE := """
shader_type spatial;
render_mode unshaded, blend_mix, depth_test_disabled, depth_draw_never, cull_disabled, shadows_disabled, skip_vertex_transform, fog_disabled;

uniform float strength = 0.0;
uniform float depth = 0.1;
uniform float open_inner = 0.96;
uniform float closed_inner = 0.42;
uniform float feather = 0.35;
uniform float outer = 1.48;
uniform vec3 tint : source_color = vec3(0.015, 0.02, 0.03);

float inner_edge() {
	return mix(open_inner, closed_inner, clamp(strength, 0.0, 1.0));
}

void vertex() {
	float theta = mix(inner_edge(), outer, UV.x);
	float phi = UV.y * TAU;
	float r = tan(theta) * depth;
	VERTEX = vec3(cos(phi) * r, sin(phi) * r, -depth);
	NORMAL = vec3(0.0, 0.0, 1.0);
}

void fragment() {
	float theta = atan(length(VERTEX.xy), -VERTEX.z);
	float a = smoothstep(inner_edge(), inner_edge() + feather, theta);
	ALBEDO = tint;
	ALPHA = a * smoothstep(0.0, 0.2, strength);
}
"""

## The rig whose motion drives the vignette (XROrigin3D).
var origin: Node3D
## Forces the strength setting (>= 0; the harness and dev scene), else the
## "comfort_vignette" value is read from `store`.
var setting_override := -1.0
## Where the "comfort_vignette" setting comes from: anything with
## get_value (the Settings autoload by default; tests pass a private one).
var store: Object = null
## Collision mask for the probe rays: world + perches.
@export_flags_3d_physics var probe_mask := 1 | 2
## Measured motion (world units), for plots, logs and tests.
var yaw_rate := 0.0
var speed := 0.0
var accel := 0.0
## The rig's speed, low-passed with SPEED_TAU, over the player's cruise
## speed (SizeRules.cruise_speed of its mass): the speed term's input (fix
## round 5). 0 without a player (no cruise to compare with).
var speed_ratio := 0.0
## The low-passed speed (world m/s) and the cruise speed it is compared
## with (0: no player).
var speed_smooth := 0.0
var cruise := 0.0
var _speed_lp1 := 0.0
## How near a surface is to judge an acceleration by, 0..1: the low-passed
## accel_proximity of the nearest held probe hit; and that held distance
## (world m; INF: nothing within reach for PROX_HOLD).
var proximity := 0.0
var nearest := INF
## Rig jumps re-seeded instead of measured (tests, logs).
var jumps := 0
var model := VignetteModel.new()
## When false the node only measures/updates on explicit calls (tests).
@export var auto_update := true

var _mat: ShaderMaterial
var _prev := Transform3D.IDENTITY
var _vel := Vector3.ZERO
var _have_prev := false
var _accel_vec := Vector3.ZERO
var _ray: PhysicsRayQueryParameters3D
var _sweep: PhysicsShapeQueryParameters3D
## What the shader was last given.
var _shown_strength := -1.0
var _shown_depth := -1.0
## Which probe ray casts next.
var _ray_turn := 0
## The probe results of the last PROX_HOLD seconds as a sliding-window
## minimum (a monotonic queue of (time, distance), nearest at the front;
## a miss is INF), and the clock it runs on.
var _probe_q: Array[Vector2] = []
var _cruise_age := 0
var _probe_t := 0.0
var _reseed_next := false
## Velocities of the last RING ticks (the stroke-average window), newest at
## _ring_head; _ring_n of them valid since the last re-seed.
var _ring := PackedVector3Array()
var _ring_head := -1
var _ring_n := 0
## The averaging window in use (s), for plots and tests.
var accel_window := ACCEL_WINDOW
## The second box's length (s); tests compare it with none (one tick).
var smooth_window := SMOOTH_WINDOW
var _window_age := 0
var _mid_vel := Vector3.ZERO
## The first box's felt acceleration per tick, and its running sum over the
## last SMOOTH_WINDOW (64-bit: Vector3 is 32-bit and would drift).
var _felt_ring := PackedVector3Array()
var _felt_n := 0
var _sx := 0.0
var _sy := 0.0
var _sz := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mesh = build_ring_mesh()
	var sh := Shader.new()
	sh.code = SHADER_CODE
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	_mat.render_priority = Material.RENDER_PRIORITY_MAX
	_mat.set_shader_parameter("open_inner", deg_to_rad(OPEN_DEG))
	_mat.set_shader_parameter("closed_inner", deg_to_rad(CLOSED_DEG))
	_mat.set_shader_parameter("feather", deg_to_rad(FEATHER_DEG))
	_mat.set_shader_parameter("outer", deg_to_rad(OUTER_DEG))
	material_override = _mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	layers = LAYER | 1
	# A recenter re-aims the rig in one tick: not a turn.
	VR.recentered.connect(func() -> void: _reseed_next = true)
	# The vertices are rewritten in view space; keep culling from ever
	# dropping the ring (it is always in front of whichever camera draws it).
	extra_cull_margin = 16384.0
	visible = false


static func build_ring_mesh() -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var rings := RINGS.size()
	for ri in rings:
		var u: float = RINGS[ri]
		for s in SEGMENTS + 1:
			var v := float(s) / SEGMENTS
			var th := deg_to_rad(lerpf(OPEN_DEG, OUTER_DEG, u))
			var r := tan(th)
			verts.append(Vector3(cos(v * TAU) * r, sin(v * TAU) * r, -1.0))
			uvs.append(Vector2(u, v))
	for ri in rings - 1:
		for s in SEGMENTS:
			var a := ri * (SEGMENTS + 1) + s
			var b := a + SEGMENTS + 1
			idx.append_array([a, b, a + 1, a + 1, b, b + 1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


func setting() -> float:
	if setting_override >= 0.0:
		return setting_override
	var src: Object = store if store != null else Settings
	return clampf(float(src.call("get_value", "comfort_vignette", 0.6)), 0.0, 1.0)


func world_scale() -> float:
	return (origin as XROrigin3D).world_scale if origin is XROrigin3D else 1.0


func _physics_process(dt: float) -> void:
	if auto_update:
		var t0 := VRProfile.begin()
		measure(dt)
		VRProfile.add(&"vignette_measure", t0)


func _process(dt: float) -> void:
	if auto_update:
		var t0 := VRProfile.begin()
		update_strength(dt)
		VRProfile.add(&"vignette_update", t0)


## Measures the rig's artificial motion over one physics tick.
func measure(dt: float) -> void:
	if origin == null or not is_instance_valid(origin) or not origin.is_inside_tree() or dt <= 0.0:
		return
	var x := origin.global_transform
	if not _have_prev:
		_prev = x
		_have_prev = true
		_reset_rings()
		return
	var v := (x.origin - _prev.origin) / dt
	var ws := world_scale()
	var dyaw := VRMath.wrap_angle(VRMath.yaw_of(-x.basis.z) - VRMath.yaw_of(-_prev.basis.z))
	# A respawn, teleport or recenter is a jump, not motion: re-seed instead
	# of flashing the vignette (the strength itself is left as it was).
	if _reseed_next or v.length() > JUMP_SPEED or absf(dyaw) / dt > JUMP_YAW_RATE or _player_flagged():
		_reseed_next = false
		jumps += 1
		if v.length() > JUMP_SPEED:
			# Somewhere else now: the surfaces held from before are gone
			# (the proximity itself glides on from where it was).
			_probe_q.clear()
		_prev = x
		_reset_rings()
		return
	yaw_rate = dyaw / dt
	_vel = v
	speed = v.length()
	_update_speed_ratio(dt)
	# The first velocity after a (re)seed is the baseline, not an
	# acceleration from zero (8 m/s in one tick would read 720 m/s²): the
	# window average starts once the ring spans the window.
	_push_velocity(v)
	# Flight's stroke period moves once per stroke (an EMA per onset): read
	# it every few ticks, not every one.
	_window_age -= 1
	if _window_age <= 0:
		_window_age = 6
		accel_window = _stroke_window()
	var a1 := _window_accel(accel_window, dt)
	# Judged against the window's mean heading (v_now + v_then): in a
	# constant-speed turn the chord v_now - v_then is exactly perpendicular
	# to it, so no centripetal part leaks in through the window's lag.
	_accel_vec = _smooth_felt(_felt_vec(a1, _mid_vel), dt)
	accel = _accel_vec.length()
	_prev = x
	_probe(ws, dt)


## 1 with a surface within ACCEL_NEAR_SPANS body spans (x world_scale), 0
## beyond ACCEL_FAR_SPANS or with none in reach (d = INF), smooth between.
static func accel_proximity(d: float, ws: float) -> float:
	if not is_finite(d):
		return 0.0
	var span := BODY_SPAN * maxf(ws, 0.01)
	return 1.0 - VRMath.sstep(ACCEL_NEAR_SPANS * span, ACCEL_FAR_SPANS * span, d)


func _push_velocity(v: Vector3) -> void:
	if _ring.size() != RING:
		_ring.resize(RING)
		_felt_ring.resize(RING)
	_ring_head = (_ring_head + 1) % RING
	_ring[_ring_head] = v
	_ring_n = mini(_ring_n + 1, RING)


## Running mean of the felt acceleration over SMOOTH_WINDOW (the second box;
## its ring shares _ring_head). Holds zeros until the first box has data.
func _smooth_felt(f: Vector3, dt: float) -> Vector3:
	var n := clampi(roundi(smooth_window / dt), 1, RING - 1)
	if _felt_n >= n:
		var old := _felt_ring[posmod(_ring_head - n, RING)]
		_sx -= old.x
		_sy -= old.y
		_sz -= old.z
	_felt_ring[_ring_head] = f
	_felt_n = mini(_felt_n + 1, RING)
	_sx += f.x
	_sy += f.y
	_sz += f.z
	return Vector3(_sx, _sy, _sz) / float(mini(_felt_n, n))


## Mean acceleration over the last `window` seconds: (v_now - v_then) /
## window, v_then interpolated between ticks so a stroke period that is not
## a whole number of ticks still cancels. Zero until the ring spans the
## window after a (re)seed: a partial window would see the beat itself
## (the first velocity after a re-seed is a baseline, never an
## acceleration from zero).
func _window_accel(window: float, dt: float) -> Vector3:
	var v_now := _ring[_ring_head]
	_mid_vel = v_now
	var steps := maxf(window / dt, 1.0)
	var k := int(floor(steps))
	if k + 1 > _ring_n - 1:
		return Vector3.ZERO
	var f := steps - k
	var then := _ring[posmod(_ring_head - k, RING)].lerp(_ring[posmod(_ring_head - k - 1, RING)], f)
	_mid_vel = 0.5 * (v_now + then)
	return (v_now - then) / (steps * dt)


## The averaging window: the player's stroke period (duck-typed
## PlayerBird.wing_state().stroke_period, flight's last measured cycle,
## 0.3-1.5 s), else a typical human stroke.
func _stroke_window() -> float:
	var p := Birds.player()
	if p == null or not p.has_method(&"wing_state"):
		return ACCEL_WINDOW
	var w: Variant = p.call(&"wing_state")
	if not (w is Object):
		return ACCEL_WINDOW
	var per: Variant = (w as Object).get(&"stroke_period")
	if not (per is float):
		return ACCEL_WINDOW
	return clampf(per, ACCEL_WINDOW_MIN, ACCEL_WINDOW_MAX)


## PlayerBird.yaw_flagged: this tick's yaw step was deliberate (respawn,
## recenter). Duck-typed; false without a player.
func _player_flagged() -> bool:
	var p := Birds.player()
	if p == null:
		return false
	var f: Variant = p.get(&"yaw_flagged")
	return f is bool and f


## The acceleration that counts for comfort: speed changes (dives, flares,
## flap surges) and vertical heave. The horizontal centripetal part of a
## coordinated turn is left out: the turn itself is the yaw term, and
## counting its centripetal acceleration too would narrow the view in every
## gentle small-bird turn (a sparrow circling at 30 m radius and 9 m/s yaws
## only 17°/s but "perceives" 2.7 / 0.141 = 19 m/s² of it).
static func _felt_vec(a: Vector3, v: Vector3) -> Vector3:
	var vh := Vector3(v.x, 0.0, v.z)
	if vh.length() < 0.5:
		return a
	var lateral := Vector3.UP.cross(vh).normalized()
	return a - lateral * a.dot(lateral)


## One probe ray per tick (PROBE_ORDER; in the rig's yaw frame, from the
## eyes, 8 body spans long), into the sliding-window minimum; then the
## proximity moves towards what the nearest surface of the last PROX_HOLD
## seconds says, with time constant PROX_TAU. Never per-frame geometry:
## the ray that just missed the gap between two trees changes nothing.
func _probe(ws: float, dt: float) -> void:
	_probe_t += dt
	var d := INF
	var cam := get_parent() as Node3D
	var world := get_world_3d()
	var space: PhysicsDirectSpaceState3D = world.direct_space_state if world != null else null
	if cam != null and space != null:
		var k := PROBE_ORDER[_ray_turn]
		_ray_turn = (_ray_turn + 1) % PROBE_ORDER.size()
		var from := cam.global_position
		var dir := Basis(Vector3.UP, VRMath.yaw_of(-origin.global_basis.z)) * PROBE_DIRS[k]
		var reach := ACCEL_FAR_SPANS * BODY_SPAN * maxf(ws, 0.01)
		if k <= 1:
			# Sides: a swept sphere as wide as the travel since this side's
			# last probe, so a post or a trunk abeam can never slip between
			# two probes (a thin ray aliased with a fence line and held it
			# only now and then: the proximity wandered).
			if _sweep == null:
				_sweep = PhysicsShapeQueryParameters3D.new()
				_sweep.shape = SphereShape3D.new()
			var r := clampf(0.5 * speed * SIDE_EVERY * dt + 0.01 * ws, 0.002, 0.25 * reach)
			(_sweep.shape as SphereShape3D).radius = r
			_sweep.transform = Transform3D(Basis.IDENTITY, from)
			_sweep.motion = dir * (reach - r)
			_sweep.collision_mask = probe_mask
			var f := space.cast_motion(_sweep)
			if f.size() == 2 and f[0] < 1.0:
				d = f[0] * (reach - r) + r
		else:
			if _ray == null:
				_ray = PhysicsRayQueryParameters3D.new()
			_ray.from = from
			_ray.to = from + dir * reach
			_ray.collision_mask = probe_mask
			var hit := space.intersect_ray(_ray)
			if not hit.is_empty():
				d = from.distance_to(hit["position"])
	_hold_push(d)
	nearest = _probe_q[0].y
	proximity += (accel_proximity(nearest, ws) - proximity) * VRMath.lp(dt, PROX_TAU)


## Sliding-window minimum over PROX_HOLD: drop the entries a nearer new one
## makes irrelevant, append it, expire the old ones from the front.
func _hold_push(d: float) -> void:
	while not _probe_q.is_empty() and _probe_q[_probe_q.size() - 1].y >= d:
		_probe_q.pop_back()
	_probe_q.push_back(Vector2(_probe_t, d))
	# (Never the entry just pushed: its time is stored in 32 bits.)
	while _probe_q.size() > 1 and _probe_q[0].x < _probe_t - PROX_HOLD:
		_probe_q.pop_front()


## The speed term's input: the smoothed rig speed over the player's cruise
## speed. The cruise speed is the bird's own (SizeRules, from its mass), so
## "fast" means fast for this body: a sparrow's dive and an eagle's read
## alike, and every steady cruise, wherever it is flown, reads under 1.
func _update_speed_ratio(dt: float) -> void:
	_cruise_age -= 1
	if _cruise_age <= 0:
		_cruise_age = CRUISE_EVERY
		var p := Birds.player()
		var m: float = p.mass if p != null else 0.0
		cruise = SizeRules.cruise_speed(m) if is_finite(m) and m > 0.0 else 0.0
	var k := VRMath.lp(dt, SPEED_TAU)
	_speed_lp1 += (speed - _speed_lp1) * k
	speed_smooth += (_speed_lp1 - speed_smooth) * k
	speed_ratio = speed_smooth / cruise if cruise > 0.0 else 0.0


## Advances the smoothed strength and pushes it to the shader.
func update_strength(dt: float) -> float:
	var s := model.update(setting(), yaw_rate, accel, world_scale(), dt, proximity, speed_ratio)
	apply_strength(s)
	return s


func apply_strength(s: float) -> void:
	if _mat == null:
		return
	var cam := get_parent() as Camera3D
	var depth := maxf((cam.near if cam != null else 0.05) * DEPTH_NEAR, 0.0005)
	# Shader parameters only when they change (at rest, every frame: 0).
	if s != _shown_strength:
		_shown_strength = s
		_mat.set_shader_parameter("strength", s)
	if depth != _shown_depth:
		_shown_depth = depth
		_mat.set_shader_parameter("depth", depth)
	visible = s > 0.002


func strength() -> float:
	return model.strength


## Angular radius (deg) of the fully clear view at strength s: the inner edge.
static func clear_radius_deg(s: float) -> float:
	return lerpf(OPEN_DEG, CLOSED_DEG, clampf(s, 0.0, 1.0))


func _reset_rings() -> void:
	_ring_n = 0
	_window_age = 0
	_felt_n = 0
	_sx = 0.0
	_sy = 0.0
	_sz = 0.0


func reset_motion() -> void:
	_have_prev = false
	_reset_rings()
	_vel = Vector3.ZERO
	_accel_vec = Vector3.ZERO
	yaw_rate = 0.0
	speed = 0.0
	accel = 0.0
	_probe_q.clear()
	_probe_t = 0.0
	nearest = INF
	proximity = 0.0
	speed_smooth = 0.0
	_speed_lp1 = 0.0
	speed_ratio = 0.0
	_cruise_age = 0
	model.reset()
	apply_strength(0.0)
