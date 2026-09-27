extends TestCase
## AU2: every species has calls, they are in character, and no two species
## sound alike; plus the hygiene of every shipped recording (trim, level,
## fades) and of the synthesized clips, verified numerically since nobody
## listened to them.
##
## Character specs come from bird acoustics, not from the clips:
##   moth      soft flutter: quiet, wingbeat AM at 25-70 Hz
##   wren      loud trill: 3-8 kHz, >= 6 notes/s
##   sparrow   chirp: 2.5-6 kHz, notes 50-300 ms, 1-8 notes/s
##   swallow   twitter: 4-8 kHz, runs of buzzy (not pure) notes, 2-10/s
##   starling  whistles: 1.5-6 kHz, tonal, notes longer than a chirp
##   pigeon    coo: 250-800 Hz, very tonal, long notes (>= 0.4 s)
##   crow      caw: 0.5-2 kHz, harsh and harmonic-rich (not a pure tone), 0.1-0.5 s notes
##   gull      cry: 0.7-3.2 kHz, laughing series (3-10 notes/s)
##   hawk      screech: 2-4.5 kHz, falling pitch, a drawn-out note (>= 0.3 s)
##   eagle     call: 1.5-3.5 kHz yelps, short (<= 0.3 s median) in a series

const Fixture := preload("res://tests/unit/audio/audio_fixture.gd")
const SPECIES: Array[StringName] = [&"moth", &"wren", &"sparrow", &"swallow", &"starling", &"pigeon", &"crow", &"gull", &"hawk", &"eagle"]
## Feature scales for "clearly different": a quarter octave in pitch or
## centroid, half an octave in note rate or note length, 0.2 in tonality.
const SCALES := {"dominant": 0.25, "centroid": 0.25, "note_rate": 0.5, "longest": 0.5, "tonality": 0.2}

var bank: AudioBank
var feats := {}  # species -> Array of feature dicts
var paths := {}  # species -> Array of resource paths ("" = synthesized)


func before_all() -> void:
	bank = AudioBank.acquire(false)
	var t0 := Time.get_ticks_msec()
	# Decoding and measuring ~30 clips is several seconds of GDScript: done
	# on the worker pool, one clip per task (AudioAnalysis is static and
	# thread-safe), then gathered in species order.
	var clips := []  # [species, stream]
	for sp in SPECIES:
		feats[sp] = []
		paths[sp] = []
		for st in bank.calls_for(sp):
			clips.append([sp, st])
	var results := []
	results.resize(clips.size())
	var mutex := Mutex.new()
	var task := WorkerThreadPool.add_group_task(func(i: int) -> void:
		var d := AudioAnalysis.clip_pcm(clips[i][1])
		var f := {}
		if not d.is_empty():
			f = AudioAnalysis.features(d["mono"], d["rate"])
			f["_pcm"] = d
			f["clip"] = String((clips[i][1] as AudioStream).get_meta(&"clip", &""))
		mutex.lock()
		results[i] = f
		mutex.unlock(), clips.size(), -1, true, "audio call features")
	WorkerThreadPool.wait_for_group_task_completion(task)
	for i in clips.size():
		var f: Dictionary = results[i]
		if f.is_empty():
			continue
		var sp: StringName = clips[i][0]
		var st: AudioStream = clips[i][1]
		(feats[sp] as Array).append(f)
		(paths[sp] as Array).append(st.resource_path if st.resource_path.begins_with("res://") else "")
	print("[audio] call features for %d species in %d ms" % [SPECIES.size(), Time.get_ticks_msec() - t0])


func after_all() -> void:
	# The mixer test's players are gone: give the mixer a moment to drop
	# their playbacks before the runner may quit.
	await Fixture.wait(get_tree(), 0.15)
	feats.clear()
	bank = null
	AudioBank.release()


static func _median(arr: Array, key: String) -> float:
	var v := PackedFloat32Array()
	for f in arr:
		v.append(float(f[key]))
	return AudioAnalysis.median(v)


