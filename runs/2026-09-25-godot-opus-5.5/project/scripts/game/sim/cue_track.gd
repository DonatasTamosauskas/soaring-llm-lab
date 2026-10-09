class_name CueTrack
extends RefCounted
## The cues as the player meets them, in whole runs: the threat cue at every
## change (Events.threat_changed) and both cues frame by frame. Moved out of
## IntegratedSim (core loop round) so the real-chain pacing runs
## (tests/shots/integration_pacing.gd: a person flying the real PlayerBird in
## the real game) record the same numbers as the modelled runs.
##
##   var track := CueTrack.new(loop, player)
##   every frame: track.t = <run clock>; ...loop steps...; track.step(dt)
##   at the end: var r := track.finish()  # [cue, target_cue]; disconnects

## The threat cue's statistics ("cue"): shown from this level (the UI's
## REAL_THREAT, 0.1; the HUD arrow draws from 0.12)...
const CUE_VISIBLE := 0.1
## ...a bird whose own raw threat is under this is harmless to the player...
const CUE_HARMLESS := 0.1
## ...and a return to the bird named before within this many seconds is a
## ping-pong (A -> B -> A).
const CUE_PING_PONG_S := 3.0
## The cues against what is really going on, frame by frame (fix round 5
## review; run()'s "cue" and "target_cue"):
##  * masked attacks: a bird hunting the player at attack strength (own
##    smoothed level >= GameLoop.ATTACK_LEVEL) that the threat cue does not
##    name while the level it reports is at least CUE_MASK_GAP lower - the
##    HUD, the haptics and the call understating the danger ("masked_*", the
##    review's own definition; "masked_live_*" counts only such a hunter
##    whose raw threat is live and itself at attack strength CUE_MASK_GAP
##    over the level shown - one that has turned away and whose level is
##    only decaying is not an attack, even at its proximity floor's raw
##    0.1-0.25, core loop fix round 1);
##  * attack onsets: every time a hunter's own level reaches attack strength,
##    how soon the cue names it ("onsets", "onsets_late" beyond CUE_LATE_S,
##    "onsets_never" - the attack ended unnamed; "onsets_held" of those late
##    or never: held behind a named bird that was itself a live attack on the
##    player - two hunters at once, the one striking first named);
##  * the target cue: changes of the named prey, "voluntary" ones away from a
##    bird still worth chasing (alive, not sheltered, worthwhile, within the
##    target range with its hysteresis - the review's definition, which in
##    the valley also counts a bird lost behind geometry), of those "closing"
##    ones the player was gaining on (5% closer than 2 s before), and the
##    median time a target was held before a voluntary change; the watch's
##    own reason for every change ("why": ThreatWatch.last_target_change),
##    its "preference" switches (a better bird, not an invalid target), the
##    ones of those while the player was gaining, and their holds.
## The threat cue as the player meets it (Events.threat_changed: what the
## HUD arrow, the haptics and the predator's call follow): time shown
## (level >= CUE_VISIBLE) and at attack strength (>= GameLoop.ATTACK_LEVEL),
## every change of the named bird, the "hops" among them (a shown cue
## moving straight to another shown bird), hops back to the bird named
## before within CUE_PING_PONG_S (A -> B -> A), changes that handed an
## attack on the player to a bird not hunting it while the attacker was
## still in play, and changes that put an attack-strength level on a bird
## whose own threat was under CUE_HARMLESS (fix round 4 review: in the
## valley the name hopped hunter -> bystander -> hunter every ~0.6 s during
## attacks, carrying the attack's level onto harmless birds).
var cue := {"visible_s": 0.0, "attack_s": 0.0, "changes": 0, "hops": 0, "ping_pong": 0, "attack_to_bystander": 0,
	"attack_to_harmless": 0, "not_own": 0}
var cue_st := {"t": 0.0, "lv": 0.0, "id": 0, "prev_id": 0, "at": -INF, "hop": false}
var loop: GameLoop
var player: Bird
var t := 0.0
var out := {"masked_s": 0.0, "masked_episodes": 0, "masked_worst_gap": 0.0, "masked_live_s": 0.0,
	"masked_live_episodes": 0, "onsets": 0, "onsets_late": 0, "onsets_never": 0, "onsets_held": 0}
var tgt := {"changes": 0, "to_null": 0, "voluntary": 0, "voluntary_closing": 0, "voluntary_within_3s": 0,
	"preference": 0, "preference_closing": 0}
## Why the target changed (ThreatWatch.last_target_change), every change.
var why := {}
## ...and for the voluntary changes away from a bird the player was closing on.
var closing_why := {}
var holds: Array[float] = []
## ...and for the watch's own preference switches.
var pref_holds: Array[float] = []
var _masked := false
var _masked_live := false
## instance id -> [seconds pending, held behind a live named hunter at the onset]
var _pending := {}
var _was := {}
var _tg: Bird = null
var _tg_at := 0.0
## [t, distance] to the current target over the last CLOSING_S.
var _tg_d: Array = []
const CLOSING_S := 2.0


