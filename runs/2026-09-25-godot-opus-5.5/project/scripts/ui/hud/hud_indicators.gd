class_name HudIndicators
extends Node3D
## Peripheral cues toward the current target (Events.target_changed) and the
## current threat (Events.threat_changed).
##
## A cue is a small chevron on a ring 24 degrees out from the centre of view,
## pointing the way to turn. It shows only while the bird is outside the
## central cone (inside it you can see the bird itself), fades with distance
## (target) or threat level (threat), and is smoothed by IndicatorFilter so it
## never flickers. Shape as well as colour tells them apart: one teal chevron
## for prey, a double coral chevron for danger.
##
## The two never draw on top of each other. In the commonest chase (prey off
## to one side, a hawk closing from behind on that side) the threat's turn
## cue points the same way as the prey's. So when the two point within
## SEPARATE_SPAN of each other, the threat cue steps out to an outer ring
## (at most SEPARATE_OUT further), smoothly with the angle between them:
## they stay >= 5 degrees apart and each still points exactly its own way.
##
## VR: chevrons are 3D meshes on a ring in front of the eye (distance scales
## with world_scale). Desktop: drawn on a full-screen Control.
##
## A cue is never drawn under a HUD plate: the chevrons render after the HUD
## panel (CUE_RENDER_PRIORITY above its 9; menus, at 10, never show while
## cues do) and on desktop on a CanvasLayer above the HUD's. The notices
## also fade and, if a cue stays on them, move (HUD.make_way).

const ECCENTRICITY := deg_to_rad(24.0)
const RING_RADIUS := 1.0          # m at world_scale 1
const CHEVRON_SIZE := 0.05        # m at world_scale 1 (~2.9 degrees)
const TARGET_MAX_ALPHA := 0.85
const THREAT_MAX_ALPHA := 0.95
## Cues pointing closer than this (ring angle) push apart...
const SEPARATE_SPAN := deg_to_rad(22.0)
## ...by moving the threat cue out by up to this (it is then 33 degrees out).
const SEPARATE_OUT := deg_to_rad(9.0)
## The step out eases in and out (when one cue appears beside the other).
const SEPARATE_TAU := 0.05
## Drawn after (over) the HUD panel, render priority 9 (UIRoot).
const CUE_RENDER_PRIORITY := 11
## Desktop: above the HUD overlay (layer 5), below menus (10).
const CUE_DESKTOP_LAYER := 6

var camera: Node3D
var rig: Node3D
var vr_mode := true
var active := false
var target: Bird
var threat: Bird
var threat_level := 0.0
var target_filter := IndicatorFilter.new()
var threat_filter := IndicatorFilter.new()
## Cruise speed for the target fade; defaults to the player's (SizeRules).
var cruise_override := -1.0

var _t := 0.0
## How far the threat cue is stepped out right now, radians.
var threat_out := 0.0
## Birds the filters last tracked: a different bird is a retarget.
var _last_target: Bird
var _last_threat: Bird
var _target_col := UITheme.PREY
var _threat_col := UITheme.THREAT
var _target_mesh: MeshInstance3D
var _threat_mesh: MeshInstance3D
var _overlay_layer: CanvasLayer
var _overlay: _Overlay


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	top_level = true
	_target_mesh = _make_chevron(UITheme.PREY, 1)
	_target_mesh.name = "TargetCue"
	add_child(_target_mesh)
	_threat_mesh = _make_chevron(UITheme.THREAT, 2)
	_threat_mesh.name = "ThreatCue"
	add_child(_threat_mesh)
	_overlay_layer = CanvasLayer.new()
	_overlay_layer.layer = CUE_DESKTOP_LAYER
	add_child(_overlay_layer)
	_overlay = _Overlay.new()
	_overlay.owner_ind = self
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay_layer.add_child(_overlay)
	_apply_visibility()


## Chevron colours pre-compensated for the world's tonemapper (UITonemap).
func set_tonemap(p: Dictionary) -> void:
	_target_col = UITonemap.compensate(UITheme.PREY, p)
	_threat_col = UITonemap.compensate(UITheme.THREAT, p)


func set_vr_mode(on: bool) -> void:
	vr_mode = on
	_apply_visibility()


func set_active(on: bool) -> void:
	active = on
	if not on:
		target_filter.reset()
		threat_filter.reset()
	_apply_visibility()