static func _vec(f: Dictionary) -> PackedFloat32Array:
	return PackedFloat32Array([
		log(maxf(f["dominant"], 1.0)) / log(2.0) / SCALES["dominant"],
		log(maxf(f["centroid"], 1.0)) / log(2.0) / SCALES["centroid"],
		log(float(f["note_rate"]) + 0.5) / log(2.0) / SCALES["note_rate"],
		log(maxf(f["longest"], 0.02)) / log(2.0) / SCALES["longest"],
		float(f["tonality"]) / SCALES["tonality"],
	])


func test_every_species_has_calls() -> void:
	for sp in SPECIES:
		var n: int = (feats[sp] as Array).size()
		if sp == &"moth":
			eq(n, 1, "moth: one looping flutter")
		else:
			between(n, 3, 6, "%s: 3-6 call variants" % sp)


func test_calls_in_character() -> void:
	for sp in SPECIES:
		var i := 0
		for f: Dictionary in feats[sp]:
			i += 1
			var tag := "%s_%d" % [sp, i]
			var dom: float = f["dominant"]
			match sp:
				&"moth":
					var pcm: Dictionary = f["_pcm"]
					var per := AudioAnalysis.periodicity(AudioAnalysis.envelope(pcm["mono"], pcm["rate"], 0.002), 500.0, 20.0, 80.0)
					metric("moth_wingbeat_hz", per["hz"])
					lt(f["rms_db"], -24.0, "%s: soft (RMS < -24 dBFS)" % tag)
					between(per["hz"], 25.0, 70.0, "%s: wingbeat flutter at 25-70 Hz" % tag)
					gt(per["strength"], 0.5, "%s: flutter strongly periodic" % tag)
				&"wren":
					between(dom, 3000.0, 8000.0, "%s: 3-8 kHz" % tag)
					gt(f["note_rate"], 6.0, "%s: trill, >= 6 notes/s" % tag)
				&"sparrow":
					between(dom, 2500.0, 6000.0, "%s: 2.5-6 kHz" % tag)
					between(f["syl_len"], 0.05, 0.3, "%s: chirps of 50-300 ms" % tag)
					between(f["note_rate"], 1.0, 8.0, "%s: 1-8 chirps/s" % tag)
				&"swallow":
					between(dom, 4000.0, 8000.0, "%s: 4-8 kHz" % tag)
					between(f["note_rate"], 2.0, 10.0, "%s: runs of 2-10 notes/s" % tag)
					lt(f["tonality"], 0.6, "%s: buzzy notes, not pure whistles" % tag)
				&"starling":
					between(dom, 1500.0, 6000.0, "%s: 1.5-6 kHz" % tag)
					gt(f["tonality"], 0.35, "%s: a whistle (tonal)" % tag)
					gt(f["longest"], 0.25, "%s: whistled notes >= 0.25 s" % tag)
				&"pigeon":
					between(dom, 250.0, 800.0, "%s: coo at 250-800 Hz" % tag)
					gt(f["tonality"], 0.6, "%s: very tonal" % tag)
					gt(f["longest"], 0.4, "%s: long notes" % tag)
					lt(f["centroid"], 1500.0, "%s: low centroid" % tag)
				&"crow":
					between(dom, 500.0, 2000.0, "%s: caw at 0.5-2 kHz" % tag)
					gt(f["rolloff95"] / dom, 1.4, "%s: rich in harmonics (95%% roll-off >= 1.4x the pitch; a coo is ~1.1x)" % tag)
					lt(f["tonality"], 0.7, "%s: harsh, not a pure tone" % tag)
					between(f["syl_len"], 0.1, 0.5, "%s: caws of 0.1-0.5 s" % tag)
				&"gull":
					between(dom, 700.0, 3200.0, "%s: 0.7-3.2 kHz" % tag)
					between(f["note_rate"], 3.0, 10.0, "%s: laughing series, 3-10 notes/s" % tag)
				&"hawk":
					between(dom, 2000.0, 4500.0, "%s: screech at 2-4.5 kHz" % tag)
					lt(f["slope_oct"], -0.1, "%s: pitch falls (kee-eeer)" % tag)
					gt(f["longest"], 0.3, "%s: drawn out (>= 0.3 s)" % tag)
				&"eagle":
					between(dom, 1500.0, 3500.0, "%s: 1.5-3.5 kHz" % tag)
					lt(f["syl_len"], 0.3, "%s: short yelps" % tag)
					gt(f["syllables"], 1.0, "%s: in a series" % tag)


