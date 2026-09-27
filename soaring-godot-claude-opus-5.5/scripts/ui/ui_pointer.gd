class_name UIPointer
extends Node3D
## The VR laser pointer: a beam from either controller's aim pose into the
## open menu panel, a reticle where it lands, and mouse events pushed into the
## panel's SubViewport (motion = hover, trigger = click).
##
## One hand is active at a time (the preferred hand from Settings.handedness,
## or whichever hand last pulled its trigger), so there is never a second
## beam waving around. The beam only exists while a menu is open.
##
## A click needs a *fresh* pull that starts after the screen it lands on
## appeared: a trigger already squeezed when a menu opens (players clench
## while flapping) must be let go first, and pulls in the first
## SCREEN_GRACE_S after a screen change are ignored (nobody can read a new
## screen that fast, so such a pull was meant for something else). Without
## this, releasing a clenched trigger could restart a run or dismiss the
## run summary the moment it appeared.

## Trigger hysteresis: press above PRESS, release below RELEASE, so a
## half-held trigger can't chatter clicks.
const PRESS := 0.65
const RELEASE := 0.35
## Seconds after a screen appears during which new pulls are not clicks.
const SCREEN_GRACE_S := 0.2
## Beam length when it hits nothing, m at world_scale 1.
const MISS_LENGTH := 2.2
## Reticle diameter as a visual angle, degrees (constant at any distance).
const RETICLE_DEG := 0.9
## Hover hysteresis: a hovered control stays hovered until the beam is this
## far (panel px; 12 px = 0.46 deg at 1.5 m) outside it, unless it lands on
## another button. A hand's tremor (0.05-0.2 deg) resting the beam on a
## button's edge no longer flickers the highlight and ticks 7 times a second.
const HOVER_KEEP_PX := 12.0
## At most one hover tick in this long ("distinct patterns, never a buzz").
const HOVER_TICK_GAP_S := 0.35

var sources: Array[UIPointerSource] = []
var active_index := 1
## Panels the pointer may hit (set by UIRoot).
var panels: Array[UIPanel] = []
var enabled := false
var world_scale := 1.0
## Last hit, for tests: {} or {panel, pixel, point, distance}.
var last_hit := {}
## Clicks delivered (for tests / diagnostics).
var click_count := 0

var _pressed := [false, false]
## Engine ticks (ms) before which trigger pulls are swallowed (see rearm()).
var _grace_until_ms := 0
## Beam/reticle colours pre-compensated for the world's tonemapper.
var _col_hit := UITheme.ACCENT
var _col_miss := UITheme.TEXT
var _col_reticle := UITheme.TEXT
var _beams: Array[MeshInstance3D] = []
var _reticle: MeshInstance3D
var _hover_panel: UIPanel
var _hover_control: Control
var _press_panel: UIPanel
var _next_tick_ms := 0


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	for i in 2:
		var beam := MeshInstance3D.new()
		beam.name = "Beam%d" % i
		beam.mesh = _beam_mesh()
		beam.material_override = _unshaded_material(20, true)
		beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		beam.visible = false
		add_child(beam)
		_beams.append(beam)
	_reticle = MeshInstance3D.new()
	_reticle.name = "Reticle"
	_reticle.mesh = _reticle_mesh()
	_reticle.material_override = _unshaded_material(21, false)
	_reticle.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_reticle.visible = false
	add_child(_reticle)
	top_level = true
	global_transform = Transform3D.IDENTITY


func set_tonemap(p: Dictionary) -> void:
	_col_hit = UITonemap.compensate(UITheme.ACCENT, p)
	_col_miss = UITonemap.compensate(UITheme.TEXT, p)
	_col_reticle = UITonemap.compensate(UITheme.TEXT, p)


## Replaces the input sources; sources no longer used are released (an XR
## source frees the aim controller it added under the rig).
func set_sources(left: UIPointerSource, right: UIPointerSource) -> void:
	for old in sources:
		if old != left and old != right:
			old.release()
	sources = [left, right]
	_pressed = [false, false]
	rearm()


## Let go of every source (UIRoot leaving the tree: the panels are going
## too, so no events are sent to them).
func set_sources_released() -> void:
	_hover_panel = null
	_hover_control = null
	_press_panel = null
	last_hit = {}
	for old in sources:
		old.release()
	sources = []


## A confirming buzz on the active hand (e.g. a held Restart went through),
## scaled by Settings > Haptics like every pointer pulse.
func pulse(amplitude: float, seconds: float) -> void:
	var src := active_source()
	if src and src.is_tracked():
		src.haptic(amplitude * _haptics_scale(), seconds)