func _apply_visibility() -> void:
	if _overlay_layer:
		_overlay_layer.visible = active and not vr_mode
	if _target_mesh:
		_target_mesh.visible = false
		_threat_mesh.visible = false


func _cruise() -> float:
	if cruise_override > 0.0:
		return cruise_override
	var p := Birds.player()
	return SizeRules.performance(p.mass)["cruise"] if p else 9.0


func _world_scale() -> float:
	return (rig as XROrigin3D).world_scale if rig is XROrigin3D else 1.0


## A new target bird (or none). Applied at once, not next frame: events can
## arrive after this node's update, and a cue left one more frame on the old
## bird's side reads as a flicker.
func set_target(b: Bird) -> void:
	target = b
	_step(0.0)


func set_threat(b: Bird, level: float) -> void:
	threat = b
	threat_level = level
	_step(0.0)


func _process(delta: float) -> void:
	_step(delta)


## Advance the cues by `delta` seconds (the frame loop calls it; tests drive
## it with synthetic time).
func step(delta: float) -> void:
	_step(delta)


func _step(delta: float) -> void:
	if not active or camera == null or not camera.is_inside_tree():
		return
	# Gameplay time only: frozen cues while paused are fine (the HUD is hidden).
	_t += delta
	var cam := camera.global_transform
	if target != _last_target:
		_last_target = target
		target_filter.retarget()
	if threat != _last_threat:
		_last_threat = threat
		threat_filter.retarget()
	var tp := {}
	var ts := 0.0
	if is_instance_valid(target) and target.alive:
		tp = HudMath.view_polar(cam, target.get_body_position())
		ts = HudMath.target_alpha(tp["distance"], _cruise()) * TARGET_MAX_ALPHA
	target_filter.update(delta, tp, ts)
	var hp := {}
	var hs := 0.0
	if is_instance_valid(threat) and threat.alive:
		hp = HudMath.view_polar(cam, threat.get_body_position())
		hs = HudMath.threat_alpha(threat_level) * THREAT_MAX_ALPHA
	threat_filter.update(delta, hp, hs)
	_update_separation(delta)
	if vr_mode:
		_place(_target_mesh, target_filter, cam, 1.0, _target_col, ECCENTRICITY)
		# Urgency pulses the threat cue's size (not its brightness: no flicker).
		var pulse := 1.0 + 0.12 * sin(_t * TAU * 1.4) * clampf((threat_level - 0.5) * 2.0, 0.0, 1.0)
		_place(_threat_mesh, threat_filter, cam, pulse, _threat_col, ECCENTRICITY + threat_out)
	else:
		_overlay.queue_redraw()


## How far the threat cue steps out when the two cues point `target_angle`
## and `threat_angle` (radians, ring angles): SEPARATE_OUT when they point
## the same way, easing to 0 at SEPARATE_SPAN apart. Smooth (no kink) and
## the same whichever side each is on, so it never needs a latch.
static func separation(target_angle: float, threat_angle: float) -> float:
	var d := absf(wrapf(target_angle - threat_angle, -PI, PI))
	if d >= SEPARATE_SPAN:
		return 0.0
	var u := d / SEPARATE_SPAN
	return SEPARATE_OUT * (1.0 - u * u) * (1.0 - u * u)


## Step the threat cue out while both cues are (about to be) drawn. A cue
## appearing beside the other eases it out; a threat cue that is itself
## appearing is placed out there at once.
func _update_separation(delta: float) -> void:
	var want := 0.0
	if threat_filter.is_wanted() and target_filter.is_wanted():
		want = separation(target_filter.angle, threat_filter.angle)
	if not threat_filter.is_drawn():
		threat_out = want
	else:
		threat_out = lerpf(threat_out, want, 1.0 - exp(-delta / SEPARATE_TAU)) if delta > 0.0 else threat_out


func _place(mi: MeshInstance3D, f: IndicatorFilter, cam: Transform3D, scale_k: float, col: Color, ecc: float) -> void:
	mi.visible = f.is_drawn()
	if not mi.visible:
		return
	var ws := _world_scale()
	var p := HudMath.ring_point(f.angle, ecc, RING_RADIUS * ws)
	# Basis in camera space: +Z towards the eye, +Y pointing outwards along
	# the cue's direction, so the chevron's tip points where to turn.
	var z := -p.normalized()
	var out := Vector3(cos(f.angle), sin(f.angle), 0.0)
	var y := (out - z * out.dot(z)).normalized()
	var x := y.cross(z)
	var s := CHEVRON_SIZE * ws * scale_k
	var b := Basis(x * s, y * s, z * s)
	mi.global_transform = cam * Transform3D(b, p)
	var mat := mi.material_override as StandardMaterial3D
	mat.albedo_color = Color(col, f.alpha)


