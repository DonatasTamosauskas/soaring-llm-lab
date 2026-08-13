class_name HUD
extends Node3D

## Head-referenced readout, first-flight coaching and the comfort vignette.
##
## Kept deliberately sparse. In a headset every pixel of UI is something bolted
## to your face, so this shows the three numbers a bird actually needs — how
## big you are, how fast you are going, how high you are — and otherwise gets
## out of the way. Everything with more to say than that — menus, settings, the
## end-of-run summary — is a world-space panel in [GameMenu] instead, because a
## wall of head-locked text is the fastest way to make a person in a headset
## want to stop.

## Emitted the first time a player has demonstrated all four gestures, so the
## coach can be remembered as done and never shown again.
signal tutorial_finished()

## Far enough away to be comfortable to focus on, low enough to stay out of the
## way of the thing you are actually trying to catch.
const PANEL_DISTANCE: float = 1.6
const PANEL_DROP: float = 0.60

## How long a catch, a promotion or a death stays on screen. Long enough to read
## at 50 m/s, short enough that the sky is clear again before the next one.
const BANNER_SECONDS: float = 2.2

## Text sizes, as font pixels times [constant LABEL_PIXEL_SIZE] metres each.
## [UITests] converts them into degrees of visual angle at [constant
## PANEL_DISTANCE] and fails if any of them drops below what a headset panel can
## resolve — the coach line especially, which is the first thing a new player
## ever has to read.
##
## All three went up by half again after a frame was measured rather than
## eyeballed: at 96 the readout's capital letters were 0.9 degrees, which is
## about a dozen pixels on a headset panel and reads as fine print at the exact
## moment you cannot afford to squint. The floor is now stated as a cap height
## in [UITheme] and these clear it.
const LABEL_PIXEL_SIZE: float = 0.00042
const READOUT_FONT: int = 140
const BANNER_FONT: int = 132
const COACH_FONT: int = 148
## Width and height of the rank bar, in metres at [constant PANEL_DISTANCE].
const BAR_SIZE := Vector2(0.62, 0.022)

var player: BirdPlayer
var manager: GameManager
## Set by [GameMenu]. Owns whether the prey marker is drawn and whether this
## player has been taught yet.
var settings: PlayerSettings = null
var coach := Coach.new()

var _label: Label3D
var _debug_label: Label3D
var _banner: Label3D
var _coach_label: Label3D
var _bar_fill: MeshInstance3D
var _bar_back: MeshInstance3D
var _chevron: MeshInstance3D
var _vignette: MeshInstance3D
var _vignette_material: ShaderMaterial
var _banner_timer: float = 0.0
var _run_over: bool = false
var _taught: bool = false

const VIGNETTE_SHADER: String = """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_test_disabled,
	depth_draw_never, fog_disabled, shadows_disabled;

uniform float inner : hint_range(0.0, 2.0) = 2.0;

void fragment() {
	// Radial tunnel: the faster you fly, the narrower the aperture. Cutting
	// peripheral optic flow is the single most effective motion-comfort trick
	// available, and it doubles as a speed cue.
	//
	// Measured from the frame rather than from the quad's own UV, which is the
	// bug that made this feature do nothing for its whole life: the quad is a
	// 1.6 m square held 0.32 m from the eye, so a camera only ever sees the
	// middle two thirds of it, and the darkening lived entirely in the part
	// that was off screen. SCREEN_UV is the eye's own viewport, in both eyes,
	// at any aspect ratio, so 1.0 is the middle of an edge and 1.41 is a
	// corner — the units [method ViewComfort.aperture] is written in.
	float d = length((SCREEN_UV - vec2(0.5)) * 2.0);
	ALBEDO = vec3(0.0);
	ALPHA = smoothstep(inner, inner + %.2f, d);
}
"""


func attach(player_ref: BirdPlayer, manager_ref: GameManager) -> void:
	player = player_ref
	manager = manager_ref
	manager.event_occurred.connect(_on_event)
	# A gesture with no acknowledgement is a gesture the player will assume did
	# not work, and then perform again.
	player.recentred.connect(_on_recentred)

	var camera: Node3D = player.xr_camera if player.xr_active else player.desktop_camera
	camera.add_child(self)
	position = Vector3.ZERO

	_build_panel()
	_build_rank_bar()
	_build_chevron()
	_build_vignette()