func set_preferred_hand(hand: String) -> void:
	active_index = 0 if hand == "left" else 1


func active_source() -> UIPointerSource:
	return sources[active_index] if active_index < sources.size() else null


func set_enabled(on: bool) -> void:
	if enabled == on:
		return
	enabled = on
	if on:
		rearm()
	else:
		_clear_hover()
		for i in _pressed.size():
			_pressed[i] = false
		_hide_visuals()


## A new screen is up: cancel any press in progress, treat a trigger that is
## already (even half) squeezed as held, so only a fresh pull can click, and
## ignore pulls for SCREEN_GRACE_S. UIRoot calls this on every screen change.
func rearm() -> void:
	_release_press()
	for i in mini(sources.size(), _pressed.size()):
		_pressed[i] = sources[i].trigger() > RELEASE
	_grace_until_ms = Time.get_ticks_msec() + int(SCREEN_GRACE_S * 1000.0)


## True once a pull would be a click (tests wait for this like a player would).
func accepting_clicks() -> bool:
	return enabled and Time.get_ticks_msec() >= _grace_until_ms


func _process(_delta: float) -> void:
	if not enabled or sources.is_empty():
		_hide_visuals()
		return
	# Trigger edges on both hands: pulling the other hand's trigger hands the
	# pointer over (and that same pull clicks, which is what people expect).
	var edges := [0, 0]
	var in_grace := Time.get_ticks_msec() < _grace_until_ms
	for i in sources.size():
		var v := sources[i].trigger()
		if not _pressed[i] and v >= PRESS:
			_pressed[i] = true
			# A pull during the grace window is held but never becomes a
			# click: its release finds no press to complete.
			edges[i] = 0 if in_grace else 1
		elif _pressed[i] and v <= RELEASE:
			_pressed[i] = false
			edges[i] = -1
	for i in sources.size():
		if edges[i] == 1 and i != active_index and sources[i].is_tracked():
			_release_press()
			active_index = i
	var src := active_source()
	if src == null or not src.is_tracked():
		_clear_hover()
		_hide_visuals()
		return
	var aim := src.aim_transform()
	var origin := aim.origin
	var dir := (-aim.basis.z).normalized()
	var hit := {}
	for p in panels:
		var h := p.intersect_ray(origin, dir)
		if not h.is_empty() and (hit.is_empty() or h["distance"] < hit["distance"]):
			h["panel"] = p
			hit = h
	last_hit = hit
	_update_hover(hit)
	var edge: int = edges[active_index]
	if edge == 1 and not hit.is_empty():
		_press_panel = hit["panel"]
		_press_panel.pointer_button(hit["pixel"], true)
		src.haptic(0.35 * _haptics_scale(), 0.03)
	elif edge == -1 and _press_panel:
		# Releasing over the pressed panel is a click. The click may close
		# the menu (and disable this pointer) re-entrantly, so keep locals.
		var panel := _press_panel
		_press_panel = null
		var on_panel: bool = not hit.is_empty() and hit["panel"] == panel
		var px: Vector2 = hit["pixel"] if on_panel else Vector2(-10000, -10000)
		if on_panel:
			click_count += 1
		panel.pointer_button(px, false)
	if not enabled:
		_hide_visuals()
		return
	_draw(origin, dir, hit)


func _update_hover(hit: Dictionary) -> void:
	var panel: UIPanel = hit.get("panel")
	if _hover_panel and _hover_panel != panel:
		_hover_panel.pointer_exit()
	var keep: Control = _hover_control if _hover_panel == panel and is_instance_valid(_hover_control) else null
	_hover_panel = panel
	var c: Control = null
	if panel:
		panel.pointer_move(hit["pixel"])
		c = panel.hovered_control()
		# Hysteresis: just off the hovered button (and on no other one) it
		# stays hovered, and the pointer is held on its edge so a click lands
		# where the highlight is (the hit is shared with the click below).
		if keep and c != keep and not (c is BaseButton) and keep.is_visible_in_tree():
			var r := keep.get_global_rect()
			var px: Vector2 = hit["pixel"]
			if r.grow(HOVER_KEEP_PX).has_point(px) and r.size.x > 2.0 and r.size.y > 2.0:
				px = px.clamp(r.position + Vector2.ONE, r.end - Vector2.ONE)
				hit["pixel"] = px
				panel.pointer_move(px)
				c = panel.hovered_control()
	if c != _hover_control:
		_hover_control = c
		# A light tick when the beam crosses onto something clickable, but
		# never more often than HOVER_TICK_GAP_S.
		var now := Time.get_ticks_msec()
		if c is BaseButton and not (c as BaseButton).disabled and active_source() and now >= _next_tick_ms:
			_next_tick_ms = now + int(HOVER_TICK_GAP_S * 1000.0)
			active_source().haptic(0.15 * _haptics_scale(), 0.012)