func test_species_are_distinct() -> void:
	var med := {}
	for sp in SPECIES:
		med[sp] = {}
		for k in SCALES:
			med[sp][k] = _median(feats[sp], k)
	var table := {}
	var worst := INF
	var worst_pair := ""
	for a in SPECIES.size():
		for b in range(a + 1, SPECIES.size()):
			var fa: Dictionary = med[SPECIES[a]]
			var fb: Dictionary = med[SPECIES[b]]
			var d := {
				"dominant": absf(log(fa["dominant"] / fb["dominant"]) / log(2.0)) / SCALES["dominant"],
				"centroid": absf(log(fa["centroid"] / fb["centroid"]) / log(2.0)) / SCALES["centroid"],
				"note_rate": absf(log((fa["note_rate"] + 0.5) / (fb["note_rate"] + 0.5)) / log(2.0)) / SCALES["note_rate"],
				"longest": absf(log(fa["longest"] / fb["longest"]) / log(2.0)) / SCALES["longest"],
				"tonality": absf(fa["tonality"] - fb["tonality"]) / SCALES["tonality"],
			}
			var best := 0.0
			var by := ""
			for k in d:
				if d[k] > best:
					best = d[k]
					by = k
			table["%s/%s" % [SPECIES[a], SPECIES[b]]] = [best, by]
			if best < worst:
				worst = best
				worst_pair = "%s/%s (by %s)" % [SPECIES[a], SPECIES[b], by]
			# Pitch, spectral centroid or rhythm must clearly differ.
			var pcr := maxf(maxf(d["dominant"], d["centroid"]), maxf(d["note_rate"], d["longest"]))
			gt(pcr, 1.0, "%s vs %s: pitch, centroid or rhythm differ clearly" % [SPECIES[a], SPECIES[b]])
	metric("closest_pair", worst_pair)
	metric("closest_distance", worst)
	metric("species_medians", med)
	# Every clip is closest to its own species (nearest median, normalised
	# feature space): nothing would be mistaken for another bird.
	var cents := {}
	for sp in SPECIES:
		var acc := PackedFloat32Array([0, 0, 0, 0, 0])
		for f in feats[sp]:
			var v := _vec(f)
			for i in 5:
				acc[i] += v[i]
		for i in 5:
			acc[i] /= maxf(1.0, (feats[sp] as Array).size())
		cents[sp] = acc
	var right := 0
	var total := 0
	var confusions := []
	for sp in SPECIES:
		for f in feats[sp]:
			var v := _vec(f)
			var best_sp := &""
			var best_d := INF
			for sp2 in SPECIES:
				var c: PackedFloat32Array = cents[sp2]
				var dd := 0.0
				for i in 5:
					dd += (v[i] - c[i]) * (v[i] - c[i])
				if dd < best_d:
					best_d = dd
					best_sp = sp2
			total += 1
			if best_sp == sp:
				right += 1
			else:
				confusions.append("%s->%s" % [sp, best_sp])
	metric("nearest_species_accuracy", float(right) / total)
	metric("confusions", confusions)
	eq(confusions.size(), 0, "every call clip is nearest to its own species (%s)" % [confusions])
	var per_clip := {}
	for sp in SPECIES:
		per_clip[sp] = []
		for f in feats[sp]:
			var g: Dictionary = f.duplicate()
			g.erase("_pcm")
			(per_clip[sp] as Array).append(g)
	Fixture.save_measure("calls", {"medians": med, "clips": per_clip, "pairs": table})


## The near-field ceiling of a voice, dB over its unit-distance level (the
## design's 6 dB; literal here, not read from the code under test).
const NEAR_BOOST_DB := 6.0


