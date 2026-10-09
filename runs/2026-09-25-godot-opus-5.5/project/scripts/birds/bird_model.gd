class_name BirdModel
extends Node3D
## A bird's look and wing animation. Owned by the birds (art) area.
##
## Authored at wingspan 1.0 m, beak towards -Z, origin at the body centre,
## so the owner sets scale = Vector3.ONE * wingspan (scaling a model is fine;
## never scale the XR rig). Drive it by setting the fields below every frame.
## BirdModels.create() is the only constructor.
##
## The model draws itself through a shared per-species MultiMesh (BirdBatch)
## with the animation in the vertex shader; it has no child nodes of its own
## (BirdFX.attach_trails adds a WingTrails child on request). Every field
## change is smoothed before it is shown (flap_amount, wing_fold, perched,
## bank, highlight), so owners may switch them abruptly without the wings
## popping; a field set to NaN or INF is ignored until it is a number again.
## A highlighted bird is drawn at its true size (far away the shader marks
## it, see below). A perched bird's feet are at y = -0.16 x span (one
## SizeRules body radius below the body centre, on the perch grip).

## 0..1 position in the wingbeat; 0 = top of the upstroke. The downstroke
## takes the first 42% of the cycle (BirdPose.DOWN_FRAC).
var flap_phase := 0.0
## 0 = gliding (wings still), 1 = full wingbeats.
var flap_amount := 0.0
## 0 = wings spread, 1 = tucked for a dive or folded while perched.
var wing_fold := 0.0
## Visual roll, radians, positive = right wing down.
var bank := 0.0
## Clinging to a perch: wings folded on the flanks, body up, legs down.
var perched := false
## Readability state set by UI/game loop: 0 none, 1 = edible, 2 = danger.
## Drawn as a marker around the bird at every distance (a ring for edible, a
## triangle for danger, in BirdModels.HIGHLIGHT_*); a bird too small for its
## plumage to be told apart is also tinted in the hue, a bigger one keeps
## its own colours (see BirdModels.min_highlight_angle).
var highlight := 0
var species: StringName = &"sparrow":
	set(value):
		if value == species and _mesh_species == value:
			return
		species = value if BirdSpecies.has(value) else &"sparrow"
		if not BirdSpecies.has(value):
			push_warning("[birds] unknown species '%s', drawing a sparrow" % value)
		_mesh_species = species
		if _batch != null:
			_reattach()

## Extra detail distance (2 = keep LOD0 twice as far). Optional.
var lod_bias := 1.0
## Force a level of detail (0..2), -1 = by distance. Optional.
var lod_override := -1
## Render layers of this bird's batch (e.g. to hide the player's own body
## from its camera). Optional.
var render_layers := 1:
	set(value):
		render_layers = value
		if _batch != null:
			_reattach()
## Optional; shadows are cheap (one extra draw per batch).
var cast_shadows := true:
	set(value):
		cast_shadows = value
		if _batch != null:
			_reattach()

## LOD thresholds, in radians of wingspan seen by the camera: LOD0 above
## ~2.9 deg (about 58 px on a Quest Pro), LOD2 below ~0.9 deg (18 px).
const LOD0_ANGLE := 0.05
const LOD1_ANGLE := 0.016
const LOD_HYSTERESIS := 0.12
## The angle (radians of wingspan, ~0.7 deg = 14 px on a Quest Pro) from
## which a highlighted bird reads by itself; slim species need more
## (BirdModels.min_highlight_angle). A highlighted bird is never drawn
## larger than it is (that would lie about its size - prey looking bigger
## than the player - and stop a chased bird looming): far away the marker
## around it (a fixed angular size) carries the state, and below this angle
## the bird itself is tinted in the hue.
const MIN_HIGHLIGHT_ANGLE := 0.012
## Smoothing time constants, seconds.
const TAU_AMOUNT := 0.12
const TAU_FOLD := 0.1
const TAU_PERCH := 0.16
const TAU_BANK := 0.08
const TAU_HIGHLIGHT := 0.1
## The drawn phase follows the owner's flap_phase. Each owner step is read
## forwards or backwards, whichever matches the beat it has been showing
## (owners beat forwards; a 50 ms hitch at 16 Hz is 0.8 of a beat, which
## would otherwise look like -0.2 and play the wings backwards). The drawn
## phase catches up at 1.6x the owner's beat over the frame's real time
## (so a steady beat of any frequency, and a hitch, are drawn exactly), and
## a jump of a still owner becomes a quick sweep of at least MIN_PHASE_STEP
## per frame rather than a pop.
const PHASE_CATCHUP := 1.6
const MIN_PHASE_STEP := 0.02

