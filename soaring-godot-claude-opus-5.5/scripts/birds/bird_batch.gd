class_name BirdBatch
extends RefCounted
## Draws every visible BirdModel of one species at one level of detail in
## one World3D as a single RenderingServer MultiMesh: 60 birds of 10 species
## cost about 10-20 draw calls instead of 60 (Quest budget: 150 in total).
##
## BirdModel keeps the per-bird node API (fields, transform, visibility,
## freeing). Once per frame, right before drawing (RenderingServer's
## frame_pre_draw, i.e. after every _process and _physics_process moved the
## birds), sync_all() walks each batch, lets each model smooth its displayed
## pose and pick its LOD, moves the models whose LOD changed to their new
## batch, and only then uploads one buffer per batch: a 3x4 transform and
## INSTANCE_CUSTOM (phase, amount, fold+perch, highlight+seed) per bird.
## Uploading last means a bird that changes LOD (or a batch that had to grow,
## which reallocates its GPU data) is drawn in that very frame: nothing
## blinks. Headless runs never draw, so tests call sync_all(dt) themselves.
##
## Highlight markers (the ring / triangle around a highlighted bird, see
## bird.gdshader) are one more batch per world and render layers: its mesh
## is BirdModels.marker_mesh(), its instances are exactly the highlighted
## birds (same transform and packed data as the bird), it casts no shadow and
## is never culled (a far marker reaches well beyond its bird's box). One
## extra draw call, and no marker geometry in the birds' own meshes.

## Floats per instance: 12 (transform, row-major 3x4) + 4 (custom).
const STRIDE := 16

static var _batches := {}
## Marker batches, by key (kept apart: they hold no models of their own).
static var _marks := {}
static var _hooked := false
## Models whose marker must be added or dropped after this frame's ticks.
static var _mark_changes: Array[BirdModel] = []
## Diagnostics for tests and the flock shot.
static var last_sync_usec := 0
static var last_sync_models := 0
static var syncs := 0
## Models moved to another batch by a LOD change in the last sync.
static var last_lod_moves := 0
## The last sync's phases, microseconds: (ticks and writes, LOD moves and
## markers, uploads).
static var last_phases := Vector3i.ZERO

var key := ""
var mesh: Mesh
var scenario := RID()
## A marker batch: its models are drawn by their own batch too; this one
## draws their markers (BirdModel._mark_slot is the slot here).
var is_marker := false
var mm := RID()
var inst := RID()
var models: Array[BirdModel] = []
var buf := PackedFloat32Array()
var capacity := 0
var _lod_moves: Array[BirdModel] = []


## The batch for this world/mesh/layers, created on first use.
static func acquire(scenario: RID, p_mesh: Mesh, p_key: String, layers: int, shadows: bool) -> BirdBatch:
	var k := "%d|%s|%d|%d" % [scenario.get_id(), p_key, layers, 1 if shadows else 0]
	var b: BirdBatch = _batches.get(k)
	if b != null:
		return b
	b = _create(k, scenario, p_mesh, layers, shadows)
	_batches[k] = b
	return b


## The marker batch for this world and render layers, created on first use.
static func acquire_marker(scenario: RID, layers: int) -> BirdBatch:
	var k := "%d|marker|%d" % [scenario.get_id(), layers]
	var b: BirdBatch = _marks.get(k)
	if b != null:
		return b
	b = _create(k, scenario, BirdModels.marker_mesh(), layers, false)
	b.is_marker = true
	# Never culled: a far bird's marker reaches far beyond the mesh's box, and
	# the batch holds only a handful of highlighted birds.
	RenderingServer.instance_set_custom_aabb(b.inst, AABB(Vector3.ONE * -MARK_REACH, Vector3.ONE * MARK_REACH * 2.0))
	_marks[k] = b
	return b


## Half-size (m) of the marker batch's culling box: beyond any world.
const MARK_REACH := 50000.0


static func _create(k: String, p_scenario: RID, p_mesh: Mesh, layers: int, shadows: bool) -> BirdBatch:
	var b := BirdBatch.new()
	b.key = k
	b.mesh = p_mesh
	b.scenario = p_scenario
	b.mm = RenderingServer.multimesh_create()
	RenderingServer.multimesh_set_mesh(b.mm, p_mesh.get_rid())
	b.inst = RenderingServer.instance_create2(b.mm, p_scenario)
	RenderingServer.instance_set_layer_mask(b.inst, layers)
	RenderingServer.instance_geometry_set_cast_shadows_setting(b.inst,
		RenderingServer.SHADOW_CASTING_SETTING_ON if shadows else RenderingServer.SHADOW_CASTING_SETTING_OFF)
	if not _hooked:
		_hooked = true
		RenderingServer.frame_pre_draw.connect(_on_frame_pre_draw)
	return b


## Bird batches (markers not counted).
static func count() -> int:
	return _batches.size()


## Bird batches (markers not included).
static func all() -> Array:
	return _batches.values()


## Marker batches (one per world and render layers with a highlighted bird).
static func markers() -> Array:
	return _marks.values()


## Markers drawn by all marker batches (for tests and stats).
static func marker_total() -> int:
	var n := 0
	for b: BirdBatch in _marks.values():
		n += b.models.size()
	return n