## Level of a call at distance d (world metres) as Godot plays it through a
## voice (CallVoices): loudness + clip gain, inverse distance from the unit
## distance, capped at the near-field ceiling, times the linear fade to the
## reach (fade = false leaves that out: VOICE.loud is the level at the
## unit distance before it). The random per-call offset (-1.5..+1 dB) is
## left out.
static func _heard_at(sp: StringName, f: Dictionary, d: float, fade: bool = true) -> float:
	var v: Dictionary = CallVoices.VOICE[sp]
	var vol := float(v["loud"]) - float(CallVoices.CALL_LOUDNESS.get(StringName(f["clip"]), f["loud_aw"]))
	var att := minf(vol + 20.0 * log(float(v["unit"]) / d) / log(10.0), minf(vol + NEAR_BOOST_DB, 0.0))
	var taper := 20.0 * log(maxf(1.0 - d / float(v["reach"]), 1e-5)) / log(10.0) if fade else 0.0
	return float(f["loud_aw"]) + att + taper


## Calls are balanced by loudness, not by peak. The table CallVoices levels
## the clips with is fresh (every clip measured here, A-weighted, loudest
## 0.4 s), every clip of a species plays equally loud, and at one common
## distance the small birds sit together (the synthesized starling
## whistles, 10-15 dB more energetic per dB of peak than the recordings,
## no longer tower over them), below the crows and gulls, below the
## raptors. This covers every clip through Godot's distance law on paper;
## test_calls_balance_holds_on_the_mixer renders the same balance.
func test_calls_are_balanced_by_loudness() -> void:
	var stale := []
	var table := PackedStringArray()
	for sp in SPECIES:
		for f: Dictionary in feats[sp]:
			var clip := StringName(f["clip"])
			var want: float = f["loud_aw"]
			table.append('&"%s": %.2f' % [clip, want])
			if not CallVoices.CALL_LOUDNESS.has(clip) or absf(float(CallVoices.CALL_LOUDNESS[clip]) - want) > 0.3:
				stale.append("%s %.2f" % [clip, want])
	if not stale.is_empty():
		print("[audio] CallVoices.CALL_LOUDNESS is stale; measured: {%s}" % ", ".join(table))
	eq(stale.size(), 0, "every clip's measured loudness matches CallVoices.CALL_LOUDNESS within 0.3 dB (%s)" % [stale])
	# The share of each species' loudness the air-absorption shelf acts on.
	var shares := PackedStringArray()
	var off_share := []
	for sp in SPECIES:
		var hf := _median(feats[sp], "hf_aw")
		shares.append('&"%s": %.2f' % [sp, hf])
		if absf(float(CallVoices.AIR_SHARE.get(sp, -1.0)) - hf) > 0.05:
			off_share.append("%s %.2f" % [sp, hf])
	if not off_share.is_empty():
		print("[audio] CallVoices.AIR_SHARE is stale; measured: {%s}" % ", ".join(shares))
	eq(off_share.size(), 0, "every species' share above %.0f Hz matches CallVoices.AIR_SHARE within 0.05 (%s)" % [CallVoices.AIR_SHELF_HZ, off_share])
	# At the unit distance every clip plays at its species' loudness, unless
	# that would take its gain over 0 dB (its -3 dBFS peak is the most one
	# voice may play at): such a quieter call type keeps its own level, and
	# is never more than 4 dB under its species.
	var off_level := []
	var capped := []
	for sp in SPECIES:
		var want: float = CallVoices.VOICE[sp]["loud"]
		for f: Dictionary in feats[sp]:
			var at_unit := _heard_at(sp, f, float(CallVoices.VOICE[sp]["unit"]), false)
			if float(f["loud_aw"]) < want:
				capped.append("%s %.1f" % [f["clip"], at_unit - want])
				if at_unit < want - 4.0:
					off_level.append("%s %.1f dB under" % [f["clip"], want - at_unit])
			elif absf(at_unit - want) > 0.5:
				off_level.append("%s %+.1f dB" % [f["clip"], at_unit - want])
	metric("gain_capped_clips", capped)
	eq(off_level.size(), 0, "every clip at its species' level at the unit distance (within 0.5 dB, or a capped quieter call within 4 dB) (%s)" % [off_level])
	# One common distance: 25 m, species medians.
	var at25 := {}
	for sp in SPECIES:
		if sp == &"moth":
			continue  # heard only within 5 m
		var lv := PackedFloat32Array()
		for f: Dictionary in feats[sp]:
			lv.append(_heard_at(sp, f, 25.0))
		at25[sp] = AudioAnalysis.median(lv)
	metric("calls_at_25m_aw_db", at25)
	var small := [&"wren", &"sparrow", &"swallow", &"starling", &"pigeon"]
	var s_lo := INF
	var s_hi := -INF
	var recorded_small_hi := -INF
	for sp in small:
		s_lo = minf(s_lo, at25[sp])
		s_hi = maxf(s_hi, at25[sp])
		if sp != &"starling" and sp != &"pigeon":
			recorded_small_hi = maxf(recorded_small_hi, at25[sp])
	lt(s_hi - s_lo, 6.0, "small and medium birds (wren..pigeon) within 6 dB of each other at 25 m (spread %.1f dB)" % (s_hi - s_lo))
	lt(float(at25[&"starling"]) - recorded_small_hi, 2.0, "synthesized starling whistles not louder than the recorded songbirds at 25 m (%.1f vs %.1f)" % [at25[&"starling"], recorded_small_hi])
	var mid := minf(at25[&"crow"], at25[&"gull"])
	gt(mid - s_hi, 3.0, "crows and gulls carry further than the small birds (%.1f vs %.1f)" % [mid, s_hi])
	gt(minf(at25[&"hawk"], at25[&"eagle"]) - maxf(at25[&"crow"], at25[&"gull"]), 1.0, "and the raptors furthest")
	Fixture.save_measure("call_balance", {"at_25m": at25})


