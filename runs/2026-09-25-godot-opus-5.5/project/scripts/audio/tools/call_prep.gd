extends Node
## Builds the shipped species calls, assets/audio/calls/<species>_<n>.wav,
## from the decoded candidate recordings (dev tool, not shipped).
##
##   scripts/audio/tools/decode_candidates.sh /tmp/dec
##   tools/gd.sh audio --headless res://scenes/dev/audio_call_prep.tscn -- --in=/tmp/dec [--only=crow]
##
## Per clip: band-limit to the species' voice (24 dB/oct high- and low-pass),
## spectral-subtraction denoise against a noise profile measured on the whole
## source file, cut the chosen stretch, trim to the sound (with a short
## pre-roll and tail), fade the ends, and peak-normalise to -3 dBFS as 32 kHz
## mono 16-bit PCM. Every clip gets a spectrogram in artifacts/audio/prep/
## and its features in prep.json, because the choices below were made by
## measurement, not by ear: the stretches were picked from the survey
## spectrograms (artifacts/audio/survey/) and checked here.

const OUT_RATE := 32000
const PEAK_DB := -3.0

## id, src (decoded file stem), from/to (s), hp/lp (Hz), sub = noise
## over-subtraction factor (0 = no denoise).
const CLIPS: Array[Dictionary] = [
	# Wren: the loud rattling trill of the song, plus the "tic-tic" alarm.
	{"id": "wren_1", "src": "wikimedia_wren_pd_sogning", "from": 1.05, "to": 2.12, "hp": 2600.0, "lp": 10500.0, "sub": 2.5},
	{"id": "wren_2", "src": "wikimedia_wren_pd_sogning", "from": 4.1, "to": 5.35, "hp": 2600.0, "lp": 10500.0, "sub": 2.5},
	{"id": "wren_3", "src": "wikimedia_wren_chirp_ccby3_amada44", "from": 0.1, "to": 0.62, "hp": 2600.0, "lp": 11000.0, "sub": 1.5},
	# House sparrow: "chirp" / "cheep" syllables in twos and threes.
	{"id": "sparrow_1", "src": "wikimedia_sparrow_house_pd_mysid", "from": 0.4, "to": 1.45, "hp": 1800.0, "lp": 10000.0, "sub": 2.0},
	{"id": "sparrow_2", "src": "wikimedia_sparrow_house_pd_mysid", "from": 2.75, "to": 3.8, "hp": 1800.0, "lp": 10000.0, "sub": 2.0},
	{"id": "sparrow_3", "src": "wikimedia_sparrow_house_pd_mysid", "from": 6.3, "to": 7.35, "hp": 1800.0, "lp": 10000.0, "sub": 2.0},
	# Barn swallow: twittering, runs of short buzzy notes (3-8 kHz).
	{"id": "swallow_1", "src": "wikimedia_swallow_barn_ccby3_wasack", "from": 8.0, "to": 9.45, "hp": 2400.0, "lp": 12000.0, "sub": 2.5},
	{"id": "swallow_2", "src": "wikimedia_swallow_barn_ccby3_wasack", "from": 10.3, "to": 12.1, "hp": 2400.0, "lp": 12000.0, "sub": 2.5},
	{"id": "swallow_3", "src": "wikimedia_swallow_barn_ccby3_wasack", "from": 23.6, "to": 25.8, "hp": 2400.0, "lp": 12000.0, "sub": 2.5},
	# Dove (pigeon stand-in): three "hoo-hooo" coos.
	{"id": "pigeon_1", "src": "wikimedia_pigeon_dove_cooing_pd_mary905", "from": 0.9, "to": 3.0, "hp": 280.0, "lp": 5000.0, "sub": 1.5},
	{"id": "pigeon_2", "src": "wikimedia_pigeon_dove_cooing_pd_mary905", "from": 3.25, "to": 5.45, "hp": 280.0, "lp": 5000.0, "sub": 1.5},
	{"id": "pigeon_3", "src": "wikimedia_pigeon_dove_cooing_pd_mary905", "from": 5.5, "to": 7.85, "hp": 280.0, "lp": 5000.0, "sub": 1.5},
	# Crow: dry, harsh corvid "kraa" caws (a Yellowstone raven recording:
	# the American crow files are reverberant, and their caws measured as
	# closer to the eagle's yelps than to these).
	{"id": "crow_1", "src": "nps_yell_raven", "from": 3.85, "to": 5.3, "hp": 350.0, "lp": 9000.0, "sub": 2.0},
	{"id": "crow_2", "src": "nps_yell_raven", "from": 5.55, "to": 6.95, "hp": 350.0, "lp": 9000.0, "sub": 2.0},
	{"id": "crow_3", "src": "nps_yell_raven", "from": 7.3, "to": 8.8, "hp": 350.0, "lp": 9000.0, "sub": 2.0},
	# Gulls: a herring gull's laugh in two cuts (sharing one note) and the
	# western gull's "kek" series in two. (The other herring gull file's
	# keks, tried in round 5, measured nearer the eagle's yelps: their
	# strongest partial is at 1.7 kHz.)
	# Each cut ends in a pause of the call (or at the recording's own end),
	# at least 0.12 s after its last note: a laugh has 80-150 ms between
	# notes, and a cut closer to a note than that fades the note's own tail
	# (round 5: four gull cuts ended 3-17 dB under their loudest note,
	# stopping mid-note). The western gull's gaps are all ~80 ms, so one cut
	# runs to the end of the recording and the other trails off.
	{"id": "gull_1", "src": "wikimedia_gull_herring_pd_avphillips_2", "from": 0.45, "to": 2.75, "hp": 600.0, "lp": 9000.0, "sub": 2.0},
	{"id": "gull_2", "src": "wikimedia_gull_herring_pd_avphillips_2", "from": 2.45, "to": 3.98, "hp": 600.0, "lp": 9000.0, "sub": 2.0},
	{"id": "gull_3", "src": "nps_western_gull", "from": 2.4, "to": 4.6, "hp": 700.0, "lp": 9000.0, "sub": 2.0},
	# The western gull's first half: its gaps are too short to end in, so
	# its last 0.6 s fall away (see `release` under the hawk), a laugh
	# trailing off.
	{"id": "gull_4", "src": "nps_western_gull", "from": 0.1, "to": 2.45, "hp": 700.0, "lp": 9000.0, "sub": 2.0, "release": 0.6},
	# Hawk: the red-tailed "kee-eeeer" scream (the iconic raptor cry) in a
	# long, a medium and a short cut. A red-shouldered hawk "kee-ah" was
	# tried and dropped: it measured as closer to an eagle yelp or a starling
	# whistle than to a screech. The scream is one continuous note that falls
	# away over 3 s (-15 dB by 2.5 s, then 70 dB/s to silence), so a shorter
	# cut has nowhere quiet to end: the medium and short ones get a release
	# (`release`: the last seconds of the cut fall 60 dB, linear in dB, at
	# the rate the scream itself dies away at its end). Until round 5 they
	# stopped 5-11 dB under the scream's peak, mid-note.
	{"id": "hawk_1", "src": "wikimedia_hawk_scream_ccby3_psychobird", "from": 0.0, "to": 3.35, "hp": 1100.0, "lp": 12000.0, "sub": 1.0},
	{"id": "hawk_2", "src": "wikimedia_hawk_scream_ccby3_psychobird", "from": 0.0, "to": 2.3, "hp": 1100.0, "lp": 12000.0, "sub": 1.0, "release": 0.8},
	{"id": "hawk_3", "src": "wikimedia_hawk_scream_ccby3_psychobird", "from": 0.0, "to": 1.5, "hp": 1100.0, "lp": 12000.0, "sub": 1.0, "release": 0.8},
	# Eagles: golden eagle yelps, bald eagle chitter.
	{"id": "eagle_1", "src": "wikimedia_eagle_golden_ccby3_bubulcus", "from": 0.2, "to": 1.4, "hp": 1000.0, "lp": 10000.0, "sub": 2.0},
	{"id": "eagle_2", "src": "wikimedia_eagle_golden_ccby3_bubulcus", "from": 1.75, "to": 3.05, "hp": 1000.0, "lp": 10000.0, "sub": 2.0},
	{"id": "eagle_3", "src": "nps_bald_eagle", "from": 0.08, "to": 2.45, "hp": 900.0, "lp": 10000.0, "sub": 2.0},
	# Distant forest chorus for the tree ambience (not a species call).
	{"id": "amb_forest_birds", "src": "nps_yell_bird_chorus", "from": 0.8, "to": 36.6, "hp": 1400.0, "lp": 10000.0, "sub": 1.5, "dir": "ambience", "peak": -6.0, "keep": true, "loop": 1.5},
]