func _build_panel() -> void:
	_label = Label3D.new()
	_label.text = ""
	_label.font_size = READOUT_FONT
	_label.pixel_size = LABEL_PIXEL_SIZE
	_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_label.no_depth_test = true
	_label.render_priority = 8
	_label.modulate = UITheme.colour("hud_text")
	_label.outline_size = 24
	_label.outline_modulate = UITheme.colour("outline_soft")
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
	_debug_label.outline_modulate = UITheme.colour("outline")
	_debug_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_debug_label.position = Vector3(-0.62, 0.34, -PANEL_DISTANCE)
	_debug_label.visible = false
	add_child(_debug_label)

	# Events go above the readout rather than in it. A catch has to be legible
	# without reading, and a number that changes inside a line of other numbers
	# is not — you find out you grew by noticing you grew.
	_banner = _make_label(BANNER_FONT, Vector3(0.0, -PANEL_DROP + 0.30, -PANEL_DISTANCE))
	_banner.modulate = _banner_colour(0.0)
	add_child(_banner)

	# One lesson at a time, above the banner so a catch never lands on top of an
	# instruction. See [Coach] for why there is a lesson at all.
	_coach_label = _make_label(COACH_FONT, Vector3(0.0, -PANEL_DROP + 0.46, -PANEL_DISTANCE))
	_coach_label.modulate = UITheme.colour("hud_coach")
	_coach_label.visible = false
	add_child(_coach_label)


func _make_label(size: int, at: Vector3) -> Label3D:
	var label := Label3D.new()
	label.font_size = size
	label.pixel_size = LABEL_PIXEL_SIZE
	label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	label.no_depth_test = true
	label.render_priority = 9
	label.outline_size = 22
	label.outline_modulate = UITheme.colour("outline")
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.position = at
	return label


## The climb, as a bar. Built from two quads rather than drawn with text
## characters because a block-drawing glyph that the headset's font happens not
## to have is a row of empty boxes, and this is the one element that has to be
## readable at a glance without being read.
func _build_rank_bar() -> void:
	_bar_back = _make_bar(UITheme.colour("hud_bar_back"), 6)
	_bar_back.position = Vector3(0.0, -PANEL_DROP + 0.135, -PANEL_DISTANCE)
	add_child(_bar_back)

	_bar_fill = _make_bar(UITheme.colour("hud_bar_fill"), 7)
	_bar_fill.position = _bar_back.position + Vector3(0.0, 0.0, 0.002)
	add_child(_bar_fill)


func _make_bar(colour: Color, priority: int) -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = BAR_SIZE
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = colour
	material.no_depth_test = true
	material.disable_fog = true
	material.render_priority = priority
	var instance := MeshInstance3D.new()
	instance.mesh = quad
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.extra_cull_margin = 16.0
	return instance


## A chevron that points at the nearest bird you could eat. This is the only
## navigation aid in the game and it exists because the sky is 1.2 km across and
## a bird 200 m away is four pixels: without it, hunting begins with a minute of
## turning around looking for something, which is the least interesting minute
## available.
func _build_chevron() -> void:
	var mesh := ArrayMesh.new()
	var vertices := PackedVector3Array([
		Vector3(0.0, 0.055, 0.0), Vector3(-0.038, -0.030, 0.0), Vector3(0.038, -0.030, 0.0)
	])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = UITheme.colour("guide")
	material.no_depth_test = true
	material.disable_fog = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.render_priority = 7

	_chevron = MeshInstance3D.new()
	_chevron.mesh = mesh
	_chevron.material_override = material
	_chevron.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_chevron.extra_cull_margin = 16.0
	_chevron.scale = Vector3(0.72, 0.72, 1.0)
	# Below the readout, not above it: at eye level it reads as a reticle, and it
	# collided with the event banner, which is the one thing that must never be
	# obscured at the moment it appears.
	_chevron.position = Vector3(0.0, -PANEL_DROP - 0.115, -PANEL_DISTANCE)
	_chevron.visible = false
	add_child(_chevron)


