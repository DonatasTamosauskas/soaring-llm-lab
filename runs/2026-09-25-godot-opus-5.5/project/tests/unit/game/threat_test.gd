extends "res://tests/unit/game/game_fixture.gd"
## G6 — threat/target evaluation: correct (time-to-contact), stable (no
## flicker under noise, sticky identities, hysteresis), cheap (< 0.3 ms for
## 60 birds).

const DT := 1.0 / 72.0


func _player(mass: float = 0.03) -> SimBird:
	make_loop()
	var p := make_bird(mass, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	p.mass = mass
	loop.step(DT)
	return p


func test_time_to_contact_is_correct() -> void:
	var f := ThreatWatch.time_to_contact
	near(f.call(Vector3.ZERO, Vector3.ZERO, Vector3(0, 0, -20), Vector3(0, 0, 10), 1.0), 1.9, 1e-9, "head-on: (20 - 1) / 10")
	near(f.call(Vector3.ZERO, Vector3(0, 0, 4), Vector3(0, 0, -20), Vector3(0, 0, 10), 1.0), 19.0 / 6.0, 1e-9, "fleeing player: closing 6 m/s")
	eq(f.call(Vector3.ZERO, Vector3.ZERO, Vector3(0, 0, -20), Vector3(10, 0, 0), 1.0), INF, "crossing, not closing: INF")
	eq(f.call(Vector3.ZERO, Vector3.ZERO, Vector3(0, 0, -20), Vector3(0, 0, -5), 1.0), INF, "receding: INF")
	eq(f.call(Vector3.ZERO, Vector3.ZERO, Vector3(0, 0, -0.5), Vector3.ZERO, 1.0), 0.0, "inside reach: 0")
	# Oblique approach: closing speed is the radial component.
	var q := Vector3(12, 0, -16)  # 20 m away
	var v := -q.normalized() * 8.0
	near(f.call(Vector3.ZERO, Vector3.ZERO, q, v, 2.0), 18.0 / 8.0, 1e-9, "oblique: gap / radial speed")
	# Through the watch with real birds: TTC and the named predator.
	var p := _player(0.03)
	loop.set_protection(p, 60.0)
	var hawk := make_bird(1.3, Vector3(0, 30, -30), Vector3.BACK)
	hawk.velocity = Vector3(0, 0, 12)
	p.velocity = Vector3.ZERO
	loop.step(DT)
	var contact := loop.rule.contact_distance(hawk.get_body_radius(), hawk.get_wingspan(), false, p.get_body_radius(), true)
	near(loop.watch.predator_ttc, (30.0 - contact) / 12.0, 1e-6, "watch TTC for a real bird")
	eq(loop.watch.predator, hawk, "the hawk is the named predator")


func test_a_big_bird_close_by_is_a_threat_even_when_not_closing() -> void:
	# Proximity floor: within proximity_spans of the predator's wingspans a
	# bird that can eat the player registers (up to proximity_weight) even
	# when its time to contact is infinite - a hawk cruising alongside two
	# of its wingspans away is a danger a player should hear.
	var p := _player(0.03)
	loop.set_protection(p, 60.0)
	var hawk := make_bird(1.3, p.get_body_position() + Vector3(2.0 * SizeRules.wingspan_for_mass(1.3), 0, 0), Vector3.FORWARD)
	hawk.velocity = Vector3(0, 0, -8)
	p.velocity = Vector3(0, 0, -8)
	var lv := loop.watch.threat_of(p, hawk, loop.rule)
	var contact := loop.rule.contact_distance(hawk.get_body_radius(), hawk.get_wingspan(), false, p.get_body_radius(), true)
	var gap := hawk.get_body_position().distance_to(p.get_body_position()) - contact
	eq(ThreatWatch.time_to_contact(p.get_body_position(), p.velocity, hawk.get_body_position(), hawk.velocity, contact), INF,
			"(setup) flying alongside: not closing")
	near(lv, loop.watch.proximity_weight * (1.0 - gap / (loop.watch.proximity_spans * hawk.get_wingspan())), 1e-6,
			"level = proximity floor")
	gt(lv, 0.2, "a hawk two wingspans away is a real (if low) threat")
	hawk.global_position = p.get_body_position() + Vector3(8.0 * hawk.get_wingspan(), 0, 0)
	eq(loop.watch.threat_of(p, hawk, loop.rule), 0.0, "beyond proximity_spans and not closing: no threat")


func test_level_orders_by_time_to_contact() -> void:
	var p := _player(0.03)
	loop.set_protection(p, 60.0)
	var w := loop.watch
	var hawk := make_bird(1.3, Vector3.ZERO, Vector3.BACK)
	var levels: Array[float] = []
	var ttcs: Array[float] = []
	for ttc in [6.0, 3.4, 3.0, 2.0, 1.0, 0.5, 0.1]:
		var speed := 12.0
		var contact := loop.rule.contact_distance(hawk.get_body_radius(), hawk.get_wingspan(), false, p.get_body_radius(), true)
		hawk.global_position = p.get_body_position() + Vector3(0, 0, -(contact + ttc * speed))
		hawk.velocity = Vector3(0, 0, speed)
		levels.append(w.threat_of(p, hawk, loop.rule))
		ttcs.append(ttc)
	metric("level_by_ttc", levels)
	lt(levels[0], 0.01, "TTC 6 s (beyond the 3.5 s horizon), 72 m away: no threat")
	for i in range(1, levels.size()):
		gt(levels[i], levels[i - 1], "level rises as TTC falls (%.1f s -> %.1f s)" % [ttcs[i - 1], ttcs[i]])
	gt(levels[-1], 0.95, "0.1 s from contact, aimed: ~1")
	# Same TTC, predator pointed away (e.g. it is chasing something else past you).
	var contact2 := loop.rule.contact_distance(hawk.get_body_radius(), hawk.get_wingspan(), false, p.get_body_radius(), true)
	hawk.global_position = p.get_body_position() + Vector3(0, 0, -(contact2 + 1.0 * 12.0))
	hawk.velocity = Vector3(0, 0, 12.0)
	hawk.set_heading(Vector3.BACK)
	var aimed := w.threat_of(p, hawk, loop.rule)
	hawk.set_heading(Vector3.RIGHT)
	var unaimed := w.threat_of(p, hawk, loop.rule)
	lt(unaimed, aimed * 0.7, "a predator not pointed at you is less threatening at the same TTC")
	# A bird that cannot eat the player is never a threat.
	var crow_like := make_bird(0.035, p.get_body_position() + Vector3(0, 0, -1), Vector3.BACK)
	crow_like.velocity = Vector3(0, 0, 10)
	loop.step(DT)
	check(loop.watch.predator != crow_like, "near-equal bird is not a predator")


func _approach_run(noise: float, seed_: int, smoothing: bool = true) -> Array:
	# A hawk approaches from 40 m at 10 m/s and turns away ~1 s from contact.
	var p := _player(0.03)
	loop.set_protection(p, 600.0)
	if not smoothing:
		loop.watch.rise_tau = 1e-6
		loop.watch.fall_tau = 1e-6
	var hawk := make_bird(1.3, Vector3(0, 30, -40), Vector3.BACK)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_
	var levels: Array = []
	var emitted: Array = []
	var cb := func(lv: float, _pr: Bird) -> void: emitted.append(lv)
	Events.threat_changed.connect(cb)
	var pos := Vector3(0, 30, -40)
	var vel := Vector3(0, 0, 10)
	for i in int(8.0 / DT):
		var t := i * DT
		if t > 3.0:
			vel = vel.lerp(Vector3(10, 0, -4), 0.05)
		pos += vel * DT
		var jitter := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)) * noise
		hawk.global_position = pos + jitter
		hawk.velocity = vel + jitter * 4.0
		hawk.set_heading(vel)
		loop.step(DT)
		levels.append(loop.watch.level)
	Events.threat_changed.disconnect(cb)
	await cleanup()
	return [levels, emitted]


## Direction reversals that a person could notice: the level must move at
## least `threshold` against the current trend (from the last extreme) for
## it to count ("zig-zag" count).
static func _reversals(xs: Array, threshold: float) -> int:
	if xs.is_empty():
		return 0
	var n := 0
	var trend := 0
	var hi := float(xs[0])
	var lo := float(xs[0])
	for x in xs:
		var v := float(x)
		if trend == 0:
			hi = maxf(hi, v)
			lo = minf(lo, v)
			if v - lo >= threshold:
				trend = 1
				hi = v
			elif hi - v >= threshold:
				trend = -1
				lo = v
		elif trend == 1:
			if v > hi:
				hi = v
			elif hi - v >= threshold:
				n += 1
				trend = -1
				lo = v
		else:
			if v < lo:
				lo = v
			elif v - lo >= threshold:
				n += 1
				trend = 1
				hi = v
	return n