func cue_mesh(which: StringName) -> MeshInstance3D:
	return _target_mesh if which == &"target" else _threat_mesh


## Where cue `which` is drawn, as a world direction from the eye (unit;
## ZERO while it is not drawn): from the camera as it is NOW and the cue's
## ring angle, so it is right whatever the frame order. (The chevron meshes
## are placed in this node's own _process, after UIRoot's make_way, and a
## flying rig carries the eye ~0.1 m a frame: the meshes' last positions
## were a few degrees off, and the notices faded for cues that were not on
## them - the round-7 engineering verifier's phantom covers.)
func cue_direction(which: StringName) -> Vector3:
	if not active or not vr_mode or camera == null or not camera.is_inside_tree():
		return Vector3.ZERO
	var f := target_filter if which == &"target" else threat_filter
	if not f.is_drawn():
		return Vector3.ZERO
	var ecc := ECCENTRICITY + (threat_out if which == &"threat" else 0.0)
	return (camera.global_transform.basis.orthonormalized() * HudMath.ring_point(f.angle, ecc, 1.0)).normalized()


static func _make_chevron(col: Color, count: int) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in count:
		var dy := -0.42 * k
		# A dark rim first (drawn larger, same surface) keeps the cue readable
		# against bright sky, then the coloured chevron on top.
		for layer in 2:
			var grow := 1.28 if layer == 0 else 1.0
			var c := Color(UITheme.INK, 0.6) if layer == 0 else Color(1, 1, 1, 1)
			var z := 0.0 if layer == 0 else 0.002
			var pts := [Vector2(0, 0.5), Vector2(0.55, -0.12), Vector2(0.32, -0.34), Vector2(0, 0.02), Vector2(-0.32, -0.34), Vector2(-0.55, -0.12)]
			var v := []
			for p: Vector2 in pts:
				v.append(Vector3(p.x * grow, (p.y - 0.08) * grow + 0.08 + dy, z))
			for tri: Array in [[0, 5, 3], [0, 3, 1], [1, 3, 2], [5, 4, 3]]:
				for i: int in tri:
					st.set_color(c)
					st.add_vertex(v[i])
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = true
	mat.render_priority = CUE_RENDER_PRIORITY
	mat.disable_fog = true
	# Never painted over the player's own wings and hands (UIPanel.mark_occluder).
	UIPanel.respect_occluders(mat)
	mat.albedo_color = Color(col, 0.0)
	mi.material_override = mat
	mi.visible = false
	return mi


## Desktop: where each cue's tip was last drawn, as a fraction of the ring
## radius from the screen centre ({} until drawn; tests read it).
func desktop_tip_radius() -> Dictionary:
	return _overlay.tips if _overlay else {}


class _Overlay:
	extends Control
	## Desktop drawing of the same cues around the screen centre.
	var owner_ind: HudIndicators
	## Tip distance from the centre / ring radius, per cue last drawn.
	var tips := {}

	func _draw() -> void:
		if owner_ind == null:
			return
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.36
		tips.clear()
		_cue(c, r, owner_ind.target_filter, UITheme.PREY, 1, &"target", r)
		# The same step out as in VR, in proportion to the ring.
		_cue(c, r * (ECCENTRICITY + owner_ind.threat_out) / ECCENTRICITY, owner_ind.threat_filter, UITheme.THREAT, 2, &"threat", r)

	func _cue(c: Vector2, r: float, f: IndicatorFilter, col: Color, count: int, which: StringName, ring: float) -> void:
		if not f.is_drawn():
			return
		tips[which] = r / ring
		# Screen y grows downwards; cue angles grow upwards.
		var dir := Vector2(cos(f.angle), -sin(f.angle))
		var side := Vector2(-dir.y, dir.x)
		var s := 26.0
		for k in count:
			var tip := c + dir * (r - k * s * 0.8)
			var pts := PackedVector2Array([tip, tip - dir * s + side * s, tip - dir * s * 0.6, tip - dir * s - side * s])
			GestureArt.poly(self, pts, Color(col, f.alpha))
