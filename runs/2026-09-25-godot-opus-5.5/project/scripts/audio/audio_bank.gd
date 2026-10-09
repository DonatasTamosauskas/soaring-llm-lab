class_name AudioBank
extends RefCounted
## Every sound the AudioDirector plays: procedural clips (SoundDesigns,
## rendered once) and the shipped recordings (species calls, the forest
## chorus, UI clicks, menu music). One shared instance per process.
##
## Synthesis runs on WorkerThreadPool threads (start_async) so a Quest never
## stalls a frame for it: SYNTH_THREADS clips at a time, taken in priority
## order (flight sounds first, ambience beds last), and each clip becomes
## available the moment it is ready; the director simply skips a layer whose
## clip is not there yet. Tests call shared() / build_sync() and get
## everything at once (on the same threads, waited for).
##
## Rendering everything costs ~6 s of GDScript on one core of the dev Mac
## (several times that on a Quest; about 2 s of wall time on SYNTH_THREADS
## threads), so finished clips are cached in
## user://audio_cache/<cache_key()>/ and later launches read them back in
## milliseconds. The cache is content-addressed: the key is a hash of the
## design sources (SoundDesigns, AudioSynth, this file's job list), the
## engine version and DESIGN_VERSION, so any change to a design misses the
## cache and is synthesized afresh. (A hand-bumped version alone let a design
## change go unnoticed: tests then measured the stale cached clip.) The
## designs are deterministic (seeded), so a cached clip is bit-identical to
## a fresh one; tests/unit/audio checks that too.
##
## The cache is plain PCM in a tiny header (_write_clip), written and read
## on the worker thread: nothing touches the disk on the main thread, and
## no ResourceLoader/ResourceSaver runs off the main thread (which leaves
## engine load tokens behind). Writes go to a temporary file renamed into
## place, so a reader (another process, a crash mid-write) never sees half a
## clip; a clip that fails its header or size check is synthesized again.

## Size classes of wingbeats: 0 small (moth..swallow), 1 medium
## (starling..crow), 2 large (gull..eagle).
const WHOOSH_VARIANTS := 3
const CRUNCH_VARIANTS := 3

const CALL_DIR := "res://assets/audio/calls/"
const UI_FILES := {
	&"click": "res://assets/audio/ui/ui_click.ogg",
	&"select": "res://assets/audio/ui/ui_select.ogg",
	&"back": "res://assets/audio/ui/ui_back.ogg",
	&"open": "res://assets/audio/ui/ui_open.ogg",
	&"close": "res://assets/audio/ui/ui_close.ogg",
	&"confirm": "res://assets/audio/ui/ui_confirm.ogg",
	&"hover": "res://assets/audio/ui/ui_hover.ogg",
}
const MUSIC_MENU := "res://assets/audio/music/menu_heavenly_loop.ogg"
## Part of the cache key. The key already follows every change to the
## design sources; bump this only for a change it cannot see.
const DESIGN_VERSION := 5
const CACHE_DIR := "user://audio_cache"
## What a procedural clip is made from: a change to any of them changes the
## cache key. (In an exported build with binary-token scripts the ".gdc"
## token file is hashed instead; it changes whenever the source does.)
const DESIGN_SOURCES: Array[String] = [
	"res://scripts/audio/sound_designs.gd",
	"res://scripts/audio/audio_synth.gd",
	"res://scripts/audio/audio_bank.gd",
]
const CACHE_MAGIC := "SAC1"
const CACHE_EXT := "clip"
## Cache folders kept (this build's plus the most recently used others, so
## sandboxes on different sources do not evict each other every run).
const CACHE_KEEP := 3
## Clips also kept as raw stereo frames, for AudioStreamGenerator playback
## (the heartbeat, scheduled beat by beat).
const FRAME_KEYS: Array[StringName] = [&"heartbeat"]
const FOREST_BIRDS := "res://assets/audio/ambience/amb_forest_birds.wav"
## Clips synthesized at once in the background (start_async). The designs
## share no state (seeded, static functions), so the jobs are independent:
## three threads bring a first launch from ~6.4 s to ~2.4 s of wall time on
## the dev Mac and leave the Quest's other cores to the game while the menu
## is up. A synchronous build (tests, every fresh test sandbox with its own
## user://) uses all the pool's threads.
const SYNTH_THREADS := 3

