extends Node
## AU7 review export (headless; images are drawn with Godot's Image):
##   artifacts/audio/clips/<name>.wav          every clip the game plays
##   artifacts/audio/spectrograms/<name>.png   a labelled spectrogram of each
##   artifacts/audio/spectrograms/render_*.png the mixer renders the tests saved
##   artifacts/audio/sheet_<group>.png         contact sheets per group
##   artifacts/audio/mix_levels.json           peak / RMS of every clip, and
##                                             of every cue at its mix level
##
##   tools/gd.sh audio --headless res://tests/shots/audio_clips.tscn [-- --only=calls]
##
## --only=<group> (flight, cues, calls, ambience, ui_music, renders) redoes
## one group; its clip levels are merged into the existing mix_levels.json
## (the cue levels are recomputed from the merged table), never dropped.
##
## Compressed files (the menu music, UI clicks) are captured from the
## mixer in real time, since only PCM can be read back directly.

const GROUPS := {
	"flight": ["wind_body", "wind_edge", "stall_flutter", "updraft_hum", "whoosh_"],
	"cues": ["crunch_", "puff_", "caught", "fanfare", "bump", "brush", "heartbeat", "drone"],
	"calls": ["moth_flutter", "wren_", "sparrow_", "swallow_", "starling_", "pigeon_", "crow_", "gull_", "hawk_", "eagle_"],
	"ambience": ["amb_", "bell"],
	"ui_music": ["ui_", "music_"],
}

var _levels := {}


func _group_of(key: String) -> String:
	for g in GROUPS:
		for prefix in GROUPS[g]:
			if key.begins_with(prefix):
				return g
	return "other"


