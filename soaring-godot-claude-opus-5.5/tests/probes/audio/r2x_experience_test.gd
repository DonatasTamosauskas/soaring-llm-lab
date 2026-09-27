extends TestCase
## Round-2 verifier probes (experience & requirements lens) for the audio
## area. They try to break the claims the way a player and a demanding game
## director would meet them:
##  * the predator screech (DESIGN: "danger (predator screech getting
##    louder)") for the smallest player, where hawks are the main threat;
##  * loudness balance of the species calls at equal distance (a flock of
##    synthesized whistles must not drown the recorded birds);
##  * whether the sparrow "chirp" check can tell a chirp from filtered noise;
##  * the wind (the main speed cue) against the ambience near the ground;
##  * music when pausing straight from flight (the common case), and the
##    menu balance of music vs UI clicks;
##  * cost with a crowded sky at the smallest scale;
##  * headroom with two catches in quick succession.
## Measurements go to artifacts/audio/verify/r2x/measurements.json.

const Fixture := preload("res://tests/unit/audio/audio_fixture.gd")
## WorldScaleDriver.target_scale for a sparrow with the default 1.5 m arm
## span: span / (arm_span + 0.2) = 0.24 / 1.7.
const SPARROW_WS := 0.24 / 1.7

const OCTAVES: Array[float] = [125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0]

var fx: Fixture
var _saved := {}
var _out := {}
var _plot_series: Array = []


func before_all() -> void:
	DirAccess.make_dir_recursive_absolute(Paths.artifacts("audio/verify/r2x"))
	for k in AudioBuses.SETTING_DEFAULT:
		_saved[k] = Settings.get_value(k, AudioBuses.SETTING_DEFAULT[k])
		# Shipped defaults for every probe (tests elsewhere may have left
		# other values in user://).
		Settings.set_value(k, AudioBuses.SETTING_DEFAULT[k])


