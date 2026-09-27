extends RefCounted
## Shared fixture for the ui suites: a UIRoot forced into VR or desktop mode,
## a mock XR rig (XROrigin3D + XRCamera3D at standing eye height), scripted
## pointer sources, a mock GameLoop and a mock player. Nothing here depends
## on another area's in-progress code (only core contracts).
##
## Settings: the settings tests write user://settings.cfg (they check it is
## persisted). tools/gd.sh gives every sandbox its own user:// directory, so
## no other process (another area's tests, a verifier's probe under its own
## sandbox name, the real game) can see or clobber it; the kit only puts the
## values it found back at teardown, so the next test starts from them.

const UI_SCENE := preload("res://scenes/ui/ui_root.tscn")
const EYE := 1.6

## Headless Godot sleeps OS.low_processor_usage_mode_sleep_usec (6.9 ms by
## default) every frame because it has no window to draw. The area's own
## suites (tests/unit/ui) wait thousands of frames for layout and input, so
## while one of their kits is up that idle sleep is shortened (restored at
## teardown); they measure real-time behaviour (fades, timers, animation
## rates, the pointer's grace window) in real time, so it is unaffected.
## Other hosts (the verifiers' probes in tests/probes/ui count frames as
## time) keep the engine's default pacing.
const FAST_SLEEP_USEC := 1000
static var _fast_depth := 0
static var _saved_sleep := -1

var host: Node
var ui: UIRoot
var rig: XROrigin3D
var cam: XRCamera3D
var left: UIPointerSource
var right: UIPointerSource
var gl: UIMockGameLoop
var player: UIMockPlayer
var progress_path := ""
var quits := 0
## The node the rig hangs under after parent_rig_like_player_bird() (null:
## the rig is the host's child, at the identity).
var rig_parent: Node3D
var _settings_snapshot := {}
var _fast := false


func setup(p_host: Node, vr := true, with_player := true, ws := 1.0) -> void:
	host = p_host
	_fast = _own_suite(p_host)
	if _fast:
		if _fast_depth == 0:
			_saved_sleep = OS.low_processor_usage_mode_sleep_usec
			OS.low_processor_usage_mode_sleep_usec = mini(_saved_sleep, FAST_SLEEP_USEC)
		_fast_depth += 1
	_snapshot_settings()
	progress_path = "user://ui_test_progress_%d.cfg" % (Time.get_ticks_usec() % 1000000)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(progress_path))
	Game.set_state(Game.State.MENU)
	rig = XROrigin3D.new()
	rig.name = "MockRig"
	rig.add_to_group(&"player_rig")
	rig.process_mode = Node.PROCESS_MODE_ALWAYS
	rig.world_scale = ws
	cam = XRCamera3D.new()
	cam.name = "Cam"
	rig.add_child(cam)
	host.add_child(rig)
	set_head(Vector3(0, EYE, 0), 0.0)
	cam.current = true
	gl = UIMockGameLoop.new()
	host.add_child(gl)
	if with_player:
		player = UIMockPlayer.new()
		host.add_child(player)
	ui = UI_SCENE.instantiate() as UIRoot
	ui.mode = UIRoot.Mode.VR if vr else UIRoot.Mode.DESKTOP
	ui.progress_path = progress_path
	host.add_child(ui)
	ui.quit_handler = func() -> void: quits += 1
	ui.attach_rig(rig, cam)
	left = UIPointerSource.new(&"left_hand")
	right = UIPointerSource.new(&"right_hand")
	left.tracked = true
	right.tracked = true
	ui.set_pointer_sources(left, right)
	park_hands()


func teardown() -> void:
	if Game.state == Game.State.PAUSED:
		Game.set_state(Game.State.MENU)
	Game.set_state(Game.State.MENU)
	for n in [ui, gl, player, rig, rig_parent]:
		if is_instance_valid(n):
			n.queue_free()
	_restore_settings()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(progress_path))
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if _fast:
		_fast = false
		_fast_depth = maxi(_fast_depth - 1, 0)
		if _fast_depth == 0 and _saved_sleep >= 0:
			OS.low_processor_usage_mode_sleep_usec = _saved_sleep


static func _own_suite(h: Node) -> bool:
	var sc: Script = h.get_script() if h else null
	return sc != null and sc.resource_path.begins_with("res://tests/unit/ui/")


