class_name QualityTier
extends RefCounted
## Per-platform quality (integration). "full" is the game as every area
## built and measured it (60 NPCs), kept for the desktop mode. "quest" is
## chosen automatically on Android and whenever the OpenXR system is a
## Quest (the Meta XR Simulator reports "Meta Quest Pro", so simulator runs
## judge the tier that ships: integration round 1), and on request with
## --quality=quest|full (to measure either on the Mac):
## the Quest Pro runs GDScript ~3-4x slower than the M1 this was built on,
## and the composed game's main-thread logic measured on the M1
## (tests/shots/integration_perf.gd, docs/INTEGRATION.md "Performance") is
##   ~0.70 ms fixed (flight, UI, audio, VR, world) + ~0.0275 ms per NPC
##   (AI brains and flight, the catch sweep, the birds' draw sync):
## 60 NPCs = 2.35 ms (Quest ~7-9.4 ms), 28 NPCs = 1.47 ms (Quest ~4.4-5.9
## ms, ~5.1 at 3.5x). The NPC count is the one lever that matters (the AI's
## LOD radii changed < 5 %). The Quest tier also carries a safety valve,
## QualityGovernor: if the headset misses frames while flying it lowers the
## NPC count further, down to GOVERNOR_FLOOR.
## Only settings other areas expose are used (Ecosystem exports).

## NPCs on the Quest (see above; the Ecosystem scales its whole plan -
## prey, threats, giants, the murmuration - to it).
const QUEST_NPCS := 28
const GOVERNOR_FLOOR := 20

var name := &"full"
var max_npcs := 60
## Ecosystem LOD radii (m): full-rate simulation inside lod_near, calm
## far birds integrate at lower rates beyond (NpcBird.tick).
var lod_near := 80.0
var lod_far := 200.0
## Lower the NPC count when frames drop (VR only).
var governor := false


static func choose() -> QualityTier:
	var q := QualityTier.new()
	var want := Paths.arg("quality", "")
	if want == "quest" or (want.is_empty() and (OS.has_feature("android") or quest_system())):
		q.set_quest()
	# Measurement overrides (how the tier was chosen, docs/INTEGRATION.md).
	var a := Paths.user_args()
	if a.has("q_npcs"):
		q.max_npcs = int(a["q_npcs"])
		q.name = &"custom"
	if a.has("q_lod_near"):
		q.lod_near = float(a["q_lod_near"])
		q.name = &"custom"
	if a.has("q_lod_far"):
		q.lod_far = float(a["q_lod_far"])
		q.name = &"custom"
	return q


## True when the running OpenXR system is a Quest (a headset, Link, or the
## Meta XR Simulator's "Meta Quest Pro" profile).
static func quest_system() -> bool:
	var xr := XRServer.primary_interface
	if xr == null or not xr.is_initialized():
		return false
	return is_quest_name(String(xr.get_system_info().get("OpenXRSystemName", "")))


static func is_quest_name(system_name: String) -> bool:
	return system_name.to_lower().contains("quest")


func set_quest() -> void:
	name = &"quest"
	max_npcs = QUEST_NPCS
	lod_near = 60.0
	lod_far = 140.0
	governor = true


func apply_ecosystem(eco: Node) -> void:
	if eco == null:
		return
	eco.set(&"max_npcs", max_npcs)
	eco.set(&"lod_near", lod_near)
	eco.set(&"lod_far", lod_far)


func describe() -> Dictionary:
	return {"name": name, "max_npcs": max_npcs, "lod_near": lod_near, "lod_far": lod_far, "governor": governor}