func test_threat_is_stable_under_noise() -> void:
	var clean: Array = await _approach_run(0.0, 1)
	var noisy: Array = await _approach_run(0.35, 2)
	var lc: Array = clean[0]
	var ln: Array = noisy[0]
	var w := ThreatWatch.new()
	var max_dev := 0.0
	var max_up := 0.0
	var max_down := 0.0
	for i in range(1, ln.size()):
		max_dev = maxf(max_dev, absf(float(ln[i]) - float(lc[i])))
		var d := float(ln[i]) - float(ln[i - 1])
		max_up = maxf(max_up, d)
		max_down = maxf(max_down, -d)
	gt(lc.max(), 0.6, "the approach produces a real threat")
	lt(max_up, w.rise_rate * DT + 1e-6, "level never jumps faster than the rise limit")
	lt(max_down, w.fall_rate * DT + 1e-6, "level never drops faster than the fall limit")
	lt(max_dev, 0.2, "35 cm / 1.4 m/s tracking noise moves the level by < 0.2")
	# One approach = one rise and one fall: exactly one perceptible reversal.
	eq(_reversals(lc, 0.03), 1, "clean run: one rise, one fall")
	lt(float(_reversals(ln, 0.03)), 2.5, "noisy run: no perceptible flicker (<= 2 zig-zags of >= 0.03)")
	var em: Array = noisy[1]
	lt(float(_reversals(em, 0.03)), 2.5, "emitted cue values do not zig-zag either")
	lt(float(em.size()), 8.0 / DT * 0.5, "threat_changed is quantised, not emitted every frame")
	eq(float(em[-1]), 0.0, "the cue ends at exactly 0 when the hawk leaves")
	# Control: the same noise without the low-pass does flicker, so the
	# assertions above really measure the filter.
	var raw: Array = await _approach_run(0.35, 2, false)
	gt(float(_reversals(raw[0], 0.03)), 4.0, "control: unsmoothed level flickers under the same noise")
	metric("reversals_unsmoothed", _reversals(raw[0], 0.03))
	metric("peak_clean", lc.max())
	metric("max_dev_noise", max_dev)
	metric("reversals_noisy_frames", _reversals(ln, 0.03))
	metric("reversals_noisy_frames_any", _reversals(ln, 1e-6))
	metric("emissions", em.size())


func test_predator_identity_is_sticky() -> void:
	# Two hawks hunting the player, both real threats (TTC ~1.3 s, inside the
	# horizon), trading the lead by 0.3 m every few frames: the named
	# predator must not hop between them. (The first version of this test
	# placed its hawks 36 m away, beyond the horizon and the proximity floor:
	# nobody was ever named and "no switches" held trivially - fix round 2
	# review.) The wobble is 0.1 s of time-to-contact either way, under the
	# strike margin (0.04 of the horizon, 0.14 s): noise, not one hunter
	# striking first.
	make_loop()
	var p := make_bird(0.03, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 1e6)
	var a := make_bird(1.3, Vector3(-2, 30, -9), Vector3.BACK)
	var b := make_bird(1.3, Vector3(2, 30, -9), Vector3.BACK)
	var raws: Array[float] = []
	var switches := 0
	var named := 0
	var last: Bird = null
	for i in int(3.0 / DT):
		var wob := 0.3 * (1.0 if (i / 7) % 2 == 0 else -1.0)
		a.global_position = Vector3(-2, 30, -9 + wob)
		b.global_position = Vector3(2, 30, -9 - wob)
		a.velocity = Vector3(0, 0, 6.0)
		b.velocity = Vector3(0, 0, 6.0)
		loop.step(DT)
		raws.append(minf(loop.watch.threat_of(p, a, loop.rule), loop.watch.threat_of(p, b, loop.rule)))
		if loop.watch.predator != null:
			named += 1
		if loop.watch.predator != last:
			if last != null:
				switches += 1
			last = loop.watch.predator
	raws.sort()
	metric("sticky", {"weaker_raw_median": raws[raws.size() / 2], "named_frames": named, "switches": switches})
	gt(raws[raws.size() / 2], 0.3, "(setup) both hawks are real threats")
	gt(float(named), 3.0 / DT * 0.9, "(setup) a predator is named nearly all the time")
	eq(switches, 0, "near-equal predators never steal the cue from each other")
	# The other one steadily a little sooner (0.1 s of time-to-contact, under
	# the strike margin) for a long time: still no switch.
	var first := loop.watch.predator
	var other: SimBird = b if first == a else a
	var steady := 0
	for i in int(2.0 / DT):
		move(first as SimBird, Vector3(-2 if first == a else 2, 30, -9.3), Vector3(0, 0, 6.0))
		move(other, Vector3(2 if first == a else -2, 30, -8.7), Vector3(0, 0, 6.0))
		loop.step(DT)
		if loop.watch.predator == first:
			steady += 1
	gt(loop.watch.level_of(other), loop.watch.level_of(first), "(setup) the other hawk is slightly worse")
	lt(loop.watch.level_of(other) - loop.watch.level_of(first), loop.watch.switch_margin, "(setup) ...by less than the margin")
	eq(steady, int(2.0 / DT), "a hunter striking a little sooner (under the strike margin) never takes the name")
	metric("sticky_margin", {"named_first_frames": steady})
	# One clearly strikes first (much closer, closing fast): it is named at
	# once - the arrow is on the bird about to strike.
	var frames := 0
	while loop.watch.predator != other and frames < 200:
		move(other, Vector3(1, 30, -2), Vector3(0, 0, 12))
		loop.step(DT)
		frames += 1
	eq(loop.watch.predator, other, "a hunter that clearly strikes first takes the cue")
	lt(frames * DT, 2.5 * DT, "...at once")
	eq(loop.watch.last_change, &"attack", "...as a real attack")
	near(loop.watch.level, loop.watch.level_of(other), 1e-9, "...and the level is its own")


## Frames of the attack-and-jink scenario (below), per named bird.
func _jink_scenario(jink_s: float, n_bystanders: int, shown_bystander: bool = false) -> Dictionary:
	# A hawk hunting the player (a sparrow) closes at 12 m/s to just outside
	# its proximity floor, then jinks: it flies across, pointed away, for
	# jink_s - its own threat is 0 - and turns in again. 1-3 crows merely
	# passing by (not hunting the player) sit in their proximity floor at a
	# small threat of their own. Round 3's cue handed the hawk's name - and
	# its attack-level threat - to a crow the moment the hawk's raw threat
	# hit 0, and took it back when it turned in (fix round 4 review).
	make_loop()
	var p := make_bird(0.03, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 1e6)
	p.velocity = Vector3.ZERO
	var hawk := make_bird(1.3, Vector3(0, 30, -40), Vector3.BACK)
	hawk.target = p
	var span := hawk.get_wingspan()
	var contact := loop.rule.contact_distance(hawk.get_body_radius(), span, false, p.get_body_radius(), true)
	var stop_gap := (loop.watch.proximity_spans + 1.0) * span
	var crows: Array[SimBird] = []
	var spots := [Vector3(5.0, 30.0, 2.0), Vector3(-4.5, 31.0, 3.0), Vector3(0.5, 34.5, 2.5)]
	for i in n_bystanders:
		var c := make_bird(0.5, spots[i], Vector3.RIGHT)
		c.target = null
		c.velocity = Vector3.ZERO
		if shown_bystander:
			# Close enough that its own threat is shown (~0.12, over QUIET_LEVEL).
			var cc := loop.rule.contact_distance(c.get_body_radius(), c.get_wingspan(), false, p.get_body_radius(), true)
			move(c, Vector3(cc + 0.8 * c.get_wingspan(), 30, 0))
		crows.append(c)
	var out := {"named_bystander": 0, "over_own": 0, "worst_over": 0.0, "peak_attack": 0.0, "hawk_raw_in_jink": 0.0,
		"crow_raw": [], "named_hawk_after": false, "frames": 0, "attack_named": false, "named_at_jink": false}
	var crow_max := {}
	for c in crows:
		crow_max[c] = 0.0
	var tally := func() -> void:
		out["frames"] += 1
		for c in crows:
			crow_max[c] = maxf(float(crow_max[c]), loop.watch.threat_of(p, c, loop.rule))
		var named := loop.watch.predator
		# (Counted from the moment the attack is the cue: before the hawk
		# closes in, a shown bystander is rightly the one named.)
		if named == hawk:
			out["attack_named"] = true
		if not out["attack_named"]:
			return
		if named != null and named != hawk:
			out["named_bystander"] += 1
			# The level shown with a bystander's name can only be that
			# bystander's own (never above the worst it ever posed).
			var own := float(crow_max.get(named, 0.0))
			if loop.watch.level > own + 1e-6:
				out["over_own"] += 1
				out["worst_over"] = maxf(float(out["worst_over"]), loop.watch.level - own)
	var z := -40.0
	var closing := func(until_gap: float) -> void:
		while -z - contact > until_gap:
			z += 12.0 * DT
			move(hawk, Vector3(0, 30, z), Vector3(0, 0, 12))
			hawk.set_heading(Vector3.BACK)
			loop.step(DT)
			tally.call()
	closing.call(stop_gap)
	out["peak_attack"] = loop.watch.level
	out["named_at_jink"] = loop.watch.predator == hawk
	# The jink: across and pointed away.
	var x := 0.0
	for i in int(round(jink_s / DT)):
		x += 12.0 * DT
		move(hawk, Vector3(x, 30, z), Vector3(12, 0, 0))
		hawk.set_heading(Vector3(1, 0, -1).normalized())
		loop.step(DT)
		tally.call()
		out["hawk_raw_in_jink"] = maxf(float(out["hawk_raw_in_jink"]), loop.watch.threat_of(p, hawk, loop.rule))
	# Turns in again and closes for another half second.
	for i in int(0.5 / DT):
		var to := (p.get_body_position() - hawk.global_position).normalized()
		move(hawk, hawk.global_position + to * 12.0 * DT, to * 12.0)
		hawk.set_heading(to)
		loop.step(DT)
		tally.call()
	out["named_hawk_after"] = loop.watch.predator == hawk
	for c in crows:
		(out["crow_raw"] as Array).append(snappedf(float(crow_max[c]), 0.001))
	await cleanup()
	return out