## The loudest `secs` of a clip (around its loudest 0.4 s, A-weighted), as
## a mono 16-bit stream carrying the clip's name (so a voice gives it the
## clip's gain), with 5 ms fades where it was cut.
static func _loudest_segment(f: Dictionary, secs: float) -> AudioStreamWAV:
	var pcm: Dictionary = f["_pcm"]
	var mono: PackedFloat32Array = pcm["mono"]
	var rate: float = pcm["rate"]
	var at: float = f["loud_at"]
	var from := clampi(int((at - secs * 0.5) * rate), 0, maxi(0, mono.size() - int(secs * rate)))
	var seg := mono.slice(from, mini(mono.size(), from + int(secs * rate)))
	var fade := int(0.005 * rate)
	for i in mini(fade, seg.size()):
		var g := 0.5 - 0.5 * cos(PI * i / fade)
		seg[i] *= g
		seg[seg.size() - 1 - i] *= g
	var w := AudioSynth.make_wav(seg, PackedFloat32Array(), int(rate))
	w.set_meta(&"clip", StringName(f["clip"]))
	return w


## The balance above is Godot's distance law on paper. Round 3 found the
## mixer 10-27 dB away from it (AudioStreamPlayer3D's default air-absorption
## shelf deepens as volume_db falls, and the levelling lives in volume_db),
## so here the balance is rendered: each species' call through the
## director's own voice pool (_request -> _start: the real 3D players with
## their gains, ceilings, shelves and distances), straight ahead at its unit
## distance and at 25 m, every voice on a tap bus of its own so
## they render at once (the director's pool of 8 and two more of the same
## class: 24 voices, one take). The level is the loudest 0.4 s,
## A-weighted, both ears' power summed: the measure CALL_LOUDNESS and
## VOICE.loud are defined in. The stream is the loudest 0.5 s of the
## species' loudest clip (the one with the lowest volume_db, where a
## gain-driven filter bites hardest), named as that clip so it plays at
## that clip's gain.
func test_calls_balance_holds_on_the_mixer() -> void:
	var fx := Fixture.new()
	fx.build(self)
	await wait_frames(2)
	Game.set_state(Game.State.PLAYING)
	fx.set_tel({"airspeed": 0.0, "perched": true, "world_scale": 1.0})
	var voices := fx.director.voices
	voices.scheduling = false  # only this test's calls
	# Two more pools of the same class, so all 19 renders fit one take (24
	# voices). They are not ticked by a director: they get the listener (for
	# their air absorption) here; their birds do not move.
	var pools: Array[CallVoices] = [voices]
	for n in 2:
		var extra := CallVoices.new()
		fx.root.add_child(extra)
		extra.setup(fx.director.bank)
		extra.scheduling = false
		extra.listener = fx.listener.global_position
		extra.world_scale = 1.0
		pools.append(extra)
	var players: Array[CallVoices.Voice] = []
	for pool in pools:
		players.append_array(pool.voices)
	var caps := fx.tap_buses("AudioTestVoice", players.size(), AudioBuses.CALLS)
	for i in players.size():
		players[i].player.bus = "AudioTestVoice%d" % i
	var jobs := []  # [species, m, stream, clip]
	for sp in SPECIES:
		var best: Dictionary = {}
		for f: Dictionary in feats[sp]:
			if best.is_empty() or float(f["loud_aw"]) > float(best["loud_aw"]):
				best = f
		var seg := _loudest_segment(best, 0.5)
		jobs.append([sp, float(CallVoices.VOICE[sp]["unit"]), seg, best["clip"]])
		if sp != &"moth":  # heard only within 5 m
			jobs.append([sp, 25.0, seg, best["clip"]])
	var takes := []  # [job, recording]
	var i := 0
	while i < jobs.size():
		var batch := jobs.slice(i, i + players.size())
		i += batch.size()
		var birds: Array[Bird] = []
		for j in batch:
			birds.append(fx.add_npc(j[0], Vector3(0, 100, -float(j[1]))))
		await wait_frames(1)
		var job_of := {}  # player index -> job
		for k in batch.size():
			var j: Array = batch[k]
			var st: AudioStream = j[2]
			var pool: CallVoices = pools[k / CallVoices.MAX_VOICES]
			check(pool._request(birds[k], {"species": j[0], "stream": st, "kind": &"call", "prio": 100.0,
				"db": CallVoices.clip_gain_db(j[0], st), "pitch": 1.0}), "%s at %.1f m gets a voice" % [j[0], j[1]])
			for vi in players.size():
				if players[vi].bird == birds[k]:
					job_of[vi] = j
		# 0.55 s: the 0.5 s segment, started a mix block after the request.
		var recs := await fx.record_many(get_tree(), caps, 0.55)
		for vi in job_of:
			takes.append([job_of[vi], recs[vi]])
		for pool in pools:
			pool.stop_all()
		for b in birds:
			fx.npcs.erase(b)
			b.queue_free()
		await wait_frames(2)
	for v in players:
		v.player.bus = AudioBuses.CALLS
	fx.teardown()
	# Loudest 0.4 s A-weighted of each ear, both summed: on the worker pool.
	# (An Array: captured by reference, unlike a packed array.)
	var levels := []
	levels.resize(takes.size())
	var mutex := Mutex.new()
	var task := WorkerThreadPool.add_group_task(func(k: int) -> void:
		var rec: Dictionary = takes[k][1]
		var lv := AudioAnalysis.from_db(AudioAnalysis.loudness_aw(rec["l"], rec["rate"], 0.4)["max"])
		var rv := AudioAnalysis.from_db(AudioAnalysis.loudness_aw(rec["r"], rec["rate"], 0.4)["max"])
		# from_db is an amplitude ratio: squared for power.
		var level := 10.0 * log(maxf(lv * lv + rv * rv, 1e-30)) / log(10.0)
		mutex.lock()
		levels[k] = level
		mutex.unlock(), takes.size(), -1, true, "audio mixer calls")
	WorkerThreadPool.wait_for_group_task_completion(task)
	var got := {}  # species -> {clip, unit, at25}
	for k in takes.size():
		var j: Array = takes[k][0]
		var row: Dictionary = got.get(j[0], {"clip": j[3]})
		row["unit" if float(j[1]) < 24.9 or j[0] == &"moth" else "at25"] = float(levels[k])
		got[j[0]] = row
	# Each species at its unit distance plays at VOICE.loud; at both
	# distances the mixer matches audibility(), which ranks the voices.
	var table := {}
	for sp in SPECIES:
		var row: Dictionary = got.get(sp, {})
		var want: float = CallVoices.VOICE[sp]["loud"]
		var unit := float(CallVoices.VOICE[sp]["unit"])
		near(float(row.get("unit", -INF)), want, 1.5, "%s (%s) at its unit distance plays at its level on the mixer" % [sp, row.get("clip", "")])
		near(float(row.get("unit", -INF)), CallVoices.audibility(sp, unit), 1.0, "%s: audibility() matches the mixer at %.1f m" % [sp, unit])
		table[String(sp)] = {"clip": row.get("clip", ""), "unit_m": unit, "unit_db": row.get("unit", -INF), "loud": want,
			"model_unit_db": CallVoices.audibility(sp, unit)}
		if sp != &"moth":
			table[String(sp)]["at25_db"] = row.get("at25", -INF)
			table[String(sp)]["model25_db"] = CallVoices.audibility(sp, 25.0)
			near(float(row.get("at25", -INF)), CallVoices.audibility(sp, 25.0), 1.0, "%s: audibility() matches the mixer at 25 m" % sp)
	metric("calls_on_mixer_aw_db", table)
	# The balance, now on what the mixer plays.
	var small := [&"wren", &"sparrow", &"swallow", &"starling", &"pigeon"]
	var s_lo := INF
	var s_hi := -INF
	var rec_hi := -INF
	for sp in small:
		var v: float = got[sp]["at25"]
		s_lo = minf(s_lo, v)
		s_hi = maxf(s_hi, v)
		if sp != &"starling" and sp != &"pigeon":
			rec_hi = maxf(rec_hi, v)
	var mid := minf(got[&"crow"]["at25"], got[&"gull"]["at25"])
	var top := minf(got[&"hawk"]["at25"], got[&"eagle"]["at25"])
	metric("mixer_small_spread_25m_db", s_hi - s_lo)
	lt(s_hi - s_lo, 6.0, "on the mixer: wren..pigeon within 6 dB of each other at 25 m (spread %.1f dB)" % (s_hi - s_lo))
	lt(float(got[&"starling"]["at25"]) - rec_hi, 2.0, "on the mixer: the synthesized starling no louder than the recorded songbirds + 2 dB (%+.1f)" % (float(got[&"starling"]["at25"]) - rec_hi))
	gt(mid - s_hi, 3.0, "on the mixer: crows and gulls carry over the small birds (%.1f vs %.1f)" % [mid, s_hi])
	gt(top - maxf(got[&"crow"]["at25"], got[&"gull"]["at25"]), 1.0, "on the mixer: the raptors furthest")
	Fixture.save_measure("call_balance_mixer", table)


