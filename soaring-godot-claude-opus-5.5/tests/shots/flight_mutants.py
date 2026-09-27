#!/usr/bin/env python3
"""Mutation runs for the flight area's fixes (rounds 1 to 6): each mutant
breaks one fix in a PRIVATE copy of the project (rsynced to
.sandboxes/flight_mutants/proj, which Godot and git ignore), runs the test
meant to catch it through that copy's own tools/gd.sh, and restores the
file. The shared tree is never edited, so no other agent can ever load a
mutant.

  python3 tests/shots/flight_mutants.py [substring | round=N]   # all, matching ids, or one round

Writes artifacts/flight/mutants.json (every field below is written by this
script: nothing is added by hand). Expected: every mutant CAUGHT except the
redundant second layers named in FLIGHT.md §6.
"""
import os, subprocess, sys, json, re, time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WORK = os.path.join(REPO, ".sandboxes", "flight_mutants")
ROOT = os.path.join(WORK, "proj")
HS = "scripts/flight/heave_smoother.gd"
PB = "scripts/flight/player_bird.gd"
FM = "scripts/flight/flight_model.gd"
WI = "scripts/flight/wing_input.gd"
VT = "scripts/flight/view_turn.gd"
FT = "scripts/flight/flight_tuning.gd"
FD = "scripts/flight/flap_detector.gd"