func _ready() -> void:
	var only := Paths.arg("only", "")
	var out := Paths.artifacts("audio")
	var clip_dir := out.path_join("clips")
	var spec_dir := out.path_join("spectrograms")
	DirAccess.make_dir_recursive_absolute(clip_dir)
	DirAccess.make_dir_recursive_absolute(spec_dir)
	AudioBuses.ensure()
	var bank := AudioBank.acquire(false)
	var streams := bank.all_streams()
	var keys: Array = streams.keys()
	# By name: StringNames compare by pointer, not alphabetically.
	keys.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	var sheets := {}
	var t_all := Time.get_ticks_msec()
	for key in keys:
		var clip_name := String(key)
		var group := _group_of(clip_name)
		if not only.is_empty() and group != only:
			continue
		var st: AudioStream = streams[key]
		var pcm := AudioAnalysis.clip_pcm(st)
		if pcm.is_empty():
			pcm = await _capture(st, minf(st.get_length(), 12.0) if st.get_length() > 0.0 else 3.0)
		var l: PackedFloat32Array = pcm["l"]
		var r: PackedFloat32Array = pcm["r"]
		var mono: PackedFloat32Array = pcm["mono"]
		var rate: float = pcm["rate"]
		var stereo := l != r
		AudioSynth.make_wav(l, r if stereo else PackedFloat32Array(), int(rate)).save_to_wav(clip_dir.path_join(clip_name + ".wav"))
		var pk := AudioAnalysis.db(maxf(AudioAnalysis.peak(l), AudioAnalysis.peak(r)))
		var ar := AudioAnalysis.active_range(mono, rate, -40.0)
		var rms := AudioAnalysis.db(AudioAnalysis.rms(mono, ar["start"], ar["end"]))
		var loop := st is AudioStreamWAV and (st as AudioStreamWAV).loop_mode != AudioStreamWAV.LOOP_DISABLED
		loop = loop or (st is AudioStreamOggVorbis and (st as AudioStreamOggVorbis).loop)
		_levels[clip_name] = {"peak_dbfs": pk, "rms_dbfs": rms, "seconds": mono.size() / rate, "rate": rate, "stereo": stereo, "loop": loop}
		var src := "SYNTHESIZED" if not st.resource_path.begins_with("res://") else st.resource_path.get_file().to_upper()
		var note := "%s  %.2f S  %d HZ %s  PEAK %.1f DBFS  RMS %.1f DBFS%s" % [src, mono.size() / rate, int(rate),
			"STEREO" if stereo else "MONO", pk, rms, "  LOOP" if loop else ""]
		var img := AudioPlot.spectrogram(mono, rate, clip_name, note)
		img.save_png(spec_dir.path_join(clip_name + ".png"))
		if not sheets.has(group):
			sheets[group] = []
		(sheets[group] as Array).append(img)
		print("[audio] clip %-22s %6.2f s  peak %6.1f  rms %6.1f" % [clip_name, mono.size() / rate, pk, rms])
	# Rendered mixes saved by the tests.
	var rdir := out.path_join("renders")
	var d := DirAccess.open(rdir)
	if d and (only.is_empty() or only == "renders"):
		var files := d.get_files()
		files.sort()
		var imgs := []
		for f in files:
			if not f.ends_with(".wav"):
				continue
			var w := AudioStreamWAV.load_from_file(rdir.path_join(f))
			if w == null:
				continue
			var dec := AudioAnalysis.decode_wav(w)
			var m: PackedFloat32Array = dec["mono"]
			var rt := float(dec["rate"])
			var note2 := "MIXER RENDER (HEADLESS DUMMY DRIVER)  %.2f S  PEAK %.1f DBFS  RMS %.1f DBFS" % [m.size() / rt,
				AudioAnalysis.db(maxf(AudioAnalysis.peak(dec["l"]), AudioAnalysis.peak(dec["r"]))), AudioAnalysis.db(AudioAnalysis.rms(m))]
			var im := AudioPlot.spectrogram(m, rt, "render " + f.get_basename(), note2)
			im.save_png(spec_dir.path_join("render_" + f.get_basename() + ".png"))
			imgs.append(im)
		sheets["renders"] = imgs
	for g in sheets:
		_sheet(sheets[g]).save_png(out.path_join("sheet_%s.png" % g))
	var exported := _levels.size()
	_write_levels(out, not only.is_empty())
	print("[audio] exported %d clips in %d ms" % [exported, Time.get_ticks_msec() - t_all])
	bank = null
	AudioBank.release()
	await get_tree().create_timer(0.1).timeout
	get_tree().quit()


## Plays a compressed stream through a private bus and records it.
func _capture(st: AudioStream, seconds: float) -> Dictionary:
	AudioServer.add_bus()
	var bi := AudioServer.bus_count - 1
	AudioServer.set_bus_name(bi, "ShotCapture")
	AudioServer.set_bus_mute(bi, false)
	var cap := AudioEffectCapture.new()
	cap.buffer_length = seconds + 1.0
	AudioServer.add_bus_effect(bi, cap)
	var p := AudioStreamPlayer.new()
	p.bus = &"ShotCapture"
	p.stream = st
	add_child(p)
	await get_tree().process_frame
	cap.clear_buffer()
	p.play()
	var need := int(seconds * AudioServer.get_mix_rate())
	var frames := PackedVector2Array()
	while frames.size() < need:
		await get_tree().process_frame
		var n := cap.get_frames_available()
		if n > 0:
			frames.append_array(cap.get_buffer(n))
	p.stop()
	p.queue_free()
	AudioServer.remove_bus(AudioServer.get_bus_index(&"ShotCapture"))
	var d := AudioAnalysis.split_frames(frames.slice(0, need))
	d["rate"] = AudioServer.get_mix_rate()
	return d


## Contact sheet: images at half size, packed left to right into rows up
## to SHEET_W wide (a long loop takes a wide slot, a short whoosh a narrow
## one, so the sheet is not mostly blank).
const SHEET_W := 1600


