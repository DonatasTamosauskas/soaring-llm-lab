class_name MenuPanel
extends Node3D

## Draws whatever a [MenuModel] currently says, as flat quads and world-space
## text standing in the air in front of the player.
##
## World-space and never head-locked. A full-screen panel bolted to the face is
## the single most reliable way to make somebody ill in VR: it cannot be looked
## away from, it moves with every head twitch, and it fights the vestibular
## system for the whole time it is up. A panel that is simply an object in the
## world can be looked at, looked away from, and leaned around, which is also
## the only reason a menu in a flight game can be legible at all.
##
## Rebuilt wholesale on every screen change rather than diffed: a menu changes
## about once a second at its very busiest, and a rebuild that cannot get out of
## step with the model is worth far more here than a few saved allocations.

const BACKING_PRIORITY: int = 14
const EDGE_PRIORITY: int = 13
const HIGHLIGHT_PRIORITY: int = 15
const BAR_PRIORITY: int = 16

## How far the edge quad sticks out past the body, in metres.
const EDGE_INSET: float = 0.014
## Panel elements are stacked along +Z by this much so the depth-test-disabled
## quads never z-fight with each other.
const LAYER_STEP: float = 0.002

var rows: int = 0
var has_title: bool = true
var body_lines: int = 0

var _backing: MeshInstance3D
var _highlight: MeshInstance3D
var _content: Node3D
var _hovered: int = -1


func _ready() -> void:
	if _content != null:
		return
	_content = Node3D.new()
	_content.name = "Content"
	add_child(_content)


## Rebuilds from [param model]. Returns the panel's size in metres.
func rebuild(model: MenuModel) -> Vector2:
	if _content == null:
		_ready()
	for child: Node in _content.get_children():
		_content.remove_child(child)
		child.queue_free()

	var entries: Array[Dictionary] = model.rows()
	var text: PackedStringArray = model.body()
	rows = entries.size()
	has_title = model.has_title()
	body_lines = text.size()
	var size: Vector2 = MenuLayout.panel_size(rows, has_title, body_lines)

	_build_backing(size)
	_build_title(model.title(), size)
	_build_body(text)
	_build_rows(entries)
	_hovered = -1
	set_hovered(model.hovered)
	return size


func _build_backing(size: Vector2) -> void:
	var edge: MeshInstance3D = UITheme.quad(
		size + Vector2(EDGE_INSET, EDGE_INSET) * 2.0, "panel_edge", EDGE_PRIORITY
	)
	edge.position = Vector3(0.0, 0.0, -LAYER_STEP)
	_content.add_child(edge)

	_backing = UITheme.quad(size, "panel", BACKING_PRIORITY)
	_content.add_child(_backing)

	_highlight = UITheme.quad(
		Vector2(size.x - MenuLayout.MARGIN, MenuLayout.ROW_HEIGHT),
		"highlight", HIGHLIGHT_PRIORITY
	)
	_highlight.position = Vector3(0.0, 0.0, LAYER_STEP)
	_highlight.visible = false
	_content.add_child(_highlight)


func _build_title(text: String, size: Vector2) -> void:
	if not has_title:
		return
	var label: Label3D = UITheme.label(UITheme.TEXT_TITLE, text, "text_accent")
	label.position = Vector3(
		0.0, MenuLayout.title_centre(rows, has_title, body_lines), LAYER_STEP * 2.0
	)
	_content.add_child(label)

	# A hairline under the title, so the eye finds the list without reading it.
	var rule: MeshInstance3D = UITheme.quad(
		Vector2(size.x - MenuLayout.MARGIN * 2.0, 0.004), "panel_edge", BAR_PRIORITY
	)
	rule.position = Vector3(
		0.0,
		MenuLayout.title_centre(rows, has_title, body_lines) - MenuLayout.TITLE_HEIGHT * 0.42,
		LAYER_STEP * 2.0
	)
	_content.add_child(rule)