func _ready() -> void:
	var src_dir: String = Paths.arg("in", "")
	var only: String = Paths.arg("only", "")
	var root := OS.get_environment("SOARING_ROOT")
	if root.is_empty():
		root = ProjectSettings.globalize_path("res://")
	var out_png := Paths.artifacts("audio/prep")
	var report := {}
	var cache := {}
	for c in CLIPS:
		if not only.is_empty() and not String(c["id"]).contains(only):
			continue
		var t0 := Time.get_ticks_msec()
		var src := String(c["src"])
		if not cache.has(src):
			var w := AudioStreamWAV.load_from_file(src_dir.path_join(src + ".wav"))
			if w == null:
				print("[audio] prep: cannot load ", src)
				continue
			var dec := AudioAnalysis.decode_wav(w)
			if int(dec["rate"]) != OUT_RATE:
				print("[audio] prep: %s is %d Hz, expected %d" % [src, dec["rate"], OUT_RATE])
			cache[src] = dec["mono"]
		var raw: PackedFloat32Array = cache[src]
		var clip := prepare(raw, OUT_RATE, c)
		var dir := String(c.get("dir", "calls"))
		var path := root.path_join("assets/audio").path_join(dir).path_join(String(c["id"]) + ".wav")
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		AudioSynth.make_wav(clip, PackedFloat32Array(), OUT_RATE).save_to_wav(path)
		var f := AudioAnalysis.features(clip, OUT_RATE)
		report[c["id"]] = f
		var note := "SRC %s %.2f-%.2f S  HP %d LP %d  DUR %.2f  DOM %d HZ  CENT %d HZ  SYL %d (%.1f/S)  SLOPE %.2f OCT/S  FLAT %.2f" % [
			src.to_upper().left(34), c["from"], c["to"], int(c["hp"]), int(c["lp"]), f["duration"], int(f["dominant"]),
			int(f["centroid"]), f["syllables"], f["syl_rate"], f["slope_oct"], f["flatness"]]
		AudioPlot.spectrogram(clip, OUT_RATE, String(c["id"]), note).save_png(out_png.path_join(String(c["id"]) + ".png"))
		print("[audio] prep %s: %.2fs dom %d Hz cent %d Hz syl %d rate %.1f len %.3f slope %.2f flat %.2f rms %.1f dB (%d ms)" % [
			c["id"], f["duration"], int(f["dominant"]), int(f["centroid"]), f["syllables"], f["syl_rate"], f["syl_len"],
			f["slope_oct"], f["flatness"], f["rms_db"], Time.get_ticks_msec() - t0])
	# Contact sheet of every call clip for review.
	var ims := []
	for c2 in CLIPS:
		var pth := out_png.path_join(String(c2["id"]) + ".png")
		if c2.get("dir", "calls") == "calls" and FileAccess.file_exists(pth):
			var im := Image.load_from_file(pth)
			im.resize(im.get_width() / 2, im.get_height() / 2, Image.INTERPOLATE_BILINEAR)
			ims.append(im)
	if not ims.is_empty():
		var cols := 3
		var cw := 0
		var ch := 0
		for im in ims:
			cw = maxi(cw, im.get_width())
			ch = maxi(ch, im.get_height())
		var sheet := AudioPlot.canvas(cw * cols, ch * int(ceil(ims.size() / float(cols))))
		for i in ims.size():
			sheet.blit_rect(ims[i], Rect2i(Vector2i.ZERO, ims[i].get_size()), Vector2i((i % cols) * cw, (i / cols) * ch))
		sheet.save_png(out_png.path_join("_calls_sheet.png"))
	var fa := FileAccess.open(out_png.path_join("prep.json"), FileAccess.WRITE)
	fa.store_string(JSON.stringify(report, "  ", true))
	get_tree().quit()