# (id, round, file, old, new, suite, test filter, expected catcher)
MUTANTS = [
    # --- round 1 fixes ---
    ("F3a sep:=0", 1, FM, "var sep := maxf(sigma, s_geo)", "var sep := 0.0", "flight/flight_model", "fm05", "FM-05 / FM-05c"),
    ("F3b sep*0.5", 1, FM, "var sep := maxf(sigma, s_geo)", "var sep := 0.5 * maxf(sigma, s_geo)", "flight/flight_model", "fm05", "FM-05 / FM-05c"),
    ("POSE pose_sane=true", 1, WI, "static func pose_sane(tr: Transform3D) -> bool:\n",
     "static func pose_sane(tr: Transform3D) -> bool:\n\treturn true\n", "flight/wing_input", "wi30", "WI-30"),
    ("POSE gate off", 1, WI, "\t\tif have and tr.origin.distance_to(pose.origin) > JUMP + v_lim * age:",
     "\t\tif false and tr.origin.distance_to(pose.origin) > JUMP + v_lim * age:", "flight/wing_input", "wi30", "WI-30"),
    ("POSE no bridge", 1, WI, "\t\telif g.have and g.age <= BRIDGE_S:", "\t\telif false:", "flight/wing_input", "wi30", "WI-30"),
    ("PERCH one-tick stop", 1, PB, "\t_capture(cand, from, model.velocity)", "\tmodel.position = closest\n\t_capture(cand)",
     "flight/perch", "p9", "P9"),
    ("TEL stale perched", 1, PB, "\tif t[\"perched\"]:\n\t\t# A gripping", "\tif false:\n\t\t# A gripping", "flight/perch", "p9", "P9"),
    ("TRIM live sigma", 1, FM, "\tvar s0 := sigma\n\tsigma = 0.0\n\tvar cd := _cd_of(a_cmd, cl, 1.0, 0.0, INF)",
     "\tvar s0 := sigma\n\tvar cd := _cd_of(a_cmd, cl, 1.0, 0.0, INF)", "flight/flight_model", "fm31", "FM-31"),
    ("ZOOM filtered speed", 1, FM, "\tvar v_gate := minf(_v_lp, va2_len)", "\tvar v_gate := _v_lp", "flight/flight_model", "fm30", "FM-30"),
    ("ZOOM no ff clamp", 1, FM, "\t\ttheta += clampf(tw * tw * (3.0 - 2.0 * tw) * wrapf(g2 - g0, -PI, PI), -qh, qh)",
     "\t\ttheta += tw * tw * (3.0 - 2.0 * tw) * wrapf(g2 - g0, -PI, PI)", "flight/flight_model", "fm30", "FM-30"),
    ("ZOOM protect snaps", 1, FM, "\t\ttheta = maxf(theta - qh, minf(theta, g2 + _c_alpha_s - _r_enter))",
     "\t\ttheta = minf(theta, g2 + _c_alpha_s - _r_enter)", "flight/flight_model", "fm30", "FM-30"),
    ("LEAK fixture cycle", 1, "tests/unit/flight/pb_fixture.gd",
     "\tif src != null:\n\t\tsrc.driver = Callable()\n\t\tsrc.body = null\n\tsrc = null\n\tdriver = Callable()\n\ton_tick = Callable()",
     "\tpass", "flight/player_bird", "pb21", "PB-21"),
    ("LEAK plot backref", 1, "scripts/flight/flight_plot.gd",
     "\t\tget:\n\t\t\treturn _plot_ref.get_ref() as FlightPlot if _plot_ref != null else null\n\t\tset(v):\n\t\t\t_plot_ref = weakref(v) if v != null else null",
     "\t\tget:\n\t\t\treturn _strong\n\t\tset(v):\n\t\t\t_strong = v\n\tvar _strong: FlightPlot",
     "flight/player_bird", "pb21", "PB-21"),
    ("REPLAY ahead", 1, "scripts/flight/pose_sources/replay_pose_source.gd", "\tvar t_now := t\n\tt += dt", "\tt += dt\n\tvar t_now := t",
     "flight/wing_input", "wi29", "WI-29"),
    ("NODES raw frame", 1, PB, "\tvar hd := wing_input.head", "\tvar hd := frame.head", "flight/player_bird", "pb19", "PB-19"),
    ("HEAD raw frame", 1, PB, "\tvar h := wing_input.head.origin", "\tvar h := frame.head.origin", "flight/player_bird", "pb19", "PB-19"),
    ("PAUSE every tick", 1, PB, "\tif wing_input.pause_requested and not _pause_sent:", "\tif wing_input.pause_requested:",
     "flight/player_bird", "pb20", "PB-20"),
    # --- camera heave (round 1 design kept, round 2 gates) ---
    ("HEAVE no smoothing", 1, HS, "\toffset = soft_clamp(off * gain * gate, lim)", "\toffset = 0.0", "flight/heave", "steady", "PB-08b steady"),
    ("HEAVE raw weights", 1, HS, "\t\tvar a := ws[2 * k - 1]\n\t\tvar b := ws[2 * k]", "\t\tvar a := w[2 * k - 1]\n\t\tvar b := w[2 * k]",
     "flight/heave", "", "HS / PB-08b / PB-08c"),
    ("HEAVE period step", 1, HS, "\tperiod = clampf(period + _period_v * dt, T_MIN, T_MAX)", "\tperiod = clampf(_period_t, T_MIN, T_MAX)",
     "flight/heave", "", "HS / PB-08b / PB-08c"),
    ("HEAVE hard clamp", 1, HS, "\toffset = soft_clamp(off * gain * gate, lim)", "\toffset = clampf(off * gate, -0.3 * lim, 0.3 * lim)",
     "flight/heave", "", "HS / PB-08b / PB-08c"),
    ("HEAVE no rhythm gate", 2, HS, "\tvar active := rhythm_open and arm_ok and _ph_gain > 0.0", "\tvar active := arm_ok and _ph_gain > 0.0",
     "flight/heave", "", "PB-08b / PB-08c"),
    ("HEAVE no phase gain", 2, HS,
     "\tvar active := rhythm_open and arm_ok and _ph_gain > 0.0\n\tvar w_act := W_OPEN if active else W_CLOSE\n\tif not active and not arm_ok:\n\t\t# Arms at rest: the template is frozen (its phase stopped with the\n\t\t# arms), so it can fade slowly without moving the view.\n\t\tw_act = W_REST\n\tvar target := _ph_gain if active else 0.0",
     "\tvar active := rhythm_open and arm_ok\n\tvar w_act := W_OPEN if active else W_CLOSE\n\tif not active and not arm_ok:\n\t\tw_act = W_REST\n\tvar target := 1.0 if active else 0.0",
     "flight/heave", "", "HS-4 / PB-08c"),
    ("HEAVE no arm gates", 2, HS,
     ["\t\tarm_ok = _arms(arm_rate, om, dt)\n\t\tvar ratio := _amp_r / maxf(_amp_lvl, 1e-3)\n\t\tamp_t = _smooth01((ratio - AMP_LO) / (AMP_HI - AMP_LO))",
      "\t\tpf_t = _smooth01((ratio - PF_LO) / (PF_HI - PF_LO)) if arm_ok else 0.0"],
     ["\t\t_arms(arm_rate, om, dt)", "\t\tpass"], "flight/bot_course", "b2", "B2 eagle s8 (heave no-harm)"),
    ("HEAVE no benefit gate", 2, HS, "\tgate = _q * _act * _amp * _on", "\tgate = _act * _amp * _on", "flight/heave", "", "PB-08b / PB-08c"),
    ("HEAVE no jerk limit", 2, HS, "\t_act_f += (target - _act_f) * (1.0 - exp(-dt * JERK_K * w_act))", "\t_act_f = target",
     "flight/heave", "", "PB-08c"),
    ("HEAVE opens on 1st rhythm", 2, HS, "const RHYTHM_NEED := 3", "const RHYTHM_NEED := 1", "flight/heave", "", "PB-08b / PB-08c"),
    ("HEAVE no freeze at rest", 2, HS, ["\t\t_theta = fposmod(_theta + om * dt * _pf, TAU)", "\tif not active and not arm_ok:\n"],
     ["\t\t_theta = fposmod(_theta + om * dt, TAU)", "\tif false:\n"], "flight/bot_course", "b2", "B2 eagle s8 (heave no-harm)"),
    # --- round 2 fixes ---
    ("REG no super", 2, PB, "\tsuper()\n\tif recorder != null:", "\tif recorder != null:", "flight/player_bird", "pb23", "PB-23"),
    ("EVT flapped", 2, PB, "\t\t\tEvents.player_flapped.emit(int(e[0]), float(e[1]))", "\t\t\tpass", "flight/player_bird", "s5", "PB-13 S5"),
    ("EVT stalled", 2, PB, "\t\t\tEvents.player_stalled.emit()", "\t\t\tpass", "flight/player_bird", "s5", "PB-13 S5"),
    ("PAUSE always", 2, PB, "\tprocess_mode = Node.PROCESS_MODE_PAUSABLE", "\tprocess_mode = Node.PROCESS_MODE_ALWAYS",
     "flight/player_bird", "s2_real", "PB-13 S2 (real tree)"),
    ("PB14 no mirror", 2, WI, "\t\t\ttarget_w = clampf((_lost_t[i] - 0.25) / 0.6, 0.0, 1.0)", "\t\t\ttarget_w = 0.0",
     "flight/player_bird", "pb14", "PB-14"),
    ("ARC no bank", 2, "scripts/flight/flap_detector.gd", "\t\t\tvar use := minf(d, bank)", "\t\t\tvar use := d",
     "flight/flap_detector", "arc_bank", "F9 arc bank"),

    ("JITTER passes", 2, WI, "\tvar t_s := _dejitter(0.5 * (twists[0] + twists[1]), dt)", "\tvar t_s := 0.5 * (twists[0] + twists[1])",
     "flight/flap_detector", "twist_jitter", "F9 twist jitter"),
    # --- round 3 fixes ---
    ("VIEW drops heading steps", 3, PB, "\t\tview_turn.owe(jump)\n", "\t\tview_turn.owe(0.0)\n", "flight/collision", "c8b", "C8b"),
    ("BODYSTEER stale rig", 3, PB, "var e := FlightMath.wrap_angle(rig_yaw + view_turn.debt + _ws.body_yaw - psi0)",
     "var e := FlightMath.wrap_angle(rig_yaw + _ws.body_yaw - psi0)", "flight/collision", "c8b", "C8b"),
    ("FLOOR bounce 0.25", 3, PB, "tuning.floor_restitution if floor_hit else 0.25", "0.25", "flight/collision", "c9", "C9"),
    ("TELEPORT keeps rate", 3, PB, "func _reset_rig_motion() -> void:\n\trig_yaw_rate = 0.0\n\trig_yaw_accel = 0.0\n\t_ff_rate = 0.0\n\tview_turn.reset()\n\t_bs_lag = 0.0\n\t_bank_lag = 0.0\n\t_body_share = 0.0\n",
     "func _reset_rig_motion() -> void:\n", "flight/player_bird", "pb24", "PB-24"),
    ("WORLD looked up once", 3, PB, "\tif _world == null and tick_count != _world_tick and is_inside_tree():",
     "\tif _world == null and _world_tick < 0 and is_inside_tree():", "flight/player_bird", "pb25", "PB-25"),
    ("TEL in_updraft 0", 3, PB, "\tt[\"in_updraft\"] = maxf(0.0, m.wind.y)", "\tt[\"in_updraft\"] = 0.0", "flight/player_bird", "pb25", "PB-25"),
    ("GRP no player group", 3, PB, "\tadd_to_group(&\"player\")\n", "", "flight/player_bird", "pb25", "PB-25"),
    ("GUST heading follows air", 3, FM, ["\t\t_absorb_wind_turn(velocity, w0, wc)", "\t\t_absorb_wind_turn(velocity, w2, wc2)"],
     ["\t\tpass", "\t\tpass"], "flight/player_bird", "pb26", "PB-26"),
    ("F1 up_gain ignored", 3, FM, "\t\t\tvar e := dn + _c_up_gain * up", "\t\t\tvar e := dn + 1.0 * up", "flight/flight_model", "fm11b", "FM-11b"),
    ("F1 up_gain ignored (chain)", 3, FM, "\t\t\tvar e := dn + _c_up_gain * up", "\t\t\tvar e := dn + 1.0 * up", "flight/flap_detector", "f1_flap", "flap_detector f1"),
    ("PERCH no hold (2nd layer)", 3, PB, "\tvar held := _assist_perch\n", "\tvar held: Perch = null\n", "flight/perch", "p10", "P10 (expected to survive: second layer)"),
    ("PERCH capture on airspeed", 3, PB, "\tif _landing_speed() > v_cap or -model.velocity.y > v_cap:",
     "\tif model.airspeed() > v_cap or -model.velocity.y > v_cap:", "flight/perch", "p10", "P10"),
    ("PERCH no wind budget", 3, PB, "\tvar cap := a.y * FlightMath.G + minf(w_perp.length() * 3.0 / maxf(t_go, 0.15), 0.5 * FlightMath.G)",
     "\tvar cap := a.y * FlightMath.G", "flight/perch", "p10", "P10"),
    ("PERCH still-air brake", 3, PB, "\t\tvar a_req := dv * maxf(vg - 0.5 * dv, 0.1) / maxf(dist - 0.5 * p.span, 0.05)",
     "\t\tvar a_req := (v * v - v_arrive * v_arrive) / (2.0 * maxf(dist - 0.5 * p.span, 0.05))", "flight/perch", "p11",
     "P11 (since round 5 expected to survive: second layer, FLIGHT.md §8)"),
    ("PERCH brake ignores dive", 3, PB, "\t\tvar a_along := maxf(a_nat.dot(vel / vg), 0.0)", "\t\tvar a_along := 0.0", "flight/perch", "p11", "P11"),
    ("PERCH crab turns the view", 3, PB, "\tif env.accel != Vector3.ZERO and mode == Mode.FLYING:\n\t\tvar va := model.velocity - model.wind",
     "\tif false:\n\t\tvar va := model.velocity - model.wind", "flight/perch", "p10", "P10"),
    ("RIG no soft follow", 3, PB, "\t\tif comfort_caps and model.comfort_yaw_accel > 0.0:\n\t\t\tvar soft := 0.5 * model.comfort_yaw_accel * dt",
     "\t\tif false:\n\t\t\tvar soft := 0.5 * model.comfort_yaw_accel * dt",
     "flight_perchwind_sweep --dir=res://tests/shots --set=verifier --species=sparrow", "", "perch wind sweep (verifier set, rig accel)"),
    # --- round 4 fixes (the round-3 "VIEW pays at once", "STUN no leave turn" and
    # "PERCH capture stops the view" mutants targeted code round 4 replaced) ---
    ("VIEW continuous stop curve", 4, VT, "\tvar v_stop := ae / (dt * (n + 1.0)) + a_dt * n * 0.5",
     "\tvar v_stop := sqrt(2.0 * max_acc * ae)", "flight/view_turn", "", "VT-1 / VT-2"),
    ("VIEW no accel cap", 4, VT, "\tvar v := clampf(v_want, rate - a_dt, rate + a_dt)", "\tvar v := v_want", "flight/view_turn", "", "VT-1"),
    ("VIEW lands past the cap", 4, VT, " and absf(paid) >= ae and absf(e / dt - rate) <= a_dt:", " and absf(paid) >= ae:",
     "flight/view_turn", "", "VT-1"),
    ("RIG turns on the ground", 4, PB, "\t\t# Perched or grounded the heading follows the view: nothing is owed.\n\t\t_ff_rate = 0.0\n\t\tview_turn.reset()",
     "\t\t_ff_rate = 0.0\n\t\tturn = rig_yaw_rate * dt", "flight/collision", "c10", "C10"),
    ("STUN turn uncapped", 4, FM, "\t\tpsi = h0 + clampf(turn, -cap, cap)", "\t\tpsi = h0 + turn", "flight/collision", "c8b", "C8b"),
    ("SWEEP guesses the normal (round 3)", 4, PB,
     "\t\t\t_sphere.radius = p.r_body + 0.002\n\t\t\tinfo = space.get_rest_info(_shape_q)\n\t\t\t_sphere.radius = p.r_body",
     "\t\t\tinfo = {\"normal\": -motion.normalized(), \"point\": hit_pos + motion.normalized() * p.r_body}",
     "flight/collision", "c11", "C11"),
    ("SEAT keeps a path it does not face", 4, FM, "\t\t\tvelocity = wind + Vector3(0.0, va.y, 0.0)\n\t\t\tchi = psi\n\t\t\tdpsi = 0.0\n\t\t\treturn",
     "\t\t\tchi = psi\n\t\t\tdpsi = 0.0\n\t\t\treturn", "flight/collision", "c8b", "C8b"),
    ("FLAP side force", 4, FM, "\t\t\tdh -= r_b * (dh.dot(r_b) * (1.0 - _t_flap_side))\n", "", "flight/player_bird", "pb28", "PB-28 / FM-18b"),
    ("KICK instantaneous", 4, FM, "_r_kick * (_as_l - _as_r) \\", "_r_kick * (_p_l - _p_r) \\", "flight/player_bird", "pb27", "PB-27"),
    ("KICK dead zone not rescaled", 4, FM, "\t\t\tk_dz = (rel - _t_kick_dz) / ((1.0 - _t_kick_dz) * rel)", "\t\t\tk_dz = 1.0",
     "flight/flight_model", "fm18c", "FM-18c"),
    ("KICK no dead zone (all rel)", 4, FM, "\t\tif rel > _t_kick_dz:\n", "\t\tif true:\n", "flight/player_bird", "pb27", "PB-27"),
    ("PERCH launch at onset", 4, PB, "\t\tif d.onset and d.onset_strength >= 0.35:\n\t\t\t_launch_pend[i] = d.onset_strength",
     "\t\tif d.onset and d.onset_strength >= 0.35:\n\t\t\tout = maxf(out, d.onset_strength)\n\t\t\t_launch_pend[i] = d.onset_strength",
     "flight/perch", "p6_resting", "P6"),
    ("PERCH folded launches", 4, PB, "\t\t\t\tif wing_out:\n\t\t\t\t\tout = maxf(out, _launch_pend[i])\n\t\t\t\t\t_launch_pend[i] = 0.0\n\t\t\t\telse:",
     "\t\t\t\tif true:\n\t\t\t\t\tout = maxf(out, _launch_pend[i])\n\t\t\t\t\t_launch_pend[i] = 0.0\n\t\t\t\telse:", "flight/perch", "p6_resting", "P6"),
    ("TEL tucked on a perch", 4, PB, "\tt[\"tucked\"] = w.tucked and mode != Mode.PERCHED and mode != Mode.GROUNDED", "\tt[\"tucked\"] = w.tucked",
     "flight/perch", "p6_resting", "P6"),
    ("DT no clamp", 4, PB, "\tdt = minf(dt, 0.1)\n", "", "flight/player_bird", "pb19b", "PB-19b"),
    ("NAN guard off", 4, FM, "\tif not ok:\n\t\tif not _guard_logged:", "\tif false:\n\t\tif not _guard_logged:", "flight/flight_model", "fm23b", "FM-23b"),
    # --- round 5: the round-5 engineering verifier's four survivors (its own
    # patterns, tests/probes r5eng_mut.py) ...
    ("SWEEP single cast (no slide continuation)", 5, PB, "\t\t\t_apply_exclusions()\n\tfor it in 3:", "\t\t\t_apply_exclusions()\n\tfor it in 1:",
     "flight/collision", "c12", "C12"),
    ("CAMERA near ignores world_scale", 5, PB, "\tcamera.near = maxf(0.001, 0.03 * ws_new)", "\tcamera.near = 0.03",
     "flight/player_bird", "pb32", "PB-32"),
    ("GROWTH snaps (no ramp)", 5, PB,
     "\tvar ws_new := world_scale_target if tick_count <= 1 or yaw_flagged else exp(cur + clampf(want - cur, -step, step))",
     "\tvar ws_new := world_scale_target", "flight/player_bird", "pb32", "PB-32"),
    ("PERCH capture while tucked", 5, PB, "\tif wing_input.state.tucked:\n\t\treturn false  # a tucked bird is diving, not landing",
     "\tif false:\n\t\treturn false  # a tucked bird is diving, not landing", "flight/perch", "p12", "P12"),
    # ... and the round-5 fixes.
    ("GROUND no friction (round 4)", 5, PB, "\t\t\t\tif floor_hit and not scramble:\n\t\t\t\t\tvar vt := model.velocity - n * model.velocity.dot(n)",
     "\t\t\t\tif false:\n\t\t\t\t\tvar vt := model.velocity - n * model.velocity.dot(n)", "flight/ground", "g2", "G2"),
    ("GROUND touchdown 0.7 V_min (round 4)", 5, FT, "@export var touchdown_speed := 1.2", "@export var touchdown_speed := 0.7",
     "flight/ground", "g2", "G2"),
    ("GROUND one-tick stop (round 4)", 5, PB, "\t_run_v = v + n * vn            # the part along the ground (v - n (v.n))\n",
     "\t_run_v = Vector3.ZERO\n", "flight/ground", "g1", "G1"),
    ("GROUND no legs", 5, PB, "\t_legs.rate = -vn\n", "\t_legs.rate = 0.0\n", "flight/ground", "g1", "G1"),
    # (Since round 6 the feet take the touchdown: the mutant drops the rest of
    # the tick after the feet's touchdown, where the body's LAND is now a
    # fallback.)
    ("GROUND touchdown drops the tick", 5, PB, "\t\t\tvar rem := motion * (1.0 - f)\n\t\t\tmotion = rem - n * minf(0.0, rem.dot(n))",
     "\t\t\tvar rem := motion * (1.0 - f)\n\t\t\tmotion = Vector3.ZERO", "flight/ground", "g1", "G1"),
    ("GROUND run-out off-edge sticks", 5, PB, ["\tif hit.is_empty() or ng.y <= 0.7 or on_perch or ng.dot(_ground_n) < cos(deg_to_rad(20.0)):",
     "float(hit[\"position\"].y) + (p.r_body"],
     ["\tif false:", "float(hit.get(\"position\", pos - Vector3.UP * p.r_body).y) + (p.r_body"],
     "flight/ground", "g3b", "G3b"),
    ("GROUND lands on a branch top", 5, PB, ["\tvar soft_floor := floor_hit and not _hit_perch and vn", "\tif n.y <= 0.7 or on_perch:"],
     ["\tvar soft_floor := floor_hit and vn", "\tif n.y <= 0.7:"], "flight/ground", "g7", "G7"),
    ("STALL guard off", 5, FM, "\t\t_stall_guard = env.agl < _t_guard_h\n", "\t\t_stall_guard = false\n", "flight/ground", "g", "G5 / G4"),
    ("STALL guard still holds", 5, FM, " and _t_stall <= _t_forced_recovery and not _stall_guard\n", " and _t_stall <= _t_forced_recovery\n",
     "flight/ground", "g5", "G5"),
    ("LANDING config off", 5, PB, "\tif mode == Mode.FLYING and _ws.pitch > 0.2 and asst.get(&\"ground_cushion\", true):\n\t\t_landing_config(agl)",
     "\tif false:\n\t\t_landing_config(agl)", "flight/ground", "g", "G4 / G6"),
    ("LANDING config while climbing", 5, PB, "\t\t* FlightMath.sstep(0.0, 0.5, model.wind.y - model.velocity.y) \\\n", "",
     "flight/ground", "g6", "G6"),
    ("RESUME keeps strokes (round 4)", 5, PB, "\t\twing_input.resume()\n", "\t\twing_input.trust_next()\n", "flight/player_bird", "pb29", "PB-29"),
    ("RESUME no hold", 5, PB, "\t\t_resume_hold = 1.5\n", "\t\t_resume_hold = 0.0\n", "flight/player_bird", "pb29", "PB-29"),
    ("RECENTER keeps the rig rate (round 4)", 5, PB, "\t\trig_yaw_rate = 0.0\n\t\t_ff_rate = 0.0\n\t\tyaw_flagged = true\n",
     "\t\tyaw_flagged = true\n", "flight/player_bird", "pb30", "PB-30"),
    ("HITCH clamped dt (round 4)", 5, WI, "hand_ok[i], dt_real, pose_dt)", "hand_ok[i], dt, pose_dt)", "flight/player_bird", "pb31", "PB-31"),
    ("HITCH pose interval ignored", 5, FD, "\tvar vdt := sample_dt if sample_dt > 0.0 else dt\n", "\tvar vdt := dt\n",
     "flight/wing_input", "wi34", "WI-34"),
    ("HITCH repeats read as still", 5, FD, "\tif sample_dt == 0.0 and _has_prev:", "\tif false and _has_prev:", "flight/wing_input", "wi34", "WI-34"),
    ("XR nodes keep the old scale (round 4)", 5, PB, "\t\tfor n: Node3D in [camera, left_hand, right_hand, left_aim, right_aim]:\n\t\t\tn.position *= k",
     "\t\tfor n: Node3D in []:\n\t\t\tn.position *= k", "flight/player_bird", "pb32", "PB-32"),
    ("PERCH no headwind hold (round 4)", 5, PB, "\tif w_head > 0.0 and v_close < v_floor:", "\tif false:", "flight/perch", "p13", "P13"),
    ("PERCH slow brush locks out (round 4)", 5, PB, "\t\t\tif _landing_speed() > _v_cap():\n\t\t\t\t_no_capture_t = 0.5",
     "\t\t\tif true:\n\t\t\t\t_no_capture_t = 0.5", "flight/perch", "p13", "P13"),
    # --- round 6: the verifiers' survivors (r6eng) and the round-6 fixes.
    ("GAME XR source not frame-timed (r6eng)", 6, PB, "\t\t\txs.frame_timing = true", "\t\t\txs.frame_timing = false",
     "flight/player_bird", "pb33", "PB-33"),
    ("AGL 20 m low: guard up to 30 m (r6eng)", 6, PB, "\tenv.agl = agl\n", "\tenv.agl = agl - 20.0\n", "flight/ground", "g5b", "G5b"),
    ("SLIDE never locks the capture out (r6eng)", 6, PB, "\t\t\tif _landing_speed() > _v_cap():\n\t\t\t\t_no_capture_t = 0.5",
     "\t\t\tif false:\n\t\t\t\t_no_capture_t = 0.5", "flight/perch", "p14", "P14"),
    ("TELEMETRY kept mid-tick (round 5)", 6, PB, "\tif _tel_tick == tick_count:\n\t\t_tel_tick = -1", "\tif false:\n\t\t_tel_tick = -1",
     "flight/player_bird", "pb34", "PB-34"),
    ("AGL ray 2 spans (round 5)", 6, PB, "\tvar reach := maxf(2.0 * p.span, model.stall_guard_height() + p.r_body + 1.0)",
     "\tvar reach := 2.0 * p.span", "flight/ground", "g5b", "G5b"),
    ("FEET no reach (round 5)", 6, FT, "@export var leg_reach := 1.0", "@export var leg_reach := 0.0", "flight/ground", "g1", "G1 / G1b"),
    ("FEET on perch geometry", 6, PB, "\tif n.y <= 0.7 or on_perch:", "\tif n.y <= 0.7:", "flight/ground", "g7", "G7"),
    ("TOUCHDOWN vn cap 0.8 V_min (round 5)", 6, FT, "@export var touchdown_vn := 1.0", "@export var touchdown_vn := 0.8",
     "flight/ground", "g1_touchdown", "G1 (44 deg)"),
    ("LEGS vertical (round 5)", 6, PB, "\t_legs.reset()\n\t_leg_n = n\n", "\t_legs.reset()\n\t_leg_n = Vector3.UP\n",
     "flight/ground", "g1_touchdown", "G1 (slopes)"),
    ("LEGS restart mid-bend", 6, PB, "\tif _legs.active():\n\t\t# Already bending", "\tif false:\n\t\t# Already bending",
     "flight/ground", "g1b", "G1b"),
    ("LEGS stand up at the bend's deceleration (round 5)", 6, PB, "\t\t_legs.max_acc = minf(a, 2.0 * FlightMath.G)",
     "\t\t_legs.max_acc = a", "flight/ground", "g1b", "G1b (the stand-up)"),
    ("SKID no legs", 6, PB, "\t\t\t\t_legs_absorb(n, vn)\n\t\t\tif has_node", "\t\t\t\tpass\n\t\t\tif has_node",
     "flight/ground", "g1b", "G1b (the pigeon's and eagle's skid)"),
    ("SKID legs even when hard", 6, PB, " and vn * _dt <= maxf(tuning.leg_flex, 0.05) * p.r_body:", ":",
     "flight/ground", "g1c", "G1c (the view never jolts more than the body)"),
    ("RUN level brake (round 5)", 6, PB, "\tvar a := maxf(mu_g * _ground_n.y + g * dir.y, tuning.run_brake_min * mu_g)",
     "\tvar a := mu_g", "flight/ground", "g3d", "G3d"),
    ("RUN bends over a ridge", 6, PB, " or on_perch or ng.dot(_ground_n) < cos(deg_to_rad(20.0)):", " or on_perch:",
     "flight/ground", "g3e", "G3e"),
    ("TAKEOFF into the slope (round 5)", 6, PB, "\tif into < 0.0:\n\t\tvar sp := v.length()", "\tif false:\n\t\tvar sp := v.length()",
     "flight/ground", "g8", "G8 / G9"),
    ("TAKEOFF no hold (round 5)", 6, PB, "\t_takeoff_t = 0.0 if from_ground else -1.0", "\t_takeoff_t = -1.0",
     "flight/ground", "g8", "G8 / G9"),
    ("TAKEOFF hold on the flap low-pass", 6, PB, "\tvar flapping := _time - _last_stroke_t <= tuning.take_off_hold_gap and controls_enabled",
     "\tvar flapping := wing_input.state.flapping >= 0.1 and controls_enabled", "flight/ground", "g8", "G8"),
    ("TAKEOFF belly-slides back (no foothold)", 6, PB, "\t\tif v.dot(f) < 0.05 * p.v_min:\n\t\t\tscramble = false",
     "\t\tif false:\n\t\t\tscramble = false", "flight/ground", "g8", "G8"),
    ("DIH ring sums not rewritten", 6, WI, "\t\t\tfor k in range(n_hist - 1, -1, -1):\n\t\t\t\t_cum_write(i, _dih_seq - k)\n", "",
     "flight/wing_input", "wi28", "WI-28"),
    ("WS copy misses a field", 6, "scripts/flight/wing_state.gd", "\tflapping = o.flapping\n", "", "flight/wing_input", "ws_copy", "WS-copy"),
    ("WRAP snaps at the seam (Godot wrapf)", 6, "scripts/flight/view_turn.gd", "\tdebt = FlightMath.wrap_angle(debt + delta)",
     "\tdebt = wrapf(debt + delta, -PI, PI)", "flight/view_turn", "vt6", "VT-6"),
    ("C8b forced-turn pin", 5, FM, "\t\tpsi = h0 + clampf(turn, -cap, cap)", "\t\tpsi = h0 + clampf(turn * 1.5, -1.5 * cap, 1.5 * cap)",
     "flight/collision", "c8b", "C8b (forced total)"),
]


