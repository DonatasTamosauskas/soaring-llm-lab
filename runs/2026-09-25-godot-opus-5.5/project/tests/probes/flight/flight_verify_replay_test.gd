extends TestCase
## Verifier probe (round 1, flight): the "replays" pose source. A scripted
## session (glide, bank, flaps, tuck, a lost hand) is recorded with
## PoseRecorder, replayed with ReplayPoseSource into a fresh WingInput, and
## the WingState commands must match the live run.

const DT := 1.0 / 72.0
const DEG := PI / 180.0


static func _drive(_tick: int, t: float, b: HumanPoseModel) -> void:
	b.set_airplane()
	var cal := WingCalibration.new()
	if t < 2.0:
		pass
	elif t < 4.0:
		b.synth(0.0, 0.7, 1.0, cal)
	elif t < 8.0:
		ScriptedPoseSource.flap(b, t, 45.0, 1.0)
		for a in b.arms:
			a.twist = -10.0 * DEG
	elif t < 9.5:
		b.synth(-1.0, 0.0, 0.0, cal)
	else:
		b.right_valid = t > 10.5
	b.humanize(DT)


func test_record_and_replay_round_trip() -> void:
	var path := Paths.artifacts("flight").path_join("verify").path_join("replay_probe.jsonl")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var src := ScriptedPoseSource.new(HumanPoseModel.new(9), _drive)
	var wi := WingInput.new()
	wi.auto_calibrate = false
	var rec := PoseRecorder.new()
	check(rec.start(path), "recorder opens its file")
	var frame := PoseFrame.new()
	var live: Array = []
	var onsets_live := 0
	for i in int(12.0 / DT):
		src.sample(frame, DT)
		rec.record(frame)
		var w := wi.update(frame, DT)
		live.append([w.pitch, w.roll, w.ext_l, w.flap_l, w.flap_r])
		onsets_live += (1 if w.onset_l else 0) + (1 if w.onset_r else 0)
	rec.stop()
	var rp := ReplayPoseSource.new(path)
	gt(rp.samples.size(), 800, "replay loaded the recorded ticks")
	var wi2 := WingInput.new()
	wi2.auto_calibrate = false
	var onsets_rep := 0
	var frame2 := PoseFrame.new()
	var rep: Array = []
	var t_first := -1.0
	for i in live.size():
		rp.sample(frame2, DT)
		if i == 0:
			t_first = frame2.t
		var w2 := wi2.update(frame2, DT)
		rep.append([w2.pitch, w2.roll, w2.ext_l, w2.flap_l, w2.flap_r])
		onsets_rep += (1 if w2.onset_l else 0) + (1 if w2.onset_r else 0)
	# Compare with a tick offset (replay tick i vs live tick i + off).
	var per_off := {}
	for off in [-1, 0, 1]:
		var wmax := 0.0
		for i in range(2, live.size() - 2):
			var a: Array = live[i + off]
			var bb: Array = rep[i]
			for k in 5:
				wmax = maxf(wmax, absf(float(bb[k]) - float(a[k])))
		per_off[off] = wmax
	print("[flight_verify] replay first sample t %.4f (live frame 0 t = 0); worst diff by tick offset %s" % [t_first, str(per_off)])
	var worst: float = per_off[0]
	print("[flight_verify] replay: worst command diff %.4f, onsets live %d replay %d" % [worst, onsets_live, onsets_rep])
	metric("worst_diff_aligned", worst)
	metric("worst_diff_offset1", per_off[1])
	lt(float(per_off[1]), 0.02, "replayed content matches the live session (shifted one tick)")
	lt(worst, 0.02, "replay is tick-aligned with the recording (ReplayPoseSource advances t before its first lookup, so it runs one tick ahead and drops the first frame)")
	eq(onsets_rep, onsets_live, "replayed session reproduces the flap onsets")
	gt(onsets_live, 4, "the session did flap")