func test_recordings_are_trimmed_and_levelled() -> void:
	for sp in SPECIES:
		var i := 0
		for f: Dictionary in feats[sp]:
			var path: String = paths[sp][i]
			i += 1
			if path.is_empty():
				continue  # synthesized (starling, moth): see test_synth_clips
			var src := AudioStreamWAV.load_from_file(ProjectSettings.globalize_path(path))
			var tag := path.get_file()
			eq(src.stereo, false, "%s: mono (3D sources)" % tag)
			eq(src.mix_rate, 32000, "%s: 32 kHz" % tag)
			eq(src.format, AudioStreamWAV.FORMAT_16_BITS, "%s: 16-bit PCM" % tag)
			var pcm: Dictionary = f["_pcm"]
			var buf: PackedFloat32Array = pcm["mono"]
			var rate: float = pcm["rate"]
			near(AudioAnalysis.db(AudioAnalysis.peak(buf)), -3.0, 0.1, "%s: peak normalised to -3 dBFS" % tag)
			var env := AudioAnalysis.envelope(buf, rate, 0.01)
			var pk := 0.0
			for e in env:
				pk = maxf(pk, e)
			var first := 0
			while first < env.size() and env[first] < pk * AudioAnalysis.from_db(-30.0):
				first += 1
			var last := env.size() - 1
			while last > 0 and env[last] < pk * AudioAnalysis.from_db(-40.0):
				last -= 1
			lt(first * 0.01, 0.06, "%s: sound starts within 60 ms (trimmed)" % tag)
			lt((env.size() - 1 - last) * 0.01, 0.15, "%s: under 150 ms of trailing silence" % tag)
			lt(absf(buf[0]), 0.01, "%s: fades in (no click)" % tag)
			lt(absf(buf[buf.size() - 1]), 0.01, "%s: fades out (no click)" % tag)
			var mean := 0.0
			for x in buf:
				mean += x
			lt(absf(mean / buf.size()), 0.002, "%s: no DC offset" % tag)
			between(buf.size() / rate, 0.3, 3.5, "%s: 0.3-3.5 s" % tag)
	_check_endings()