func test_an_attackers_jink_never_hands_the_cue_to_a_bystander() -> void:
	# The lead's case (fix round 4): the attacker stops closing for 0.3-0.8 s
	# with 1-3 bystanders at small raw threat nearby. The name never moves to
	# a bystander, and the level shown never exceeds the named bird's own.
	# (The last case: one bystander close enough that its own threat is shown,
	# ~0.12 - over QUIET_LEVEL, so it could take a quiet attacker's name.)
	for case: Array in [[0.3, 1, false], [0.5, 2, false], [0.8, 3, false], [0.8, 1, false], [0.8, 1, true]]:
		var r: Dictionary = await _jink_scenario(case[0], case[1], case[2])
		var tag := "jink %.1f s, %d bystander(s)%s" % [case[0], case[1], ", shown" if case[2] else ""]
		metric("jink_%.1f_%d%s" % [case[0], case[1], "_shown" if case[2] else ""], r)
		gt(float(r["peak_attack"]), 0.3, "(setup, %s) the hawk's attack is at attack level" % tag)
		check(bool(r["named_at_jink"]), "(setup, %s) the attacking hawk is named when it jinks" % tag)
		lt(float(r["hawk_raw_in_jink"]), 1e-6, "(setup, %s) jinking, the hawk's own threat is 0" % tag)
		for cr in r["crow_raw"]:
			if case[2]:
				between(float(cr), ThreatWatch.QUIET_LEVEL, 0.15, "(setup, %s) the bystander's own threat is shown: %.3f" % [tag, cr])
			else:
				check(float(cr) > 0.0 and float(cr) < 0.1, "(setup, %s) a bystander's own threat is small but not 0: %.3f" % [tag, cr])
		eq(int(r["named_bystander"]), 0, "%s: the cue never names a bystander" % tag)
		eq(int(r["over_own"]), 0, "%s: the level shown is never above the named bird's own (worst excess %.2f)" % [tag, r["worst_over"]])
		check(bool(r["named_hawk_after"]), "%s: the hawk turning in again is named" % tag)


func test_a_real_new_attacker_is_named_the_moment_it_attacks() -> void:
	# A hawk hunting the player loiters next to it (named, at its proximity
	# floor, not closing); a second hawk stoops in from 40 m. The newcomer
	# is named the frame its own level reaches attack strength: the named
	# hawk will not strike first (it is not closing), so the attack is not
	# held back behind it (fix round 5 review: round 4 named it only after a
	# 0.5 s hold, while it climbed to 0.4-0.8 unnamed).
	make_loop()
	var p := make_bird(0.03, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 1e6)
	p.velocity = Vector3.ZERO
	var a := make_bird(1.3, Vector3(0, 30, 0), Vector3.RIGHT)
	var span := a.get_wingspan()
	var contact := loop.rule.contact_distance(a.get_body_radius(), span, false, p.get_body_radius(), true)
	move(a, Vector3(contact + 2.0 * span, 30, 0), Vector3(0, 0, -0.01))
	var b := make_bird(1.3, Vector3(0, 30, -40), Vector3.BACK)
	b.velocity = Vector3.ZERO
	run_steps(int(1.0 / DT), DT)
	eq(loop.watch.predator, a, "(setup) the loitering hawk is named")
	var a_level := loop.watch.level
	between(a_level, 0.15, 0.35, "(setup) at its proximity floor")
	var z := -40.0
	var reached := -1
	var named_at := -1
	var back := 0
	var not_own := 0
	for i in int(4.0 / DT):
		z += 14.0 * DT
		move(b, Vector3(0, 30, minf(z, -contact - 0.5)), Vector3(0, 0, 14))
		loop.step(DT)
		if reached < 0 and loop.watch.level_of(b) >= loop.watch.announce_level:
			reached = i
		if loop.watch.predator == b:
			if named_at < 0:
				named_at = i
		elif named_at >= 0:
			back += 1  # (the name went back: counted as hopping)
		if absf(loop.watch.level - loop.watch.level_of(loop.watch.predator)) > 1e-9:
			not_own += 1
	check(reached >= 0 and named_at >= 0, "(setup) the stooping hawk reached attack strength and was named")
	eq(named_at, reached, "named the frame its own level reached attack strength (%d vs %d)" % [named_at, reached])
	eq(back, 0, "the name never went back to the loiterer")
	eq(not_own, 0, "the level shown is always the named bird's own")
	# The named bird leaving the game hands the cue on at once, at the next
	# bird's own level.
	b.alive = false
	loop.step(DT)
	eq(loop.watch.predator, a, "a named bird that dies is replaced at once")
	near(loop.watch.level, loop.watch.level_of(a), 1e-9, "...at the next bird's own level")
	lt(loop.watch.level, a_level + 0.05, "...not the dead bird's")


func test_a_clearly_worse_bystander_takes_the_name_only_after_the_hold() -> void:
	# Birds NOT hunting the player (flying at it after something else, or
	# idling near it): a rival takes the name only once its level has beaten
	# the named one's by switch_margin for switch_hold_s - not before (an
	# attacker's jink must not hand its name to a bystander) and not much
	# later.
	make_loop()
	var p := make_bird(0.03, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 1e6)
	p.velocity = Vector3.ZERO
	var a := make_bird(1.3, Vector3(0, 30, 0), Vector3.RIGHT)
	a.target = null
	var span := a.get_wingspan()
	var contact := loop.rule.contact_distance(a.get_body_radius(), span, false, p.get_body_radius(), true)
	move(a, Vector3(contact + 0.3 * span, 30, 0), Vector3(0, 0, -0.01))
	var b := make_bird(1.3, Vector3(0, 30, -40), Vector3.BACK)
	b.target = null
	b.velocity = Vector3.ZERO
	run_steps(int(1.0 / DT), DT)
	eq(loop.watch.predator, a, "(setup) the idling bird is named")
	between(loop.watch.level, ThreatWatch.QUIET_LEVEL, 0.2, "(setup) shown, at its proximity floor")
	var z := -40.0
	var beat_at := -1
	var named_at := -1
	var back := 0
	for i in int(4.0 / DT):
		z += 14.0 * DT
		move(b, Vector3(0, 30, minf(z, -contact - 0.5)), Vector3(0, 0, 14))
		loop.step(DT)
		if beat_at < 0 and loop.watch.level_of(b) > loop.watch.level_of(a) + loop.watch.switch_margin:
			beat_at = i
		if loop.watch.predator == b:
			if named_at < 0:
				named_at = i
		elif named_at >= 0:
			back += 1
	check(beat_at >= 0 and named_at >= 0, "(setup) the passing bird became clearly worse and was named")
	if beat_at < 0 or named_at < 0:
		return
	var delay := (named_at - beat_at + 1) * DT
	metric("bystander_named_after_s", delay)
	between(delay, loop.watch.switch_hold_s - DT, loop.watch.switch_hold_s + 2.0 * DT,
			"named %.3f s after it became clearly worse (switch_hold_s %.2f)" % [delay, loop.watch.switch_hold_s])
	eq(loop.watch.last_change, &"challenge", "...by the challenge rule")
	eq(back, 0, "the name never went back")


