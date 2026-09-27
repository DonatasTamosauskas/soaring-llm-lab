class_name SpeciesProfile
extends RefCounted
## Temperament of each species: who flocks, who soars, how it hunts, how alert
## it is. The flight *envelope* (speeds, turn, climb) is not here: it comes
## from SizeRules.performance(mass) so NPCs and the player obey one physics.
## This table only says how a species chooses to use that envelope.
##
## Numbers are loosely ethological and tuned so the sky reads well:
##  * awareness_m / reaction_s: how far away a predator is noticed and how
##    long before the bird acts on it (small birds are twitchy and quick).
##  (What prey is worth a chase is not here: SizeRules.is_worthwhile, the
##  game loop's rule, decides it for NPCs and the player alike - an eagle
##  ignores sparrows.)
##  * alt: preferred height band above ground while travelling, metres.
##  * glide_ratio: best lift/drag with wings spread (soaring birds glide far).
##  * style: how flapping is shown - "flutter" (moth, continuous and
##    erratic), "bounding" (finches: bursts of beats then a folded bound),
##    "flap_glide" (bursts then a glide), "soar" (mostly gliding),
##    "flap" (steady beats, pigeons).

const DATA := {
	&"moth": {
		"style": "flutter", "glide_ratio": 3.0,
		"flock": 0.0, "flock_kind": "none", "flock_size": [1, 1],
		"soar": 0.0, "perch": 0.35, "perch_kinds": [0, 4],
		"hunt": 0.0, "stoop": false, "hunt_range_m": 0.0, "hunt_timeout_s": 0.0,
		"awareness_m": 11.0, "reaction_s": 0.24, "jink": 0.9,
		"alt": [1.5, 7.0], "hunger_rate": 0.0,
		"habitat": ["forest", "field", "meadow", "orchard", "glade", "town"], "erratic": 0.8,
	},
	&"wren": {
		"style": "bounding", "glide_ratio": 4.0,
		"flock": 0.0, "flock_kind": "none", "flock_size": [1, 1],
		"soar": 0.0, "perch": 0.75, "perch_kinds": [0, 4, 1],
		"hunt": 0.55, "stoop": false, "hunt_range_m": 22.0, "hunt_timeout_s": 8.0,
		"awareness_m": 20.0, "reaction_s": 0.15, "jink": 0.95,
		"alt": [1.5, 8.0], "hunger_rate": 0.018,
		"habitat": ["forest", "hedge", "hedgerow", "orchard", "glade", "town"], "erratic": 0.25,
	},
	&"sparrow": {
		"style": "bounding", "glide_ratio": 5.0,
		"flock": 0.85, "flock_kind": "loose", "flock_size": [4, 7],
		"soar": 0.0, "perch": 0.7, "perch_kinds": [0, 1, 3, 4],
		"hunt": 0.45, "stoop": false, "hunt_range_m": 28.0, "hunt_timeout_s": 9.0,
		"awareness_m": 26.0, "reaction_s": 0.18, "jink": 0.7,
		"alt": [3.0, 16.0], "hunger_rate": 0.015,
		"habitat": ["town", "hedge", "hedgerow", "farm", "field"], "erratic": 0.1,
	},
	&"swallow": {
		"style": "flap_glide", "glide_ratio": 9.0,
		"flock": 0.55, "flock_kind": "loose", "flock_size": [3, 5],
		"soar": 0.1, "perch": 0.45, "perch_kinds": [1, 3],
		"hunt": 0.85, "stoop": false, "hunt_range_m": 38.0, "hunt_timeout_s": 13.0,
		"awareness_m": 28.0, "reaction_s": 0.16, "jink": 0.8,
		"alt": [4.0, 30.0], "hunger_rate": 0.02,
		"habitat": ["field", "meadow", "lake", "farm", "powerline", "town"], "erratic": 0.05,
	},
	&"starling": {
		"style": "flap_glide", "glide_ratio": 7.0,
		"flock": 1.0, "flock_kind": "murmuration", "flock_size": [12, 22],
		"soar": 0.0, "perch": 0.5, "perch_kinds": [0, 1, 3],
		"hunt": 0.3, "stoop": false, "hunt_range_m": 30.0, "hunt_timeout_s": 20.0,
		"awareness_m": 32.0, "reaction_s": 0.2, "jink": 0.8,
		"alt": [10.0, 60.0], "hunger_rate": 0.012,
		"habitat": ["roost", "field", "meadow", "powerline", "town"], "erratic": 0.0,
	},
	&"pigeon": {
		"style": "flap", "glide_ratio": 7.0,
		"flock": 0.7, "flock_kind": "loose", "flock_size": [4, 8],
		"soar": 0.05, "perch": 0.65, "perch_kinds": [2, 3, 1],
		"hunt": 0.25, "stoop": false, "hunt_range_m": 35.0, "hunt_timeout_s": 10.0,
		"awareness_m": 36.0, "reaction_s": 0.28, "jink": 0.76,
		"alt": [6.0, 40.0], "hunger_rate": 0.01,
		"habitat": ["town", "farm", "tower", "bridge", "field"], "erratic": 0.0,
	},
	&"crow": {
		"style": "flap_glide", "glide_ratio": 9.0,
		"flock": 0.25, "flock_kind": "loose", "flock_size": [2, 3],
		"soar": 0.3, "perch": 0.5, "perch_kinds": [0, 1, 3, 5],
		"hunt": 0.6, "stoop": false, "hunt_range_m": 55.0, "hunt_timeout_s": 14.0,
		"awareness_m": 48.0, "reaction_s": 0.28, "jink": 0.65,
		"alt": [10.0, 50.0], "hunger_rate": 0.012,
		"habitat": ["field", "farm", "town", "forest", "meadow"], "erratic": 0.0,
	},
	&"gull": {
		"style": "soar", "glide_ratio": 14.0,
		"flock": 0.3, "flock_kind": "loose", "flock_size": [2, 4],
		"soar": 0.9, "perch": 0.3, "perch_kinds": [2, 3, 5, 6],
		"hunt": 0.5, "stoop": false, "hunt_range_m": 65.0, "hunt_timeout_s": 11.0,
		"awareness_m": 40.0, "reaction_s": 0.32, "jink": 0.45,
		"alt": [25.0, 140.0], "hunger_rate": 0.011,
		"habitat": ["lake", "jetty", "cliff", "canyon", "thermal"], "erratic": 0.0,
	},
	&"hawk": {
		"style": "soar", "glide_ratio": 12.0,
		"flock": 0.0, "flock_kind": "none", "flock_size": [1, 1],
		"soar": 0.7, "perch": 0.6, "perch_kinds": [5, 0, 6, 1],
		"hunt": 0.95, "stoop": true, "hunt_range_m": 90.0, "hunt_timeout_s": 16.0,
		"awareness_m": 60.0, "reaction_s": 0.3, "jink": 0.5,
		"alt": [25.0, 110.0], "hunger_rate": 0.016,
		"habitat": ["field", "meadow", "forest", "powerline", "thermal"], "erratic": 0.0,
	},
	&"eagle": {
		"style": "soar", "glide_ratio": 15.0,
		"flock": 0.0, "flock_kind": "none", "flock_size": [1, 1],
		"soar": 1.0, "perch": 0.35, "perch_kinds": [6, 5, 0, 2],
		"hunt": 0.9, "stoop": true, "hunt_range_m": 120.0, "hunt_timeout_s": 18.0,
		"awareness_m": 70.0, "reaction_s": 0.35, "jink": 0.25,
		"alt": [50.0, 190.0], "hunger_rate": 0.014,
		"habitat": ["cliff", "canyon", "thermal", "lake"], "erratic": 0.0,
	},
}


static func of(species: StringName) -> Dictionary:
	return DATA.get(species, DATA[&"sparrow"])


## Wingbeat frequency, Hz. Small birds beat fast; Pennycuick's scaling puts
## frequency roughly at mass^-1/4, capped so a moth still reads at 90 fps.
static func flap_hz(mass: float) -> float:
	return clampf(3.8 * pow(mass, -0.22), 2.2, 14.0)

