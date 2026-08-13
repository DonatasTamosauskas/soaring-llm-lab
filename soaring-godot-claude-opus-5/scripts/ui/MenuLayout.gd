class_name MenuLayout
extends RefCounted

## Where a menu's rows are, and which one a controller is pointing at.
##
## Pure geometry with no scene in it, for the same reason [FlightModel] has no
## scene in it: "can a player actually hit this row from a metre and a half away
## with a hand that wobbles" is a question with a numeric answer, and answering
## it in a test is much cheaper than answering it by putting a headset on.
##
## Panel space is the panel's own local frame: +X right, +Y up, the panel lying
## in the XY plane facing +Z, origin at its centre.

## How far in front of the player a panel sits. Inside arm's reach reads as
## aggressive and forces the eyes to converge hard; past about two and a half
## metres the text has to grow until the panel fills the view.
const DISTANCE: float = 1.55
## How far below eye level the panel's centre sits. A resting gaze is a few
## degrees down, not level, so a panel centred exactly on the eyes is one the
## player has to lift their chin to read the top of.
const EYE_DROP: float = 0.10

const PANEL_WIDTH: float = 1.02
## Row height is the pointing target, and it is the number that decides whether
## this menu is usable: at [constant DISTANCE] it subtends 3.4 degrees, against
## the roughly half a degree a hand-held ray wobbles by. Any larger and the
## comfort screen stops being a panel and becomes a wall.
##
## It was 0.100 with a 0.010 gap until the comfort screen grew a ninth row (the
## view-turning option), which took the panel past the 45 degrees [UITests]
## allows. Shrinking the target is the cheaper of the two ways out — the other
## was pushing the whole panel further away, which costs focal comfort on every
## screen to fix one — and 3.4 degrees is still nearly seven times the wobble.
const ROW_HEIGHT: float = 0.092
const ROW_GAP: float = 0.008
const MARGIN: float = 0.045
const TITLE_HEIGHT: float = 0.150
## Height reserved per line of non-interactive body text (the summary's numbers,
## the controls table).
const BODY_LINE: float = 0.066
const BODY_GAP: float = 0.030

## Inset of a row's text from the panel edge, in metres.
const TEXT_INSET: float = 0.075
## Where a setting's value sits, as a fraction of the half-width. Values are
## right-aligned in their own column so the numbers form a readable stack rather
## than floating wherever the label happens to end.
const VALUE_COLUMN: float = 0.94
## The level of a numeric setting, drawn as a thin rule along the bottom of its
## row. It started life as a short bar beside the number and collided with it at
## every value; an underline has nothing to collide with and reads faster.
const BAR_SIZE := Vector2(0.62, 0.012)
const BAR_CENTRE_X: float = -0.12
const BAR_DROP: float = 0.042

## Column separator in a body line: everything before it is left-aligned,
## everything after is right-aligned. Padding a line with spaces to make columns
## only works in a monospaced font, and the headset picks the font.
const COLUMN_SEPARATOR: String = "|"


## Total panel size for a screen with [param rows] selectable rows, an optional
## title, and [param body_lines] lines of plain text between them.
static func panel_size(rows: int, has_title: bool, body_lines: int = 0) -> Vector2:
	var count: int = maxi(rows, 0)
	var height: float = MARGIN * 2.0
	if has_title:
		height += TITLE_HEIGHT
	if body_lines > 0:
		height += float(body_lines) * BODY_LINE + BODY_GAP
	if count > 0:
		height += float(count) * ROW_HEIGHT + float(maxi(count - 1, 0)) * ROW_GAP
	return Vector2(PANEL_WIDTH, maxf(height, ROW_HEIGHT + MARGIN * 2.0))


## Y of the centre of row [param index], in panel space. Rows stack downward
## from under the title.
static func row_centre(index: int, rows: int, has_title: bool, body_lines: int = 0) -> float:
	var size: Vector2 = panel_size(rows, has_title, body_lines)
	var top: float = size.y * 0.5 - MARGIN
	if has_title:
		top -= TITLE_HEIGHT
	if body_lines > 0:
		top -= float(body_lines) * BODY_LINE + BODY_GAP
	return top - ROW_HEIGHT * 0.5 - float(index) * (ROW_HEIGHT + ROW_GAP)


static func title_centre(rows: int, has_title: bool, body_lines: int = 0) -> float:
	var size: Vector2 = panel_size(rows, has_title, body_lines)
	return size.y * 0.5 - MARGIN - TITLE_HEIGHT * 0.5