func test_an_attack_is_announced_at_once_when_nothing_is_shown() -> void:
	# A crow passing by (not hunting) holds the name at a level the cue shows
	# as no threat (under QUIET_LEVEL); a hawk stoops in. It is named the
	# frame its own level reaches announce_level - an attack's warning is
	# never held back by a bird the player is not being shown.
	make_loop()
	var p := make_bird(0.03, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 1e6)
	p.velocity = Vector3.ZERO
	var crow := make_bird(0.5, Vector3(3.5, 30, 1.0), Vector3.RIGHT)
	crow.target = null
	crow.velocity = Vector3.ZERO
	var hawk := make_bird(1.3, Vector3(0, 30, -45), Vector3.BACK)
	hawk.velocity = Vector3.ZERO
	# (A long hold, so that neither the quiet rule nor a challenge can name
	# the hawk first: this measures the announcement alone.)
	loop.watch.switch_hold_s = 30.0
	run_steps(int(1.0 / DT), DT)
	eq(loop.watch.predator, crow, "(setup) the passing crow is named")
	between(loop.watch.level, 0.001, ThreatWatch.QUIET_LEVEL - 0.001, "(setup) at a level shown as no threat")
	var z := -45.0
	var reached := -1
	var named := -1
	for i in int(4.0 / DT):
		z += 14.0 * DT
		move(hawk, Vector3(0, 30, z), Vector3(0, 0, 14))
		loop.step(DT)
		if reached < 0 and loop.watch.level_of(hawk) >= loop.watch.announce_level:
			reached = i
		if named < 0 and loop.watch.predator == hawk:
			named = i
	check(reached >= 0, "(setup) the stoop reaches attack strength")
	eq(named, reached, "the hawk is named the frame its level reaches announce_level")
	eq(loop.watch.last_change, &"attack", "...as an announced attack")


## A bird not hunting the player holds the name at a level the cue SHOWS
## (0.12-0.15, loitering or closing on something beside the player), and a
## hawk hunting the player stoops in: the frame of its own level reaching
## attack strength, and the frame it is named (fix round 5 review: round 4
## held it back 0.39-0.49 s while it climbed to 0.41-0.57).
func _stoop_behind_bystander(bystander_closing: bool, stoop_speed: float) -> Dictionary:
	make_loop()
	var p := make_bird(0.03, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 1e6)
	p.velocity = Vector3.ZERO
	var crow := make_bird(0.5, Vector3(0, 30, 0), Vector3.RIGHT)
	crow.target = null
	var cc := loop.rule.contact_distance(crow.get_body_radius(), crow.get_wingspan(), false, p.get_body_radius(), true)
	var crow_at := Vector3(cc + 6.0, 30, 0) if bystander_closing else Vector3(cc + 0.8 * crow.get_wingspan(), 30, 0)
	var crow_v := Vector3(-3.0, 0, 0) if bystander_closing else Vector3.ZERO
	move(crow, crow_at, crow_v)
	if bystander_closing:
		crow.set_heading(Vector3.LEFT)
	var hawk := make_bird(1.3, Vector3(0, 30, -60), Vector3.BACK)
	hawk.velocity = Vector3.ZERO
	run_steps(int(0.5 / DT), DT, func(_i: int) -> void: move(crow, crow_at, crow_v))
	var out := {"bystander_named": loop.watch.predator == crow, "bystander_level": loop.watch.level, "reached": -1,
		"named": -1, "unnamed_max": 0.0}
	var hc := loop.rule.contact_distance(hawk.get_body_radius(), hawk.get_wingspan(), false, p.get_body_radius(), true)
	var z := -60.0
	var i := 0
	while -z - hc > 0.05 and i < int(8.0 / DT):
		z += stoop_speed * DT
		move(hawk, Vector3(0, 30, z), Vector3(0, 0, stoop_speed))
		move(crow, crow_at, crow_v)
		loop.step(DT)
		var hl := loop.watch.level_of(hawk)
		if int(out["reached"]) < 0 and hl >= loop.watch.announce_level:
			out["reached"] = i
		if loop.watch.predator == hawk:
			if int(out["named"]) < 0:
				out["named"] = i
		elif int(out["reached"]) >= 0:
			out["unnamed_max"] = maxf(float(out["unnamed_max"]), hl)
		i += 1
	await cleanup()
	return out


func test_an_attack_is_named_at_once_behind_a_shown_bystander() -> void:
	for case: Array in [[false, 14.0], [false, 30.0], [true, 14.0], [true, 30.0]]:
		var r: Dictionary = await _stoop_behind_bystander(case[0], case[1])
		var tag := "%s bystander, stoop %.0f m/s" % ["closing" if case[0] else "loitering", case[1]]
		metric("behind_bystander_%s_%d" % ["closing" if case[0] else "loiter", int(case[1])], r)
		check(bool(r["bystander_named"]), "(setup, %s) the bystander is named first" % tag)
		gt(float(r["bystander_level"]), ThreatWatch.QUIET_LEVEL, "(setup, %s) at a shown level" % tag)
		check(int(r["reached"]) >= 0, "(setup, %s) the hawk reaches attack strength" % tag)
		eq(int(r["named"]), int(r["reached"]), "%s: the hunting hawk is named the frame it reaches attack strength" % tag)
		eq(float(r["unnamed_max"]), 0.0, "%s: never unnamed at attack strength" % tag)


func test_an_attack_is_named_at_once_behind_a_hunter_that_turned_away() -> void:
	# The named hunter has made its pass and turned away: its own raw threat
	# is 0, its level only decaying (0.9/s) from attack strength. A second
	# hunter stooping in is named the frame it reaches attack strength - it
	# is the attack now, not the bird flying off (fix round 5 review: in 10
	# of 12 valley runs the worst masked case's named bird had raw <= 0.1).
	make_loop()
	var p := make_bird(0.03, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 1e6)
	p.velocity = Vector3.ZERO
	var a := make_bird(1.3, Vector3(0, 30, -30), Vector3.BACK)
	var b := make_bird(1.3, Vector3(0, 30, 80), Vector3.FORWARD)
	b.velocity = Vector3.ZERO
	var za := -30.0
	var ac := loop.rule.contact_distance(a.get_body_radius(), a.get_wingspan(), false, p.get_body_radius(), true)
	while -za - ac > 3.0:
		za += 14.0 * DT
		move(a, Vector3(0, 30, za), Vector3(0, 0, 14))
		loop.step(DT)
	eq(loop.watch.predator, a, "(setup) the first hunter is named")
	gt(loop.watch.level, 0.6, "(setup) at a high level")
	# It breaks off: across and away.
	var xa := 0.0
	var zb := 80.0
	var reached := -1
	var named := -1
	var a_level := 0.0
	var b_level := 0.0
	for i in int(2.0 / DT):
		xa += 14.0 * DT
		move(a, Vector3(xa, 30, za), Vector3(14, 0, 0))
		a.set_heading(Vector3(1, 0, -1).normalized())
		zb -= 30.0 * DT
		move(b, Vector3(0, 30, zb), Vector3(0, 0, -30))
		loop.step(DT)
		if reached < 0 and loop.watch.level_of(b) >= loop.watch.announce_level:
			reached = i
			a_level = loop.watch.level_of(a)
			b_level = loop.watch.level_of(b)
		if named < 0 and loop.watch.predator == b:
			named = i
	check(reached >= 0, "(setup) the second hunter reaches attack strength")
	gt(a_level, b_level + loop.watch.switch_margin, "(setup) the first one's decaying level is still well above it then (%.2f vs %.2f)" % [
			a_level, b_level])
	metric("turned_away", {"a_level": a_level, "b_level": b_level, "reached": reached, "named": named})
	eq(named, reached, "the second hunter is named the frame it reaches attack strength")


## Hunter A holds a steady time-to-contact (held in place, pointed at the
## player, with the closing velocity that gives it); hunter B stoops in from
## behind at 16 m/s. Returns when B is named and its time-to-contact then.
func _second_hunter(a_ttc: float) -> Dictionary:
	make_loop()
	var p := make_bird(0.03, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 1e6)
	p.velocity = Vector3.ZERO
	var a := make_bird(1.3, Vector3(0, 30, -4.0), Vector3.BACK)
	var ac := loop.rule.contact_distance(a.get_body_radius(), a.get_wingspan(), false, p.get_body_radius(), true)
	var gap := 4.0 - ac
	var hold_a := func() -> void: move(a, Vector3(0, 30, -4.0), Vector3(0, 0, gap / a_ttc))
	run_steps(int(1.5 / DT), DT, func(_i: int) -> void: hold_a.call())
	var out := {"a_named": loop.watch.predator == a, "a_level": loop.watch.level, "b_named": false, "ttc_left": INF,
		"back_to_a": 0}
	var b := make_bird(1.3, Vector3(0, 30, 60), Vector3.FORWARD)
	var bc := loop.rule.contact_distance(b.get_body_radius(), b.get_wingspan(), false, p.get_body_radius(), true)
	var z := 60.0
	var i := 0
	while z - bc > 0.05 and i < int(8.0 / DT):
		hold_a.call()
		z -= 16.0 * DT
		move(b, Vector3(0, 30, z), Vector3(0, 0, -16.0))
		loop.step(DT)
		if loop.watch.predator == b and not out["b_named"]:
			out["b_named"] = true
			out["ttc_left"] = (z - bc) / 16.0
		elif out["b_named"] and loop.watch.predator == a:
			out["back_to_a"] += 1
		i += 1
	await cleanup()
	return out


