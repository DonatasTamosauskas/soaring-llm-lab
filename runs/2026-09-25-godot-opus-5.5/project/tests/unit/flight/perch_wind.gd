extends RefCounted
## F10 in wind (fix round 3): slow perch approaches in a uniform breeze of
## the world's perch-height strength (scripts/world/wind.gd: 2.6 m/s x
## (0.4 + 0.02 y), about 1.3-2.1 m/s at 5-15 m), from ahead, the side and
## behind, scored as the share of a set of approaches that perch.
##
## In every approach the bird's AIR velocity is aimed at the branch (it moves
## with the air: ground velocity = air + wind), arms spread with a fixed
## wrist pitch and no steering at all: the assist alone brings it in.
## Two sets:
##  - glide_set (the suite's): a player gliding down to a branch with the
##    wrists up. The bird starts in its steady glide for that wrist pitch
##    (0.5 ... 0.95: 1.4 ... 1.05 V_min), 6, 9 or 12 spans out, on its own
##    still-air glide path to the grip point or a span above / half a span
##    below it: where an approach enters the assist zone (4 spans + 0.5 s x V,
##    10-12 spans for a slow sparrow).
##  - verifier_set (round-3 verifier's probe set, reported): 2, 4 or 6 spans
##    out, 0-1 span above, at 0.72, 0.96 or 1.0 V_min with the wrists at 0 or
##    0.3, states a steady glide never holds (pitch 0 trims at cruise speed:
##    at V_min the wing lifts ~0.2 of the weight and the bird dives).
## Shared by perch_test (a reduced set) and tests/shots/flight_perchwind_sweep.

const FX := preload("res://tests/unit/flight/pb_fixture.gd")
const DT := 1.0 / 72.0
const PERCH := Vector3(0, 20, -10)


## One approach `c` ({back, up, air, pitch} in spans, spans, m/s; or
## {back, off, pitch, trim = true}) flown in `fx` (a fixture whose world has
## the perch and the wind). The bird is respawned far away first: that
## releases any perch, forgets the perch just left and resets WingInput, the
## pose source and the heave, so every approach starts clean. Returns {t: time
## to perch or -1, dmin: closest distance in spans, stuns, collided, comfort}.
static func approach(fx: FX, c: Dictionary, seconds := 4.0) -> Dictionary:
	var p := fx.player
	var pr := p.model.params
	var target := PERCH + Vector3.UP * pr.r_body
	var wind: Vector3 = fx.world.uniform_wind
	var pitch: float = c["pitch"]
	p.respawn(Transform3D(Basis.IDENTITY, PERCH + Vector3(0, 200, 400)))
	if c.get("trim", false):
		var sol := p.model.trim_solution(pitch)
		var g0: float = sol["gamma"]
		var back: float = float(c["back"]) * pr.span
		var start := target + Vector3(0, -back * tan(g0) + float(c["off"]) * pr.span, back)
		p.start_flying(start, 0.0, pitch)
		p.model.velocity += wind
	else:
		var start := target + Vector3(0, float(c["up"]) * pr.span, float(c["back"]) * pr.span)
		p.start_flying(start, 0.0, 0.0)
		p.model.reset(start, Vector3(0, 0, -float(c["air"])) + wind, 0.0)
	fx.driver = fx.synth(pitch, 0.0, 1.0)
	fx.reset_events()
	fx.reset_comfort()
	var st := {"t": -1.0, "dmin": INF, "stuns": 0, "prev": p.mode, "air_acc": 0.0, "after": 0.0, "rest": -1.0, "v_in": -1.0}
	# V_cap with no grip held (the synthetic arms never grip): the tuning's
	# capture speed, 0.8 V_min.
	var v_cap := p.tuning.perch_capture_speed * pr.v_min
	# Body contacts (slides and stuns) before the capture: a clean landing
	# grabs the branch without bumping it first.
	var c0 := int(p.contacts["slide"]) + int(p.contacts["stun"])
	var bumps := {"n": 0}
	var t0 := fx.ticks
	fx.on_tick = func(tick: int, f: Variant) -> void:
		var pl: PlayerBird = f.player
		st["dmin"] = minf(st["dmin"], pl.model.position.distance_to(target))
		# The landing speed (x V_cap) where the brake's plan ends, half a
		# span from the grip point, or on the last flying tick before the
		# capture if that comes first (a perched bird is at rest).
		if float(st["v_in"]) < 0.0:
			if pl.mode == PlayerBird.Mode.FLYING:
				st["v_last"] = minf(pl.model.airspeed(), pl.model.velocity.length()) / v_cap
				if pl.model.position.distance_to(target) < 0.5 * pr.span:
					st["v_in"] = st["v_last"]
			elif pl.mode == PlayerBird.Mode.PERCHED and st.has("v_last"):
				st["v_in"] = st["v_last"]
		if pl.mode == PlayerBird.Mode.STUNNED and st["prev"] != PlayerBird.Mode.STUNNED:
			st["stuns"] += 1
		st["prev"] = pl.mode
		if pl.mode == PlayerBird.Mode.FLYING and not pl.yaw_flagged and tick - t0 > 2:
			st["air_acc"] = maxf(st["air_acc"], absf(pl.rig_yaw_accel))
		if st["t"] < 0.0:
			bumps["n"] = int(pl.contacts["slide"]) + int(pl.contacts["stun"]) - c0
		if st["t"] < 0.0 and pl.mode == PlayerBird.Mode.PERCHED:
			st["t"] = (tick - t0) * DT
		elif st["t"] >= 0.0:
			# After the touchdown: how far the view still turns, how soon at rest.
			st["after"] += absf(pl.rig_yaw_rate) * DT
			if st["rest"] < 0.0 and pl.rig_yaw_rate == 0.0:
				st["rest"] = (tick - t0) * DT - float(st["t"])
	var t_end := -1
	for i in int(round(seconds / DT)):
		fx.step()
		if float(st["t"]) >= 0.0 and t_end < 0:
			t_end = i + int(0.5 / DT)
		if t_end >= 0 and i >= t_end:
			break
	fx.on_tick = Callable()
	return {"t": st["t"], "dmin": float(st["dmin"]) / pr.span, "stuns": st["stuns"],
		"collided": fx.events["collided"], "comfort": fx.comfort.duplicate(), "air_acc": st["air_acc"],
		"after": st["after"], "rest": st["rest"] if float(st["t"]) >= 0.0 else 0.0, "bumps": bumps["n"], "v_in": st["v_in"]}