static var _shared: AudioBank = null
static var _users := 0
static var _key := ""

## name -> AudioStream (procedural clips and loaded files).
var _streams := {}
## species -> Array[AudioStream]
var _calls := {}
## name -> milliseconds it took to synthesize (0 when it came from the
## cache; evidence for the load cost), and the whole build's wall time.
var build_ms := {}
var synth_ms_total := 0.0
## name -> PackedVector2Array for FRAME_KEYS.
var _frames := {}
var _mutex := Mutex.new()
var _task := -1
var _done := false
## Set on release: the worker stops between jobs (quitting mid-synthesis
## must not wait for every remaining clip).
var _cancel := false
var _files_loaded := false
## Read/write the disk cache (tests that measure synthesis turn it off),
## where it lives (tests use a scratch folder), and, when not empty, the
## only jobs to run (tests).
var use_cache := true
var cache_root := CACHE_DIR
var only: Array[StringName] = []
## Clips that came from the cache this session, and what reading them took.
var cached := 0
var cache_load_ms := 0.0


static func shared() -> AudioBank:
	if _shared == null:
		_shared = AudioBank.new()
	_shared.build_sync()
	return _shared


## The shared bank, synthesizing in the background if it has not started.
static func shared_async() -> AudioBank:
	if _shared == null:
		_shared = AudioBank.new()
	_shared.start_async()
	return _shared


## Directors (and tests) hold the shared bank between acquire and release;
## when the last user releases it the clips are freed (a static reference
## would otherwise keep them alive past exit and be reported as leaks).
static func acquire(async: bool) -> AudioBank:
	_users += 1
	return shared_async() if async else shared()


static func release() -> void:
	_users = maxi(0, _users - 1)
	if _users == 0 and _shared != null:
		_shared._cancel = true
		_shared.wait()
		_shared.poll()
		_shared = null


## Blocks until background synthesis (if any) has finished.
func wait() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


## Synthesis jobs in the order they are needed: [name, Callable -> stream].
func jobs() -> Array:
	var j := []
	j.append([&"wind_body", func() -> AudioStream: return _stereo(SoundDesigns.wind_body(), SoundDesigns.FX_RATE, true)])
	for s in 3:
		for v in WHOOSH_VARIANTS:
			j.append([StringName("whoosh_%d_%d" % [s, v]), func() -> AudioStream: return _mono(SoundDesigns.whoosh(s, v), SoundDesigns.FX_RATE, false)])
	j.append([&"wind_edge", func() -> AudioStream: return _stereo(SoundDesigns.wind_edge(), SoundDesigns.FX_RATE, true)])
	j.append([&"stall_flutter", func() -> AudioStream: return _mono(SoundDesigns.stall_flutter(), SoundDesigns.FX_RATE, true)])
	j.append([&"updraft_hum", func() -> AudioStream: return _stereo(SoundDesigns.updraft_hum(), SoundDesigns.BED_RATE, true)])
	for v in CRUNCH_VARIANTS:
		j.append([StringName("crunch_%d" % v), func() -> AudioStream: return _mono(SoundDesigns.crunch(v), SoundDesigns.FX_RATE, false)])
		j.append([StringName("puff_%d" % v), func() -> AudioStream: return _mono(SoundDesigns.feather_puff(v), SoundDesigns.FX_RATE, false)])
	j.append([&"heartbeat", func() -> AudioStream: return _mono(SoundDesigns.danger_heartbeat(), SoundDesigns.FX_RATE, false)])
	j.append([&"drone", func() -> AudioStream: return _mono(SoundDesigns.danger_drone(), SoundDesigns.FX_RATE, true)])
	j.append([&"caught", func() -> AudioStream: return _mono(SoundDesigns.caught_stinger(), SoundDesigns.FX_RATE, false)])
	j.append([&"fanfare", func() -> AudioStream: return _mono(SoundDesigns.tier_fanfare(), SoundDesigns.FX_RATE, false)])
	j.append([&"bump", func() -> AudioStream: return _mono(SoundDesigns.bump(), SoundDesigns.FX_RATE, false)])
	j.append([&"brush", func() -> AudioStream: return _mono(SoundDesigns.brush(), SoundDesigns.FX_RATE, false)])
	j.append([&"moth_flutter", func() -> AudioStream: return _mono(SoundDesigns.moth_flutter(), SoundDesigns.FX_RATE, true)])
	for v in 3:
		j.append([StringName("starling_%d" % v), func() -> AudioStream: return _mono(SoundDesigns.starling(v), SoundDesigns.FX_RATE, false)])
	j.append([&"amb_leaves", func() -> AudioStream: return _stereo(SoundDesigns.amb_leaves(), SoundDesigns.BED_RATE, true)])
	j.append([&"amb_meadow", func() -> AudioStream: return _stereo(SoundDesigns.amb_meadow(), SoundDesigns.BED_RATE, true)])
	j.append([&"amb_water", func() -> AudioStream: return _stereo(SoundDesigns.amb_water(), SoundDesigns.BED_RATE, true)])
	j.append([&"amb_village", func() -> AudioStream: return _stereo(SoundDesigns.amb_village(), SoundDesigns.BED_RATE, true)])
	j.append([&"amb_open", func() -> AudioStream: return _stereo(SoundDesigns.amb_open(), SoundDesigns.BED_RATE, true)])
	j.append([&"bell", func() -> AudioStream: return _mono(SoundDesigns.church_bell(), SoundDesigns.FX_RATE, false)])
	return j