func test_a_second_hunter_that_strikes_first_is_named_in_time() -> void:
	# Two hawks hunt a sparrow (the AI sends two or three at once): A holds a
	# steady threat (named); B stoops in from behind. B, the one about to
	# strike, is named with at least 1 s of time-to-contact left (a person
	# needs ~0.2 s to react and ~0.5 s to roll into an evasive turn), and the
	# name stays on it (fix round 5 review: with A at 0.66, round 4 named B
	# 0.13 s before contact).
	for a_ttc: float in [2.6, 1.75, 1.2]:
		var r: Dictionary = await _second_hunter(a_ttc)
		metric("second_hunter_a_ttc_%.2f" % a_ttc, r)
		var tag := "A at level %.2f (time-to-contact %.2f s)" % [r["a_level"], a_ttc]
		check(bool(r["a_named"]), "(setup, %s) hunter A is named" % tag)
		check(bool(r["b_named"]), "%s: the stooping hunter B is named before it strikes" % tag)
		gt(float(r["ttc_left"]), 1.0, "%s: B named with more than 1 s to contact (%.2f s)" % [tag, r["ttc_left"]])
		lt(float(r["ttc_left"]), a_ttc + 1e-6, "%s: ...once it strikes sooner than A" % tag)
		eq(int(r["back_to_a"]), 0, "%s: and the name stays on B" % tag)


func test_cue_invariants_in_a_busy_sky() -> void:
	# Eight birds that can eat the player (half of them hunting it) weave
	# round a sparrow for two minutes, now and then stooping at it: at every
	# frame the level shown is the named bird's own (0 with nobody named);
	# the name never moves by preference (a challenge, quiet or an announced
	# attack) to a bird that is no threat right now (own raw threat under
	# QUIET_LEVEL); and such moves are at least switch_hold_s apart. With
	# the attack warning (ThreatWatch.warn_level: hunters shown at 0.2 from
	# afar) and without it.
	await _busy_sky(false)
	await cleanup()
	await _busy_sky(true)


func _busy_sky(warn: bool) -> void:
	make_loop(false, warn)
	var p := make_bird(0.03, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 1e6)
	p.velocity = Vector3.ZERO
	var rng := RandomNumberGenerator.new()
	rng.seed = 4
	var preds: Array[SimBird] = []
	var goals: Array[Vector3] = []
	var until: Array[float] = []
	for i in 8:
		var q := make_bird(exp(rng.randf_range(log(0.3), log(3.0))), Vector3(rng.randf_range(-25, 25), 30 + rng.randf_range(-6, 6),
				rng.randf_range(-25, 25)), Vector3.FORWARD)
		q.target = p if i % 2 == 0 else null
		preds.append(q)
		goals.append(q.global_position)
		until.append(0.0)
	var t := 0.0
	var not_own := 0
	var bad_pref := 0
	var changes := 0
	var pref_changes := 0
	var too_soon := 0
	var last_pref := -INF
	var last: Bird = null
	var attack_s := 0.0
	var masked := 0
	for f in int(120.0 / DT):
		t += DT
		for i in preds.size():
			var q := preds[i]
			if t >= until[i]:
				# A stoop at the player (hunters, now and then) or a new point
				# somewhere around it.
				var stoop := q.target == p and rng.randf() < 0.35
				goals[i] = p.global_position if stoop else Vector3(rng.randf_range(-30, 30), 30 + rng.randf_range(-8, 8), rng.randf_range(-30, 30))
				until[i] = t + rng.randf_range(1.0, 3.0)
			var to := goals[i] - q.global_position
			var v := to.normalized() * rng.randf_range(8.0, 13.0) if to.length() > 0.5 else Vector3.ZERO
			move(q, q.global_position + v * DT, v)
			if v != Vector3.ZERO:
				q.set_heading(v)
		loop.step(DT)
		var w := loop.watch
		var named := w.predator
		if w.level >= 0.3:
			attack_s += DT
		if absf(w.level - (w.level_of(named) if named != null else 0.0)) > 1e-9:
			not_own += 1
		# A live attack masked (CueTrack's masked_live, core loop fix round 1).
		for q in preds:
			if q != named and q.target == p and w.level_of(q) >= GameLoop.ATTACK_LEVEL \
					and w.raw_of(q) >= ThreatWatch.QUIET_LEVEL \
					and minf(w.level_of(q), w.raw_of(q)) - w.level >= CueTrack.CUE_MASK_GAP:
				masked += 1
				break
		if named != last and named != null and last != null:
			changes += 1
			if w.last_change in [&"attack", &"challenge", &"quiet"]:
				pref_changes += 1
				if w.raw_of(named) < ThreatWatch.QUIET_LEVEL:
					bad_pref += 1
				if w.last_change != &"attack" and t - last_pref < w.switch_hold_s - 1e-6:
					too_soon += 1
				last_pref = t
		last = named
	var tag := "warning on" if warn else "warning off"
	metric("busy_sky_%s" % ("warn" if warn else "plain"), {"changes": changes, "by_preference": pref_changes, "attack_s": attack_s})
	gt(float(pref_changes), 5.0, "(setup, %s) the name changes by preference now and then" % tag)
	gt(attack_s, 5.0, "(setup, %s) the player is attacked for a while" % tag)
	eq(not_own, 0, "%s: the level shown is always the named bird's own" % tag)
	eq(masked, 0, "%s: no live attack is ever masked (a hunter at attack strength unnamed while the cue shows %.2f less)" % [
			tag, CueTrack.CUE_MASK_GAP])
	eq(bad_pref, 0, "%s: the name never moves by preference to a bird that is no threat right now" % tag)
	eq(too_soon, 0, "%s: challenges and quiet hand-overs are at least switch_hold_s apart" % tag)