func _init(p_loop: GameLoop, p_player: Bird) -> void:
	loop = p_loop
	player = p_player
	Events.threat_changed.connect(_on_threat)


## One frame, after the loop's step (the caller keeps `t`, the run's clock).
func step(dt: float) -> void:
	var p := player
	var w := loop.watch
	if p == null or not p.alive or loop.phase != GameLoop.Phase.PLAYING:
		_pending.clear()
		_was.clear()
		_masked = false
		_masked_live = false
		return
	var named := w.predator if w.predator != null and is_instance_valid(w.predator) else null
	var named_live_hunter := named != null and IntegratedSim.hunts(named, p) and w.raw_of(named) >= ThreatWatch.QUIET_LEVEL \
			and w.level >= ThreatWatch.QUIET_LEVEL
	var worst := 0.0
	var worst_live := 0.0
	var now_attacking := {}
	for q in Birds.all():
		if q == p or not q.alive or not IntegratedSim.hunts(q, p) or not SizeRules.can_eat(q.mass, p.mass):
			continue
		var id := q.get_instance_id()
		var lv := w.level_of(q)
		if lv >= GameLoop.ATTACK_LEVEL:
			now_attacking[id] = true
			if not _was.has(id):
				out["onsets"] += 1
				if q != named:
					_pending[id] = [0.0, named_live_hunter]
		if _pending.has(id):
			if q == named:
				var d: Array = _pending[id]
				if float(d[0]) > CUE_LATE_S:
					out["onsets_late"] += 1
					if bool(d[1]):
						out["onsets_held"] += 1
				_pending.erase(id)
			elif lv < ThreatWatch.QUIET_LEVEL:
				out["onsets_never"] += 1
				if bool((_pending[id] as Array)[1]):
					out["onsets_held"] += 1
				_pending.erase(id)
			else:
				(_pending[id] as Array)[0] = float((_pending[id] as Array)[0]) + dt
		if q != named:
			worst = maxf(worst, lv)
			# Live: its raw threat right now is live and not below the level
			# it is judged at - a hunter flying off after its pass shows its
			# decaying level at a proximity-floor raw threat of 0.1-0.25, and
			# it is not the attack (core loop fix round 1: the raw >= 0.1
			# test alone counted it, and the attack stooping in named instead
			# - the watch's rule - as "masked").
			if w.raw_of(q) >= ThreatWatch.QUIET_LEVEL:
				worst_live = maxf(worst_live, minf(lv, w.raw_of(q)))
	for id: int in _pending.keys():
		var q2 := instance_from_id(id) as Bird
		if q2 == null or not q2.alive:
			# (Held or not as at its onset: a bird leaving the game while
			# held behind a live attack striking first was counted unheld.)
			out["onsets_never"] += 1
			if bool((_pending[id] as Array)[1]):
				out["onsets_held"] += 1
			_pending.erase(id)
	_was = now_attacking
	var m := worst >= GameLoop.ATTACK_LEVEL and worst - w.level >= CUE_MASK_GAP
	if m:
		out["masked_s"] += dt
		if not _masked:
			out["masked_episodes"] += 1
		out["masked_worst_gap"] = maxf(float(out["masked_worst_gap"]), worst - w.level)
	_masked = m
	var ml := worst_live >= GameLoop.ATTACK_LEVEL and worst_live - w.level >= CUE_MASK_GAP
	if ml:
		out["masked_live_s"] += dt
		if not _masked_live:
			out["masked_live_episodes"] += 1
	_masked_live = ml
	# The target cue.
	var tg := w.target if w.target != null and is_instance_valid(w.target) else null
	if tg != _tg:
		why[String(w.last_target_change)] = int(why.get(String(w.last_target_change), 0)) + 1
		if tg == null:
			tgt["to_null"] += 1
		elif _tg != null and is_instance_valid(_tg):
			tgt["changes"] += 1
			var old := _tg
			var dp := old.get_body_position().distance_to(p.get_body_position())
			var closing := not _tg_d.is_empty() and dp < float(_tg_d[0][1]) * 0.95
			if w.last_target_change == &"preference":
				tgt["preference"] += 1
				pref_holds.append(t - _tg_at)
				if closing:
					tgt["preference_closing"] += 1
			if old.alive and not loop.is_sheltered(old, p.get_wingspan()) and SizeRules.is_worthwhile(p.mass, old.mass) \
					and dp <= w.target_range(p.mass) * w.target_range_hysteresis:
				tgt["voluntary"] += 1
				holds.append(t - _tg_at)
				if t - _tg_at < 3.0:
					tgt["voluntary_within_3s"] += 1
				if closing:
					tgt["voluntary_closing"] += 1
					var wk := String(w.last_target_change)
					closing_why[wk] = int(closing_why.get(wk, 0)) + 1
		_tg = tg
		_tg_at = t
		_tg_d.clear()
	if tg != null:
		_tg_d.append([t, tg.get_body_position().distance_to(p.get_body_position())])
		while _tg_d.size() > 1 and t - float(_tg_d[0][0]) > CLOSING_S:
			_tg_d.pop_front()