func _release_press() -> void:
	if _press_panel:
		_press_panel.pointer_button(Vector2(-10000, -10000), false)
		_press_panel = null


func _clear_hover() -> void:
	_release_press()
	if _hover_panel:
		_hover_panel.pointer_exit()
	_hover_panel = null
	_hover_control = null
	last_hit = {}


func hovered() -> Control:
	return _hover_control


func _haptics_scale() -> float:
	return clampf(float(Settings.get_value("haptics", 1.0)), 0.0, 1.0)


func _hide_visuals() -> void:
	for b in _beams:
		b.visible = false
	if _reticle:
		_reticle.visible = false


func _draw(origin: Vector3, dir: Vector3, hit: Dictionary) -> void:
	var length: float = hit["distance"] if not hit.is_empty() else MISS_LENGTH * world_scale
	for i in _beams.size():
		_beams[i].visible = i == active_index
	var beam := _beams[active_index]
	# The beam mesh is 1 m long along -Z; scale it to the hit and keep its
	# thickness proportional to the player's scale.
	var up := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.98 else Vector3.BACK
	var b := Basis.looking_at(dir, up)
	beam.global_transform = Transform3D(Basis(b.x * world_scale, b.y * world_scale, b.z * length), origin)
	var mat := beam.material_override as StandardMaterial3D
	mat.albedo_color = Color(_col_hit, 0.9) if not hit.is_empty() else Color(_col_miss, 0.35)
	_reticle.visible = not hit.is_empty()
	if not hit.is_empty():
		var panel: UIPanel = hit["panel"]
		var d: float = hit["distance"]
		var diameter := 2.0 * d * tan(deg_to_rad(RETICLE_DEG) * 0.5)
		# Lie flat on the (curved) surface where the ray lands.
		var n: Vector3 = hit.get("normal", panel.global_transform.basis.z.normalized())
		var x := panel.global_transform.basis.y.normalized().cross(n).normalized()
		var pb := Basis(x, n.cross(x), n)
		# Sit a hair in front of the panel so it never z-fights the quad.
		var pos: Vector3 = hit["point"] + n * 0.002 * world_scale
		_reticle.global_transform = Transform3D(pb.scaled(Vector3.ONE * diameter), pos)
		var hov := _hover_control is BaseButton
		(_reticle.material_override as StandardMaterial3D).albedo_color = _col_hit if hov else _col_reticle


func reticle_node() -> MeshInstance3D:
	return _reticle


func beam_node(i: int) -> MeshInstance3D:
	return _beams[i]


static func _beam_mesh() -> Mesh:
	# A thin square tube tapering towards the far end: 6 mm at the hand,
	# 3 mm at the tip; drawn unshaded so it reads in any light.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var r0 := 0.003
	var r1 := 0.0015
	var near := [Vector3(-r0, -r0, 0), Vector3(r0, -r0, 0), Vector3(r0, r0, 0), Vector3(-r0, r0, 0)]
	var far := [Vector3(-r1, -r1, -1), Vector3(r1, -r1, -1), Vector3(r1, r1, -1), Vector3(-r1, r1, -1)]
	for i in 4:
		var j := (i + 1) % 4
		st.set_color(Color(1, 1, 1, 1))
		st.add_vertex(near[i])
		st.add_vertex(far[j])
		st.add_vertex(near[j])
		st.add_vertex(near[i])
		st.add_vertex(far[i])
		st.add_vertex(far[j])
	return st.commit()


static func _reticle_mesh() -> Mesh:
	# A flat hexagon: low-poly, 1 unit across, facing +Z.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in 6:
		var a0 := TAU * i / 6.0
		var a1 := TAU * (i + 1) / 6.0
		st.add_vertex(Vector3.ZERO)
		st.add_vertex(Vector3(cos(a0), sin(a0), 0) * 0.5)
		st.add_vertex(Vector3(cos(a1), sin(a1), 0) * 0.5)
	return st.commit()


## Unshaded, drawn over everything (the pointer must stay visible on the
## panel, which itself ignores depth)...
static func _unshaded_material(priority: int, alpha: bool) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if alpha:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = true
	mat.render_priority = priority
	mat.disable_fog = true
	# ...except over the player's own hands (they are nearer).
	UIPanel.respect_occluders(mat)
	return mat