static func prepare(raw: PackedFloat32Array, rate: int, c: Dictionary) -> PackedFloat32Array:
	var hpf := float(c["hp"])
	var lpf := float(c["lp"])
	var chain := [AudioSynth.hp(hpf, 0.707, rate), AudioSynth.hp(hpf, 0.707, rate),
		AudioSynth.lp(lpf, 0.707, rate), AudioSynth.lp(lpf, 0.707, rate)]
	var filtered := AudioSynth.filter(raw, chain)
	var pad := int(0.25 * rate)
	var a := maxi(0, int(float(c["from"]) * rate) - pad)
	var b := mini(filtered.size(), int(float(c["to"]) * rate) + pad)
	var seg := filtered.slice(a, b)
	var sub := float(c.get("sub", 0.0))
	if sub > 0.0:
		# Noise measured around the snippet (+-4 s): backgrounds change
		# within a recording, and a whole-file profile misses local hums.
		var span := float(c.get("profile", 4.0))
		var pa := maxi(0, int((float(c["from"]) - span) * rate))
		var pb := mini(filtered.size(), int((float(c["to"]) + span) * rate))
		var profile := noise_profile(filtered.slice(pa, pb), 1024, float(c.get("pct", 0.25)))
		seg = denoise(seg, profile, 1024, sub, -26.0)
	# Back to the requested stretch.
	var ca := int(float(c["from"]) * rate) - a
	var cb := ca + int((float(c["to"]) - float(c["from"])) * rate)
	seg = seg.slice(maxi(0, ca), mini(seg.size(), cb))
	if c.has("release"):
		# A cut from the middle of a sustained call: its last `release`
		# seconds fall 60 dB, linear in dB (a natural decay, not a fade that
		# stops a note still at full level). The trim below then ends the
		# clip once that has gone 40 dB down.
		var n := mini(seg.size(), int(float(c["release"]) * rate))
		var r0 := seg.size() - n
		for i in n:
			seg[r0 + i] *= pow(10.0, -3.0 * float(i) / n)
	if not c.get("keep", false):
		# Start at the first sound within 30 dB of the peak (residual noise
		# must not keep a lead-in), end once it has decayed 40 dB.
		var ar := AudioAnalysis.active_range(seg, rate, -40.0, -30.0)
		var s0 := maxi(0, int(ar["start"]) - int(0.02 * rate))
		var s1 := mini(seg.size(), int(ar["end"]) + int(0.08 * rate))
		seg = seg.slice(s0, s1)
	if c.has("loop"):
		# A bed that loops: fold the last `loop` seconds over the start with
		# an equal-power crossfade, so the wrap is seamless.
		seg = AudioSynth.fold_loop(seg, seg.size() - int(float(c["loop"]) * rate))
	else:
		seg = AudioSynth.fade(seg, 0.008, 0.04, rate)
	return AudioSynth.normalize(seg, float(c.get("peak", PEAK_DB)))


