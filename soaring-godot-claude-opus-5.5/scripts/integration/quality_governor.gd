class_name QualityGovernor
extends Node
## The Quest tier's safety valve (integration): while a run is being played
## in the headset, if the frame rate stays below MISS_RATIO x the display
## refresh for MISS_S, the NPC budget drops by STEP (never below `floor_npcs`;
## the Ecosystem recycles the surplus out of view). The CPU estimate behind
## the tier's default is a rule of thumb (GDScript 3-4x slower than an M1);
## this makes a wrong guess cost a few birds instead of dropped frames.
## Recovery (integration round 2: the budget never came back, so one dip -
## a load spike, a busy moment - thinned the sky, and the prey in it, for
## the rest of the session): after RECOVER_S of play at RECOVER_RATIO x the
## refresh or better, the budget rises by STEP, never above `ceiling_npcs`
## (the tier's own). A rise the frame rate cannot hold (a cut within
## PULSE_S of it) doubles the wait before the next one, so the sky does not
## pulse. Logs every step ("[integration]").

const MISS_RATIO := 0.92
const MISS_S := 3.0
const COOLDOWN_S := 10.0
const STEP := 4
const RECOVER_RATIO := 0.98
const RECOVER_S := 30.0
const PULSE_S := 20.0

var ecosystem: Node
var floor_npcs := 20
## The most the budget recovers to (the tier's own; < 0: never rises).
var ceiling_npcs := -1
## () -> float; defaults to Engine.get_frames_per_second().
var fps_source: Callable
## () -> float; defaults to VR.refresh_rate (72 when unknown).
var refresh_source: Callable
## () -> bool; defaults to Game.state == PLAYING.
var playing_source: Callable
var steps_taken := 0
var raises_taken := 0

var _low_s := 0.0
var _good_s := 0.0
var _cool := 0.0
var _acc := 0.0
var _recover_s := RECOVER_S
var _since_raise := INF


func _init() -> void:
	name = "QualityGovernor"
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(dt: float) -> void:
	step(dt)


## One update (tests call it with their own clock).
func step(dt: float) -> void:
	_acc += dt
	_cool = maxf(0.0, _cool - dt)
	if _acc < 0.5:
		return
	var span := _acc
	_acc = 0.0
	if ecosystem == null or not is_instance_valid(ecosystem):
		return
	var playing: bool = playing_source.call() if playing_source.is_valid() else Game.state == Game.State.PLAYING
	var fps: float = fps_source.call() if fps_source.is_valid() else Engine.get_frames_per_second()
	var hz: float = refresh_source.call() if refresh_source.is_valid() else (VR.refresh_rate if VR.refresh_rate > 0.0 else 72.0)
	_since_raise += span
	if not playing:
		_low_s = 0.0
		_good_s = 0.0
		return
	if fps < MISS_RATIO * hz:
		_low_s += span
	else:
		_low_s = 0.0
	_good_s = _good_s + span if fps >= RECOVER_RATIO * hz else 0.0
	var cur := int(ecosystem.get(&"max_npcs"))
	if _low_s >= MISS_S and _cool <= 0.0 and cur > floor_npcs:
		var nxt := maxi(floor_npcs, cur - STEP)
		ecosystem.set(&"max_npcs", nxt)
		steps_taken += 1
		_low_s = 0.0
		_good_s = 0.0
		_cool = COOLDOWN_S
		if _since_raise < PULSE_S:
			# The last rise did not hold: wait twice as long next time.
			_recover_s *= 2.0
		print("[integration] frames below %.0f%% of %.0f Hz (%.1f fps): NPC budget %d -> %d" % [MISS_RATIO * 100.0, hz, fps, cur, nxt])
	elif ceiling_npcs > cur and _good_s >= _recover_s and _cool <= 0.0:
		var up := mini(ceiling_npcs, cur + STEP)
		ecosystem.set(&"max_npcs", up)
		raises_taken += 1
		_good_s = 0.0
		_since_raise = 0.0
		_cool = COOLDOWN_S
		print("[integration] %.0f s at %.0f%% of %.0f Hz or better: NPC budget %d -> %d" % [_recover_s, RECOVER_RATIO * 100.0, hz, cur, up])
