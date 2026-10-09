extends Node
## Candidate survey (dev tool, not shipped): renders a spectrogram and prints
## the syllables and features of every decoded WAV in --in=<dir>, so call
## snippets can be chosen by measurement (the audio area cannot listen).
##   tools/gd.sh audio --headless res://scenes/dev/audio_survey.tscn -- --in=/abs/dir [--only=substr] [--max=30]

func _ready() -> void:
	var dir: String = Paths.arg("in", "")
	var only: String = Paths.arg("only", "")
	var max_s := float(Paths.arg("max", "40"))
	var out := Paths.artifacts("audio/survey")
	var d := DirAccess.open(dir)
	if d == null:
		print("[audio] survey: cannot open ", dir)
		get_tree().quit(1)
		return
	var files := d.get_files()
	files.sort()
	for f in files:
		if not f.ends_with(".wav") or (not only.is_empty() and not f.contains(only)):
			continue
		var w := AudioStreamWAV.load_from_file(dir.path_join(f))
		if w == null:
			print("[audio] survey: failed ", f)
			continue
		var dec := AudioAnalysis.decode_wav(w)
		var buf: PackedFloat32Array = dec["mono"]
		var rate := float(dec["rate"])
		var from_s := float(Paths.arg("from", "0"))
		buf = buf.slice(int(from_s * rate), mini(buf.size(), int((from_s + max_s) * rate)))
		var t0 := Time.get_ticks_msec()
		var syl := AudioAnalysis.syllables(buf, rate, -24.0, -30.0, 0.02, 0.06)
		var line := "[audio] %s %.1fs peak %.1f rms %.1f | %d syl:" % [f, buf.size() / rate, AudioAnalysis.db(AudioAnalysis.peak(buf)), AudioAnalysis.db(AudioAnalysis.rms(buf)), syl.size()]
		for s in syl.slice(0, 40):
			var seg := buf.slice(int(s.x * rate), int(s.y * rate))
			var tr := AudioAnalysis.peak_track(seg, rate, 150.0, 12000.0, 512, 256, -12.0)
			line += " %.2f-%.2f(%.0fdB,%.0fHz)" % [s.x, s.y, AudioAnalysis.db(AudioAnalysis.peak(seg)), AudioAnalysis.median(tr["hz"])]
		print(line)
		var img := AudioPlot.spectrogram(buf, rate, f.get_basename(), "%.1f S  PEAK %.1f DBFS" % [buf.size() / rate, AudioAnalysis.db(AudioAnalysis.peak(buf))])
		img.save_png(out.path_join(f.get_basename() + ("_%d" % int(from_s) if from_s > 0.0 else "") + ".png"))
		print("[audio]   (%d ms)" % (Time.get_ticks_msec() - t0))
	get_tree().quit()