# Displayed (smoothed) state.
var _phase_s := 0.0
var _amount_s := 0.0
var _fold_s := 0.0
var _perch_s := 0.0
var _bank_s := 0.0
var _edible_s := 0.0
var _danger_s := 0.0
var _seed := 0
var _fresh := true
var _phase_prev := 0.0
## Owner's beat (cycles per second, signed) and its last step (cycles/s).
var _phase_rate := 0.0
var _phase_adv_prev := 0.0
## How far the drawn phase is behind the owner's (cycles, signed).
var _phase_lag := 0.0
var _lod := 0
var _mesh_species: StringName = &""


# Smoothing factors for this frame's dt, shared by every bird (BirdBatch
# calls prepare_frame once per sync instead of 5 exp() per bird).
static var _k_dt := -1.0
static var _k_amount := 0.0
static var _k_fold := 0.0
static var _k_perch := 0.0
static var _k_bank := 0.0
static var _k_hl := 0.0


static func prepare_frame(dt: float) -> void:
	if dt == _k_dt:
		return
	_k_dt = dt
	_k_amount = 1.0 - exp(-dt / TAU_AMOUNT)
	_k_fold = 1.0 - exp(-dt / TAU_FOLD)
	_k_perch = 1.0 - exp(-dt / TAU_PERCH)
	_k_bank = 1.0 - exp(-dt / TAU_BANK)
	_k_hl = 1.0 - exp(-dt / TAU_HIGHLIGHT)


# Batch bookkeeping (BirdBatch reads _xf/_inst after _tick).
var _batch: BirdBatch = null
var _slot := -1
var _xf := Transform3D()
var _inst := Vector4()
# Highlight marker: shown (any highlight weight in _inst), its batch, slot.
var _hl_on := false
var _mark: BirdBatch = null
var _mark_slot := -1


func _init() -> void:
	_seed = hash(get_instance_id()) & 255


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_ENTER_WORLD:
			if _batch == null:
				_attach()
		NOTIFICATION_EXIT_WORLD:
			_detach()
		NOTIFICATION_VISIBILITY_CHANGED:
			if is_inside_tree() and is_visible_in_tree():
				if _batch == null:
					_attach()
			else:
				_detach()
		NOTIFICATION_PREDELETE:
			_detach()


## Show the current field values at once, without smoothing (after spawning,
## pooling or teleporting a bird). Happens automatically when a model starts
## drawing.
func snap() -> void:
	_fresh = true


## The level of detail being drawn (0 = full): always the mesh of the batch
## the model is in (the LOD is chosen before the model joins a batch).
func get_lod() -> int:
	return _lod


## What is being drawn right now: (phase, amount, fold, perch), smoothed.
func displayed_pose() -> Vector4:
	return Vector4(_phase_s, _amount_s, _fold_s, _perch_s)


## Displayed highlight weights (edible, danger), 0..1.
func displayed_highlight() -> Vector2:
	return Vector2(_edible_s, _danger_s)


## Displayed bank, radians.
func displayed_bank() -> float:
	return _bank_s


## World position of a wingtip (side 1 right, -1 left) in the pose being
## drawn: for wingtip trails, haptics or anything that must follow the tip.
func get_wingtip(side: int = 1) -> Vector3:
	var rec := BirdModels.tip_record(species)
	if rec.is_empty():
		return global_position
	var p: Vector3 = rec[0]
	var c0: Vector4 = rec[2]
	if side < 0:
		p.x = -p.x
		c0.y = -1.0
	var r := BirdPose.pose(p, rec[1], c0, rec[3], rec[4], rec[5], displayed_pose(), 0.0, 0.0, false, rec[6], rec[7])
	return _display_transform() * (r[0] as Vector3)