func _build_vignette() -> void:
	var shader := Shader.new()
	shader.code = VIGNETTE_SHADER % ViewComfort.APERTURE_FEATHER
	_vignette_material = ShaderMaterial.new()
	_vignette_material.shader = shader
	_vignette_material.set_shader_parameter("inner", ViewComfort.APERTURE_OPEN)

	var quad := QuadMesh.new()
	quad.size = Vector2(1.6, 1.6)

	_vignette = MeshInstance3D.new()
	_vignette.mesh = quad
	_vignette.material_override = _vignette_material
	_vignette.position = Vector3(0.0, 0.0, -0.32)
	_vignette.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_vignette.extra_cull_margin = 16.0
	add_child(_vignette)


func _process(delta: float) -> void:
	if player == null:
		return
	_update_vignette()
	_update_text()
	_update_rank_bar()
	_update_chevron()
	_update_banner(delta)
	_update_coach(delta)


# --- teaching ----------------------------------------------------------------

## Handed the player's settings by [GameMenu], which is where they are loaded
## from and saved to. A player who has flown before is not taught again.
func use_settings(settings_ref: PlayerSettings) -> void:
	settings = settings_ref
	if settings != null and settings.flag("learned"):
		coach.skip()
		_taught = true


func teach_again() -> void:
	coach.restart()
	_taught = false


## The lesson goes away the moment the player does the thing, and never fights
## the status line: "WINGS FOLDED — spread your arms" and "SPREAD YOUR ARMS"
## on screen together would be this game shouting.
func _update_coach(delta: float) -> void:
	if _run_over or coach.complete:
		_coach_label.visible = false
		if coach.complete and not _taught:
			_taught = true
			tutorial_finished.emit()
		return
	coach.observe(player.command, player.perched, delta)
	var cue: String = coach.cue()
	_coach_label.text = cue
	_coach_label.visible = not cue.is_empty() and _status_text().is_empty()


# --- the run -----------------------------------------------------------------

## One channel for everything that happens to the player, so the banner cannot
## fall out of step with the sound and the haptics — they are all reacting to the
## same event. See [signal GameManager.event_occurred].
func _on_event(kind: StringName, payload: Dictionary) -> void:
	match kind:
		&"catch":
			var streak: int = int(payload.get("streak", 1))
			# The multiplier itself lives on the rank line; repeating it here just
			# puts the same number on screen twice.
			_show_banner("+%d%s" % [
				int(payload.get("score", 0)),
				"    %d IN A ROW" % streak if streak > 1 else "",
			])
		&"caught":
			var lives: int = int(payload.get("lives", 0))
			_show_banner(
				"CAUGHT — %d %s left" % [lives, "life" if lives == 1 else "lives"]
					if lives > 0 else "CAUGHT"
			)
		&"rank_up":
			_show_banner("%s" % payload.get("name", ""))
		&"rank_down":
			_show_banner("DEMOTED — %s" % payload.get("name", ""))
		&"ended":
			# The summary itself belongs to [GameMenu]'s world-space panel; all
			# this display does is get out of its way.
			_run_over = true
		&"restart":
			_run_over = false
			_show_banner("FLY")


func _on_recentred() -> void:
	_show_banner("RECENTRED")


func _banner_colour(alpha: float) -> Color:
	var colour: Color = UITheme.colour("hud_banner")
	colour.a = clampf(alpha, 0.0, 1.0)
	return colour


func _show_banner(text: String) -> void:
	_banner.text = text
	_banner_timer = BANNER_SECONDS


func _update_banner(delta: float) -> void:
	if _banner_timer <= 0.0:
		return
	_banner_timer = maxf(0.0, _banner_timer - delta)
	# Hold, then fade over the last third, so it never blinks out mid-read.
	var fade: float = clampf(_banner_timer / (BANNER_SECONDS * 0.35), 0.0, 1.0)
	_banner.modulate = _banner_colour(fade)


func _update_rank_bar() -> void:
	var visible_bar: bool = not _run_over
	_bar_back.visible = visible_bar
	_bar_fill.visible = visible_bar
	if not visible_bar:
		return
	var progress: float = Progression.rank_progress(player.size)
	# Scale about the left edge, not the centre, so the bar fills instead of
	# growing outward from the middle.
	_bar_fill.scale = Vector3(maxf(progress, 0.001), 1.0, 1.0)
	_bar_fill.position.x = -BAR_SIZE.x * 0.5 * (1.0 - progress)


