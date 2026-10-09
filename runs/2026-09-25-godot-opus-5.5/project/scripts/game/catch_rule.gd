class_name CatchRule
extends RefCounted
## The geometry of a catch: who is close enough, and pointed the right way.
##
## Pure maths on positions, so tests can pin every boundary without a scene.
## GameLoop owns *when* this runs (every physics frame, every candidate pair
## its broad phase finds: CatchSweep, or the CatchGrid spatial hash) and what
## happens after (growth, death, events).
##
## A catch needs, during the frame:
##  * the predator to be at least SizeRules.EAT_RATIO times heavier (GameLoop
##    checks it on the frame's snapshot to find candidates, and again with
##    the masses of the moment when it applies each catch in contact order),
##  * the bodies to come within contact_distance(): both body radii plus a
##    reach margin (beak/talons) proportional to the predator's wingspan,
##  * the prey to be inside the predator's forward aim cone at that moment
##    (so a predator must actually chase: brushing past a bird's back does not
##    kill it), unless the bodies overlap deeply,
##  * neither bird to be in cover (is_hidden: an NpcBird sitting in a refuge
##    is out of play until it comes out), and the prey not inside a refuge
##    too small for the predator (in_refuge / RefugeIndex).
## Contact is swept over the frame (relative motion is linear within one
## step), so a hawk stooping at 40 m/s cannot tunnel through a sparrow
## between two physics frames, and the first moment the prey is both within
## reach and inside the cone is solved exactly (contact_time).
##
## The player gets VR forgiveness: a longer reach and a wider cone that is
## tested around both the body heading and the velocity. In a headset nobody
## can judge a bird's depth to a few centimetres, and the body heading
## (from arm geometry) wobbles with every flap; missing a bird that visibly
## passed "through your face" feels like a bug, not like skill.

## Reach margin beyond touching bodies, as a fraction of the predator's wingspan.
var npc_reach := 0.25
## The player's reach at sparrow scale (SizeRules.time_scale 1)...
var player_reach := 2.0
## ...shrinking with the square root of body time as the player grows:
## reach_spans = player_reach * time_scale^-player_reach_exp (2.0 spans for a
## sparrow, 1.46 for a pigeon, 1.0 for an eagle). A small bird lives fast:
## in the headset (world_scale follows wingspan) a sparrow's world rushes
## past at ~60 felt m/s, an eagle's at ~16, so the same felt reach is a
## shorter moment of contact for the sparrow. But a big bird's worthwhile
## prey is relatively smaller and nimbler than a small bird's (a pigeon
## turns in 0.4 of an eagle's radius, a wren in 0.67 of a sparrow's) and
## slips past a heavy chaser: in the shipped valley a hawk or an eagle
## caught 2-7% of its chases with reach ~ 1 / body time (round 2), a
## sparrow 29%. The square root splits the two (the contact window grows
## x2 from sparrow to eagle, the felt reach halves): an eagle's chases then
## succeed ~19% of the time (fix round 3, docs/areas/GAMELOOP.md).
var player_reach_exp := 0.5
## The player's SizeRules.time_scale (GameLoop sets it every step).
var player_time_scale := 1.0
## Half-angle (degrees) of the forward aim cone.
var npc_cone_deg := 55.0
## VR forgiveness for the player as prey: an NPC's strike on the player must
## really connect - a smaller reach margin (fraction of the predator's
## wingspan) than NPC-on-NPC strikes, and a cone no wider. A person cannot
## dodge with a bird's reflexes (reaction ~0.2 s, arm-limited turns, no
## sense of what is behind), and being taken by talons that visibly missed
## reads as a bug. Tuned with the integrated simulation against the AI's
## hunters (docs/areas/GAMELOOP.md, "Danger"). The cone was 40 deg until fix
## round 5: since integration round 2 the AI's attacks on the player are
## committed passes (the last 0.4 s holds its line and turns at most 0.8 of
## its rate, so a well-timed break makes the hunter overshoot) and the
## threat cue names an attack the frame it starts; with both, a strike on a
## competent modelled player connected ~1 time in 10 close attacks and only
## 23-30% of runs were ever caught (the brief's "being eaten happens" is
## pinned at >= 40%). The committed pass is the forgiveness now.
var npc_reach_on_player := 0.15
var npc_cone_on_player_deg := 55.0
## ...and bodies merely overlapping (a hunter's sideways lunge landing on
## the player) do not count on their own: the player must be inside the
## strike cone.
var overlap_on_player := false
## GameLoop's danger assist 0..1: narrows the strike cone on the player by
## GameLoop.DANGER_ASSIST_CONE_DEG at 1.
var player_danger_assist := 0.0
## ...by this many degrees at full danger assist (GameLoop sets it).
var danger_assist_cone_deg := GameLoop.DANGER_ASSIST_CONE_DEG
var player_cone_deg := 80.0
## Catch assist 0..1 for the player (GameLoop sets it from how long the
## player has gone without a catch): at 1 the player's reach is
## ASSIST_REACH larger and the cone ASSIST_CONE_DEG wider - but never wider
## than PLAYER_CONE_MAX_DEG: the brief says prey *in front*, and a cone past
## 90 deg would take birds behind the wing line (fix round 2 review). The
## assist buys reach instead (+125% at full assist; the cone's +10 deg).
var player_assist := 0.0
const ASSIST_REACH := 1.25
const ASSIST_CONE_DEG := 10.0
const PLAYER_CONE_MAX_DEG := 90.0
## However much assist, the player's catch never reaches further than this
## many of its wingspans, centre to centre: 2.9 x 1.7 = 4.9 felt metres in
## the headset (WorldScaleDriver: world_scale = wingspan / 1.7 m), under
## three arm spans. Round 2's full assist let a sparrow take prey 8 felt m
## away - a "magnet", a feather burst far from the beak (fix round 3
## review). A sparrow's own reach is 2.3 spans, so for small birds the
## assist is mostly the wider cone; for big ones its reach.
const PLAYER_CONTACT_MAX_SPANS := 2.9
## Felt metres per wingspan in the headset (the VR area's WorldScaleDriver:
## arm span 1.5 m + 0.2). A copy for tests and docs; nothing depends on it.
const FELT_M_PER_SPAN := 1.7
## Centre distances below this fraction of the summed body radii count as a
## catch whatever the heading: the bodies are inside each other.
var overlap_fraction := 0.6
## Seconds after a catch before the same bird can catch again (handling the
## prey). Stops a hawk diving through a flock and eating five at once.
var npc_handling_s := 1.2
var player_handling_s := 0.2