## A call ends at a natural decay, not mid-note (round 5: 9 of 25 shipped
## cuts, 2 of the 3 hawk screams among them, stopped 3-20 dB under their
## loudest note, where a window of the source ended before the call did).
## The 50 ms before a clip's final 40 ms fade sit at least 20 dB under its
## loudest 50 ms: the last note has died away (call_prep's own trim ends a
## call once it has decayed 40 dB) or been given a release. Every species
## call, recorded or synthesized (the moth's flutter is a loop).
func _check_endings() -> void:
	var rows := {}
	for sp in SPECIES:
		if sp == &"moth":
			continue
		for f: Dictionary in feats[sp]:
			var pcm: Dictionary = f["_pcm"]
			var buf: PackedFloat32Array = pcm["mono"]
			var rate: float = pcm["rate"]
			var w := int(0.05 * rate)
			var loud := 0.0
			var i := 0
			while i + w <= buf.size():
				loud = maxf(loud, AudioAnalysis.rms(buf, i, i + w))
				i += w / 4
			var end_rms := AudioAnalysis.rms(buf, buf.size() - int(0.09 * rate), buf.size() - int(0.04 * rate))
			var rel := AudioAnalysis.db(end_rms) - AudioAnalysis.db(loud)
			rows[String(f["clip"])] = snappedf(rel, 0.1)
			lt(rel, -20.0, "%s: ends at a natural decay (the 50 ms before its end fade %.1f dB under its loudest 50 ms)" % [f["clip"], rel])
	metric("call_endings_db_re_loudest", rows)
	Fixture.save_measure("call_endings", rows)