func result() -> Array:
	var o := out.duplicate()
	o["masked_s"] = snappedf(float(o["masked_s"]), 0.01)
	o["masked_live_s"] = snappedf(float(o["masked_live_s"]), 0.01)
	o["masked_worst_gap"] = snappedf(float(o["masked_worst_gap"]), 0.001)
	var g := tgt.duplicate()
	var hs := holds.duplicate()
	hs.sort()
	g["hold_median_s"] = snappedf(hs[hs.size() / 2], 0.01) if not hs.is_empty() else -1.0
	g["holds"] = hs.map(func(x: float) -> float: return snappedf(x, 0.01))
	var ph := pref_holds.duplicate()
	ph.sort()
	g["preference_holds"] = ph.map(func(x: float) -> float: return snappedf(x, 0.01))
	g["why"] = why.duplicate()
	g["closing_why"] = closing_why.duplicate()
	return [o, g]


## A hunter unnamed while the cue reports at least this much less is masked...
const CUE_MASK_GAP := 0.15
## ...and an attack named more than this after its onset is late.
const CUE_LATE_S := 0.25


func _on_threat(lv: float, pred: Bird) -> void:
	var span: float = t - float(cue_st["t"])
	if float(cue_st["lv"]) >= CUE_VISIBLE:
		cue["visible_s"] += span
	if float(cue_st["lv"]) >= GameLoop.ATTACK_LEVEL:
		cue["attack_s"] += span
	var old_id: int = cue_st["id"]
	var new_id := pred.get_instance_id() if pred != null else 0
	var old_lv: float = cue_st["lv"]
	# The level shown is the named bird's own, always.
	if absf(lv - (loop.watch.level_of(pred) if pred != null else 0.0)) > 1e-6:
		cue["not_own"] += 1
	if old_id != 0 and new_id != 0 and old_id != new_id:
		cue["changes"] += 1
		var hop := old_lv >= CUE_VISIBLE and lv >= CUE_VISIBLE
		if hop:
			cue["hops"] += 1
			if new_id == int(cue_st["prev_id"]) and bool(cue_st["hop"]) and t - float(cue_st["at"]) < CUE_PING_PONG_S:
				cue["ping_pong"] += 1
		var old := instance_from_id(old_id) as Bird
		if old_lv >= GameLoop.ATTACK_LEVEL and old != null and old.alive and IntegratedSim.hunts(old, player) \
				and SizeRules.can_eat(old.mass, player.mass) and not CatchRule.is_hidden(old) and not IntegratedSim.hunts(pred, player):
			cue["attack_to_bystander"] += 1
		# (A bird is only ever named at its own level; this counts a name
		# moved by preference - not because the named bird left - to a
		# bird shown at attack strength whose own threat right now is
		# under CUE_HARMLESS.)
		if lv >= GameLoop.ATTACK_LEVEL and loop.watch.raw_of(pred) < CUE_HARMLESS \
				and loop.watch.last_change in [&"attack", &"challenge", &"quiet"]:
			cue["attack_to_harmless"] += 1
		cue_st["prev_id"] = old_id
		cue_st["at"] = t
		cue_st["hop"] = hop
	cue_st["id"] = new_id
	cue_st["t"] = t
	cue_st["lv"] = lv


## Ends the run's tracking: the threat cue's last span counted, the signal
## let go. Returns [cue, target_cue] (the frame tracker's numbers merged into
## the cue's).
func finish() -> Array:
	if Events.threat_changed.is_connected(_on_threat):
		Events.threat_changed.disconnect(_on_threat)
	var tail: float = t - float(cue_st["t"])
	if float(cue_st["lv"]) >= CUE_VISIBLE:
		cue["visible_s"] += tail
	if float(cue_st["lv"]) >= GameLoop.ATTACK_LEVEL:
		cue["attack_s"] += tail
	cue_st["t"] = t
	var c := cue.duplicate()
	c["visible_s"] = snappedf(float(c["visible_s"]), 0.01)
	c["attack_s"] = snappedf(float(c["attack_s"]), 0.01)
	var tracked := result()
	c.merge(tracked[0])
	return [c, tracked[1]]