## The rig as the real game has it: flight's PlayerBird is the XROrigin3D's
## parent and yaws it with every flown turn, while Bird.velocity and
## Bird.get_forward() are in world space. Moves the rig under a new node
## (returned; yaw it with set_rig_heading) and re-attaches it to the UI.
func parent_rig_like_player_bird() -> Node3D:
	rig_parent = Node3D.new()
	rig_parent.name = "MockPlayerBird"
	host.add_child(rig_parent)
	rig.get_parent().remove_child(rig)
	rig_parent.add_child(rig)
	ui.attach_rig(rig, cam)
	return rig_parent


## The rig's heading in the world (degrees, + = left), as PlayerBird yaws it
## in a flown turn.
func set_rig_heading(yaw_deg: float) -> void:
	if rig_parent:
		rig_parent.global_basis = Basis(Vector3.UP, deg_to_rad(yaw_deg))


## A recorded real-game flight (tests/shots/ui_game_record.gd, see its
## columns): rows by name ("tutorial", "manoeuvres").
static func game_flight(name_: String) -> Array:
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://tests/unit/ui/ui_game_flights.json"))
	return ((d as Dictionary)["flights"] as Dictionary).get(name_, []) if d is Dictionary else []


## Put the scene where a recorded game flight was at time `t` (call after
## parent_rig_like_player_bird), through core contracts only: the rig's
## heading, the mock player's velocity and forward (world) and torso
## (telemetry body_yaw), world_scale, the head (rig frame; `head_add` [yaw,
## pitch] deg on top), and stand-in birds where GameLoop's target and threat
## were, named on Events.target_changed / threat_changed as GameLoop names
## them (a new bird, or the level moving 0.02). `room_deg` turns the player
## in their room: torso and head further left, the rig as much the other
## way, the flight in the world the same. `state` ({} at first) carries the
## cursor and the birds between calls. Returns {velocity, torso_deg}.
func apply_game_row(rows: Array, t: float, room_deg: float, state: Dictionary, head_add := Vector2.ZERO) -> Dictionary:
	var n := rows.size()
	var ri := int(state.get("ri", 0))
	while ri < n - 2 and float(rows[ri + 1][0]) <= t:
		ri += 1
	state["ri"] = ri
	var a: Array = rows[ri]
	var b: Array = rows[ri + 1]
	var u := clampf((t - float(a[0])) / maxf(float(b[0]) - float(a[0]), 1e-4), 0.0, 1.0)
	var ang := func(i: int) -> float: return float(a[i]) + wrapf(float(b[i]) - float(a[i]), -180.0, 180.0) * u
	var lin := func(i: int) -> float: return lerpf(float(a[i]), float(b[i]), u)
	var v := Vector3(lin.call(2), lin.call(3), lin.call(4))
	var fw := Vector3(lin.call(5), lin.call(6), lin.call(7))
	var torso: float = float(ang.call(8)) + room_deg
	set_rig_heading(float(ang.call(1)) - room_deg)
	player.velocity = v
	if fw.length() > 1e-3 and absf(fw.normalized().y) < 0.999:
		player.global_basis = Basis.looking_at(fw.normalized(), Vector3.UP)
	player.tel["body_yaw"] = deg_to_rad(torso)
	var ws: float = lin.call(11)
	if absf(rig.world_scale - ws) > 1e-4:
		set_world_scale(ws)
	set_head(Vector3(0, EYE, 0), float(ang.call(9)) + room_deg + head_add.x, float(lin.call(10)) + head_add.y)
	# GameLoop's target and threat, where they were from the eye.
	var birds: Dictionary = state.get_or_add("birds", {})
	var eye := cam.global_position
	for col: int in [13, 17]:
		var id := int(a[col])
		if id < 0:
			continue
		if not birds.has(id):
			var nb := Bird.new()
			nb.name = "Recorded%d" % id
			host.add_child(nb)
			birds[id] = nb
		var rel := Vector3(lin.call(col + 1), lin.call(col + 2), lin.call(col + 3)) if int(b[col]) == id \
			else Vector3(float(a[col + 1]), float(a[col + 2]), float(a[col + 3]))
		(birds[id] as Node3D).global_position = eye + rel
	if int(a[13]) != int(state.get("target", -2)):
		state["target"] = int(a[13])
		Events.target_changed.emit(birds.get(int(a[13])) if int(a[13]) >= 0 else null)
	var lv := float(a[21])
	var last := float(state.get("level", -1.0))
	if int(a[17]) != int(state.get("threat", -2)) or absf(lv - last) >= 0.02 or (lv == 0.0 and last > 0.0):
		state["threat"] = int(a[17])
		state["level"] = lv
		Events.threat_changed.emit(lv, birds.get(int(a[17])) if int(a[17]) >= 0 else null)
	return {"velocity": v, "torso_deg": torso}