func test_an_attack_is_telegraphed_from_afar() -> void:
	# Core loop round (the lead's direction: "a telegraphed attack ... with
	# an audible/visible warning early enough to evade"; "danger marks only
	# on birds actually hunting the player"): a bird hunting the player is
	# named, marked (2) and shown at warn_level (0.2) from the moment it sets
	# off within warn_range (60 m, or 40 of its wingspans) - under attack
	# strength (0.3): announced, not an attack yet - and climbs from there
	# with its time to contact. A bird as big that is not hunting the player
	# shows no floor and no danger mark (unless named). Literal numbers.
	make_loop(false, true)
	var p := make_bird(0.03, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	loop.opening_respite_s = 0.0
	loop.set_protection(p, 1e6)
	p.velocity = Vector3.ZERO
	eq([loop.watch.warn_level, ThreatWatch.WARN_MIN_M, loop.watch.warn_spans], [0.2, 60.0, 40.0], "the warning's numbers")
	near(loop.watch.warn_range(1.6), 64.0, 1e-9, "a hawk's warning range: 40 of its wingspans, 64 m")
	near(loop.watch.warn_range(0.95), 60.0, 1e-9, "a crow's: 60 m")
	# A hawk hunting the player 50 m off (inside its highlight range, 54 m),
	# circling (not closing): named, marked, at the floor.
	var hawk := make_bird(1.3, Vector3(50, 30, 0), Vector3.FORWARD, false, true)
	hawk.velocity = Vector3(0, 0, -8)
	for i in int(1.0 / DT):
		loop.step(DT)
	eq(loop.watch.predator, hawk, "a hunter 50 m off is named")
	near(loop.watch.level, 0.2, 1e-3, "...at the warning's level")
	lt(loop.watch.level, GameLoop.ATTACK_LEVEL, "...under attack strength: no attack yet")
	check(not loop._attack_on, "(the loop has no attack on)")
	eq(int(hawk.model.highlight), 2, "...and marked as danger")
	# Beyond its range (70 m): nothing.
	hawk.global_position = Vector3(70, 30, 0)
	for i in int(2.0 / DT):
		loop.step(DT)
	eq(loop.watch.level, 0.0, "a hunter 70 m off (its range 64 m): not shown")
	# It comes in: the level climbs past the floor with its time to contact.
	hawk.global_position = Vector3(40, 30, 0)
	hawk.velocity = Vector3(-14, 0, 0)
	hawk.set_heading(Vector3.LEFT)
	var peak := 0.0
	for i in int(2.4 / DT):
		move(hawk, hawk.global_position + hawk.velocity * DT, hawk.velocity)
		loop.step(DT)
		peak = maxf(peak, loop.watch.level)
	gt(peak, 0.6, "closing in, the level climbs past the floor to the urgent cues (%.2f)" % peak)
	check(loop._attack_on, "...and it is an attack")
	# A hawk passing 30 m off, not hunting the player: no floor, no mark.
	birds.erase(hawk)
	hawk.free()
	for i in int(3.0 / DT):
		loop.step(DT)
	var other := make_bird(1.3, Vector3(30, 30, 0), Vector3.FORWARD, false, true)
	other.target = null
	other.velocity = Vector3(0, 0, -8)
	for i in int(1.0 / DT):
		move(other, other.global_position + other.velocity * DT, other.velocity)
		loop.step(DT)
	eq(loop.watch.level, 0.0, "a hawk not hunting the player 30 m off: nothing shown")
	eq(int(other.model.highlight), 0, "...and no danger mark")


func test_moths_are_easy_prey_to_the_cue() -> void:
	# The target cue weighs worth by how readily prey comes to a chase
	# (ThreatWatch.prey_ease; core loop round): a pellet (a swarm moth, duck
	# typed `pellet`) 1, a bird 0.3 - fleeing or not (a factor that fell as
	# a target fled moved the ring off it by preference). Literal. And by it
	# a moth 10 m off is ringed over a wren 30 m off, a wren 4 m off over it
	# (fix round 1: the switch ratio 3, was 2 - 5 m then).
	var p := _player(0.03)
	loop.set_protection(p, 600.0)
	var o := p.get_body_position()
	var bird := make_bird(0.012, o + Vector3(0, 0, -30))
	near(ThreatWatch.prey_ease(bird, p), 0.3, 1e-9, "a bird: 0.3")
	var moth := _Pellet.new()
	moth.mass = 0.004
	add_child(moth)
	moth.global_position = o + Vector3(0, 0, -10)
	near(ThreatWatch.prey_ease(moth, p), 1.0, 1e-9, "a pellet: 1")
	loop.step(DT)
	eq(loop.watch.target, moth, "a moth 10 m ahead is ringed over a wren 30 m ahead")
	bird.global_position = o + Vector3(0, 0, -4)
	for i in int((loop.watch.target_min_hold_s + 0.5) / DT):
		loop.step(DT)
	eq(loop.watch.target, bird, "...a wren 4 m ahead over the moth")
	moth.queue_free()


class _Pellet extends Bird:
	var pellet := true


func test_the_ui_and_the_loop_agree_on_highlights() -> void:
	# The UI marks the named predator itself (scripts/ui/ui_root.gd
	# _on_threat_changed / _on_target_changed, mirrored here): 2 while the
	# cue's level is at least its REAL_THREAT (0.1), else 0, and 0 on a bird
	# it stops naming. The loop marks danger (2) only on a bird hunting the
	# player or one that hunted it within DANGER_MARK_HOLD_S (core loop
	# round: not a bird merely named for passing close), and re-asserts its
	# value on the birds the UI just wrote: a hunter never ends a frame
	# unlit (fix round 4 review: a hawk passing 5-9 m away ended 10 of 720
	# frames unlit, and BirdModel's smoothing showed the flicker), and a bird
	# that is not hunting the player never ends one marked as danger, named
	# or not.
	make_loop(true, true)
	var p := make_bird(0.03, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	loop.opening_respite_s = 0.0
	loop.set_protection(p, 1e6)
	p.velocity = Vector3.ZERO
	var hawk := make_bird(1.3, Vector3(8, 30, 0), Vector3.RIGHT, false, true)
	hawk.target = null  # passing by, not hunting (the first half)
	var prey := make_bird(0.012, Vector3(0, 30, -6), Vector3.FORWARD, false, true)
	var ui := {"threat": null, "target": null}
	var mark := func(b: Variant, v: int) -> void:
		if b != null and is_instance_valid(b) and (b as Bird).get(&"model") != null:
			(b as Bird).get(&"model").set(&"highlight", v)
	var on_threat := func(level: float, predator: Bird) -> void:
		if ui["threat"] != predator:
			mark.call(ui["threat"], 0)
			ui["threat"] = predator
		mark.call(predator, 2 if level >= 0.1 else 0)
	var on_target := func(t: Bird) -> void:
		if ui["target"] != t:
			mark.call(ui["target"], 0)
			ui["target"] = t
			mark.call(t, 1)
	Events.threat_changed.connect(on_threat)
	Events.target_changed.connect(on_target)
	var frames := 0
	var unlit := 0
	var named_low := 0
	var disagree := 0
	var passive_frames := 0
	var passive_marked := 0
	var passive_named := 0
	var hunted_at := -INF
	var t := 0.0
	for i in 1440:
		t += DT
		if i == 720:
			hawk.target = p  # ...then it hunts the player
		if hawk.target == p:
			hunted_at = t
		# The hawk drifts past at 6 m/s, 5-9 m away: a low, changing threat.
		var k := i % 720
		move(hawk, Vector3(8.0 - 4.0 * sin(k * 0.01), 30.0, -20.0 + k * 6.0 / 72.0), Vector3(0, 0, 6))
		loop.step(DT)
		for b: SimBird in [hawk, prey]:
			if int(b.model.highlight) != int(loop.watch.highlights.get(b.get_instance_id(), 0)):
				disagree += 1
		if hawk.global_position.distance_to(p.global_position) < loop.watch.highlight_range(p.mass) * 0.9:
			var named := loop.watch.predator == hawk
			if t - hunted_at <= ThreatWatch.DANGER_MARK_HOLD_S - DT:
				frames += 1
				if int(hawk.model.highlight) != 2:
					unlit += 1
			elif t - hunted_at > ThreatWatch.DANGER_MARK_HOLD_S + DT:
				passive_frames += 1
				if int(hawk.model.highlight) == 2:
					passive_marked += 1
				if named:
					passive_named += 1
			if named and loop.watch.level < 0.1:
				named_low += 1
	Events.threat_changed.disconnect(on_threat)
	Events.target_changed.disconnect(on_target)
	metric("two_writers", {"frames_marked_due": frames, "frames_unlit": unlit, "frames_named_below_0.1": named_low,
		"frames_disagreeing": disagree, "frames_passive": passive_frames, "passive_marked": passive_marked, "passive_named": passive_named})
	gt(float(named_low), 10.0, "(setup) the UI's rule unlights the hawk on some frames (named below 0.1)")
	gt(float(frames), 600.0, "(setup) the hawk hunts the player, in highlight range")
	gt(float(passive_frames), 50.0, "(setup) the hawk passes by not hunting the player")
	gt(float(passive_named), 10.0, "(setup) ...named by the cue now and then (passing close)")
	eq(unlit, 0, "a bird hunting the player never ends a frame unlit")
	eq(passive_marked, 0, "a bigger bird not hunting the player never ends a frame marked as danger, named or not")
	eq(disagree, 0, "every model ends every frame with the loop's value")


func test_a_small_players_cue_reaches_its_sky() -> void:
	# The AI spreads birds over metric radii (70-230 m): a range in wingspans
	# alone would leave a sparrow's cue and highlights empty (the round-1
	# bug), so the ranges are at least a few seconds of flight - 6 s for the
	# target (core loop round; 4 s before: the sky's moth swarms are placed
	# just beyond the marks' reach and the ring must meet them as they come
	# in), 6 s for highlights. (Pinned by their effect: a mutant setting
	# target_range_s to 0 survived round 3.) Literal.
	var w := ThreatWatch.new()
	var cruise := SizeRules.cruise_speed(0.03)
	near(w.target_range(0.03), maxf(45.0 * SizeRules.wingspan_for_mass(0.03), 6.0 * cruise), 1e-6,
			"a sparrow's target range: 6 s of its cruise, or 45 wingspans")
	near(w.target_range(0.03), 54.0, 1e-6, "a sparrow's cue looks 54 m out (%.1f m)" % w.target_range(0.03))
	gt(w.highlight_range(0.03), 54.0 - 1e-6, "and its highlights at least 54 m (%.1f m)" % w.highlight_range(0.03))
	gt(w.target_range(0.03), 45.0 * SizeRules.wingspan_for_mass(0.03) * 2.0, "(the seconds, not the wingspans, set a sparrow's range)")
	metric("sparrow_ranges_m", {"target": w.target_range(0.03), "highlight": w.highlight_range(0.03), "cruise": cruise})


func test_a_big_players_ranges_are_its_wingspans() -> void:
	# For a big player the highlights' range in wingspans is the longer one
	# - an eagle's 70 of its spans (147 m, against 6 s of its cruise, 116 m):
	# the player's world_scale grows with its wingspan, so the marks reach as
	# far in the headset at every size. Its cue looks 6 s of its cruise out
	# (116 m; core loop round: 6 s, was 4 s - then 45 of its spans, 94.5 m,
	# was the longer). Pinned by their effect (fix round 5 review: mutants
	# setting 20 and 30 spans survived). Literal.
	var p := _player(3.0)
	loop.set_protection(p, 600.0)
	var span := p.get_wingspan()
	near(loop.watch.target_range(3.0), 6.0 * SizeRules.cruise_speed(3.0), 1e-6, "an eagle's target range: 6 s of its cruise")
	gt(loop.watch.target_range(3.0), 45.0 * span, "(the seconds are the longer, 116 m against 94.5 m)")
	near(loop.watch.highlight_range(3.0), 70.0 * span, 1e-6, "its highlight range: 70 wingspans")
	gt(70.0 * span, 6.0 * SizeRules.cruise_speed(3.0) + 10.0, "(setup) the wingspans, not the seconds, set an eagle's highlights")
	# A gull 85 m ahead is the target; another 130 m off to the side is lit.
	var near_gull := make_bird(0.85, Vector3(0, 0, -85), Vector3.FORWARD, false, true)
	var far_gull := make_bird(0.85, Vector3(-90, 0, -94), Vector3.FORWARD, false, true)
	loop.step(DT)
	eq(loop.watch.target, near_gull, "a gull 85 m ahead is an eagle's target")
	eq(far_gull.model.highlight, 1, "a gull 130 m away is lit as worthwhile prey")
	eq(near_gull.model.highlight, 1, "(and the nearer one)")


func test_near_equals_are_neither_prey_nor_danger() -> void:
	# Only a bird EAT_RATIO heavier can eat the player: one 1.0-1.24x its mass
	# closing fast is no threat and not lit as danger, one 0.81-1x is not
	# prey; at 1.25x it is.
	var p := _player(0.1)
	loop.set_protection(p, 600.0)
	var o := p.get_body_position()
	var peers: Array[SimBird] = []
	for k in [1.0, 1.1, 1.24]:
		var q := make_bird(0.1 * k, o + Vector3(k * 4.0 - 4.0, 0, -3.0), Vector3.BACK, false, true)
		q.velocity = Vector3(0, 0, 10)
		q.target = p
		peers.append(q)
	var small := make_bird(0.1 * 0.85, o + Vector3(-2, 0, -4), Vector3.FORWARD, false, true)
	for i in 10:
		for q in peers:
			q.global_position += q.velocity * DT
		loop.step(DT)
	for q in peers:
		eq(q.model.highlight, 0, "a %.2fx bird is not lit as danger" % (q.mass / p.mass))
	eq(small.model.highlight, 0, "a 0.85x bird is not lit as prey")
	eq(loop.watch.predator, null, "no near-equal is named as a threat")
	eq(loop.watch.level, 0.0, "threat level stays 0")
	check(loop.watch.target != small, "a near-equal is never the target")
	var big := make_bird(0.125, o + Vector3(0, 0, -2.0), Vector3.BACK, false, true)
	big.velocity = Vector3(0, 0, 10)
	loop.step(DT)
	eq(big.model.highlight, 2, "at 1.25x it can eat the player: danger")
	eq(loop.watch.predator, big, "...and a threat")


func test_prey_behind_is_never_auto_targeted() -> void:
	# The cue points ahead (within 110 deg of the heading): a lone worthwhile
	# bird behind the player is never picked, one off to the side is.
	var p := _player(0.09)
	loop.set_protection(p, 600.0)
	var span := p.get_wingspan()
	var o := p.get_body_position()
	var at := func(deg: float) -> Vector3:
		var a := deg_to_rad(deg)
		return o + Vector3(sin(a), 0, -cos(a)) * 10.0 * span
	var behind := make_bird(0.03, at.call(150.0), Vector3.FORWARD)
	loop.step(DT)
	eq(loop.watch.target, null, "a bird 150 deg off the heading is never the target")
	behind.global_position = at.call(120.0)
	loop.step(DT)
	eq(loop.watch.target, null, "...nor at 120 deg")
	behind.global_position = at.call(100.0)
	loop.step(DT)
	eq(loop.watch.target, behind, "at 100 deg it is")
	# Once picked, it stays the target if the player turns away a little
	# (hysteresis on the angle: the current target is kept behind the limit).
	behind.global_position = at.call(125.0)
	loop.step(DT)
	eq(loop.watch.target, behind, "the current target is kept past the angle limit")


func test_dead_birds_lose_their_highlight() -> void:
	var p := _player(0.09)
	loop.set_protection(p, 600.0)
	var o := p.get_body_position()
	var prey := make_bird(0.03, o + Vector3(0, 0, -10), Vector3.FORWARD, false, true)
	var hawk := make_bird(1.3, o + Vector3(3, 0, -20), Vector3.FORWARD, false, true)
	loop.step(DT)
	eq([prey.model.highlight, hawk.model.highlight], [1, 2], "(setup) lit")
	prey.alive = false
	hawk.alive = false
	loop.step(DT)
	eq([prey.model.highlight, hawk.model.highlight], [0, 0], "a bird that died is unlit on the next frame")
	check(not loop.watch.highlights.has(prey.get_instance_id()), "...and forgotten")


func test_target_selection_and_hysteresis() -> void:
	var p := _player(0.09)  # starling
	loop.set_protection(p, 600.0)
	var span := p.get_wingspan()
	# Candidates (all well outside catch reach):
	var tiny := make_bird(0.004, Vector3(0, 30, -3 * span), Vector3.FORWARD)  # moth: not worth it
	var good := make_bird(0.03, Vector3(1 * span, 30, -12 * span), Vector3.FORWARD)  # sparrow ahead
	var behind := make_bird(0.055, Vector3(0, 30, 10 * span), Vector3.FORWARD)  # swallow behind (edible? no: 0.09 < 0.069? yes edible)
	loop.step(DT)
	check(not SizeRules.is_worthwhile(p.mass, tiny.mass), "(setup) moth not worthwhile for a starling")
	eq(loop.watch.target, good, "best worthwhile prey ahead is the target, not the closer moth or the one behind")
	check(loop.watch.target != tiny, "tiny prey never targeted")
	# Twin prey trading places by +-10% score: no switching.
	var twin := make_bird(0.03, Vector3(-1 * span, 30, -12 * span), Vector3.FORWARD)
	var switches := 0
	var last: Bird = loop.watch.target
	for i in int(5.0 / DT):
		var wob := 0.6 * span * (1.0 if (i / 9) % 2 == 0 else -1.0)
		good.global_position = Vector3(1 * span, 30, -12 * span + wob)
		twin.global_position = Vector3(-1 * span, 30, -12 * span - wob)
		loop.step(DT)
		if loop.watch.target != last:
			switches += 1
			last = loop.watch.target
	eq(switches, 0, "near-equal prey do not flicker the target")
	# The pair drifts off (the player is not gaining on its target), and a
	# clearly better prey appears ahead - as catchable, much nearer, over
	# target_switch_ratio x the score: switch (the target has been held
	# longer than the minimum hold).
	good.global_position = Vector3(1 * span, 30, -30 * span)
	twin.global_position = Vector3(-1 * span, 30, -30 * span)
	run_steps(int(loop.watch.target_commit_s / DT) + 2, DT)
	check(not loop.watch.target_committed, "(setup) not committed: the player is not closing on its target")
	var prize := make_bird(0.03, Vector3(0, 30, -3 * span), Vector3.FORWARD)
	var frames := 0
	while loop.watch.target != prize and frames < int((loop.watch.target_min_hold_s + 1.0) / DT):
		loop.step(DT)
		frames += 1
	eq(loop.watch.target, prize, "a clearly better prey becomes the target")
	lt(frames * DT, loop.watch.target_min_hold_s + 2 * DT, "switch happens within the hold time")
	# Target eaten by someone else: target moves on immediately.
	start_logging()
	prize.alive = false
	loop.step(DT)
	check(loop.watch.target != prize, "dead target dropped")
	eq(count("target"), 1, "target_changed emitted once")


func test_events_and_highlights_through_loop() -> void:
	var p := _player(0.09)
	loop.set_protection(p, 600.0)
	start_logging()
	var hawk := make_bird(1.3, Vector3(0, 30, -25), Vector3.BACK, false, true)
	var prey := make_bird(0.03, Vector3(0.5, 30, -2), Vector3.FORWARD, false, true)
	var moth := make_bird(0.004, Vector3(-0.5, 30, -1), Vector3.FORWARD, false, true)
	hawk.velocity = Vector3(0, 0, 10)
	for i in 30:
		hawk.global_position += hawk.velocity * DT
		loop.step(DT)
	eq(hawk.model.highlight, 2, "danger highlight on the hawk")
	eq(prey.model.highlight, 1, "edible highlight on worthwhile prey")
	eq(moth.model.highlight, 0, "no highlight on prey not worth eating")
	var t := events("target")
	check(t.size() >= 1 and t[0][1] == prey, "target_changed(prey)")
	var th := events("threat")
	check(th.size() > 3, "threat_changed emitted as the hawk closes")
	check(th[-1][2] == hawk, "threat names the hawk")
	gt(float(th[-1][1]), 0.3, "threat level rising")
	# Caught -> cues cleared.
	loop.set_protection(p, 0.0)
	hawk.global_position = p.get_body_position() + Vector3(0, 0, -0.3)
	loop.step(DT)
	eq(Game.state, Game.State.CAUGHT, "caught")
	eq(float(events("threat")[-1][1]), 0.0, "threat cue reset on death")
	eq(events("target")[-1][1], null, "target cleared on death")
	eq(prey.model.highlight, 0, "highlights cleared on death")
	eq(hawk.model.highlight, 0, "danger highlight cleared on death")


## Median of the watch pass (µs) over `frames` steps, best of `tries`
## windows: other agents' Godot runs share this machine, and a single window's
## tail catches their load, not this code (the p95 is reported, not asserted).
func _watch_cost(frames: int, tries: int, mover: Callable = Callable()) -> Dictionary:
	var best := INF
	var p95 := INF
	var p99 := INF
	var worst := INF
	for k in tries:
		var times: Array[float] = []
		for s in frames:
			if mover.is_valid():
				mover.call()
			loop.step(DT)
			times.append(float(loop.perf["watch"]))
		times.sort()
		if times[frames / 2] < best:
			best = times[frames / 2]
			p95 = times[int(frames * 0.95)]
			p99 = times[int(frames * 0.99)]
			worst = times[-1]
	# (p99 and the worst frame are reported, not asserted: on this shared
	# machine a single frame's time is mostly how long the OS held the
	# process off the CPU.)
	return {"median": best, "p95": p95, "p99": p99, "max": worst}


func test_watch_cost_60_birds() -> void:
	var p := _player(0.35)  # pigeon: plenty of both prey and predators
	loop.set_protection(p, 600.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for i in 59:
		var m := exp(rng.randf_range(log(0.004), log(4.5)))
		var pos := Vector3(rng.randf_range(-40, 40), 30 + rng.randf_range(-10, 10), rng.randf_range(-40, 40))
		var b := make_bird(m, pos, Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)), false, true)
		b.velocity = b.heading * 8.0
	var c := _watch_cost(150, 3)
	metric("watch_us_median", c["median"])
	metric("watch_us_p95", c["p95"])
	metric("watch_us_p99_max", [c["p99"], c["max"]])
	lt(c["median"], 300.0, "threat/target/highlight pass for 60 birds < 0.3 ms (median)")


func test_watch_cost_in_the_worst_60_bird_frames() -> void:
	# The review's worst plausible frames (fix round 5: 280-289 µs median on
	# round 4's pass, just under the bar): 59 predators all hunting and
	# closing on the player (every one a threat track and a strike check),
	# and 59 worthwhile prey all in the target range with static geometry
	# around (the cue casts sight rays). The pass keeps one record per bird
	# (its model, its intent), inlines time-to-contact and prunes records
	# instead of erasing per bird: ~200 µs for both on the dev Mac.
	var walls: Array[StaticBody3D] = []
	for k in 12:
		var sb := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(2, 8, 2)
		cs.shape = box
		sb.add_child(cs)
		add_child(sb)
		sb.global_position = Vector3(cos(k * 0.52) * 9.0, 30, sin(k * 0.52) * 9.0)
		walls.append(sb)
	await get_tree().physics_frame
	var res := {}
	for mode in ["hunters", "prey"]:
		make_loop()
		var p := make_bird(0.3 if mode == "hunters" else 1.3, Vector3(0, 30, 0), Vector3.FORWARD, true)
		loop.start_run()
		loop.set_protection(p, 1e6)
		var rng := RandomNumberGenerator.new()
		rng.seed = 7
		var others: Array[SimBird] = []
		for k in 59:
			var ang := rng.randf() * TAU
			var d := rng.randf_range(6.0, 30.0)
			var pos := Vector3(cos(ang) * d, 30 + rng.randf_range(-5, 5), sin(ang) * d)
			var m := rng.randf_range(0.5, 3.0) if mode == "hunters" else rng.randf_range(0.2, 0.9)
			var b := make_bird(m, pos, (Vector3(0, 30, 0) - pos).normalized(), false, true)
			b.velocity = (Vector3(0, 30, 0) - pos).normalized() * 6.0
			others.append(b)
		loop.step(DT)
		await get_tree().physics_frame
		var c := _watch_cost(120, 3, func() -> void:
			for b in others:
				b.global_position += b.velocity * DT * 0.2)
		res[mode] = c
		metric("worst_frames_%s_us" % mode, c)
		lt(c["median"], 300.0, "%s: the watch pass for 60 birds < 0.3 ms (median %.0f µs, p95 %.0f)" % [mode, c["median"], c["p95"]])
		await cleanup()
	for w in walls:
		w.queue_free()


func test_watch_cost_with_the_valleys_refuges() -> void:
	# The shipped valley has ~300 refuges, most of them hedgerow hollows a
	# starling fits (SoaringWorld: 296). The worst case the review found: a
	# pigeon with a 30-starling murmuration inside its target range (each a
	# candidate the refuge test used to scan every refuge for) and 29 other
	# birds. Here with 320 refuges, 280 of them packed round the player.
	var world := _RefugeWorld.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 296
	for i in 320:
		var near := i < 280
		var a := rng.randf() * TAU
		var r := sqrt(rng.randf()) * (60.0 if near else 600.0)
		world.refuges.append({"name": "r%d" % i, "position": Vector3(cos(a) * r, 30.0 + rng.randf_range(-8, 8), sin(a) * r),
			"radius": rng.randf_range(0.3, 1.5), "max_span": 0.40 if near else rng.randf_range(0.2, 2.5)})
	add_child(world)
	make_loop()
	await get_tree().process_frame  # the loop finds the world (deferred)
	var p := make_bird(0.35, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	p.global_position = Vector3(0, 30, 0)
	p.mass = 0.35
	loop.set_protection(p, 600.0)
	p.velocity = Vector3.FORWARD * 12.0
	var movers: Array[SimBird] = []
	for i in 30:
		var b := make_bird(0.1, p.global_position + Vector3(rng.randf_range(-12, 12), rng.randf_range(-6, 6), -rng.randf_range(10, 40)),
				Vector3.FORWARD, false, true)
		b.velocity = Vector3.FORWARD * 11.0
		loop.set_protection(b, 600.0)
		movers.append(b)
	for i in 29:
		var m := exp(rng.randf_range(log(0.004), log(4.5)))
		var b := make_bird(m, p.global_position + Vector3(rng.randf_range(-60, 60), rng.randf_range(-15, 15), rng.randf_range(-60, 60)),
				Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)), false, true)
		b.velocity = b.heading * 9.0
		loop.set_protection(b, 600.0)
		movers.append(b)
	eq(loop._refuges.size(), 320, "(setup) the loop took the world's refuges")
	var sheltered := 0
	for b in movers:
		if loop.is_sheltered(b, p.get_wingspan()):
			sheltered += 1
	# Drift the whole scene slowly so the birds pass through the refuges.
	var drift := func() -> void:
		for b in movers:
			b.global_position += Vector3(0, 0, -0.02)
	var with := _watch_cost(150, 3, drift)
	var keep := world.refuges
	loop._refuges = [] as Array[Dictionary]
	loop.watch.refuges = [] as Array[Dictionary]
	var without := _watch_cost(150, 3, drift)
	loop._refuges = keep
	loop.watch.refuges = keep
	metric("watch_us_refuges", {"with_320": with, "without": without, "birds_sheltered_at_start": sheltered})
	lt(with["median"], 300.0, "watch pass < 0.3 ms (median) for 60 birds with the valley's refuge count")
	lt(with["median"], without["median"] * 1.5 + 20.0, "the refuges add little to the pass")
	world.queue_free()


class _RefugeWorld extends World:
	var refuges: Array[Dictionary] = []

	func get_refuges() -> Array[Dictionary]:
		return refuges
