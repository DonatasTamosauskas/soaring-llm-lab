class_name BirdPose
extends RefCounted
## The wing/tail/leg/head animation, on the CPU.
##
## The birds are animated in the vertex shader (scripts/birds/bird.gdshader)
## from four per-instance numbers, so 60 birds cost no CPU skinning. This
## file is the same maths line for line in GDScript: tests pose meshes with
## it (stroke timing, no inverted or intersecting wings, fold poses), FX use
## it to find wingtips, and tests/shots/birds_gpu_check renders both and
## compares their silhouettes and every drawn pixel's posed position, so the
## two can never drift apart unnoticed. Change one, change the other.
##
## Per-vertex rig data (see BirdMeshBuilder):
##   CUSTOM0 = (group, side, weight, fold_gather)
##   weight: hand = share of the hand's own rotation (0 at the wrist .. 1 at
##   the tip): the hand bends like a flexible plate instead of creasing.
##   CUSTOM1 = (pivot A xyz, param A)   shoulder | tail base | hip | neck;
##                                      wings: A.w = arm dihedral (rad)
##   UV.x (wings) = hand dihedral relative to the arm (rad). Folding
##   flattens both, so a folded wing lies along the body instead of
##   splaying out by its glide dihedral.
##   UV.y (wings) = the species' perched wing droop (rad): how far the
##   folded wing tips down behind the shoulder so the wingtips rest on top
##   of the tail (BirdSpecies anim[4]; checked by the animation suite).
##   CUSTOM2 = (pivot B xyz, param B)   wrist (hand) ; wings: B.w = fold
##                                      sweep scale; tail: B.w = how much
##                                      of its width it closes folded
##   fold_gather: how far (model units) a wing vertex slides forward towards
##   the leading edge when fully folded (the feathers stack up), most at the
##   wing root so the folded root never reaches the other wing.
##   CUSTOM3 = (flap amplitude, fold roll scale, articulation, perched pitch)
##   articulation: 1 = a bird's jointed wing (the arm retracts, sweeps and
##   twists, the folded wing droops and sits out on the flank), 0 = a
##   moth's stiff wing plates (none of that).
##   UV2 (wings) = the fold hug (dx, dy), model units: at full fold the wing
##   moves this far in towards the midline and up, so it lies on the body's
##   upper flank and back and follows its taper to the rump (baked per wing
##   station by BirdMeshBuilder, see _fold_hug). Applied as fold^3, so a
##   half-folded or flapping wing is barely moved.
## Groups: 0 body, 1 arm, 2 hand, 3 tail, 4 leg, 5 head, 6 highlight marker
## (not in the bird meshes: its own mesh, BirdModels.marker_mesh(), a ring
## for edible and a triangle for danger that the shader places around a
## highlighted bird, facing the viewer; all its vertices rest at the origin
## and BirdPose leaves them there).
## COLOR.a = the species' readable angle / BirdModels.READABLE_MAX (the
## shader's highlight tint; no effect on the pose).
## Wing vertices are posed in right-wing coordinates (x mirrored for side -1).

const G_BODY := 0
const G_ARM := 1
const G_HAND := 2
const G_TAIL := 3
const G_LEG := 4
const G_HEAD := 5
const G_MARK := 6