## Un-name the replay's birds and free them.
func end_game_replay(state: Dictionary) -> void:
	Events.target_changed.emit(null)
	Events.threat_changed.emit(0.0, null)
	for nb: Node in (state.get("birds", {}) as Dictionary).values():
		nb.queue_free()


## Head pose in rig space: position (unscaled metres, like a tracker) and yaw.
func set_head(pos_m: Vector3, yaw_deg: float, pitch_deg: float = 0.0) -> void:
	var b := Basis(Vector3.UP, deg_to_rad(yaw_deg)) * Basis(Vector3.RIGHT, deg_to_rad(pitch_deg))
	# XR nodes apply world_scale to tracked positions; so do we.
	cam.transform = Transform3D(b, pos_m * rig.world_scale)


func set_world_scale(ws: float) -> void:
	var local := cam.transform.origin / rig.world_scale
	rig.world_scale = ws
	cam.transform.origin = local * ws


## Hands at the hips, pointing at the floor: aiming at nothing.
func park_hands() -> void:
	var ws := rig.world_scale
	var down := Basis.looking_at(Vector3.DOWN, Vector3.FORWARD)
	left.aim = rig.global_transform * Transform3D(down, Vector3(-0.25, 1.0, -0.2) * ws)
	right.aim = rig.global_transform * Transform3D(down, Vector3(0.25, 1.0, -0.2) * ws)


## Aim a source from its hand position at a world point.
func aim(src: UIPointerSource, at: Vector3) -> void:
	var ws := rig.world_scale
	var hand := Vector3(0.22 if src == right else -0.22, 1.25, -0.25) * ws
	src.aim_at(rig.global_transform * hand, at)


func aim_at_control(src: UIPointerSource, c: Control) -> void:
	aim(src, ui.menu_panel.control_to_world(c))


## A full trigger pull over real frames (the pointer polls in _process).
## Like a player, it waits until the screen has been up long enough for a
## pull to count (UIPointer.SCREEN_GRACE_S).
func click(host_node: Node, src: UIPointerSource) -> void:
	var tree := host_node.get_tree()
	await tree.process_frame
	await wait_clickable(host_node)
	src.trigger_value = 1.0
	await tree.process_frame
	await tree.process_frame
	src.trigger_value = 0.0
	await tree.process_frame
	await tree.process_frame


## Logic tests: every HoldButton needs only 0.25 s (one pointer test pins
## the real HoldButton.HOLD_S).
func fast_holds() -> void:
	for b in ui.find_children("*", "HoldButton", true, false):
		(b as HoldButton).hold_seconds = 0.25


## Aim at `c` and hold the trigger for `seconds` of real time (default: the
## button's hold time plus a margin).
func hold_control(host_node: Node, c: Control, seconds: float = -1.0, src: UIPointerSource = null) -> void:
	if seconds < 0.0:
		seconds = ((c as HoldButton).hold_seconds if c is HoldButton else HoldButton.HOLD_S) + 0.15
	if src == null:
		src = right
	aim_at_control(src, c)
	var tree := host_node.get_tree()
	await tree.process_frame
	await wait_clickable(host_node)
	src.trigger_value = 1.0
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(seconds * 1000.0):
		await tree.process_frame
	src.trigger_value = 0.0
	await tree.process_frame
	await tree.process_frame


func click_control(host_node: Node, c: Control, src: UIPointerSource = null) -> void:
	if src == null:
		src = right
	aim_at_control(src, c)
	await click(host_node, src)


## Wait (real time, at most ~0.5 s) until the pointer would take a click.
func wait_clickable(host_node: Node) -> void:
	var t0 := Time.get_ticks_msec()
	while not ui.pointer.accepting_clicks() and Time.get_ticks_msec() - t0 < 500:
		await host_node.get_tree().process_frame


## Let containers lay out and the panel settle.
func settle(host_node: Node, frames: int = 4) -> void:
	for i in frames:
		await host_node.get_tree().process_frame


func _snapshot_settings() -> void:
	for k in Settings.DEFAULTS:
		_settings_snapshot[k] = Settings.get_value(k)


## Put back the settings this kit found (Settings saves them to the
## sandbox's own user://settings.cfg).
func _restore_settings() -> void:
	for k in _settings_snapshot:
		if Settings.get_value(k) != _settings_snapshot[k]:
			Settings.set_value(k, _settings_snapshot[k])