## Whether prey at `prey_pos` is inside a refuge (World.get_refuges():
## {position, radius, max_span}) too small for a predator of `pred_span`.
## Birds that dive into a hedge are safe from anything wider than the hedge
## lets through. A linear scan: the reference RefugeIndex.blocks() (what the
## loop and the cue use every frame) is tested against.
static func in_refuge(prey_pos: Vector3, pred_span: float, refuges: Array[Dictionary]) -> bool:
	for r in refuges:
		if pred_span > float(r.get("max_span", INF)):
			var rad := float(r.get("radius", 0.0))
			if prey_pos.distance_squared_to(r.get("position", Vector3.INF)) <= rad * rad:
				return true
	return false


## Whether a bird is in cover: an NpcBird that has hidden in a refuge
## (`hidden`, duck-typed; birds without the property never are). A bird in
## cover is out of play until it comes out: it can neither be caught nor
## catch, is never a threat and never the target cue. The AI's hunters never
## start a hunt on a hidden bird either, and its hiding is short (a breather
## of a few seconds, 20 s at most) - so cover really protects, and a predator
## waits for the bird to bolt. Before (fix round 2 review) any bird that
## fitted the refuge could take a sitting bird out of it, and in the valley
## two thirds of a modelled player's catches were birds sitting in house
## rooms and nest boxes: hiding had become a larder.
static func is_hidden(b: Object) -> bool:
	var h: Variant = b.get(&"hidden")
	return h is bool and h


func reach_margin(pred_span: float, pred_is_player: bool, prey_is_player: bool = false) -> float:
	if pred_is_player:
		return pred_span * player_reach_spans()
	if prey_is_player:
		return pred_span * npc_reach_on_player * (1.0 - GameLoop.DANGER_ASSIST_REACH_LOSS * player_danger_assist)
	return pred_span * npc_reach


## The widest reach margin any NPC strike can have (broad phase bound).
func npc_reach_max() -> float:
	return maxf(npc_reach, npc_reach_on_player)


## The player's current reach margin in wingspans (size and assist applied).
func player_reach_spans() -> float:
	return player_reach * pow(maxf(player_time_scale, 1.0), -player_reach_exp) * (1.0 + ASSIST_REACH * player_assist)


## Centre-to-centre distance at which a predator touches its prey.
func contact_distance(pred_radius: float, pred_span: float, pred_is_player: bool, prey_radius: float,
		prey_is_player: bool = false) -> float:
	var c := pred_radius + prey_radius + reach_margin(pred_span, pred_is_player, prey_is_player)
	return minf(c, PLAYER_CONTACT_MAX_SPANS * pred_span) if pred_is_player else c


func cone_cos(pred_is_player: bool, prey_is_player: bool = false) -> float:
	if pred_is_player:
		return cos(deg_to_rad(minf(player_cone_deg + ASSIST_CONE_DEG * player_assist, PLAYER_CONE_MAX_DEG)))
	if prey_is_player:
		return cos(deg_to_rad(maxf(npc_cone_on_player_deg - danger_assist_cone_deg * player_danger_assist, 5.0)))
	return cos(deg_to_rad(npc_cone_deg))


func handling_s(pred_is_player: bool) -> float:
	return player_handling_s if pred_is_player else npc_handling_s


