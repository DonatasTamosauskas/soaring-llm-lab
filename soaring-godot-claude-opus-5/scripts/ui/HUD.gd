class_name HUD
extends Node3D

## Head-referenced readout and comfort vignette.
##
## Kept deliberately sparse. In a headset every pixel of UI is something bolted
## to your face, so this shows the three numbers a bird actually needs — how
## big you are, how fast you are going, how high you are — and otherwise gets
## out of the way.

## Far enough away to be comfortable to focus on, low enough to stay out of the
## way of the thing you are actually trying to catch.
const PANEL_DISTANCE: float = 1.6
const PANEL_DROP: float = 0.60

var player: BirdPlayer
var manager: GameManager

var _label: Label3D
var _debug_label: Label3D
var _vignette: MeshInstance3D
var _vignette_material: ShaderMaterial
var _score: int = 0

const VIGNETTE_SHADER: String = """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_test_disabled,
	depth_draw_never, fog_disabled, shadows_disabled;

uniform float strength : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	// Radial tunnel: the faster you fly, the narrower the aperture. Cutting
	// peripheral optic flow is the single most effective motion-comfort trick
	// available, and it doubles as a speed cue.
	float d = length(UV - vec2(0.5)) * 2.0;
	float inner = mix(1.6, 0.34, strength);
	ALBEDO = vec3(0.0);
	ALPHA = smoothstep(inner, inner + 0.38, d);
}
"""


func attach(player_ref: BirdPlayer, manager_ref: GameManager) -> void:
	player = player_ref
	manager = manager_ref
	manager.score_changed.connect(func(value: int) -> void: _score = value)

	var camera: Node3D = player.xr_camera if player.xr_active else player.desktop_camera
	camera.add_child(self)
	position = Vector3.ZERO

	_build_panel()
	_build_vignette()


func _build_panel() -> void:
	_label = Label3D.new()
	_label.text = ""
	_label.font_size = 96
	_label.pixel_size = 0.00042
	_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_label.no_depth_test = true
	_label.render_priority = 8
	_label.modulate = Color(1.0, 1.0, 1.0, 0.92)
	_label.outline_size = 24
	_label.outline_modulate = Color(0.0, 0.0, 0.0, 0.75)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.position = Vector3(0.0, -PANEL_DROP, -PANEL_DISTANCE)
	add_child(_label)

	_debug_label = Label3D.new()
	_debug_label.font_size = 64
	_debug_label.pixel_size = 0.00040
	_debug_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_debug_label.no_depth_test = true
	_debug_label.render_priority = 8
	_debug_label.outline_size = 18
	_debug_label.outline_modulate = Color(0.0, 0.0, 0.0, 0.8)
	_debug_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_debug_label.position = Vector3(-0.62, 0.34, -PANEL_DISTANCE)
	_debug_label.visible = false
	add_child(_debug_label)


func _build_vignette() -> void:
	var shader := Shader.new()
	shader.code = VIGNETTE_SHADER
	_vignette_material = ShaderMaterial.new()
	_vignette_material.shader = shader
	_vignette_material.set_shader_parameter("strength", 0.0)

	var quad := QuadMesh.new()
	quad.size = Vector2(1.6, 1.6)

	_vignette = MeshInstance3D.new()
	_vignette.mesh = quad
	_vignette.material_override = _vignette_material
	_vignette.position = Vector3(0.0, 0.0, -0.32)
	_vignette.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_vignette.extra_cull_margin = 16.0
	add_child(_vignette)


func _process(_delta: float) -> void:
	if player == null:
		return
	_update_vignette()
	_update_text()


## The vignette closes with speed, and closes harder in a hard turn — those are
## the two moments the inner ear disagrees most with the eyes.
func _update_vignette() -> void:
	var speed: float = player.airspeed()
	var speed_term: float = clampf((speed - 16.0) / 34.0, 0.0, 1.0)
	var turn_term: float = clampf(absf(player.model.bank) / 1.2, 0.0, 1.0) * 0.45
	var strength: float = clampf((speed_term + turn_term) * Tuning.comfort_vignette, 0.0, 0.85)
	# A full-screen transparent quad is not free on a headset — it is two eyes of
	# blending every frame. Skip it entirely while gliding slowly, which is most
	# of the time the vignette would be invisible anyway.
	_vignette.visible = strength > 0.02
	if _vignette.visible:
		_vignette_material.set_shader_parameter("strength", strength)


func _update_text() -> void:
	var speed_kmh: int = int(round(player.airspeed() * 3.6))
	var status: String = ""
	# Folded wings take priority over every other message. A player whose hands
	# are too close together is falling out of the sky for a reason they cannot
	# see, and nothing else on this display matters until they know it.
	if player.is_flying_by_wings() and player.wings.awaiting_first_spread:
		status = "  SPREAD YOUR ARMS TO OPEN YOUR WINGS"
	elif player.command.span < 0.35 and not player.perched:
		status = "  WINGS FOLDED — spread your arms"
	elif player.perched:
		status = "  PERCHED — spread your arms and flap"
	elif player.model.is_stalled:
		status = "  STALL — drop the nose"
	_label.text = "size %.2f    %d km/h    %d m%s\nscore %d" % [
		player.size, speed_kmh, int(round(player.altitude())), status, _score
	]

	_debug_label.visible = Tuning.show_debug_hud
	if not Tuning.show_debug_hud:
		return
	var m: FlightModel = player.model
	_debug_label.text = (
		"airspeed  %6.1f m/s\n" % m.airspeed
		+ "AoA       %6.1f deg\n" % rad_to_deg(m.angle_of_attack)
		+ "bank      %6.1f deg\n" % rad_to_deg(m.bank)
		+ "span      %6.2f\n" % player.command.span
		+ "stroke    %6.2f m/s\n" % player.command.stroke_speed
		+ "climb     %6.1f m/s\n" % m.velocity.y
		+ "load      %6.2f g\n" % m.load_factor
		+ "lift/drag %6.2f\n" % (m.lift_accel / maxf(m.drag_accel, 0.001))
		+ "wing area %6.2f m2\n" % m.wing_area
		+ "mass      %6.1f kg\n" % m.mass
		+ "stalled   %s" % ("YES" if m.is_stalled else "no")
	)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_debug"):
		Tuning.show_debug_hud = not Tuning.show_debug_hud