## A body line is either one centred string or two columns split by
## [constant MenuLayout.COLUMN_SEPARATOR] — a gesture and what it does — because
## padding a line with spaces to make columns only lines up in a monospaced
## font, and the headset chooses the font.
func _build_body(lines: PackedStringArray) -> void:
	var size: Vector2 = MenuLayout.panel_size(rows, has_title, body_lines)
	for i in lines.size():
		var y: float = MenuLayout.body_centre(i, rows, has_title, body_lines)
		var line: String = lines[i]
		if not line.contains(MenuLayout.COLUMN_SEPARATOR):
			var centred: Label3D = UITheme.label(UITheme.TEXT_BODY, line, "text_dim")
			centred.position = Vector3(0.0, y, LAYER_STEP * 2.0)
			_content.add_child(centred)
			continue
		var columns: PackedStringArray = line.split(MenuLayout.COLUMN_SEPARATOR)
		var left: Label3D = UITheme.label(
			UITheme.TEXT_BODY, columns[0], "text", HORIZONTAL_ALIGNMENT_LEFT
		)
		left.position = Vector3(-size.x * 0.5 + MenuLayout.TEXT_INSET, y, LAYER_STEP * 2.0)
		_content.add_child(left)
		var right: Label3D = UITheme.label(
			UITheme.TEXT_BODY, columns[1], "text_accent", HORIZONTAL_ALIGNMENT_RIGHT
		)
		right.position = Vector3(
			size.x * 0.5 * MenuLayout.VALUE_COLUMN, y, LAYER_STEP * 2.0
		)
		_content.add_child(right)


func _build_rows(entries: Array[Dictionary]) -> void:
	var size: Vector2 = MenuLayout.panel_size(rows, has_title, body_lines)
	for i in entries.size():
		var entry: Dictionary = entries[i]
		var y: float = MenuLayout.row_centre(i, rows, has_title, body_lines)
		var is_setting: bool = int(entry["kind"]) == MenuModel.Kind.SETTING
		var label: Label3D = UITheme.label(
			UITheme.TEXT_ROW, String(entry["label"]), "text",
			HORIZONTAL_ALIGNMENT_LEFT if is_setting else HORIZONTAL_ALIGNMENT_CENTER
		)
		label.position = Vector3(
			-size.x * 0.5 + MenuLayout.TEXT_INSET if is_setting else 0.0,
			y, LAYER_STEP * 2.0
		)
		_content.add_child(label)
		if not is_setting:
			continue

		var value: Label3D = UITheme.label(
			UITheme.TEXT_ROW, String(entry["value"]), "text_accent",
			HORIZONTAL_ALIGNMENT_RIGHT
		)
		value.position = Vector3(
			size.x * 0.5 * MenuLayout.VALUE_COLUMN, y, LAYER_STEP * 2.0
		)
		_content.add_child(value)

		var fill: float = float(entry["fill"])
		if fill >= 0.0:
			_build_bar(fill, Vector3(
				MenuLayout.BAR_CENTRE_X, y - MenuLayout.BAR_DROP, LAYER_STEP * 2.0
			))


## A setting's value as a bar as well as a number. The number is the truth; the
## bar is what tells you at a glance that you are near the top of the range,
## which is the question a comfort slider is actually asking.
func _build_bar(fill: float, at: Vector3) -> void:
	var back: MeshInstance3D = UITheme.quad(MenuLayout.BAR_SIZE, "bar_back", BAR_PRIORITY)
	back.position = at
	_content.add_child(back)

	var front: MeshInstance3D = UITheme.quad(MenuLayout.BAR_SIZE, "bar_fill", BAR_PRIORITY + 1)
	var amount: float = clampf(fill, 0.0, 1.0)
	# Scaled about the left edge so the bar fills instead of growing outwards.
	front.scale = Vector3(maxf(amount, 0.0001), 1.0, 1.0)
	front.position = at + Vector3(
		-MenuLayout.BAR_SIZE.x * 0.5 * (1.0 - amount), 0.0, LAYER_STEP * 0.5
	)
	_content.add_child(front)


func set_hovered(row: int) -> void:
	_hovered = row if row >= 0 and row < rows else -1
	if _highlight == null:
		return
	_highlight.visible = _hovered >= 0
	if _hovered >= 0:
		_highlight.position = Vector3(
			0.0, MenuLayout.row_centre(_hovered, rows, has_title, body_lines), LAYER_STEP
		)


## Which row a ray hits, and where. See [method MenuLayout.ray_panel].
func probe(origin: Vector3, direction: Vector3) -> Dictionary:
	var hit: Dictionary = MenuLayout.ray_panel(origin, direction, global_transform)
	hit["row"] = -1
	if bool(hit["hit"]):
		hit["row"] = MenuLayout.row_at(hit["local"] as Vector2, rows, has_title, body_lines)
	return hit