## Points at the nearest bird the player can eat, and gets out of the way once
## that bird is roughly ahead — an arrow that never stops pointing is furniture.
func _update_chevron() -> void:
	var wanted: bool = not _run_over and (settings == null or settings.flag("show_guide"))
	var prey: BirdNPC = manager.nearest_prey() if wanted else null
	if not wanted:
		_chevron.visible = false
	if prey == null or not is_instance_valid(prey):
		_chevron.visible = false
		return
	var local: Vector3 = to_local(prey.global_position)
	var bearing: float = atan2(local.x, -local.z)
	if absf(bearing) < 0.20 and local.z < 0.0:
		_chevron.visible = false
		return
	_chevron.visible = true
	# Screen-space compass: rotate the arrow about the view axis so that "up" is
	# straight ahead and a bird behind you points straight down.
	_chevron.rotation = Vector3(0.0, 0.0, -bearing)


## The vignette closes with speed, and closes harder in a hard turn — those are
## the two moments the inner ear disagrees most with the eyes.
func _update_vignette() -> void:
	# The shape of it belongs to [ViewComfort], which is also what decides how
	# fast the view is allowed to rotate — the two are the same comfort decision
	# and used to be two different opinions about it in two files.
	var strength: float = player.comfort.vignette
	# A full-screen transparent quad is not free on a headset — it is two eyes of
	# blending every frame. Skip it entirely while gliding slowly, which is most
	# of the time the vignette would be invisible anyway.
	_vignette.visible = strength > 0.02
	if _vignette.visible:
		_vignette_material.set_shader_parameter("inner", ViewComfort.aperture(strength))


func _update_text() -> void:
	# A finished run gets the summary and nothing else. Leaving the live readout
	# up underneath it says "0 lives" next to an explanation of why.
	_label.visible = not _run_over
	if _run_over:
		return
	var speed_kmh: int = int(round(player.airspeed() * 3.6))
	var status: String = _status_text()
	var session: GameSession = manager.session
	# Two lines, the same as before: what you are, then how you are flying. The
	# rank line carries the three things a run is made of — who you are, how many
	# mistakes you have left, and where you stand — and the bar underneath it is
	# how close the next promotion is.
	_label.text = "%s%s        %s\nsize %.2f    %d km/h    %d m%s" % [
		Progression.name_of_rank(session.rank),
		"   x%.2f" % Progression.streak_multiplier(session.streak) if session.streak > 1 else "",
		_lives_and_standing(session),
		player.size, speed_kmh, int(round(player.altitude())), status,
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


## Folded wings take priority over every other message. A player whose hands are
## too close together is falling out of the sky for a reason they cannot see, and
## nothing else on this display matters until they know it.
##
## Also the coach's mute switch: an instruction and a warning that say the same
## thing in different words, at the same moment, is this game shouting.
func _status_text() -> String:
	# Above even the folded wings, because it explains why nothing the player
	# does is working. A bird that has stopped answering the controls and says
	# nothing is a game that has crashed, as far as anyone wearing a headset can
	# tell — and the wings are levelling themselves, so this is also the only
	# warning that the bird is currently flying itself.
	if not player.wings.tracking_ok:
		return "   TRACKING LOST — the wings are gliding themselves"
	if player.command.span < 0.35 and not player.perched:
		return "   WINGS FOLDED — spread your arms"
	if player.perched:
		return "   PERCHED — spread your arms and flap"
	if player.model.is_stalled:
		return "   STALL — drop the nose"
	return ""


## Lives as plain characters and standing as an ordinal. Spelled out rather than
## drawn with pips because the headset's font is not this game's to choose, and a
## row of missing-glyph boxes where your remaining lives should be is worse than
## a word.
func _lives_and_standing(session: GameSession) -> String:
	return "%d %s      %s of %d" % [
		session.lives, "life" if session.lives == 1 else "lives",
		_ordinal(manager.standing), manager.standing_total,
	]


static func _ordinal(place: int) -> String:
	var suffix: String = "th"
	if place % 100 < 11 or place % 100 > 13:
		match place % 10:
			1:
				suffix = "st"
			2:
				suffix = "nd"
			3:
				suffix = "rd"
	return "%d%s" % [place, suffix]


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_debug"):
		Tuning.show_debug_hud = not Tuning.show_debug_hud