func after_all() -> void:
	for k in _saved:
		Settings.set_value(k, _saved[k])
	var dir := Paths.artifacts("audio/verify/r2x")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join("measurements.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(_out, "  ", true))
	f.close()
	await Fixture.wait(get_tree(), 0.3)


func before_each() -> void:
	fx = Fixture.new()
	fx.build(self)
	await wait_frames(2)


func after_each() -> void:
	fx.teardown()
	await Fixture.wait(get_tree(), 0.1)


# ------------------------------------------------------------ helpers ---

## Per-bin A-weighting (power), IEC 61672, the same curve as
## AudioAnalysis.a_weighted_db.
static func _a_weights(n: int, rate: float) -> PackedFloat32Array:
	var w := PackedFloat32Array()
	w.resize(n / 2 + 1)
	for i in w.size():
		var f := i * rate / n
		if f < 10.0:
			w[i] = 0.0
			continue
		var f2 := f * f
		var ra := 148693636.0 * f2 * f2 / ((f2 + 424.36) * sqrt((f2 + 11599.29) * (f2 + 544496.41)) * (f2 + 148693636.0))
		w[i] = ra * ra * 1.5849
	return w


## A-weighted power of each STFT frame (1024, hop 512; magnitudes scaled so a
## full-scale sine reads 1.0): one number per 16 ms at 32 kHz.
static func _aw_frames(buf: PackedFloat32Array, rate: float) -> PackedFloat32Array:
	var w := _a_weights(1024, rate)
	var out := PackedFloat32Array()
	for fr in AudioAnalysis.stft(buf, 1024, 512):
		var s := 0.0
		for i in fr.size():
			s += fr[i] * fr[i] * w[i]
		out.append(s)
	return out


static func _pdb(p: float) -> float:
	return 10.0 * log(maxf(p, 1e-30)) / log(10.0)


## {max: loudest `win` s window, mean: whole buffer}, A-weighted dB.
static func _aw_level(buf: PackedFloat32Array, rate: float, win: float = 0.4) -> Dictionary:
	var fp := _aw_frames(buf, rate)
	if fp.is_empty():
		return {"max": -INF, "mean": -INF}
	var per := maxi(1, int(round(win * rate / 512.0)))
	var total := 0.0
	for v in fp:
		total += v
	var best := 0.0
	var acc := 0.0
	for k in fp.size():
		acc += fp[k]
		if k >= per:
			acc -= fp[k - per]
		best = maxf(best, acc / mini(per, k + 1))
	return {"max": _pdb(best), "mean": _pdb(total / fp.size())}


# ---------------------------------------------------- predator screech ---

## Fires a rising threat edge through 0.6 for `bird` and reports whether the
## director's "screech" cue fired.
func _edge(bird: Bird, lo: float, hi: float, cues: Array) -> bool:
	var before := cues.count(&"screech")
	Events.threat_changed.emit(lo, bird)
	await wait_frames(2)
	Events.threat_changed.emit(hi, bird)
	await wait_frames(2)
	return cues.count(&"screech") > before


## DESIGN.md: "danger (predator screech getting louder)"; CallVoices:
## "A predator closing in on the player is always heard". For a
## sparrow-sized player (world_scale 0.141) a hawk's reach (300 perceived m)
## is 42 m of world. ThreatWatch crosses 0.6 at a time-to-contact of 1.4 s
## (horizon 3.5 s, aimed), i.e. ~45-60 m out for a hawk stooping at 30-44
## m/s. The scream must not be dropped there, and a dropped attempt must not
## use up the cooldown for the rest of the attack.
func test_small_player_hears_the_predator_scream() -> void:
	Game.set_state(Game.State.PLAYING)
	fx.set_tel({"world_scale": SPARROW_WS, "airspeed": 9.0})
	await wait_frames(3)
	var cues: Array = []
	fx.director.cue.connect(func(n: StringName, _i: Dictionary) -> void: cues.append(n))
	var res := {}
	for dist in [20.0, 35.0, 50.0, 65.0]:
		fx.director._screech_cool = 0.0
		var hawk := fx.add_npc(&"hawk", Vector3(0, 100, -dist))
		await wait_frames(2)
		var heard := await _edge(hawk, 0.3, 0.65, cues)
		res["%d m" % int(dist)] = {"screech": heard, "perceived_m": fx.director.voices.perceived_distance(hawk.get_body_position())}
		Events.threat_changed.emit(0.0, null)
		fx.director.voices.stop_all()
		fx.npcs.erase(hawk)
		hawk.queue_free()
		await wait_frames(3)
	_out["screech_by_distance_sparrow_player"] = res
	metric("screech_by_distance", res)
	check(res["20 m"]["screech"], "hawk 20 m away: screams at the 0.6 crossing")
	check(res["35 m"]["screech"], "hawk 35 m away: screams at the 0.6 crossing")
	check(res["50 m"]["screech"], "hawk 50 m away (a stoop's 0.6 crossing for a sparrow player): screams")
	check(res["65 m"]["screech"], "hawk 65 m away (fast stoop): screams")
	# The attack goes on: the hawk that was too far at the crossing is now
	# 12 m away and the threat rises again within the 5 s cooldown.
	fx.director._screech_cool = 0.0
	var hawk2 := fx.add_npc(&"hawk", Vector3(0, 100, -55))
	await wait_frames(2)
	var first := await _edge(hawk2, 0.3, 0.65, cues)
	hawk2.global_position = Vector3(0, 100, -12)
	Events.threat_changed.emit(0.55, hawk2)
	await wait_frames(2)
	var second := await _edge(hawk2, 0.55, 0.9, cues)
	_out["screech_retry"] = {"first_at_55m": first, "then_at_12m": second, "cooldown_left": fx.director._screech_cool}
	check(first or second, "a hawk stooping from 55 m to 12 m screams at least once during the attack")
	Events.threat_changed.emit(0.0, null)


# ------------------------------------------------------- call balance ---

## Every call at the level CallVoices gives it, measured A-weighted over its
## loudest 0.4 s: at the species' own unit distance and at one common
## perceived distance (25 m). A director expects the small songbirds to sit
## together and the synthesized starling whistles not to tower over the
## recorded birds of the same size.
func test_call_loudness_balance_at_equal_distance() -> void:
	var bank := fx.director.bank
	var table := {}
	var at25 := {}
	for sp in CallVoices.VOICE:
		var levels := PackedFloat32Array()
		for st in bank.calls_for(sp):
			var d := AudioAnalysis.clip_pcm(st)
			if d.is_empty():
				continue
			levels.append(_aw_level(d["mono"], d["rate"])["max"])
		if levels.is_empty():
			continue
		var med := AudioAnalysis.median(levels)
		var v: Dictionary = CallVoices.VOICE[sp]
		# Mean of the per-call random offset randf_range(-1.5, 1.0).
		var at_unit := med + float(v["db"]) - 0.25
		var common := CallVoices.audibility(sp, 25.0) - float(v["db"]) + at_unit
		table[String(sp)] = {"clip_aw_max_db": med, "at_unit_db": at_unit, "unit_m": v["unit"], "at_25m_db": common,
			"per_clip": Array(levels)}
		at25[String(sp)] = common
	_out["call_balance"] = table
	metric("calls_at_25m_aw_db", at25)
	print("[audio] r2x call loudness at 25 perceived m (A-weighted, dB): %s" % [at25])
	var small := ["wren", "sparrow", "swallow"]
	var small_max := -INF
	for s in small:
		small_max = maxf(small_max, float(at25[s]))
	lt(float(at25["starling"]) - small_max, 6.0, "starling whistles at most 6 dB louder than the loudest recorded small bird at 25 m (%.1f vs %.1f)" % [at25["starling"], small_max])
	var lo := INF
	var hi := -INF
	for s in ["wren", "sparrow", "swallow", "starling", "pigeon"]:
		lo = minf(lo, float(at25[s]))
		hi = maxf(hi, float(at25[s]))
	lt(hi - lo, 10.0, "small/medium birds (wren..pigeon) within 10 dB of each other at 25 m (spread %.1f dB)" % (hi - lo))


# ------------------------------------------------------- sparrow chirp ---

## A band-passed noise burst train, no tone at all: does it pass the suite's
## "sparrow chirp" character check? And where do the shipped sparrow cuts sit
## between that noise and the tonal recordings?
func test_sparrow_chirp_is_not_just_noise() -> void:
	var rate := 32000.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var n := int(0.9 * rate)
	var noise := AudioSynth.white(n, rng)
	noise = AudioSynth.filter(noise, [AudioSynth.hp(2800.0, 0.707, rate), AudioSynth.hp(2800.0, 0.707, rate),
		AudioSynth.lp(5500.0, 0.707, rate), AudioSynth.lp(5500.0, 0.707, rate)])
	# Three 120 ms bursts over a -12 dB bed (like a noisy field cut).
	var env := PackedFloat32Array()
	env.resize(n)
	for i in n:
		var t := i / rate
		var e := 0.25
		for c in [0.1, 0.4, 0.7]:
			var x: float = (t - c) / 0.06
			e = maxf(e, exp(-x * x))
		env[i] = e
	noise = AudioSynth.apply(noise, env)
	noise = AudioSynth.normalize(AudioSynth.fade(noise, 0.005, 0.02, rate), -3.0)
	var f := AudioAnalysis.features(noise, rate)
	var passes: bool = f["dominant"] >= 2500.0 and f["dominant"] <= 6000.0 and f["syl_len"] >= 0.05 and f["syl_len"] <= 0.3 \
		and f["note_rate"] >= 1.0 and f["note_rate"] <= 8.0
	var bank := fx.director.bank
	var tone := {}
	for sp in [&"sparrow", &"wren", &"swallow", &"crow", &"gull", &"hawk", &"eagle", &"pigeon", &"starling"]:
		var arr := []
		for st in bank.calls_for(sp):
			var d := AudioAnalysis.clip_pcm(st)
			if not d.is_empty():
				var g := AudioAnalysis.features(d["mono"], d["rate"])
				# How far the quiet parts of the cut sit under its calls: the
				# 10th vs 90th percentile of the 10 ms envelope inside the
				# active range, dB (a clean call in silence is 30+ dB).
				var e2 := AudioAnalysis.envelope(d["mono"], d["rate"], 0.01)
				var floor_db := AudioAnalysis.db(AudioAnalysis.percentile(e2, 0.1) / maxf(AudioAnalysis.percentile(e2, 0.9), 1e-9))
				arr.append({"tonality": g["tonality"], "flatness": g["flatness"], "floor_db": floor_db})
		tone[String(sp)] = arr
	_out["sparrow_vs_noise"] = {"noise_features": {"dominant": f["dominant"], "syl_len": f["syl_len"], "note_rate": f["note_rate"],
		"tonality": f["tonality"], "flatness": f["flatness"]}, "noise_passes_sparrow_check": passes, "clips": tone}
	metric("noise_passes_sparrow_check", passes)
	metric("noise_tonality", f["tonality"])
	print("[audio] r2x band-passed noise: dom %.0f Hz, syl %.3f s, notes %.1f/s, tonality %.3f -> passes sparrow check: %s" % [
		f["dominant"], f["syl_len"], f["note_rate"], f["tonality"], passes])
	for sp in tone:
		var ts := []
		for c in tone[sp]:
			ts.append("t%.2f f%.2f floor%.0f" % [c["tonality"], c["flatness"], c["floor_db"]])
		print("[audio] r2x   %s: %s" % [sp, ts])
	check(not passes, "the suite's sparrow 'chirp' character check rejects band-passed noise bursts")
	for c in tone["sparrow"]:
		gt(float(c["tonality"]), float(f["tonality"]) * 2.0, "each sparrow cut is clearly more tonal than filtered noise (%.2f vs %.2f)" % [c["tonality"], f["tonality"]])
		lt(float(c["floor_db"]), -15.0, "each sparrow cut: gaps sit >= 15 dB under the chirps (%.1f dB)" % c["floor_db"])


# ------------------------------------------- wind vs ambience (speed cue) ---

## Near the ground (4 m) in each zone, the Wind bus and the Ambience bus over
## the same stretch, A-weighted, at 0.7x / 1.0x / 1.4x cruise (sparrow).
func test_wind_speed_cue_over_ambience_near_ground() -> void:
	Game.set_state(Game.State.PLAYING)
	var marks: Array[Dictionary] = [
		{"name": "wood", "kind": "forest", "position": Vector3(0, 0, 0), "radius": 150.0},
		{"name": "lake", "kind": "lake", "position": Vector3(1000, 0, 0), "radius": 150.0},
		{"name": "village", "kind": "town", "position": Vector3(0, 0, 1000), "radius": 150.0},
		{"name": "meadow", "kind": "meadow", "position": Vector3(-1000, 0, 0), "radius": 150.0},
	]
	fx.add_world(marks)
	var wind := fx.tap(AudioBuses.WIND)
	var amb := fx.tap(AudioBuses.AMBIENCE)
	var cruise := FlightSoundMap.cruise(0.03)
	var res := {}
	var worst_cruise := INF
	# Beds only: the church bell (tested on its own below) must not land in
	# the village window.
	fx.director.ambience._bell_next = 1e12
	for zone in [["forest", Vector3(0, 4, 0)], ["lake", Vector3(1000, 4, 0)], ["village", Vector3(0, 4, 1000)], ["meadow", Vector3(-1000, 4, 0)]]:
		fx.listener.global_position = zone[1]
		fx.player.global_position = zone[1]
		fx.director.ambience.set_world(fx.world)
		await Fixture.wait(get_tree(), 3.5)  # beds crossfade (tau 1.2 s)
		var row := {}
		for r in [0.7, 1.0, 1.4]:
			fx.set_tel({"airspeed": cruise * r, "tucked": false, "wing_extension": 1.0})
			await Fixture.wait(get_tree(), 0.4)
			var pair := await fx.record2(get_tree(), wind, amb, 1.5)
			var w := _aw_level(pair[0]["mono"], pair[0]["rate"], 0.4)
			var a := _aw_level(pair[1]["mono"], pair[1]["rate"], 0.4)
			var rate: float = pair[0]["rate"]
			var pw := AudioAnalysis.mean_power(pair[0]["mono"], 2048, 1024, -90.0)
			var pa := AudioAnalysis.mean_power(pair[1]["mono"], 2048, 1024, -90.0)
			# Octave bands where the wind stands above the bed (a rumble can
			# stay audible under a brighter bed that is louder overall).
			var bands := {}
			var above := 0
			var lws := PackedFloat32Array()
			var las := PackedFloat32Array()
			for fc in OCTAVES:
				var bw := AudioAnalysis.band_fraction(pw, rate, fc / sqrt(2.0), fc * sqrt(2.0))
				var ba := AudioAnalysis.band_fraction(pa, rate, fc / sqrt(2.0), fc * sqrt(2.0))
				var lw := _pdb(bw * pow(10.0, AudioAnalysis.db(AudioAnalysis.rms(pair[0]["mono"])) / 10.0))
				var la := _pdb(ba * pow(10.0, AudioAnalysis.db(AudioAnalysis.rms(pair[1]["mono"])) / 10.0))
				bands["%d" % int(fc)] = snappedf(lw - la, 0.1)
				lws.append(lw)
				las.append(la)
				if lw > la:
					above += 1
			if r == 1.0:
				_plot_series.append({"name": "%s bed" % zone[0], "x": PackedFloat32Array(OCTAVES), "y": las})
				if zone[0] == "forest":
					_plot_series.push_front({"name": "wind at cruise (sparrow)", "x": PackedFloat32Array(OCTAVES), "y": lws})
			row["%.1fx" % r] = {"wind_aw": w["mean"], "amb_aw": a["mean"], "margin_db": w["mean"] - a["mean"],
				"wind_rms": AudioAnalysis.db(AudioAnalysis.rms(pair[0]["mono"])), "amb_rms": AudioAnalysis.db(AudioAnalysis.rms(pair[1]["mono"])),
				"octave_margin_db": bands, "octaves_wind_above": above}
			if r == 1.0:
				worst_cruise = minf(worst_cruise, w["mean"] - a["mean"])
		res[zone[0]] = row
		print("[audio] r2x %s @4 m: %s" % [zone[0], row])
	_out["wind_vs_ambience_4m"] = res
	metric("wind_over_ambience_at_cruise_worst_db", worst_cruise)
	var img := AudioPlot.chart("R2 VERIFY: WIND AT CRUISE VS AMBIENCE BEDS, 4 M UP", _plot_series, {
		"x_label": "OCTAVE BAND HZ", "y_label": "BAND LEVEL DB (BUS TAPS)", "log_x": true,
		"note": "MEASURED ON THE MIXER (WIND BUS, AMBIENCE BUS), SPARROW AT 9 M/S, BELL OFF. BEDS ABOVE THE WIND = SPEED CUE MASKED."})
	img.save_png(Paths.artifacts("audio/verify/r2x").path_join("wind_vs_ambience_octaves.png"))
	# The main speed cue: gliding at cruise, the wind is at least as loud to
	# the ear as the zone's ambience bed.
	gt(worst_cruise, 0.0, "at cruise 4 m up, the wind is not quieter (A-weighted) than the ambience in any zone (worst %.1f dB)" % worst_cruise)


## The village bell in 3D: how loud is a stroke when the player flies round
## the church (the belfry is one of the world's showcase flythroughs), next
## to a tucked dive's wind (Wind bus about -22 dBFS RMS) and the catch
## crunch (peak about -10 dBFS)?
func test_church_bell_level_near_the_tower() -> void:
	Game.set_state(Game.State.PLAYING)
	var marks: Array[Dictionary] = [
		{"name": "village", "kind": "town", "position": Vector3(0, 0, 0), "radius": 130.0},
		{"name": "church_spire", "kind": "landmark", "position": Vector3(0, 25, 0), "radius": 4.0},
	]
	fx.add_world(marks)
	var amb := fx.tap(AudioBuses.AMBIENCE)
	var res := {}
	for d in [8.0, 30.0, 80.0]:
		var p := Vector3(d, 25, 0)
		fx.listener.global_position = p
		fx.player.global_position = p
		fx.director.ambience.set_world(fx.world)
		await Fixture.wait(get_tree(), 0.6)
		# Toll now (three strokes 2.3 s apart); measure the first stroke.
		fx.director.ambience._bell_next = 0.0
		var rec := await fx.record(get_tree(), amb, 2.2)
		var pk := AudioAnalysis.db(maxf(AudioAnalysis.peak(rec["l"]), AudioAnalysis.peak(rec["r"])))
		var rms := AudioAnalysis.db(AudioAnalysis.rms(rec["mono"]))
		res["%d m" % int(d)] = {"peak_dbfs": pk, "rms_dbfs": rms}
		# Let the toll finish and re-arm far in the future.
		await Fixture.wait(get_tree(), 5.2)
		fx.director.ambience._bell_next = 1e12
	_out["bell_levels_ambience_bus"] = res
	print("[audio] r2x church bell on the Ambience bus: %s" % [res])
	var xs := PackedFloat32Array([8.0, 30.0, 80.0])
	var pks := PackedFloat32Array()
	var rmss := PackedFloat32Array()
	for k in ["8 m", "30 m", "80 m"]:
		pks.append(res[k]["peak_dbfs"])
		rmss.append(res[k]["rms_dbfs"])
	var img := AudioPlot.chart("R2 VERIFY: CHURCH BELL STROKE VS DISTANCE", [
		{"name": "bell peak (ambience bus)", "x": xs, "y": pks, "dots": true},
		{"name": "bell rms over the stroke", "x": xs, "y": rmss, "dots": true}],
		{"x_label": "DISTANCE TO THE CHURCH_SPIRE LANDMARK M", "y_label": "DBFS", "y_min": -40.0, "y_max": 3.0,
		"hlines": [{"y": AudioBuses.CEILING_DB, "label": "limiter ceiling -1.5"}, {"y": -5.0, "label": "caught stinger peak"},
			{"y": -10.0, "label": "catch crunch peak"}, {"y": -21.8, "label": "tucked dive wind rms"}],
		"note": "AMBIENCEZONES._BELL: VOLUME -6 DB AT UNIT 60 M, MAX_DB LEFT AT GODOT'S DEFAULT +3 DB."})
	img.save_png(Paths.artifacts("audio/verify/r2x").path_join("bell_vs_distance.png"))
	lt(float(res["8 m"]["peak_dbfs"]), -6.0, "a bell stroke 8 m away peaks under -6 dBFS on the Ambience bus (%.1f)" % res["8 m"]["peak_dbfs"])
	lt(float(res["30 m"]["rms_dbfs"]), -22.0, "a bell 30 m away is not louder (RMS) than a tucked dive's wind (%.1f dBFS)" % res["30 m"]["rms_dbfs"])


## Heavy play (the suite's scenario) flying past the church as the bell
## tolls: AUDIO.md claims heavy play peaks at -4.2 dBFS and the limiter
## never acts in real play.
func test_heavy_play_by_the_church_bell() -> void:
	Game.set_state(Game.State.PLAYING)
	var marks: Array[Dictionary] = [
		{"name": "village", "kind": "town", "position": Vector3(0, 0, 0), "radius": 130.0},
		{"name": "church_spire", "kind": "landmark", "position": Vector3(0, 25, 0), "radius": 4.0},
	]
	fx.add_world(marks)
	var p := Vector3(20, 20, 0)
	fx.listener.global_position = p
	fx.player.global_position = p
	fx.set_tel({"airspeed": 23.0, "tucked": true, "wing_extension": 0.1})
	var hawk := fx.add_npc(&"hawk", p + Vector3(0, 6, 15))
	var prey := fx.add_npc(&"sparrow", p + Vector3(0, 0, -1))
	Events.threat_changed.emit(0.8, hawk)
	fx.director.ambience.set_world(fx.world)
	await Fixture.wait(get_tree(), 0.8)
	var pre := fx.tap(AudioBuses.MASTER, 0)
	var post := fx.tap(AudioBuses.MASTER)
	var driver := Timer.new()
	driver.wait_time = 0.35
	fx.root.add_child(driver)
	var n := [0]
	driver.timeout.connect(func() -> void:
		n[0] += 1
		Events.player_flapped.emit(0, 1.0)
		if n[0] == 3:
			Events.bird_caught.emit(fx.player, prey))
	fx.director.ambience._bell_next = 0.0
	driver.start()
	var recs := await fx.record2(get_tree(), pre, post, 2.0)
	driver.stop()
	var a: Dictionary = recs[0]
	var b: Dictionary = recs[1]
	var pre_pk := AudioAnalysis.db(maxf(AudioAnalysis.peak(a["l"]), AudioAnalysis.peak(a["r"])))
	var post_pk := AudioAnalysis.db(maxf(AudioAnalysis.peak(b["l"]), AudioAnalysis.peak(b["r"])))
	var ea := AudioAnalysis.envelope(a["mono"], a["rate"], 0.02)
	var eb := AudioAnalysis.envelope(b["mono"], b["rate"], 0.02)
	var gr := 0.0
	for i in mini(ea.size(), eb.size()):
		if ea[i] > 1e-6 and eb[i] > 1e-6:
			gr = maxf(gr, AudioAnalysis.db(ea[i]) - AudioAnalysis.db(eb[i]))
	_out["heavy_play_by_bell"] = {"pre_peak_dbfs": pre_pk, "post_peak_dbfs": post_pk, "max_gain_reduction_db_20ms": gr}
	print("[audio] r2x heavy play by the bell: pre-limiter peak %.1f dBFS, output peak %.1f dBFS, limiter gain reduction up to %.1f dB" % [pre_pk, post_pk, gr])
	lt(post_pk, -1.0, "output still under -1 dBFS (the limiter holds)")
	lt(pre_pk, AudioBuses.CEILING_DB, "heavy play by the church stays under the limiter ceiling (%.1f dBFS)" % pre_pk)
	Fixture.save_render(b, "../verify/r2x/heavy_play_by_bell_output")
	Events.threat_changed.emit(0.0, null)


# ----------------------------------------------------------- music/menu ---

## The usual way into the pause menu is from flight. The music must come up
## there too (the suite only checks MENU -> PAUSED). Also: in the main menu,
## how far do UI clicks stand over the music?
func test_music_after_pausing_from_flight_and_menu_balance() -> void:
	var music_cap := fx.tap(AudioBuses.MUSIC)
	var master := fx.tap(AudioBuses.MASTER)
	Game.set_state(Game.State.PLAYING)
	await Fixture.wait(get_tree(), 2.0)  # music faded out (1.5 s) and paused
	Game.set_state(Game.State.PAUSED)
	await Fixture.wait(get_tree(), 1.0)
	var p1 := await fx.record(get_tree(), music_cap, 0.6)
	await Fixture.wait(get_tree(), 1.0)
	var p2 := await fx.record(get_tree(), music_cap, 0.6)
	var m1 := AudioAnalysis.db(AudioAnalysis.rms(p1["mono"]))
	var m2 := AudioAnalysis.db(AudioAnalysis.rms(p2["mono"]))
	_out["music_after_pause_from_flight"] = {"t1_db": m1, "t2_db": m2, "music_db": fx.director._music_db}
	print("[audio] r2x music after pausing from flight: %.1f dBFS at 1 s, %.1f dBFS at 2.6 s" % [m1, m2])
	gt(m2, -40.0, "music audible in pause entered from flight (%.1f dBFS)" % m2)
	# Menu: music alone, then a click and a select over it.
	Game.set_state(Game.State.MENU)
	await Fixture.wait(get_tree(), 2.5)
	var quiet := await fx.record(get_tree(), master, 1.0)
	master.clear_buffer()
	fx.director.play_ui(&"click")
	var with_click := await fx.record(get_tree(), master, 0.15)
	fx.director.play_ui(&"select")
	var with_sel := await fx.record(get_tree(), master, 0.15)
	var mq := _aw_level(quiet["mono"], quiet["rate"], 0.1)
	var mc := _aw_level(with_click["mono"], with_click["rate"], 0.1)
	var ms := _aw_level(with_sel["mono"], with_sel["rate"], 0.1)
	var master_fader := AudioBuses.volume_to_db(AudioBuses.setting_value(AudioBuses.MASTER))
	_out["menu_balance"] = {"music_rms_dbfs_out": AudioAnalysis.db(AudioAnalysis.rms(quiet["mono"])) + master_fader,
		"music_aw_mean": mq["mean"], "click_aw_max": mc["max"], "select_aw_max": ms["max"],
		"click_over_music_db": mc["max"] - mq["mean"], "select_over_music_db": ms["max"] - mq["mean"]}
	print("[audio] r2x menu: music %.1f dBFS RMS at the output; click +%.1f dB, select +%.1f dB over it (A-weighted, 0.1 s)" % [
		_out["menu_balance"]["music_rms_dbfs_out"], mc["max"] - mq["mean"], ms["max"] - mq["mean"]])


# ------------------------------------------------------------------ cost ---

## A crowded sky at the smallest scale: 150 birds within 40 m (world), the
## player a sparrow (everything in perceived reach is 7x farther), flight
## changing every frame, flaps, threats, zones.
func test_cost_crowded_sky_small_player() -> void:
	Game.set_state(Game.State.PLAYING)
	var rng := RandomNumberGenerator.new()
	rng.seed = 21
	var marks: Array[Dictionary] = []
	for i in 60:
		var kinds := ["forest", "lake", "town", "meadow", "field", "orchard", "farm", "hedge", "cliff", "river"]
		marks.append({"name": "m%d" % i, "kind": kinds[i % kinds.size()], "radius": rng.randf_range(20, 150),
			"position": Vector3(rng.randf_range(-300, 300), 0, rng.randf_range(-300, 300))})
	fx.add_world(marks)
	fx.listener.global_position = Vector3(0, 6, 0)
	fx.player.global_position = Vector3(0, 6, 0)
	fx.set_tel({"world_scale": SPARROW_WS})
	var species := [&"moth", &"wren", &"sparrow", &"swallow", &"starling", &"starling", &"pigeon", &"crow", &"gull", &"hawk", &"eagle"]
	var birds: Array[Bird] = []
	for i in 150:
		var a := rng.randf() * TAU
		var d := rng.randf_range(1.0, 40.0)
		birds.append(fx.add_npc(species[i % species.size()], Vector3(cos(a) * d, 6.0 + rng.randf_range(-4, 8), sin(a) * d)))
	await Fixture.wait(get_tree(), 0.5)
	fx.director.reset_perf()
	for frame in 300:
		var t := frame / 60.0
		fx.set_tel({"airspeed": 9.0 + 8.0 * sin(t), "tucked": sin(t) > 0.5, "wing_extension": 0.5 + 0.5 * cos(t),
			"stalled": frame % 97 < 10, "in_updraft": maxf(0.0, 3.0 * sin(t * 0.7)), "world_scale": SPARROW_WS})
		fx.player.velocity = Vector3(sin(t), 0, -cos(t)) * 9.0
		if frame % 15 == 0:
			Events.player_flapped.emit([-1, 0, 1][frame % 3], 0.9)
		if frame % 20 == 0:
			Events.threat_changed.emit(absf(sin(t)), birds[9])
		for b in birds:
			b.global_position += Vector3(0.04, 0, 0).rotated(Vector3.UP, t + b.get_instance_id() % 7)
		await get_tree().process_frame
	var st := fx.director.perf_stats()
	var best := INF
	for block in 5:
		var t0 := Time.get_ticks_usec()
		for i in 200:
			fx.director._process(1.0 / 72.0)
		best = minf(best, (Time.get_ticks_usec() - t0) / 200.0 / 1000.0)
	_out["cost_150_birds"] = {"stats": st, "tight_loop_ms": best, "voices_stats": fx.director.voices.stats.duplicate(),
		"max_active_now": fx.director.voices.active_count()}
	print("[audio] r2x cost 150 birds @ws %.3f: median %.3f p95 %.3f trimmed %.3f max %.3f ms, tight %.3f ms, voice stats %s" % [
		SPARROW_WS, st["median"], st["p95"], st["trimmed"], st["max"], best, fx.director.voices.stats])
	lt(st["median"], 0.25, "median frame cost < 0.25 ms with 150 birds (-> < 1 ms on Quest)")
	lt(best, 0.15, "tight-loop _process < 0.15 ms with 150 birds")
	lt(fx.director.voices.active_count(), CallVoices.MAX_VOICES + 1, "voice cap holds")
	Events.threat_changed.emit(0.0, null)


# -------------------------------------------------------------- headroom ---

## Heavy play as the suite stages it, but a sweep through two prey in quick
## succession (two catches 50 ms apart) instead of one. AUDIO.md claims the
## limiter never acts in real play.
func test_two_quick_catches_in_heavy_play() -> void:
	Game.set_state(Game.State.PLAYING)
	var marks: Array[Dictionary] = [
		{"name": "f", "kind": "forest", "position": Vector3(0, 0, 0), "radius": 200.0},
		{"name": "l", "kind": "lake", "position": Vector3(60, 0, 0), "radius": 100.0},
	]
	fx.add_world(marks)
	fx.listener.global_position = Vector3(0, 6, 0)
	fx.player.global_position = Vector3(0, 6, 0)
	fx.set_tel({"airspeed": 23.0, "tucked": true, "wing_extension": 0.1, "in_updraft": 2.0})
	var callers := [fx.add_npc(&"crow", Vector3(10, 8, -5)), fx.add_npc(&"sparrow", Vector3(-12, 5, 8)), fx.add_npc(&"gull", Vector3(5, 20, 20))]
	var prey := [fx.add_npc(&"moth", Vector3(0, 6, -1)), fx.add_npc(&"wren", Vector3(0, 6, -1.5))]
	var hawk := fx.add_npc(&"hawk", Vector3(0, 12, 15))
	Events.threat_changed.emit(0.8, hawk)
	await Fixture.wait(get_tree(), 0.8)
	var pre := fx.tap(AudioBuses.MASTER, 0)
	var worst := -INF
	var runs := []
	for trial in 4:
		pre.clear_buffer()
		var frames := PackedVector2Array()
		var t_end := Time.get_ticks_msec() + 1200
		var fired := 0
		var t0 := Time.get_ticks_msec()
		while Time.get_ticks_msec() < t_end:
			var el := Time.get_ticks_msec() - t0
			if fired == 0 and el > 200:
				Events.player_flapped.emit(0, 1.0)
				fx.director.voices.request_call(callers[trial % 3], 20.0)
				fired = 1
			if fired == 1 and el > 300 + trial * 20:
				Events.bird_caught.emit(fx.player, prey[0])
				fired = 2
			if fired == 2 and el > 350 + trial * 20:
				Events.bird_caught.emit(fx.player, prey[1])
				Events.player_flapped.emit(0, 1.0)
				fired = 3
			await get_tree().process_frame
			var n := pre.get_frames_available()
			if n > 0:
				frames.append_array(pre.get_buffer(n))
		var d := AudioAnalysis.split_frames(frames)
		var pk := AudioAnalysis.db(maxf(AudioAnalysis.peak(d["l"]), AudioAnalysis.peak(d["r"])))
		runs.append(pk)
		worst = maxf(worst, pk)
		await Fixture.wait(get_tree(), 0.6)
	_out["two_catches_heavy_play"] = {"pre_limiter_peaks_dbfs": runs, "worst": worst, "ceiling": AudioBuses.CEILING_DB}
	print("[audio] r2x two quick catches in heavy play: pre-limiter peaks %s dBFS" % [runs])
	lt(worst, AudioBuses.CEILING_DB, "two quick catches in heavy play stay under the limiter ceiling (worst %.1f dBFS)" % worst)
	Events.threat_changed.emit(0.0, null)