## Instances drawn by all batches (for tests and stats).
static func instance_total() -> int:
	var n := 0
	for b: BirdBatch in _batches.values():
		n += b.models.size()
	return n


func add(m: BirdModel) -> int:
	models.append(m)
	var slot := models.size() - 1
	if models.size() > capacity:
		_grow(maxi(8, capacity * 2))
	# The GPU copy is refreshed by the next sync (always before drawing).
	return slot


func remove(m: BirdModel) -> void:
	var i := m._mark_slot if is_marker else m._slot
	if i < 0 or i >= models.size() or models[i] != m:
		i = models.find(m)
		if i < 0:
			return
	var last := models.size() - 1
	if i != last:
		var moved := models[last]
		models[i] = moved
		if is_marker:
			moved._mark_slot = i
		else:
			moved._slot = i
		for f in STRIDE:
			buf[i * STRIDE + f] = buf[last * STRIDE + f]
	models.resize(last)
	if models.is_empty():
		_release()


func _grow(new_cap: int) -> void:
	capacity = new_cap
	buf.resize(capacity * STRIDE)
	# Reallocating clears the GPU data; the next upload fills it again.
	RenderingServer.multimesh_allocate_data(mm, capacity, RenderingServer.MULTIMESH_TRANSFORM_3D, false, true)


## Sends this batch's buffer to the GPU (after every change of the frame).
func upload() -> void:
	RenderingServer.multimesh_set_visible_instances(mm, models.size())
	RenderingServer.multimesh_set_buffer(mm, buf)


## True when the GPU holds exactly what the CPU buffer says (tests; the
## headless renderer keeps the uploaded buffer, so this is checkable there).
func gpu_in_sync() -> bool:
	return RenderingServer.multimesh_get_buffer(mm) == buf


func _release() -> void:
	if is_marker:
		_marks.erase(key)
	else:
		_batches.erase(key)
	if inst.is_valid():
		RenderingServer.free_rid(inst)
	if mm.is_valid():
		RenderingServer.free_rid(mm)
	inst = RID()
	mm = RID()
	capacity = 0


func write(slot: int, xf: Transform3D, c: Vector4) -> void:
	var o := slot * STRIDE
	var bx := xf.basis.x
	var by := xf.basis.y
	var bz := xf.basis.z
	buf[o] = bx.x
	buf[o + 1] = by.x
	buf[o + 2] = bz.x
	buf[o + 3] = xf.origin.x
	buf[o + 4] = bx.y
	buf[o + 5] = by.y
	buf[o + 6] = bz.y
	buf[o + 7] = xf.origin.y
	buf[o + 8] = bx.z
	buf[o + 9] = by.z
	buf[o + 10] = bz.z
	buf[o + 11] = xf.origin.z
	buf[o + 12] = c.x
	buf[o + 13] = c.y
	buf[o + 14] = c.z
	buf[o + 15] = c.w


func _sync(dt: float) -> void:
	_lod_moves.clear()
	# One camera lookup per batch (its birds share a world and, in practice,
	# a viewport).
	var cam := BirdModels.camera_position(models[0].get_viewport())
	for i in models.size():
		var m := models[i]
		if m._tick(dt, cam):
			_lod_moves.append(m)
		write(i, m._xf, m._inst)
		if m._hl_on != (m._mark != null):
			_mark_changes.append(m)


## A marker batch copies its birds' transforms and data (already ticked).
func _write_marks() -> void:
	for i in models.size():
		var m := models[i]
		write(i, m._xf, m._inst)


static func _on_frame_pre_draw() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	sync_all(tree.root.get_process_delta_time() if tree else 1.0 / 60.0)


## Updates every batch; dt = seconds since the last sync. LOD changes are
## applied after all batches are written (a model moving batch mid-loop
## would be skipped or written twice), and every batch is uploaded after
## that, so the models that moved (and batches that grew) are drawn in this
## frame.
static func sync_all(dt: float) -> void:
	var t0 := Time.get_ticks_usec()
	var moves: Array[BirdModel] = []
	var n := 0
	_mark_changes.clear()
	for b: BirdBatch in _batches.values():
		if b.models.is_empty():
			continue
		b._sync(dt)
		n += b.models.size()
		moves.append_array(b._lod_moves)
	var t1 := Time.get_ticks_usec()
	for m in moves:
		if is_instance_valid(m):
			m._reattach()
	# Birds that became highlighted (or stopped being) join or leave their
	# world's marker batch; then the markers follow their birds.
	for m in _mark_changes:
		if is_instance_valid(m):
			m._sync_mark()
	_mark_changes.clear()
	for b: BirdBatch in _marks.values():
		b._write_marks()
	var t2 := Time.get_ticks_usec()
	for b: BirdBatch in _batches.values():
		if not b.models.is_empty():
			b.upload()
	for b: BirdBatch in _marks.values():
		b.upload()
	var t3 := Time.get_ticks_usec()
	last_phases = Vector3i(t1 - t0, t2 - t1, t3 - t2)
	last_lod_moves = moves.size()
	last_sync_usec = t3 - t0
	last_sync_models = n
	syncs += 1