## Per-bin RMS noise magnitude, estimated from a low percentile of each bin
## over the frames (what that frequency sounds like when nothing calls).
static func noise_profile(buf: PackedFloat32Array, n: int, pct: float) -> PackedFloat32Array:
	var frames := AudioAnalysis.stft(buf, n, n / 2)
	var bins := n / 2 + 1
	var prof := PackedFloat32Array()
	prof.resize(bins)
	var col := PackedFloat32Array()
	col.resize(frames.size())
	for k in bins:
		for fi in frames.size():
			col[fi] = frames[fi][k]
		# A noise bin's magnitude is Rayleigh distributed: its q-quantile is
		# sigma * sqrt(-2 ln(1 - q)) while its mean power is 2 sigma^2, so
		# convert the percentile to an RMS magnitude (the power to subtract).
		var q := AudioAnalysis.percentile(col, pct)
		prof[k] = q / sqrt(-log(1.0 - pct))
	return prof


## Spectral subtraction with a smoothed gain mask (75% overlap Hann/Hann
## OLA). Gains: sqrt(max(floor^2, 1 - sub * N^2 / |X|^2)), smoothed over
## +-2 bins and with a slow release in time so call tails are not chopped
## and no "musical noise" twitters survive.
static func denoise(buf: PackedFloat32Array, profile: PackedFloat32Array, n: int, sub: float, floor_db: float) -> PackedFloat32Array:
	var hop := n / 4
	var bins := n / 2 + 1
	var t := AudioAnalysis._get_tables(n)
	var hann: PackedFloat32Array = t[3]
	var out := PackedFloat32Array()
	out.resize(buf.size() + n)
	out.fill(0.0)
	var floor_g := AudioAnalysis.from_db(floor_db)
	var prev := PackedFloat32Array()
	prev.resize(bins)
	prev.fill(floor_g)
	# magnitude() scales by 4/n; the profile is in those units.
	var mscale := 4.0 / n
	var start := -n / 2
	while start < buf.size():
		var re := PackedFloat32Array()
		var im := PackedFloat32Array()
		re.resize(n)
		im.resize(n)
		for i in n:
			var j := start + i
			re[i] = buf[j] * hann[i] if j >= 0 and j < buf.size() else 0.0
			im[i] = 0.0
		var fwd := AudioAnalysis.fft_complex(re, im, false)
		re = fwd[0]
		im = fwd[1]
		var g := PackedFloat32Array()
		g.resize(bins)
		for k in bins:
			var m := sqrt(re[k] * re[k] + im[k] * im[k]) * mscale
			var nz := profile[k]
			var r := 1.0 - sub * nz * nz / maxf(m * m, 1e-20)
			g[k] = sqrt(maxf(floor_g * floor_g, r))
		var gs := PackedFloat32Array()
		gs.resize(bins)
		for k in bins:
			var s := 0.0
			var w := 0.0
			for d in range(-2, 3):
				var kk := k + d
				if kk >= 0 and kk < bins:
					var wt := 1.0 if d == 0 else (0.6 if absi(d) == 1 else 0.3)
					s += g[kk] * wt
					w += wt
			# Fast attack, slow release (~30 ms at hop 256 / 32 kHz).
			gs[k] = maxf(s / w, prev[k] * 0.7)
		prev = gs
		for k in bins:
			re[k] *= gs[k]
			im[k] *= gs[k]
			if k > 0 and k < n / 2:
				re[n - k] = re[k]
				im[n - k] = -im[k]
		var inv := AudioAnalysis.fft_complex(re, im, true)
		re = inv[0]
		for i in n:
			var j2 := start + i
			if j2 >= 0 and j2 < out.size():
				out[j2] += re[i] * hann[i] / 1.5
		start += hop
	return out.slice(0, buf.size())