## Success share of the approaches `set` in `wind` (one fixture for all),
## with the worst comfort.
static func share(suite: Node, sp: StringName, wind: Vector3, set: Array) -> Dictionary:
	var fx := FX.new(suite)
	await fx.setup(sp, func(w: Variant) -> void:
		w.add_perch(PERCH, Vector3.FORWARD, 10.0, 0.015, 1.0)
		w.uniform_wind = wind)
	var ok := 0
	var clean := 0
	var stuns := 0
	var misses := []
	var worst_rate := 0.0
	var worst_acc := 0.0
	var worst_air := 0.0
	var worst_after := 0.0
	var worst_rest := 0.0
	var times := []
	var v_in := []
	var pr := fx.player.model.params
	for c in set:
		var cc: Dictionary = (c as Dictionary).duplicate()
		if cc.has("air_vmin"):
			cc["air"] = float(cc["air_vmin"]) * pr.v_min
		var r: Dictionary = approach(fx, cc)
		if float(r["t"]) >= 0.0:
			ok += 1
			times.append(r["t"])
			if int(r["bumps"]) == 0:
				clean += 1
		else:
			misses.append([c, snappedf(r["dmin"], 0.01)])
		if float(r["v_in"]) >= 0.0:
			v_in.append(float(r["v_in"]))
		stuns += int(r["stuns"])
		worst_rate = maxf(worst_rate, r["comfort"]["max_rate"])
		worst_acc = maxf(worst_acc, r["comfort"]["max_accel"])
		worst_air = maxf(worst_air, r["air_acc"])
		worst_after = maxf(worst_after, r["after"])
		worst_rest = maxf(worst_rest, r["rest"])
	fx.teardown()
	times.sort()
	v_in.sort()
	return {"share": float(ok) / set.size(), "n": set.size(), "stuns": stuns, "misses": misses, "clean": clean,
		"median_t": times[times.size() / 2] if not times.is_empty() else -1.0,
		"max_rate_deg": rad_to_deg(worst_rate), "max_accel_deg": rad_to_deg(worst_acc), "air_accel_deg": rad_to_deg(worst_air),
		"after_deg": rad_to_deg(worst_after), "rest_s": worst_rest,
		"v_in_med": v_in[v_in.size() / 2] if not v_in.is_empty() else -1.0,
		"v_in_max": v_in[-1] if not v_in.is_empty() else -1.0}


## 3 wrist pitches x 3 distances x 3 offsets = 27 trimmed glide-ins. The
## pitches trim at 1.25, 1.15 and 1.07 V_min (sparrow; similar at every
## size): slow flight, inside the assist's 1.6 V_cap = 1.28 V_min gate. Level
## wrists up to 0.5 trim at 1.3 V_min and faster: a slow fly-by that the
## assist leaves alone by design (§10.6).
static func glide_set() -> Array:
	var out := []
	for pt in [0.6, 0.75, 0.9]:
		for b in [6.0, 9.0, 12.0]:
			for off in [-0.5, 0.0, 1.0]:
				out.append({"back": b, "off": off, "pitch": pt, "trim": true})
	return out


## The suite's reduced glide set (10): on the glide path at the ends of the
## pitch range and every distance, plus the offsets at the middle pitch.
static func glide_set_small() -> Array:
	var out := []
	for pt in [0.6, 0.9]:
		for b in [6.0, 9.0, 12.0]:
			out.append({"back": b, "off": 0.0, "pitch": pt, "trim": true})
	for b in [6.0, 12.0]:
		for off in [-0.5, 1.0]:
			out.append({"back": b, "off": off, "pitch": 0.75, "trim": true})
	return out


## The round-3 verifier's 54 approaches (r3_perchwind_probe_test.gd, whose
## loop over `up` never reached the start point: here it does).
static func verifier_set() -> Array:
	var out := []
	for b in [2.0, 4.0, 6.0]:
		for u in [0.0, 0.3, 1.0]:
			for k in [0.72, 0.96, 1.0]:
				for pt in [0.0, 0.3]:
					out.append({"back": b, "up": u, "air_vmin": k, "pitch": pt})
	return out