const DEG := PI / 180.0
## Share of the wingbeat spent in the downstroke: the power stroke is quicker
## than the recovery (the brief asks for a downstroke faster than the upstroke).
const DOWN_FRAC := 0.42
## How far (cycles) the hand lags the arm: the tip whips through each turn.
const LAG := 0.08
## Shoulder elevation at the top / bottom of the stroke.
const ELEV_UP := 50.0 * DEG
const ELEV_DOWN := 38.0 * DEG
const ELEV_C := (ELEV_UP - ELEV_DOWN) * 0.5
const ELEV_A := (ELEV_UP + ELEV_DOWN) * 0.5
## Upstroke: the wrist flexes, the arm sweeps back and shortens, the hand
## trails down and back and twists leading-edge-up (feathers open), so the
## recovery stroke has less area than the power stroke.
const UP_SWEEP := 12.0 * DEG
const UP_RETRACT := 0.3
const UP_TWIST := 10.0 * DEG
const UP_HAND_SWEEP := 30.0 * DEG
const UP_HAND_DROP := 16.0 * DEG
const UP_HAND_TWIST := 20.0 * DEG
const WHIP := 0.3
## Downstroke: leading edge down (pronation), tips bend up under load.
const DOWN_TWIST := 6.0 * DEG
const DOWN_CURL := 10.0 * DEG
## Folding (wing_fold = 1): wing swept back along the body about the root
## leading edge, arm shortened, chord gathered towards the leading edge, and
## rolled so the upper surface faces out: perched the folded wing covers the
## upper flank and back (trailing edge along the spine); in a dive (not
## perched) it rolls less, a tight teardrop.
const FOLD_SWEEP := -84.0 * DEG
const FOLD_ELEV_FLY := -55.0 * DEG
const FOLD_ELEV_PERCH := -70.0 * DEG
## The folded wing is tipped down at its back end: a little in a dive tuck,
## and perched by the species' own droop (UV.y), which lays the wingtips on
## top of the tail rather than under it.
const FOLD_DROOP_FLY := 4.0 * DEG
const FOLD_RETRACT := 0.72
const FOLD_OUT := 0.016
## Tail: bobs with the beat, spreads when flapping, closes when tucked or
## perched (by the species' close share, CUSTOM2.w of tail vertices).
const TAIL_FLAP_PITCH := 6.0 * DEG
const TAIL_FLAP_SPREAD := 0.12
## Legs: pulled back and up into the belly feathers in flight.
const LEG_TUCK_SCALE := 0.3
## Perched birds look around in short, held glances.
const HEAD_LOOK := 38.0 * DEG
## Body bob with the wingbeat (fraction of the wingspan).
const BOB := 0.014
## Mirrors the shader's head_look_amount uniform (0 freezes idle glances).
static var head_look_amount := 1.0


static func stroke(p: float) -> float:
	# +1 at the top of the upstroke, -1 at the bottom; smooth (zero velocity)
	# at both turns, DOWN_FRAC of the cycle going down.
	if p < DOWN_FRAC:
		return cos(PI * p / DOWN_FRAC)
	return -cos(PI * (p - DOWN_FRAC) / (1.0 - DOWN_FRAC))


static func upflex(p: float) -> float:
	if p < DOWN_FRAC:
		return 0.0
	return sin(PI * (p - DOWN_FRAC) / (1.0 - DOWN_FRAC))


static func downpow(p: float) -> float:
	if p < DOWN_FRAC:
		return sin(PI * p / DOWN_FRAC)
	return 0.0


static func rx(v: Vector3, a: float) -> Vector3:
	var c := cos(a)
	var s := sin(a)
	return Vector3(v.x, v.y * c - v.z * s, v.y * s + v.z * c)


static func ry(v: Vector3, a: float) -> Vector3:
	var c := cos(a)
	var s := sin(a)
	return Vector3(v.x * c + v.z * s, v.y, -v.x * s + v.z * c)


static func rz(v: Vector3, a: float) -> Vector3:
	var c := cos(a)
	var s := sin(a)
	return Vector3(v.x * c - v.y * s, v.x * s + v.y * c, v.z)


## Held glance direction (-1..1) for a perched bird's head.
static func head_look(seed: float, time: float) -> float:
	var u := time * (0.45 + 0.35 * seed) + seed * 31.0
	var k := floorf(u)
	var f := u - k
	var a0 := fposmod(k * 0.6180339887 + seed, 1.0) * 2.0 - 1.0
	var a1 := fposmod((k + 1.0) * 0.6180339887 + seed, 1.0) * 2.0 - 1.0
	return lerpf(a0, a1, smoothstep(0.0, 0.18, f))


