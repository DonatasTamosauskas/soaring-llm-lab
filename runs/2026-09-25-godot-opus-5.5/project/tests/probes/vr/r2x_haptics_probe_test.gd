extends TestCase
## VERIFIER PROBE (vr, round 2, experience lens), V6 haptics in a realistic
## session rather than one pattern at a time.
##   tools/gd.sh vr_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/vr --suite=r2x_hap
## A player thermalling (updraft throb on both wings) and flapping at 1 Hz,
## then a hawk closes in (danger heartbeat), then a stall, then a catch.
## Checks what the player feels:
##  - every wingbeat thump arrives (the core mechanic's feedback is never
##    starved by the continuous hum/heartbeat/duty cap);
##  - the heartbeat keeps its rhythm while flapping in a thermal;
##  - a catch always plays both bites, even in a stall buffet;
##  - never a constant buzz: <= 30 % duty per 1 s window, per hand.

const DT := 1.0 / 72.0


class Sink:
	extends RefCounted
	var service: VRHaptics
	var calls: Array[Dictionary] = []
	func pulse(hand: int, amplitude: float, duration: float) -> void:
		calls.append({"t": service.now(), "hand": hand, "amp": amplitude, "dur": duration})


var hap: VRHaptics
var sink: Sink
var sent: Array[Dictionary] = []


func before_each() -> void:
	hap = VRHaptics.new()
	hap.listen_to_events = false
	hap.poll_player = false
	hap.auto_tick = false
	hap.intensity_override = 1.0
	sink = Sink.new()
	sink.service = hap
	hap.sink = sink
	add_child(hap)
	sent.clear()
	hap.pulse_sent.connect(func(hand: int, amp: float, dur: float, pattern: StringName) -> void:
		sent.append({"t": hap.now(), "hand": hand, "amp": amp, "dur": dur, "name": pattern}))


func after_each() -> void:
	hap.queue_free()
	await wait_frames(1)


## Runs `secs`, flapping both wings at `flap_hz` (strength 0.6).
func play_for(secs: float, flap_hz: float, extra: Callable = Callable()) -> int:
	var flaps := 0
	var next_flap := hap.now()
	for i in int(round(secs / DT)):
		if flap_hz > 0.0 and hap.now() >= next_flap:
			hap.play(&"flap", VRHaptics.MASK_BOTH, 0.6)
			flaps += 1
			next_flap += 1.0 / flap_hz
		if extra.is_valid():
			extra.call(i)
		hap.tick(DT)
	return flaps


func count(name: StringName, hand: int, t0: float, t1: float) -> int:
	var n := 0
	for s in sent:
		if s["name"] == name and s["hand"] == hand and s["t"] >= t0 - 1e-6 and s["t"] < t1:
			n += 1
	return n


func max_duty(hand: int) -> float:
	# Effective intervals: a later pulse on the same hand replaces the one
	# playing (OpenXR semantics), so each ends at the next start at the latest.
	var iv: Array = []
	var hc: Array = []
	for c in sink.calls:
		if c["hand"] == hand:
			hc.append(c)
	for i in hc.size():
		var a := float(hc[i]["t"])
		var b := a + float(hc[i]["dur"])
		if i + 1 < hc.size():
			b = minf(b, float(hc[i + 1]["t"]))
		iv.append([a, b])
	var worst := 0.0
	var t := 0.0
	while t < hap.now():
		var on := 0.0
		for e in iv:
			on += maxf(0.0, minf(float(e[1]), t + 1.0) - maxf(float(e[0]), t))
		worst = maxf(worst, on)
		t += 0.05
	return worst