func _sheet(imgs: Array) -> Image:
	var small: Array[Image] = []
	for im: Image in imgs:
		var s := im.duplicate() as Image
		s.resize(maxi(1, s.get_width() / 2), maxi(1, s.get_height() / 2), Image.INTERPOLATE_BILINEAR)
		small.append(s)
	var pos: Array[Vector2i] = []
	var x := 0
	var y := 0
	var row_h := 0
	var w := 0
	for s2 in small:
		if x > 0 and x + s2.get_width() > SHEET_W:
			x = 0
			y += row_h
			row_h = 0
		pos.append(Vector2i(x, y))
		x += s2.get_width()
		w = maxi(w, x)
		row_h = maxi(row_h, s2.get_height())
	var sheet := AudioPlot.canvas(maxi(1, w), maxi(1, y + row_h))
	for i in small.size():
		sheet.blit_rect(small[i], Rect2i(Vector2i.ZERO, small[i].get_size()), pos[i])
	return sheet


## Clip levels plus each cue at the level the director plays it.
func _write_levels(out: String, partial: bool) -> void:
	# Merge: a partial (--only) export keeps every other clip's numbers; a
	# full export replaces the table.
	var path := out.path_join("mix_levels.json")
	if partial and FileAccess.file_exists(path):
		var old: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if old is Dictionary and (old as Dictionary).get("clips") is Dictionary:
			var merged: Dictionary = old["clips"]
			merged.merge(_levels, true)
			_levels = merged
	var cues := {}
	var at := func(clip: String, db: float) -> Dictionary:
		var c: Dictionary = _levels.get(clip, {})
		if c.is_empty():
			return {}
		return {"clip": clip, "gain_db": db, "peak_dbfs": c["peak_dbfs"] + db, "rms_dbfs": c["rms_dbfs"] + db}
	for k in AudioDirector.LEVEL:
		var clip: String = {"crunch": "crunch_0", "puff": "puff_0", "caught": "caught", "fanfare": "fanfare",
			"bump_min": "bump", "bump_max": "bump", "brush": "brush", "perch": "brush", "npc_crunch": "crunch_0"}.get(k, "")
		cues[k] = at.call(clip, AudioDirector.LEVEL[k])
	cues["whoosh_full"] = at.call("whoosh_0_0", FlightSoundMap.whoosh_db(1.0))
	cues["whoosh_soft"] = at.call("whoosh_0_0", FlightSoundMap.whoosh_db(0.3))
	cues["wind_body_cruise"] = at.call("wind_body", FlightSoundMap.body_db(1.0))
	cues["wind_body_dive_tucked"] = at.call("wind_body", FlightSoundMap.body_db(2.6, 1.0))
	cues["heartbeat_max"] = at.call("heartbeat", FlightSoundMap.heart_db(1.0))
	cues["drone_max"] = at.call("drone", FlightSoundMap.drone_db(1.0))
	cues["updraft_hum_max"] = at.call("updraft_hum", FlightSoundMap.hum_db(6.0))
	for k in AudioDirector.UI_LEVEL:
		cues["ui_" + String(k)] = at.call("ui_" + String(k), AudioDirector.UI_LEVEL[k])
	cues["music_menu"] = at.call("music_menu", AudioDirector.MUSIC_GAIN_DB)
	cues["bell_at_the_tower"] = at.call("bell", AmbienceZones.BELL_DB)
	for z in AmbienceZones.BEDS:
		for spec in AmbienceZones.BEDS[z]:
			cues["bed_" + String(spec[0])] = at.call(String(spec[0]), spec[1])
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"clips": _levels, "cues_at_mix_level": cues,
		"note": "Wind levels are before the Wind bus filters; beds are at full zone weight before the flight speed duck (FlightSoundMap.ambience_duck_db); the bell is at the belfry; calls are levelled by loudness (CallVoices.CALL_LOUDNESS, VOICE.loud) and add distance attenuation."}, "  ", true))
