extends RefCounted
## One source of truth for readable tiers, fair catches, and feeding rewards.

const CATCH_RATIO := 1.18
const CROWN_MASS := 8.0
const TIERS := [
	{"name": "Wren", "mass": 0.38, "limit": 0.65, "color": Color("f3bb63"), "accent": Color("785242")},
	{"name": "Swift", "mass": 0.78, "limit": 1.35, "color": Color("55c7dc"), "accent": Color("194765")},
	{"name": "Kite", "mass": 1.65, "limit": 2.8, "color": Color("81c974"), "accent": Color("344a48")},
	{"name": "Eagle", "mass": 3.35, "limit": 5.5, "color": Color("da8677"), "accent": Color("613e5a")},
	{"name": "Sovereign", "mass": 6.5, "limit": INF, "color": Color("b995ef"), "accent": Color("514274")}
]

static func tier_index(mass: float) -> int:
	for i in TIERS.size():
		if mass < float(TIERS[i]["limit"]):
			return i
	return TIERS.size() - 1

static func tier_name(mass: float) -> String:
	return String(TIERS[tier_index(mass)]["name"])

static func can_catch(predator_mass: float, prey_mass: float) -> bool:
	return prey_mass > 0.0 and predator_mass >= prey_mass * CATCH_RATIO

static func reward(predator_mass: float, prey_mass: float) -> float:
	if not can_catch(predator_mass, prey_mass):
		return 0.0
	# Tiny birds stop mattering as the player grows. A relevant catch is worth
	# 32% of the prey's mass; prey below 12% of yours gives no growth.
	var relevance := smoothstep(0.12, 0.5, prey_mass / maxf(predator_mass, 0.01))
	return prey_mass * 0.32 * relevance

static func radius(mass: float) -> float:
	return 0.38 * pow(maxf(mass, 0.1), 1.0 / 3.0)

static func cruise_speed(mass: float) -> float:
	return clampf(13.2 - pow(maxf(mass, 0.1), 0.4) * 2.8, 7.0, 12.0)
