class_name EcosystemPlan
extends RefCounted
## Who lives around the player at a given player mass: species -> count.
##
## Mirrors the AI area's Ecosystem population plan (scripts/ai/ecosystem.gd,
## _make_plan, as of 2026-09-25) so the game-loop's pacing simulations assume
## the sky the real game will have: 60 NPCs; a starling murmuration; ~12
## threats, mostly the next rungs up; ~8 near-equals; a little dust; the
## rest worthwhile prey weighted towards the larger edible species; species
## caps. One deliberate difference: prey vs dust is split with
## SizeRules.is_worthwhile() (the loop's own notion of worth) instead of a
## fixed mass ratio, which is what docs/areas/GAMELOOP.md recommends the AI
## area adopt.

const MAX_NPCS := 60
const SPECIES_CAP := {
	&"moth": 10, &"wren": 10, &"sparrow": 16, &"swallow": 12, &"starling": 24,
	&"pigeon": 14, &"crow": 8, &"gull": 10, &"hawk": 5, &"eagle": 4,
}
const MURMURATION := 12
const THREATS := 12
const PEERS := 8
const DUST := 4


## Counts per species index (Array of int, one per SizeRules.SPECIES entry),
## plus the plan's roles: {counts, prey, dust, peers, threats, apex}.
static func plan(pm: float) -> Dictionary:
	var n := SizeRules.SPECIES.size()
	var counts: Array[int] = []
	counts.resize(n)
	counts.fill(0)
	var prey: Array[int] = []
	var dust: Array[int] = []
	var peers: Array[int] = []
	var threats: Array[int] = []
	for i in n:
		var m: float = SizeRules.SPECIES[i]["mass"]
		if SizeRules.can_eat(pm, m):
			if SizeRules.is_worthwhile(pm, m):
				prey.append(i)
			else:
				dust.append(i)
		elif SizeRules.can_eat(m, pm):
			threats.append(i)
		else:
			peers.append(i)
	var left := MAX_NPCS
	var starling := SizeRules.species_index(&"starling")
	left -= _add(counts, starling, MURMURATION)
	var apex := 0
	if threats.is_empty():
		apex = 3  # oversized eagles: something to respect at the top
		left -= apex
	else:
		left -= _fill(counts, threats, THREATS, func(k: int, _i: int) -> float: return 1.0 / pow(k + 1.0, 0.7))
	left -= _fill(counts, peers, PEERS, func(_k: int, _i: int) -> float: return 1.0)
	left -= _fill(counts, dust, mini(DUST, left), func(k: int, _i: int) -> float: return float(k + 1))
	left -= _fill(counts, prey, left, func(_k: int, i: int) -> float: return sqrt(float(SizeRules.SPECIES[i]["mass"]) / pm))
	if left > 0:
		for pool in [prey, peers, dust, threats]:
			if left <= 0:
				break
			left -= _fill(counts, pool, left, func(_k: int, _i: int) -> float: return 1.0)
	return {"counts": counts, "prey": prey, "dust": dust, "peers": peers, "threats": threats, "apex": apex}


static func _add(counts: Array[int], i: int, k: int) -> int:
	var cap: int = SPECIES_CAP.get(SizeRules.SPECIES[i]["id"], 10)
	var take := clampi(k, 0, cap - counts[i])
	counts[i] += take
	return take


## Distributes n over pool by weight(k, species) (largest remainder), capped.
static func _fill(counts: Array[int], pool: Array[int], n: int, weight: Callable) -> int:
	if pool.is_empty() or n <= 0:
		return 0
	var ws: Array[float] = []
	var total := 0.0
	for k in pool.size():
		var w: float = weight.call(k, pool[k])
		ws.append(w)
		total += w
	var placed := 0
	var fracs: Array = []
	for k in pool.size():
		var want := n * ws[k] / total
		placed += _add(counts, pool[k], floori(want))
		fracs.append([want - floorf(want), k])
	fracs.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	for f in fracs:
		if placed >= n:
			break
		placed += _add(counts, pool[f[1]], 1)
	return placed