def run(suite, test):
    # `suite` may carry extra runner arguments after the suite name.
    parts = suite.split()
    cmd = [os.path.join(ROOT, "tools/gd.sh"), "mut", "--headless", "res://tests/runner.tscn", "--", "--suite=" + parts[0]] + parts[1:]
    if test:
        cmd.append("--test=" + test)
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=1200)
    out = r.stdout + r.stderr
    m = re.search(r"===== (\d+) passed, (\d+) failed", out)
    # Failure lines are printed as "[test]        - <test>: <message>".
    fails = []
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("[test]"):
            s = s[len("[test]"):].strip()
            if s.startswith("- "):
                fails.append(s[2:])
    perr = "SCRIPT ERROR" in out or "Parse Error" in out
    return (int(m.group(1)), int(m.group(2))) if m else (0, -1), fails[:3], perr


def sync():
    os.makedirs(WORK, exist_ok=True)
    subprocess.run(["rsync", "-a", "--delete", "--exclude", "/.godot/", "--exclude", "/.sandboxes/",
                    "--exclude", "/artifacts/", "--exclude", "/.git/", REPO + "/", ROOT + "/"], check=True)


def main():
    only = sys.argv[1] if len(sys.argv) > 1 else ""
    sync()
    results = []
    for mid, rnd, f, old, new, suite, test, catcher in MUTANTS:
        if only.startswith("round="):
            if str(rnd) != only[len("round="):]:
                continue
        elif only and only not in mid:
            continue
        path = os.path.join(ROOT, f)
        src = open(path).read()
        olds = old if isinstance(old, list) else [old]
        news = new if isinstance(new, list) else [new]
        counts = [src.count(o) for o in olds]
        if any(c != 1 for c in counts):
            print("[mut] %-26s SKIP: pattern counts %s" % (mid, counts), flush=True)
            results.append({"mutant": mid, "round": rnd, "file": f, "expected_catcher": catcher, "skipped": True,
                            "pattern_count": counts})
            continue
        mutated = src
        for o, n in zip(olds, news):
            mutated = mutated.replace(o, n)
        open(path, "w").write(mutated)
        t0 = time.time()
        try:
            (p, fl), fails, perr = run(suite, test)
        finally:
            open(path, "w").write(src)
        caught = fl > 0
        print("[mut] %-26s %s (expected: %s; passed %d, failed %d, %.0f s)%s" % (
            mid, "CAUGHT" if caught else "SURVIVED", catcher, p, fl, time.time() - t0, " PARSE-ERROR" if perr else ""))
        for x in fails:
            print("        " + x[:220])
        results.append({"mutant": mid, "round": rnd, "file": f, "suite": suite, "test_filter": test,
                        "expected_catcher": catcher, "caught": caught, "passed": p, "failed": fl,
                        "first_failures": fails, "parse_error": perr})
    out = os.path.join(REPO, "artifacts", "flight", "mutants.json")
    if only and os.path.exists(out):
        # A filtered run updates its own entries and keeps the others.
        old_res = json.load(open(out)).get("results", [])
        ran = {r["mutant"] for r in results}
        known = {m[0] for m in MUTANTS}
        results = [r for r in old_res if r["mutant"] not in ran and r["mutant"] in known] + results
        order = {m[0]: i for i, m in enumerate(MUTANTS)}
        results.sort(key=lambda r: order.get(r["mutant"], 999))
    json.dump({"generated_by": "tests/shots/flight_mutants.py", "time": time.strftime("%Y-%m-%d %H:%M:%S"),
               "results": results}, open(out, "w"), indent=1)
    n = [r for r in results if not r.get("skipped")]
    print("[mut] %d caught of %d run (%d skipped); report %s" % (sum(1 for r in n if r["caught"]), len(n),
          len(results) - len(n), out))


main()