## Poses one vertex. Returns [position, normal]. `inst` = (phase, amount,
## fold, perch) as the shader receives them; seed/time only move the head.
## body_frame = true skips the final whole-body pitch and bob (tests use it
## to compare wings against the body's own shape).
static func pose(p: Vector3, n: Vector3, c0: Vector4, c1: Vector4, c2: Vector4, c3: Vector4,
		inst: Vector4, seed: float = 0.0, time: float = 0.0, body_frame: bool = false, uv: Vector2 = Vector2.ZERO,
		uv2: Vector2 = Vector2.ZERO) -> Array:
	var phase := inst.x
	var amount := inst.y
	var fold := inst.z
	var perch := inst.w
	var group := int(roundf(c0.x))
	var amp := c3.x
	# Wingbeats fade out fast as the wings fold (birds do not beat a
	# folded wing).
	var a_eff := amount * (1.0 - fold) * (1.0 - fold)
	var s := stroke(phase)
	var sl := stroke(fposmod(phase - LAG, 1.0))
	var q := p
	var m := n
	if group == G_ARM or group == G_HAND:
		var fx := upflex(phase)
		var pw := downpow(phase)
		var retr := c3.z
		var elev := a_eff * amp * (ELEV_C + ELEV_A * s) + fold * lerpf(FOLD_ELEV_FLY, FOLD_ELEV_PERCH, perch) * c3.y
		var sweep := -a_eff * fx * UP_SWEEP * retr + fold * FOLD_SWEEP * c2.w
		var twist := a_eff * (fx * UP_TWIST - pw * DOWN_TWIST) * retr
		var span_k := 1.0 - (a_eff * fx * UP_RETRACT + fold * FOLD_RETRACT) * retr
		var mirror := c0.y < 0.0
		if mirror:
			q.x = -q.x
			m.x = -m.x
		var sh := Vector3(c1.x, c1.y, c1.z)
		# The feathers gather towards the leading edge ahead of the sweep
		# (1 - (1 - fold)^2): half folded, the trailing edge at the wrist is
		# already mostly gathered, so sweeping back cannot swing it into the
		# flank.
		q.z -= fold * (2.0 - fold) * c0.w
		var d: Vector3
		if group == G_ARM:
			d = q - sh
			d.x *= span_k
			m = Vector3(m.x / span_k, m.y, m.z).normalized()
		else:
			var wc := Vector3(c2.x, c2.y, c2.z)
			var dw := wc - sh
			dw.x *= span_k
			var hw := c0.z
			var h_elev := hw * (a_eff * amp * (ELEV_A * WHIP * (sl - s) - fx * UP_HAND_DROP) + a_eff * pw * DOWN_CURL) - fold * uv.x
			var h_sweep := -hw * a_eff * fx * UP_HAND_SWEEP
			var h_twist := hw * a_eff * fx * UP_HAND_TWIST
			d = dw + rz(ry(rx(q - wc, h_twist), h_sweep), h_elev)
			m = rz(ry(rx(m, h_twist), h_sweep), h_elev)
		# (moths, retract 0, rest their wings flat: no droop)
		var droop := fold * lerpf(FOLD_DROOP_FLY, uv.y, perch) * retr
		var flat := -fold * c1.w
		q = sh + rx(rz(ry(rx(rz(d, flat), twist), sweep), elev), droop)
		m = rx(rz(ry(rx(rz(m, flat), twist), sweep), elev), droop)
		q.x += fold * FOLD_OUT * retr
		# The hug: in onto the back and up over the rump, as fold^3 (nearly
		# all of it in the last part of the fold, where the wing already
		# lies along the body).
		var hug := fold * fold * fold
		q.x -= hug * uv2.x
		q.y += hug * uv2.y
		if mirror:
			q.x = -q.x
			m.x = -m.x
	elif group == G_TAIL:
		var t := Vector3(c1.x, c1.y, c1.z)
		# Closes on the same leading curve as the feather gather, so the tail
		# is narrow before the folding wings come alongside it.
		var tc := maxf(fold, perch)
		var spread := 1.0 + a_eff * TAIL_FLAP_SPREAD - c2.w * tc * (2.0 - tc)
		var tp := a_eff * amp * TAIL_FLAP_PITCH * sl + perch * c1.w
		var d := q - t
		d.x *= spread
		q = t + rx(d, -tp)
		m = rx(Vector3(m.x / spread, m.y, m.z).normalized(), -tp)
	elif group == G_LEG:
		var hip := Vector3(c1.x, c1.y, c1.z)
		var k := lerpf(LEG_TUCK_SCALE, 1.0, perch)
		var ang := lerpf(c1.w, -c3.w, perch)
		q = hip + rx((q - hip) * k, ang)
		m = rx(m, ang)
	elif group == G_HEAD:
		var nk := Vector3(c1.x, c1.y, c1.z)
		var look := perch * HEAD_LOOK * head_look(seed, time) * head_look_amount
		var hp := -perch * c3.w
		q = nk + rx(ry(q - nk, look), hp)
		m = rx(ry(m, look), hp)
	if body_frame:
		return [q, m.normalized()]
	# Whole body: perched birds sit nose-up; flapping bobs the body.
	var bp := perch * c3.w
	q = rx(q, bp)
	m = rx(m, bp)
	q.y -= BOB * a_eff * amp * sl
	return [q, m.normalized()]