static func _mono(buf: PackedFloat32Array, rate: int, loop: bool) -> AudioStream:
	return AudioSynth.make_wav(buf, PackedFloat32Array(), rate, loop)


static func _stereo(lr: Array[PackedFloat32Array], rate: int, loop: bool) -> AudioStream:
	return AudioSynth.make_wav(lr[0], lr[1], rate, loop)


## Loads the shipped files (main thread; they are imported resources).
func load_files() -> void:
	if _files_loaded:
		return
	_files_loaded = true
	var d := DirAccess.open(CALL_DIR)
	var files: PackedStringArray = d.get_files() if d else PackedStringArray()
	var names: Array[String] = []
	for f in files:
		# Exported builds list "x.wav.import"/"x.wav.remap"; load by base name.
		var base := f.trim_suffix(".import").trim_suffix(".remap")
		if base.ends_with(".wav") and not names.has(base):
			names.append(base)
	names.sort()
	for f in names:
		var st := load(CALL_DIR + f) as AudioStream
		if st == null:
			continue
		# The clip's name travels with the stream: CallVoices looks its
		# measured loudness up by it (CallVoices.CALL_LOUDNESS).
		st.set_meta(&"clip", StringName(f.get_basename()))
		var species := StringName(f.get_basename().rsplit("_", true, 1)[0])
		_mutex.lock()
		if not _calls.has(species):
			_calls[species] = []
		(_calls[species] as Array).append(st)
		_streams[StringName(f.get_basename())] = st
		_mutex.unlock()
	for k in UI_FILES:
		var ui := load(UI_FILES[k]) as AudioStream
		if ui:
			_put(StringName("ui_" + String(k)), ui)
	var music := load(MUSIC_MENU) as AudioStream
	if music:
		if music is AudioStreamOggVorbis:
			(music as AudioStreamOggVorbis).loop = true
		_put(&"music_menu", music)
	var birds := load(FOREST_BIRDS) as AudioStreamWAV
	if birds:
		_set_loop(birds)
		_put(&"amb_forest_birds", birds)


## Imported WAVs do not loop unless told to; set a whole-clip forward loop.
static func _set_loop(w: AudioStreamWAV) -> void:
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = int(round(w.get_length() * w.mix_rate))


func _put(key: StringName, st: AudioStream) -> void:
	_mutex.lock()
	_streams[key] = st
	_mutex.unlock()


func build_sync() -> void:
	load_files()
	wait()
	if is_ready():
		return
	# The caller waits for every clip anyway (tests, tools): all the pool's
	# threads.
	_run_jobs(-1)


## Synthesizes (or reads from the cache) every clip on a worker thread.
## Only the imported files load here, on the calling (main) thread.
func start_async() -> void:
	load_files()
	if is_ready() or _task >= 0:
		return
	_task = WorkerThreadPool.add_task(_run_jobs.bind(SYNTH_THREADS), false, "AudioBank synthesis")