## Swept contact test for one predator/prey pair over one frame.
##
## pred0/pred1 and prey0/prey1 are body positions at the start and end of the
## frame. fwd is the predator's unit forward; vel_dir its unit velocity (or
## zero). Returns the earliest fraction of the frame (0..1) at which the prey
## is within `contact` of the predator AND inside its aim cone (or within
## `overlap`, bodies inside each other), or -1.0.
##
## Exact, not sampled: with the relative position d(t) = d0 + dv t linear in
## the frame, "within reach" (|d|^2 <= contact^2), "overlapping" and "inside
## a cone of half-angle a around f" (f.d >= 0 and (f.d)^2 >= cos^2(a) |d|^2,
## for a <= 90 deg) are each a quadratic or linear inequality in t. Every
## change of truth happens at one of their roots, so testing each root and
## each gap between consecutive roots finds the first moment all hold. (The
## first version tested only entry, closest approach and exit: in 120 crowded
## scenes it missed one contact and mis-ordered three chains - fix round 2
## review.)
func contact_time(pred0: Vector3, pred1: Vector3, prey0: Vector3, prey1: Vector3,
		contact: float, overlap: float, fwd: Vector3, vel_dir: Vector3, pred_is_player: bool,
		prey_is_player: bool = false) -> float:
	var d0 := prey0 - pred0
	var dv := (prey1 - prey0) - (pred1 - pred0)
	var a := dv.length_squared()
	var c2 := contact * contact
	var cc := d0.length_squared() - c2
	var t_in := 0.0
	var t_out := 1.0
	if a < 1e-12:
		# No relative motion: in contact for the whole frame or not at all.
		if cc > 0.0:
			return -1.0
	else:
		var hb := d0.dot(dv)
		var disc := hb * hb - a * cc
		if disc < 0.0:
			return -1.0
		var sq := sqrt(disc)
		t_in = (-hb - sq) / a
		t_out = (-hb + sq) / a
		if t_out < 0.0 or t_in > 1.0:
			return -1.0
		t_in = maxf(t_in, 0.0)
		t_out = minf(t_out, 1.0)
	# The distance is convex in t, so the prey is within reach on [t_in, t_out];
	# find the first moment in it that it is also aimed at (or overlapping).
	var cos_cone := maxf(cone_cos(pred_is_player, prey_is_player), 0.0)
	var ov := -1.0 if prey_is_player and not overlap_on_player else overlap
	var use_vel := pred_is_player and vel_dir != Vector3.ZERO
	# Breakpoints: the ends and every root inside (t_in, t_out).
	var ts := PackedFloat64Array([t_in, t_out])
	var hb2 := d0.dot(dv)
	if ov > 0.0:
		_roots(a, 2.0 * hb2, d0.length_squared() - ov * ov, t_in, t_out, ts)
	for f: Vector3 in ([fwd, vel_dir] if use_vel else [fwd]):
		var u0 := f.dot(d0)
		var u1 := f.dot(dv)
		var k := cos_cone * cos_cone
		_roots(u1 * u1 - k * a, 2.0 * (u0 * u1 - k * hb2), u0 * u0 - k * d0.length_squared(), t_in, t_out, ts)
		if absf(u1) > 1e-12:
			var tz := -u0 / u1
			if tz > t_in and tz < t_out:
				ts.append(tz)
	ts.sort()
	# Truth only changes at a breakpoint: test each one, and each gap between
	# two (at its midpoint; the gap then starts at the earlier breakpoint).
	for i in ts.size():
		var t := ts[i]
		if _aimed(d0 + dv * t, ov, fwd, vel_dir, cos_cone, use_vel):
			return t
		if i + 1 < ts.size() and ts[i + 1] > t:
			if _aimed(d0 + dv * ((t + ts[i + 1]) * 0.5), ov, fwd, vel_dir, cos_cone, use_vel):
				return t
	return -1.0


## Roots of q2 t^2 + q1 t + q0 = 0 strictly inside (lo, hi), appended to out.
static func _roots(q2: float, q1: float, q0: float, lo: float, hi: float, out: PackedFloat64Array) -> void:
	var rs: Array[float] = []
	if absf(q2) < 1e-12:
		if absf(q1) > 1e-12:
			rs.append(-q0 / q1)
	else:
		var disc := q1 * q1 - 4.0 * q2 * q0
		if disc >= 0.0:
			var sq := sqrt(disc)
			rs.append((-q1 - sq) / (2.0 * q2))
			rs.append((-q1 + sq) / (2.0 * q2))
	for r in rs:
		if r > lo and r < hi:
			out.append(r)


## Inside the cone (around the heading, or the velocity for the player), or
## overlapping. cos_cone >= 0 (cones are at most 90 deg).
static func _aimed(d: Vector3, overlap: float, fwd: Vector3, vel_dir: Vector3, cos_cone: float, use_vel: bool) -> bool:
	var dist := d.length()
	if dist <= overlap:
		return true
	# Forgiveness: the player's body heading lags their actual flight path
	# during hard manoeuvres; prey ahead of the velocity counts too.
	var lim := cos_cone * dist - 1e-9
	return fwd.dot(d) >= lim or (use_vel and vel_dir.dot(d) >= lim)