## Poses every vertex of a mesh surface's arrays (as returned by
## Mesh.surface_get_arrays). Returns the posed positions.
static func pose_arrays(arrays: Array, inst: Vector4, seed: float = 0.0, time: float = 0.0, body_frame: bool = false) -> PackedVector3Array:
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var nn: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var c0: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
	var c1: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM1]
	var c2: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM2]
	var c3: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM3]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var uv2s := uv2_of(arrays)
	var out := PackedVector3Array()
	out.resize(v.size())
	for i in v.size():
		var j := i * 4
		var r := pose(v[i], nn[i], Vector4(c0[j], c0[j + 1], c0[j + 2], c0[j + 3]),
			Vector4(c1[j], c1[j + 1], c1[j + 2], c1[j + 3]), Vector4(c2[j], c2[j + 1], c2[j + 2], c2[j + 3]),
			Vector4(c3[j], c3[j + 1], c3[j + 2], c3[j + 3]), inst, seed, time, body_frame, uvs[i], uv2s[i])
		out[i] = r[0]
	return out


## The mesh's UV2 (the fold hug), or zeros for a mesh without one.
static func uv2_of(arrays: Array) -> PackedVector2Array:
	var u: Variant = arrays[Mesh.ARRAY_TEX_UV2]
	if u is PackedVector2Array and (u as PackedVector2Array).size() == (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size():
		return u
	var z := PackedVector2Array()
	z.resize((arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size())
	return z


## Same, returning [positions, normals].
static func pose_arrays_with_normals(arrays: Array, inst: Vector4, seed: float = 0.0, time: float = 0.0) -> Array:
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var uv2s := uv2_of(arrays)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var nn: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var c0: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
	var c1: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM1]
	var c2: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM2]
	var c3: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM3]
	var out := PackedVector3Array()
	var on := PackedVector3Array()
	out.resize(v.size())
	on.resize(v.size())
	for i in v.size():
		var j := i * 4
		var r := pose(v[i], nn[i], Vector4(c0[j], c0[j + 1], c0[j + 2], c0[j + 3]),
			Vector4(c1[j], c1[j + 1], c1[j + 2], c1[j + 3]), Vector4(c2[j], c2[j + 1], c2[j + 2], c2[j + 3]),
			Vector4(c3[j], c3[j + 1], c3[j + 2], c3[j + 3]), inst, seed, time, false, uvs[i], uv2s[i])
		out[i] = r[0]
		on[i] = r[1]
	return [out, on]