func test_thermalling_flapper_feels_every_beat() -> void:
	hap.set_updraft(2.5, 2.5)
	var t0 := hap.now()
	var flaps := play_for(20.0, 1.0)
	var got_l := count(&"flap", 0, t0, hap.now() + 1.0)
	var got_r := count(&"flap", 1, t0, hap.now() + 1.0)
	print("[vr-verify] thermal: flaps %d, thumps L %d R %d, updraft throbs L %d, stats %s" % [flaps, got_l, got_r,
		count(&"updraft", 0, t0, hap.now() + 1.0), str(hap.stats)])
	eq(got_l, flaps, "every wingbeat thumps the left hand while thermalling")
	eq(got_r, flaps, "every wingbeat thumps the right hand while thermalling")
	lt(max_duty(0), 0.30 + 1e-3, "left duty <= 30 % in every 1 s window")


func test_heartbeat_keeps_its_rhythm_while_flapping_in_a_thermal() -> void:
	hap.set_updraft(2.5, 2.5)
	hap.set_danger(0.8)
	var t0 := hap.now()
	var flaps := play_for(10.0, 1.2)
	var beats := count(&"danger", 0, t0, hap.now() + 1.0)
	var thumps := count(&"flap", 0, t0, hap.now() + 1.0)
	# 0.8 -> interval lerp(1.0, 0.5, 0.69) = 0.65 s: ~15 pairs = ~30 beats in 10 s.
	print("[vr-verify] danger in thermal: beats %d (pairs ~%d), thumps %d / %d flaps, duty L %.2f, stats %s" % [beats,
		beats / 2, thumps, flaps, max_duty(0), str(hap.stats)])
	gt(float(beats), 24.0, "the heartbeat keeps ~all its beats (>= 25 of ~30) while flapping in a thermal")
	eq(thumps, flaps, "and every wingbeat still thumps")
	lt(max_duty(0), 0.30 + 1e-3, "left duty <= 30 %")


func test_catch_bites_through_a_stall_buffet() -> void:
	hap.set_stall(1.0)
	hap.set_updraft(1.5, 1.5)
	play_for(1.0, 0.0)
	var t0 := hap.now()
	hap.play(&"catch")
	play_for(0.5, 0.0)
	var bites := count(&"catch", 0, t0, t0 + 0.5)
	print("[vr-verify] catch in stall: bites %d, stats %s" % [bites, str(hap.stats)])
	eq(bites, 2, "both bites of a catch play through the stall buffet")


func test_worst_case_mix_is_not_a_buzz() -> void:
	# Everything at once: stall + updraft + danger + flapping at 1.5 Hz.
	hap.set_stall(1.0)
	hap.set_updraft(3.0, 3.0)
	hap.set_danger(1.0)
	var t0 := hap.now()
	play_for(5.0, 1.5)
	var starts := 0
	var longest_quiet := 0.0
	var prev_end := t0
	var calls_l: Array = []
	for c in sink.calls:
		if c["hand"] == 0 and c["t"] >= t0:
			calls_l.append(c)
	for c in calls_l:
		starts += 1
		longest_quiet = maxf(longest_quiet, float(c["t"]) - prev_end)
		prev_end = float(c["t"]) + float(c["dur"])
	var rate := starts / 5.0
	var names := {}
	for s in sent:
		if s["hand"] == 0 and s["t"] >= t0:
			names[s["name"]] = int(names.get(s["name"], 0)) + 1
	print("[vr-verify] worst mix: %.1f pulse starts/s on the left hand, longest quiet gap %.0f ms, by pattern %s, duty %.2f" % [rate,
		longest_quiet * 1000.0, str(names), max_duty(0)])
	metric("r2x_worst_mix", {"starts_per_s": rate, "longest_quiet_ms": snappedf(longest_quiet * 1000.0, 1.0), "by_pattern": names,
		"duty": snappedf(max_duty(0), 0.001)})
	lt(max_duty(0), 0.30 + 1e-3, "worst mix: left duty <= 30 %")
	# The stall buffet outranks the wingbeat (flight_vr.md §13 priority
	# order), so a thump that lands on a buffet tick is dropped by design.
	gt(float(names.get(&"flap", 0)), 4.0, "worst mix: most wingbeat thumps still come through (>= 5 of 8; stall outranks flap)")
	gt(float(names.get(&"danger", 0)), 8.0, "worst mix: the heartbeat still comes through (>= 9 beats in 5 s)")