func _display_transform() -> Transform3D:
	var xf := get_global_transform_interpolated() if is_physics_interpolated_and_enabled() else global_transform
	if absf(_bank_s) > 1e-5 and is_finite(_bank_s):
		xf.basis = xf.basis * Basis(Vector3.BACK, -_bank_s)
	return xf


func _attach() -> void:
	if not is_inside_tree() or not is_visible_in_tree():
		return
	var w := get_world_3d()
	if w == null:
		return
	if _batch != null:
		_batch.remove(self)
		_batch = null
	# State and LOD first, so the model joins the batch of the mesh it will
	# be drawn with (a bird spawned far away starts at LOD2, one shown again
	# close up at LOD0).
	_advance(0.0)
	var cam := BirdModels.camera_position(get_viewport())
	_compose()
	_lod = _pick_lod(cam)
	var mesh := BirdModels.mesh(species, _lod)
	# Far birds (LOD2, under a degree across) cast no visible shadow: their
	# batches skip the shadow pass (one draw call each).
	_batch = BirdBatch.acquire(w.scenario, mesh, "%s:%d" % [species, _lod], render_layers, cast_shadows and _lod < 2)
	_slot = _batch.add(self)
	_batch.write(_slot, _xf, _inst)
	_sync_mark()


func _detach() -> void:
	if _batch != null:
		_batch.remove(self)
	_batch = null
	_slot = -1
	_fresh = true
	_drop_mark()


## Joins (or leaves) the marker batch of this bird's world and layers, as its
## highlight is shown or not.
func _sync_mark() -> void:
	if not _hl_on or _batch == null:
		_drop_mark()
		return
	var mb := BirdBatch.acquire_marker(_batch.scenario, render_layers)
	if mb == _mark:
		return
	_drop_mark()
	_mark = mb
	_mark_slot = mb.add(self)
	mb.write(_mark_slot, _xf, _inst)


func _drop_mark() -> void:
	if _mark != null:
		_mark.remove(self)
	_mark = null
	_mark_slot = -1


func _reattach() -> void:
	var fresh := _fresh
	if _batch != null:
		_batch.remove(self)
		_batch = null
	_attach()
	_fresh = fresh


## Advances the displayed state by dt, computes the instance transform and
## data. Returns true when the LOD should change (BirdBatch re-attaches).
func _tick(dt: float, cam: Vector3 = Vector3(NAN, NAN, NAN)) -> bool:
	_advance(dt if can_process() else 0.0)
	# The batch passes the camera it looked up once for all its birds.
	if is_nan(cam.x):
		cam = BirdModels.camera_position(get_viewport())
	_compose()
	return _pick_lod(cam) != _lod