static func body_centre(line: int, rows: int, has_title: bool, body_lines: int) -> float:
	var size: Vector2 = panel_size(rows, has_title, body_lines)
	var top: float = size.y * 0.5 - MARGIN
	if has_title:
		top -= TITLE_HEIGHT
	return top - BODY_LINE * 0.5 - float(line) * BODY_LINE


## Which row a point in panel space falls in, or -1 for none. The gap between
## rows is deliberately live: a ray that lands in the two-millimetre crack
## between two buttons should pick the nearer one rather than nothing, because
## "my pointer is on it and it did not light up" reads as broken hardware.
static func row_at(local: Vector2, rows: int, has_title: bool, body_lines: int = 0) -> int:
	if rows <= 0 or not local.is_finite():
		return -1
	var size: Vector2 = panel_size(rows, has_title, body_lines)
	if absf(local.x) > size.x * 0.5 or absf(local.y) > size.y * 0.5:
		return -1
	var pitch: float = ROW_HEIGHT + ROW_GAP
	var first: float = row_centre(0, rows, has_title, body_lines)
	var index: int = int(round((first - local.y) / pitch))
	if index < 0 or index >= rows:
		return -1
	# Reject a point that is inside the panel but above the first row or below
	# the last — the title is not a button.
	var centre: float = row_centre(index, rows, has_title, body_lines)
	if absf(local.y - centre) > (ROW_HEIGHT + ROW_GAP) * 0.5:
		return -1
	return index


## Where a ray meets a panel. Returns
## [code]{hit: bool, local: Vector2, distance: float}[/code].
##
## Hostile input is rejected here rather than deeper in, the same boundary rule
## the flight core follows: a controller that loses tracking mid-frame hands you
## a basis full of NaN, and a menu is exactly where a player would be when they
## set a controller down.
static func ray_panel(
	origin: Vector3, direction: Vector3, panel: Transform3D
) -> Dictionary:
	var miss: Dictionary = {"hit": false, "local": Vector2.ZERO, "distance": 0.0}
	if not origin.is_finite() or not direction.is_finite():
		return miss
	if direction.length_squared() < 1e-8:
		return miss
	var normal: Vector3 = panel.basis.z.normalized()
	var ray: Vector3 = direction.normalized()
	var denominator: float = ray.dot(normal)
	if absf(denominator) < 1e-5:
		return miss
	var distance: float = (panel.origin - origin).dot(normal) / denominator
	if distance <= 0.0 or not is_finite(distance):
		return miss
	var point: Vector3 = origin + ray * distance
	var local: Vector3 = panel.affine_inverse() * point
	if not local.is_finite():
		return miss
	return {"hit": true, "local": Vector2(local.x, local.y), "distance": distance}


## The panel's pose: [param distance] metres in front of [param head], levelled
## and facing back at it.
##
## Levelled rather than aligned to the head, because a panel that copies the
## player's head pitch and roll is a panel that moves when you look at it, and
## because this game leaves the player banked more often than not. A player who
## opens the menu in a 60-degree turn should not have to read it sideways.
static func place(head: Transform3D, distance: float = DISTANCE) -> Transform3D:
	if not head.is_finite():
		return Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -distance))
	var forward: Vector3 = -head.basis.z
	forward.y = 0.0
	if forward.length_squared() < 1e-4:
		# Looking straight up or straight down: fall back to the head's own up
		# axis flattened, which is where the body is pointing.
		forward = Vector3(head.basis.y.x, 0.0, head.basis.y.z)
	if forward.length_squared() < 1e-4:
		forward = Vector3.FORWARD
	forward = forward.normalized()
	var origin: Vector3 = head.origin + forward * distance + Vector3.DOWN * EYE_DROP
	# The panel faces the player, so its +Z points back along the view.
	# looking_at points -Z along the target, and the readable face of a quad is
	# +Z, so aiming -Z away from the player is what turns the panel around to
	# face them.
	return Transform3D(Basis.looking_at(forward, Vector3.UP), origin)


## How far off the panel the player is looking, in radians. Used to decide when
## a body-locked panel has been ignored long enough to be worth moving.
static func off_axis(head: Transform3D, panel_origin: Vector3) -> float:
	if not head.is_finite() or not panel_origin.is_finite():
		return 0.0
	var to_panel: Vector3 = panel_origin - head.origin
	to_panel.y = 0.0
	var forward: Vector3 = -head.basis.z
	forward.y = 0.0
	if to_panel.length_squared() < 1e-6 or forward.length_squared() < 1e-6:
		return 0.0
	return absf(to_panel.normalized().signed_angle_to(forward.normalized(), Vector3.UP))