func test_synth_clips_are_clean() -> void:
	var all := bank.all_streams()
	var n := 0
	for key in all:
		var w := all[key] as AudioStreamWAV
		if w == null or w.format != AudioStreamWAV.FORMAT_16_BITS or String(w.resource_path).begins_with("res://"):
			continue
		n += 1
		var d := AudioAnalysis.decode_wav(w)
		var pk := maxf(AudioAnalysis.peak(d["l"]), AudioAnalysis.peak(d["r"]))
		lt(AudioAnalysis.db(pk), -0.9, "%s: peak at or below -1 dBFS" % key)
		gt(AudioAnalysis.db(pk), -13.0, "%s: not silent (peak > -13 dBFS)" % key)
		if w.loop_mode == AudioStreamWAV.LOOP_FORWARD:
			# Seam: the jump from the last sample to the first is no bigger
			# than the clip's typical sample-to-sample step.
			var l: PackedFloat32Array = d["l"]
			var steps := PackedFloat32Array()
			for i in range(1, l.size(), 7):
				steps.append(absf(l[i] - l[i - 1]))
			var seam := absf(l[0] - l[l.size() - 1])
			lt(seam, AudioAnalysis.percentile(steps, 0.999) + 1e-4, "%s: seamless loop" % key)
		else:
			var l2: PackedFloat32Array = d["l"]
			lt(absf(l2[l2.size() - 1]), 0.01, "%s: one-shot ends silent" % key)
	gt(n, 30.0, "all synthesized clips checked")