## Smooths the displayed pose towards the fields (dt = 0: only the first
## frame after snap() or attaching, which shows the fields at once).
func _advance(d: float) -> void:
	# A smoothed value that is not a number (it can only come from an earlier
	# bad frame) would stick forever: start over from the fields. (One test:
	# the sum of these small numbers is finite exactly when all of them are.)
	if not is_finite(_phase_s + _amount_s + _fold_s + _bank_s + _phase_rate + _phase_lag + _phase_adv_prev + _phase_prev):
		_fresh = true
	var tgt_perch := 1.0 if perched else 0.0
	var tgt_e := 1.0 if highlight == 1 else 0.0
	var tgt_d := 1.0 if highlight == 2 else 0.0
	# A field an owner set to NaN or INF for a frame is ignored (the last good
	# value stays) instead of poisoning the drawn state.
	var amount := clampf(flap_amount, 0.0, 1.0) if is_finite(flap_amount) else clampf(_amount_s, 0.0, 1.0)
	var fold := clampf(wing_fold, 0.0, 1.0) if is_finite(wing_fold) else clampf(_fold_s, 0.0, 1.0)
	var phase := fposmod(flap_phase, 1.0) if is_finite(flap_phase) else _phase_prev
	var tgt_bank := bank if is_finite(bank) else (_bank_s if is_finite(_bank_s) else 0.0)
	if _fresh:
		_fresh = false
		_phase_s = phase
		_phase_prev = phase
		_phase_rate = 0.0
		_phase_adv_prev = 0.0
		_phase_lag = 0.0
		_amount_s = amount
		_fold_s = fold
		_perch_s = tgt_perch
		_bank_s = tgt_bank
		_edible_s = tgt_e
		_danger_s = tgt_d
		return
	if d <= 0.0:
		return
	if d != _k_dt:
		prepare_frame(d)
	_amount_s += (amount - _amount_s) * _k_amount
	_fold_s += (fold - _fold_s) * _k_fold
	_perch_s += (tgt_perch - _perch_s) * _k_perch
	_bank_s += (tgt_bank - _bank_s) * _k_bank
	_edible_s += (tgt_e - _edible_s) * _k_hl
	_danger_s += (tgt_d - _danger_s) * _k_hl
	# The owner's step this frame, read in the direction that matches its
	# beat (cycles/s): forwards for a beating bird even across a long frame.
	var raw := fposmod(phase - _phase_prev, 1.0)
	_phase_prev = phase
	var fwd := raw / d
	var bwd := (raw - 1.0) / d
	var adv := fwd if absf(fwd - _phase_rate) <= absf(bwd - _phase_rate) else bwd
	# The beat is the smaller of the last two steps (same direction only): a
	# single jump does not look like a fast beat, a real beat counts from its
	# second frame.
	var steady := 0.0
	if adv * _phase_adv_prev > 0.0:
		steady = signf(adv) * minf(absf(adv), absf(_phase_adv_prev))
	_phase_adv_prev = adv
	_phase_rate = lerpf(_phase_rate, steady, 0.5)
	# Whole beats of lag look the same as none: keep less than one.
	_phase_lag = fmod(_phase_lag + adv * d, 1.0)
	var cap := maxf(absf(_phase_rate) * d * PHASE_CATCHUP + 0.004, MIN_PHASE_STEP)
	var dp := clampf(_phase_lag, -cap, cap)
	_phase_lag -= dp
	_phase_s = fposmod(_phase_s + dp, 1.0)


## The instance transform (with the bank) and packed data.
func _compose() -> void:
	_xf = _display_transform()
	var b := _xf.basis
	# (One test: a sum is finite exactly when every term is, for any transform
	# short of 1e38.)
	if not is_finite(b.x.x + b.x.y + b.x.z + b.y.x + b.y.y + b.y.z + b.z.x + b.z.y + b.z.z + _xf.origin.x + _xf.origin.y + _xf.origin.z):
		# An owner put the bird at NaN/INF: draw nothing rather than NaN.
		_xf = Transform3D(Basis.from_scale(Vector3.ZERO), Vector3.ZERO)
	var fq := roundf(clampf(_fold_s, 0.0, 1.0) * 4095.0) + 4096.0 * roundf(clampf(_perch_s, 0.0, 1.0) * 4095.0)
	var eq := roundf(clampf(_edible_s, 0.0, 1.0) * 255.0)
	var dq := roundf(clampf(_danger_s, 0.0, 1.0) * 255.0)
	_hl_on = eq + dq > 0.0
	_inst = Vector4(_phase_s, _amount_s, fq, eq + 256.0 * dq + 65536.0 * float(_seed))


## Level of detail from the wingspan's angular size (with hysteresis around
## the current level, so a bird at a threshold does not flicker).
func _pick_lod(cam: Vector3) -> int:
	if lod_override >= 0:
		return clampi(lod_override, 0, BirdModels.LOD_COUNT - 1)
	if cam.x == INF:
		# No camera to measure against: full detail.
		return 0
	var span := _xf.basis.x.length()
	var ang := span / maxf(_xf.origin.distance_to(cam), 0.001) * lod_bias
	var h := 1.0 + (LOD_HYSTERESIS if _lod > 0 else -LOD_HYSTERESIS)
	var h1 := 1.0 + (LOD_HYSTERESIS if _lod > 1 else -LOD_HYSTERESIS)
	if ang >= LOD0_ANGLE * h:
		return 0
	if ang >= LOD1_ANGLE * h1:
		return 1
	return 2