## Main thread, every frame: joins the worker once it has finished. Returns
## at once otherwise (nothing else happens here any more: the cache is
## written by the worker).
func poll() -> void:
	if _task >= 0 and is_ready():
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


## Every job, `threads` at a time in priority order (-1: as many as the
## pool has): from the cache when it holds this build's clip, otherwise
## synthesized and written to the cache. Runs on a worker (start_async, on
## SYNTH_THREADS threads) or on the caller's thread (build_sync, on all of
## them), which waits for the clips' threads either way.
func _run_jobs(threads: int = SYNTH_THREADS) -> void:
	var t_all := Time.get_ticks_usec()
	if use_cache:
		_touch()
	var todo := []
	for job in jobs():
		if not has(job[0]) and (only.is_empty() or only.has(job[0])):
			todo.append(job)
	if not todo.is_empty():
		var group := WorkerThreadPool.add_group_task(func(i: int) -> void: _run_job(todo[i]),
			todo.size(), threads, false, "AudioBank clips")
		WorkerThreadPool.wait_for_group_task_completion(group)
	if use_cache and not _cancel:
		_touch()
		_prune()
	_mutex.lock()
	synth_ms_total = (Time.get_ticks_usec() - t_all) / 1000.0
	_done = true
	_mutex.unlock()


## One clip: read back from the cache, or synthesized and written there.
## Skipped once the bank is released (quitting mid-synthesis).
func _run_job(job: Array) -> void:
	if _cancel:
		return
	var key: StringName = job[0]
	var t0 := Time.get_ticks_usec()
	var st: AudioStreamWAV = _read_clip(clip_path(key)) if use_cache else null
	var from_cache := st != null
	if st == null:
		st = (job[1] as Callable).call()
		if use_cache:
			_write_clip(clip_path(key), st)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	st.set_meta(&"clip", key)
	var fr := _to_frames(st) if FRAME_KEYS.has(key) else PackedVector2Array()
	_mutex.lock()
	_streams[key] = st
	build_ms[key] = 0.0 if from_cache else ms
	if from_cache:
		cached += 1
		cache_load_ms += ms
	if not fr.is_empty():
		_frames[key] = fr
	_mutex.unlock()


## The cache key of this build: DESIGN_VERSION plus a hash of the engine
## version and every design source.
static func cache_key() -> String:
	if _key.is_empty():
		var hashes := PackedStringArray()
		for p in DESIGN_SOURCES:
			hashes.append(source_hash(p))
		_key = key_from(hashes)
	return _key


static func key_from(source_hashes: PackedStringArray) -> String:
	var h := "%d|%s|%s" % [DESIGN_VERSION, Engine.get_version_info().string, "|".join(source_hashes)]
	return "v%d_%s" % [DESIGN_VERSION, h.md5_text().substr(0, 16)]


## MD5 of a script as shipped: its source, or its binary-token form in an
## export; "" when neither can be read (the key then still has the version).
static func source_hash(path: String) -> String:
	for p in [path, path.get_basename() + ".gdc"]:
		if FileAccess.file_exists(p):
			return FileAccess.get_md5(p)
	return ""


## Where this bank keeps clip `key` (cache_root may be a test's scratch).
func clip_path(key: StringName) -> String:
	return "%s/%s/%s.%s" % [cache_root, cache_key(), key, CACHE_EXT]


## Writes a clip as magic, format fields and raw PCM; to a temporary file
## first, renamed into place (atomic), so no reader sees a partial clip.
static func _write_clip(path: String, w: AudioStreamWAV) -> bool:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var tmp := "%s.%d_%d.tmp" % [path, OS.get_process_id(), Time.get_ticks_usec()]
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(CACHE_MAGIC.to_ascii_buffer())
	f.store_32(w.mix_rate)
	f.store_8(1 if w.stereo else 0)
	f.store_8(w.format)
	f.store_8(w.loop_mode)
	f.store_32(w.loop_begin)
	f.store_32(w.loop_end)
	f.store_32(w.data.size())
	f.store_buffer(w.data)
	var ok := f.get_error() == OK
	f.close()
	if not ok or DirAccess.rename_absolute(tmp, path) != OK:
		DirAccess.remove_absolute(tmp)
		return false
	return true


## Reads a clip written by _write_clip, or null if it is missing, from
## another format, or truncated.
static func _read_clip(path: String) -> AudioStreamWAV:
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_length() < 23:
		return null
	if f.get_buffer(4).get_string_from_ascii() != CACHE_MAGIC:
		return null
	var w := AudioStreamWAV.new()
	w.mix_rate = f.get_32()
	w.stereo = f.get_8() == 1
	w.format = f.get_8() as AudioStreamWAV.Format
	w.loop_mode = f.get_8() as AudioStreamWAV.LoopMode
	w.loop_begin = f.get_32()
	w.loop_end = f.get_32()
	var n := f.get_32()
	if f.get_length() - f.get_position() != n or w.format != AudioStreamWAV.FORMAT_16_BITS:
		return null
	w.data = f.get_buffer(n)
	return w


## 16-bit PCM -> stereo frames in [-1, 1] (once per FRAME_KEYS clip, on the
## worker).
static func _to_frames(w: AudioStreamWAV) -> PackedVector2Array:
	var d := w.data
	var ch := 2 if w.stereo else 1
	var n := d.size() / (2 * ch)
	var out := PackedVector2Array()
	out.resize(n)
	for i in n:
		var l := d.decode_s16(i * 2 * ch) / 32768.0
		out[i] = Vector2(l, d.decode_s16(i * 4 + 2) / 32768.0 if ch == 2 else l)
	return out


## Stamps this build's cache folder as in use (at the start of a build, so
## a concurrent process never takes it for a leftover, and at the end).
func _touch() -> void:
	var mine := "%s/%s" % [cache_root, cache_key()]
	DirAccess.make_dir_recursive_absolute(mine)
	var f := FileAccess.open(mine.path_join("used.stamp"), FileAccess.WRITE)
	if f:
		f.store_string(str(Time.get_unix_time_from_system()))
		f.close()


## Deletes old cache folders: every folder without a stamp (a leftover of an
## older cache format) and all but the CACHE_KEEP - 1 most recently used
## others, so updates and design changes do not pile up on the device.
func _prune() -> void:
	var mine := "%s/%s" % [cache_root, cache_key()]
	if not DirAccess.dir_exists_absolute(cache_root):
		return
	var others := []
	var doomed: Array[String] = []
	for d in DirAccess.get_directories_at(cache_root):
		var path := cache_root.path_join(d)
		if path == mine:
			continue
		var stamp := path.path_join("used.stamp")
		if FileAccess.file_exists(stamp):
			others.append([FileAccess.get_modified_time(stamp), path])
		else:
			doomed.append(path)
	others.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	for i in range(CACHE_KEEP - 1, others.size()):
		doomed.append(others[i][1])
	for path in doomed:
		for file in DirAccess.get_files_at(path):
			DirAccess.remove_absolute(path.path_join(file))
		DirAccess.remove_absolute(path)


func is_ready() -> bool:
	_mutex.lock()
	var d := _done
	_mutex.unlock()
	return d


func has(key: StringName) -> bool:
	_mutex.lock()
	var h := _streams.has(key)
	_mutex.unlock()
	return h


## The stream called key, or null while it is still being synthesized.
func get_stream(key: StringName) -> AudioStream:
	_mutex.lock()
	var s: AudioStream = _streams.get(key)
	_mutex.unlock()
	return s


## Every call clip of a species (moth: its flutter loop; starling: the
## synthesized whistles), in a stable order.
func calls_for(species: StringName) -> Array:
	match species:
		&"moth":
			var m := get_stream(&"moth_flutter")
			return [m] if m else []
		&"starling":
			var out := []
			for v in 3:
				var s := get_stream(StringName("starling_%d" % v))
				if s:
					out.append(s)
			return out
	_mutex.lock()
	var c: Array = (_calls.get(species, []) as Array).duplicate()
	_mutex.unlock()
	return c


## Stereo frames of a FRAME_KEYS clip (empty until it is ready).
func frames(key: StringName) -> PackedVector2Array:
	_mutex.lock()
	var f: PackedVector2Array = _frames.get(key, PackedVector2Array())
	_mutex.unlock()
	return f


## Every clip, name -> stream (exports and tests).
func all_streams() -> Dictionary:
	_mutex.lock()
	var d := _streams.duplicate()
	_mutex.unlock()
	return d
