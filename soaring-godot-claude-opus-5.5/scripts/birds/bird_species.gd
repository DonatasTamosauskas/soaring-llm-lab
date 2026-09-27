class_name BirdSpecies
extends RefCounted
## Shape and colour of every species on the ladder, as data for
## BirdMeshBuilder. Owned by the birds area.
##
## Units: authored with a semispan of about 0.5 (the builder rescales so the
## wingspan is exactly 1.0), +X = right wing, +Y up, -Z = beak. The wing
## planform is the right wing's, root to tip, as stations
## [x, leading-edge z, chord] (z grows backwards; 0 = the wing root's leading
## edge). `wrist` is the index of the last arm station.
##
## Silhouette cues follow docs/research/ASSETS.md (field-guide shapes) so
## shape as well as size says what a bird is: forked swallow tail, triangular
## starling wing, crooked gull wing, fingered crow/hawk/eagle tips (5/5/7),
## fanned hawk tail, cocked wren tail, four moth wings.
##
## Colours are sRGB hex and chosen to stay distinct at distance (checked by
## tests/unit/birds/birds_silhouette_test.gd). Colour slots:
##   body:  back rump nape belly flank breast throat vent [streak spot band]
##   head:  crown forehead face cheek brow throat_head eye beak beak_tip cere
##   wings: bands on the upper surface of arm and hand, and underneath,
##          given as [chord fraction where the band ends, slot]; `tip` +
##          `tip_from` paint the outer hand (0..1 across the hand)
##   tail:  tail tail_under tail_band, legs: leg

## Species ids in ladder order (mirrors SizeRules.SPECIES).
const IDS: Array[StringName] = [&"moth", &"wren", &"sparrow", &"swallow", &"starling",
	&"pigeon", &"crow", &"gull", &"hawk", &"eagle"]

## Body: [length neck->vent, width, height]; head: [radius, lift (x H),
## forward (x radius)]; beak: [length, depth, width, hook].
## anim: [flap amplitude scale, fold roll scale, arm retract strength,
## perched body pitch (deg), perched wing droop (deg): how far the folded
## wing tips down behind the shoulder so its tips rest just on top of the
## tail (0.01-0.03 span above it; the wren's cocked tail stands above
## them). Chosen by measurement: the animation suite checks the wings never
## pass through the tail or the body anywhere between flight and perch]. tail: [length, base width, end width,
## shape, notch/fork depth, perched cock (deg, + = up), upper-side bands,
## rest pitch (deg, + = up)].
const DATA := {
	&"moth": {
		"kind": "moth",
		"body": [0.30, 0.09, 0.09], "plump": 1.0,
		"head": [0.04, 0.1, 0.5], "beak": [0.0, 0.0, 0.0, 0.0],
		"anim": [1.0, 0.25, 0.0, 0.0, 0.0],
		"colors": {
			"back": "b69a70", "rump": "a88c62", "belly": "c9b28a", "flank": "b8a07a", "breast": "c4ad86",
			"throat": "c4ad86", "vent": "a88c62", "band": "8c7152",
			"crown": "a58a64", "face": "a58a64", "eye": "241c17", "beak": "3a2e24",
			"fore": "d8c8a2", "fore_band": "8e7254", "fore_spot": "5a4636", "fore_under": "cdbd9a",
			"hind": "e6d4ab", "hind_ring": "e3a849", "hind_spot": "2f2622", "hind_under": "d9c9a4",
			"antenna": "6b5842", "leg": "7a6650",
		},
	},
	&"wren": {
		"kind": "bird",
		"body": [0.32, 0.2, 0.21], "plump": 1.05,
		"head": [0.07, 0.24, 0.5], "beak": [0.05, 0.02, 0.018, 0.004],
		"anim": [1.1, 1.0, 1.0, 12.0, 10.0],
		# A wren's cocked tail is narrow: it closes to 45% of its width when
		# folded, and stands up between the wingtips.
		"tail_close": 0.55,
		"wing": {"stations": [[0.03, 0.0, 0.23], [0.22, 0.0, 0.225], [0.35, 0.015, 0.195],
				[0.46, 0.045, 0.13], [0.5, 0.1, 0.045]],
			"wrist": 1, "dihedral": [3.0, 2.0], "tip": "round",
			"arm_bands": [[0.25, "cov"], [0.55, "bar"], [1.0, "flight"]],
			"hand_bands": [[0.25, "cov"], [0.6, "prim"], [1.0, "bar"]],
			"under_bands": [[0.5, "under_cov"], [1.0, "under_flight"]]},
		"tail": [0.15, 0.06, 0.095, "fan", 0.0, 62.0, [[0.4, "tail"], [0.7, "tail_band"], [1.0, "tail"]], 14.0],
		"colors": {
			"back": "94532b", "rump": "9c5b31", "nape": "8c4f2a", "belly": "c99e6c", "flank": "a8764a",
			"breast": "c29665", "throat": "d8b88c", "vent": "9a6e46", "streak": "5c371d",
			"crown": "7a4b2a", "face": "a8784c", "cheek": "b88a5e", "brow": "e8d6ae", "throat_head": "e2cba6",
			"eye": "1a1411", "beak": "6e5842", "beak_tip": "4a3a2c",
			"cov": "965830", "bar": "4c2a15", "flight": "754323", "prim": "683b1c",
			"under_cov": "b98b5c", "under_flight": "936a48",
			"tail": "7c4d2b", "tail_band": "3f2515", "tail_under": "a88363", "leg": "c0967a",
		},
	},
	&"sparrow": {
		"kind": "bird",
		"body": [0.31, 0.16, 0.18], "plump": 1.0,
		"head": [0.064, 0.26, 0.5], "beak": [0.042, 0.038, 0.034, 0.002],
		"anim": [1.0, 1.0, 1.0, 16.0, 10.0],
		"wing": {"stations": [[0.03, 0.0, 0.175], [0.13, -0.004, 0.176], [0.22, 0.0, 0.168], [0.35, 0.013, 0.148],
				[0.46, 0.036, 0.102], [0.5, 0.07, 0.036]],
			"wrist": 2, "dihedral": [4.0, 2.0], "tip": "round",
			"arm_bands": [[0.44, "cov"], [0.56, "bar"], [1.0, "flight"]],
			"hand_bands": [[0.3, "cov2"], [1.0, "prim"]],
			"under_bands": [[0.5, "under_cov"], [1.0, "under_flight"]]},
		"tail": [0.19, 0.05, 0.1, "notch", 0.025, 0.0, [[1.0, "tail"]], 0.0],
		"colors": {
			"back": "9c6b3b", "rump": "8e8575", "nape": "8f4b25", "belly": "cdc8bc", "flank": "b5ad9d",
			"breast": "bdb7a9", "throat": "1f1c1a", "vent": "c2bcaf", "streak": "3e2a19",
			"crown": "858582", "face": "dbd5c9", "cheek": "dbd5c9", "nape_head": "8f4b25", "throat_head": "1f1c1a",
			"eye": "141110", "beak": "2e2b29", "beak_tip": "232120",
			"cov": "9d5b2f", "cov2": "7a5234", "bar": "f0ebe0", "flight": "5c4129", "prim": "4b3625",
			"under_cov": "d6cebf", "under_flight": "a79b89",
			"tail": "5c4531", "tail_under": "8f8373", "leg": "b28e76",
		},
		"patterns": {"back_streak": true},
	},
	&"swallow": {
		"kind": "bird",
		"body": [0.27, 0.09, 0.085], "plump": 0.95,
		"head": [0.046, 0.14, 0.55], "beak": [0.018, 0.016, 0.028, 0.0],
		"anim": [0.95, 1.0, 1.0, 14.0, 15.0],
		# Folding, the streamers close together into one spike under the
		# long crossed wings (the others close 45% of the tail's width).
		"tail_close": 0.7,
		"wing": {"stations": [[0.025, 0.0, 0.12], [0.08, -0.008, 0.112], [0.135, -0.01, 0.1], [0.25, 0.035, 0.084],
				[0.37, 0.09, 0.06], [0.45, 0.142, 0.034], [0.5, 0.188, 0.0]],
			"wrist": 2, "dihedral": [2.0, -2.0], "tip": "point",
			"arm_bands": [[0.35, "cov"], [1.0, "flight"]],
			"hand_bands": [[0.3, "cov"], [1.0, "prim"]],
			"under_bands": [[0.55, "under_cov"], [1.0, "under_flight"]]},
		"tail": [0.34, 0.04, 0.11, "fork", 0.23, -5.0, [[0.62, "tail"], [0.74, "tail_spot"], [1.0, "tail"]], 0.0],
		"colors": {
			"back": "22336f", "rump": "25387a", "nape": "20306a", "belly": "f0e2c6", "flank": "e8d4b2",
			"breast": "1f2d62", "throat": "a8412a", "vent": "efe0c4",
			"crown": "1f2e66", "forehead": "9e3b25", "face": "1f2d62", "cheek": "1f2d62", "throat_head": "ab442c",
			"eye": "0f0d0c", "beak": "1a1716",
			"cov": "213171", "flight": "18214a", "prim": "141b3a",
			"under_cov": "eadabd", "under_flight": "9c978a",
			"tail": "1b2652", "tail_spot": "f0eadc", "tail_under": "3b4058", "leg": "3a2a24",
		},
		"patterns": {"breast_band": true},
	},
	&"starling": {
		"kind": "bird",
		"body": [0.28, 0.13, 0.14], "plump": 1.05,
		"head": [0.054, 0.14, 0.55], "beak": [0.084, 0.021, 0.021, 0.0],
		"anim": [1.0, 1.0, 1.0, 18.0, 10.0],
		"wing": {"stations": [[0.03, 0.0, 0.2], [0.11, 0.0, 0.18], [0.19, 0.006, 0.155], [0.30, 0.026, 0.112],
				[0.41, 0.052, 0.066], [0.5, 0.082, 0.0]],
			"wrist": 2, "dihedral": [3.0, 1.0], "tip": "point",
			"arm_bands": [[0.25, "cov"], [0.9, "flight"], [1.0, "edge"]],
			"hand_bands": [[0.25, "cov"], [0.84, "prim"], [1.0, "edge"]],
			"under_bands": [[0.55, "under_cov"], [1.0, "under_flight"]]},
		"tail": [0.12, 0.05, 0.09, "square", 0.0, -8.0, [[0.8, "tail"], [1.0, "edge"]], 0.0],
		"colors": {
			"back": "1d3a2b", "rump": "3a2a52", "nape": "22483a", "belly": "242e2a", "flank": "34294a",
			"breast": "24402f", "throat": "22412f", "vent": "3a3530", "spot": "d9c393",
			"crown": "213027", "face": "263a2d", "cheek": "2c2638", "throat_head": "2a3a30",
			"eye": "120f0e", "beak": "e8c43a", "beak_tip": "e3be33",
			"cov": "233b2d", "flight": "262430", "prim": "1f1d22", "edge": "a3875c",
			"under_cov": "5f594d", "under_flight": "4b463e",
			"tail": "23231f", "tail_under": "3b382f", "leg": "c47d6c",
		},
		"patterns": {"speckle": true},
	},
	&"pigeon": {
		"kind": "bird",
		"body": [0.33, 0.145, 0.145], "plump": 1.15,
		"head": [0.04, 0.26, 0.5], "beak": [0.026, 0.012, 0.012, 0.002],
		"anim": [0.9, 1.0, 1.0, 10.0, 20.0],
		"wing": {"stations": [[0.035, 0.0, 0.19], [0.13, -0.005, 0.18], [0.21, 0.0, 0.16], [0.32, 0.03, 0.12],
				[0.42, 0.075, 0.075], [0.47, 0.108, 0.04], [0.5, 0.14, 0.0]],
			"wrist": 2, "dihedral": [4.0, 0.0], "tip": "point",
			"arm_bands": [[0.52, "cov"], [0.62, "bar"], [0.72, "cov"], [0.82, "bar"], [1.0, "flight"]],
			"hand_bands": [[0.3, "cov"], [1.0, "prim"]],
			"under_bands": [[0.55, "under_cov"], [1.0, "under_flight"]]},
		"tail": [0.24, 0.055, 0.14, "fan", 0.0, -12.0, [[0.76, "tail"], [1.0, "tail_band"]], 0.0],
		"colors": {
			"back": "8b95a6", "rump": "cdd2da", "nape": "4d8a6a", "belly": "8e96a4", "flank": "98a0ad",
			"breast": "86708f", "throat": "5f7d72", "vent": "8e96a4",
			"crown": "6c7586", "face": "6c7586", "cheek": "6c7586", "throat_head": "5d7a70",
			"eye": "e0782a", "beak": "3a3530", "cere": "ebe7df",
			"cov": "9aa3b3", "bar": "22252b", "flight": "7e8797", "prim": "3e4351",
			"under_cov": "e8ebef", "under_flight": "bcc2cc",
			"tail": "7e8797", "tail_band": "2a2d33", "tail_under": "9aa1ad", "leg": "c85a5a",
		},
		"patterns": {"neck_sheen": true},
	},
	&"crow": {
		"kind": "bird",
		"body": [0.37, 0.12, 0.125], "plump": 1.0,
		"head": [0.058, 0.2, 0.55], "beak": [0.08, 0.042, 0.03, 0.01],
		"anim": [0.9, 1.0, 1.0, 16.0, 5.0],
		"wing": {"stations": [[0.03, 0.0, 0.2], [0.12, -0.005, 0.2], [0.21, 0.0, 0.19], [0.32, 0.01, 0.175],
				[0.39, 0.018, 0.155]],
			"wrist": 2, "dihedral": [4.0, 3.0], "tip": "fingers",
			"fingers": {"n": 5, "length": 0.11, "spread": [-8.0, 30.0], "profile": [0.82, 0.97, 1.0, 0.92, 0.78], "width": 0.96, "upturn": 3.0},
			"arm_bands": [[0.35, "cov"], [1.0, "flight"]],
			"hand_bands": [[0.3, "cov"], [1.0, "prim"]],
			"under_bands": [[0.5, "under_cov"], [1.0, "under_flight"]]},
		"tail": [0.23, 0.055, 0.13, "fan", 0.0, -10.0, [[1.0, "tail"]], 0.0],
		"colors": {
			"back": "1d1f26", "rump": "1f2230", "nape": "1c1e24", "belly": "1b1c21", "flank": "1d1e24",
			"breast": "1c1d23", "throat": "1a1b20", "vent": "1b1c21",
			"crown": "1b1d24", "face": "1a1b21", "cheek": "1a1b21", "throat_head": "1a1b20",
			"eye": "070707", "beak": "121214",
			"cov": "22252f", "flight": "181a20", "prim": "131418",
			"under_cov": "2a2b31", "under_flight": "33343a",
			"tail": "18191f", "tail_under": "222329", "leg": "15151a",
		},
	},
	&"gull": {
		"kind": "bird",
		"body": [0.35, 0.095, 0.095], "plump": 1.05,
		"head": [0.047, 0.2, 0.55], "beak": [0.07, 0.026, 0.017, 0.008],
		"anim": [0.75, 1.0, 1.0, 12.0, 16.0],
		"wing": {"stations": [[0.025, 0.0, 0.12], [0.13, -0.02, 0.115], [0.24, -0.032, 0.106], [0.34, 0.01, 0.086],
				[0.43, 0.06, 0.056], [0.5, 0.112, 0.0]],
			"wrist": 2, "dihedral": [15.0, -17.0], "tip": "point", "tip_from": 0.55,
			"arm_bands": [[0.3, "cov"], [0.84, "flight"], [1.0, "te"]],
			"hand_bands": [[0.3, "cov"], [1.0, "prim"]],
			"under_bands": [[0.55, "under_cov"], [1.0, "under_flight"]]},
		"tail": [0.12, 0.05, 0.1, "square", 0.0, -8.0, [[1.0, "tail"]], 0.0],
		"colors": {
			"back": "a9b4bd", "rump": "f2f2ed", "nape": "f2f2ed", "belly": "f2f2ed", "flank": "eeeeea",
			"breast": "f3f3ee", "throat": "f3f3ee", "vent": "f0f0eb",
			"crown": "f4f4ef", "face": "f4f4ef", "cheek": "f4f4ef", "throat_head": "f3f3ee",
			"eye": "d9c46a", "beak": "efc83a", "beak_spot": "d8412d",
			"cov": "abb5be", "flight": "a1acb5", "te": "f4f4ef", "prim": "a1acb5", "tip": "18191b",
			"under_cov": "f1f2ef", "under_flight": "d9dee2", "under_tip": "2a2b2e",
			"tail": "f4f4ef", "tail_under": "eaeae6", "leg": "e3aaa1",
		},
	},
	&"hawk": {
		"kind": "bird",
		"body": [0.32, 0.12, 0.13], "plump": 1.1,
		"head": [0.052, 0.2, 0.5], "beak": [0.036, 0.032, 0.022, 0.016],
		"anim": [0.7, 1.0, 1.0, 20.0, 7.0],
		"wing": {"stations": [[0.03, 0.0, 0.22], [0.12, -0.006, 0.226], [0.21, 0.0, 0.222], [0.32, 0.012, 0.2],
				[0.4, 0.026, 0.17]],
			"wrist": 2, "dihedral": [5.0, 3.0], "tip": "fingers",
			"fingers": {"n": 5, "length": 0.095, "spread": [-12.0, 34.0], "profile": [0.8, 0.95, 1.0, 0.95, 0.8], "width": 0.96, "upturn": 3.0},
			"arm_bands": [[0.35, "cov"], [0.9, "flight"], [1.0, "te"]],
			"hand_bands": [[0.3, "cov"], [1.0, "prim"]],
			"under_bands": [[0.3, "patagial"], [0.58, "under_cov"], [0.9, "under_flight"], [1.0, "under_te"]],
			"under_wrist": "wrist", "under_tip": 0.6},
		"tail": [0.2, 0.065, 0.18, "fan", 0.0, -10.0, [[0.82, "tail"], [0.92, "tail_band"], [1.0, "tail"]], 0.0],
		"colors": {
			"back": "5d3e27", "rump": "6b472c", "nape": "6e4b30", "belly": "f0e8d6", "flank": "d9c3a0",
			"breast": "f3ecdc", "throat": "efe5d2", "vent": "f0e8d8", "band": "5c3d26",
			"crown": "6e4c31", "face": "8a6647", "cheek": "8a6647", "throat_head": "ebdec5",
			"eye": "3a2a1a", "beak": "37373c", "cere": "e6c24a",
			"cov": "664528", "flight": "553d28", "te": "3f2e22", "prim": "3c2c21",
			"under_cov": "f2ebdb", "patagial": "4b3221", "wrist": "35231a", "under_flight": "e8e1d2",
			"under_te": "5a4636", "under_tip": "3d2c21",
			"tail": "b95a32", "tail_band": "5e3220", "tail_under": "e5bb9c", "leg": "e6c24a",
		},
		"patterns": {"belly_band": true},
	},
	&"eagle": {
		"kind": "bird",
		"body": [0.31, 0.11, 0.115], "plump": 1.05,
		"head": [0.06, 0.2, 0.8], "beak": [0.064, 0.046, 0.03, 0.028],
		"anim": [0.65, 1.0, 1.0, 22.0, 6.0],
		"wing": {"stations": [[0.03, 0.0, 0.2], [0.13, 0.0, 0.2], [0.22, 0.0, 0.2], [0.31, 0.004, 0.192],
				[0.37, 0.01, 0.182]],
			"wrist": 2, "dihedral": [10.0, 4.0], "tip": "fingers",
			"fingers": {"n": 7, "length": 0.13, "spread": [-10.0, 32.0], "profile": [0.82, 0.94, 0.99, 1.0, 0.97, 0.9, 0.8], "width": 0.97, "upturn": 7.0},
			"arm_bands": [[0.3, "cov"], [0.55, "cov2"], [1.0, "flight"]],
			"hand_bands": [[0.3, "cov"], [1.0, "prim"]],
			"under_bands": [[0.5, "under_cov"], [1.0, "under_flight"]]},
		"tail": [0.17, 0.065, 0.14, "wedge", 0.0, -12.0, [[0.5, "tail"], [0.65, "tail_band"], [1.0, "tail"]], 0.0],
		"colors": {
			"back": "553825", "rump": "5a3c27", "nape": "cd9a42", "belly": "46301f", "flank": "4a3322",
			"breast": "4d3423", "throat": "4a3222", "vent": "4f3a27",
			"crown": "b8893d", "face": "5a3d27", "cheek": "5a3d27", "nape_head": "c9963f", "throat_head": "4a3222",
			"eye": "6b4219", "beak": "3a342e", "cere": "e3c04a",
			"cov": "7d5a36", "cov2": "a07a47", "flight": "443022", "prim": "2e231a",
			"under_cov": "4a3526", "under_flight": "5b4938",
			"tail": "4f4034", "tail_band": "2e261f", "tail_under": "6a5a4a", "leg": "e3c04a",
		},
	},
}


static func has(id: StringName) -> bool:
	return DATA.has(id)


static func data(id: StringName) -> Dictionary:
	return DATA.get(id, DATA[&"sparrow"])


## A species' colour (sRGB) for a slot, falling back through related slots
## so a table only lists what differs.
static func color(id: StringName, slot: String) -> Color:
	var cols: Dictionary = data(id)["colors"]
	var s := slot
	for _i in 6:
		if cols.has(s):
			return Color(cols[s])
		s = FALLBACK.get(s, "back")
	return Color(cols.get("back", "808080"))


const FALLBACK := {
	"rump": "back", "nape": "back", "flank": "belly", "breast": "belly", "throat": "breast", "vent": "belly",
	"streak": "back", "spot": "back", "band": "belly",
	"crown": "back", "forehead": "crown", "face": "crown", "cheek": "face", "brow": "face",
	"nape_head": "crown", "throat_head": "throat", "eye": "crown", "beak": "crown", "beak_tip": "beak",
	"beak_spot": "beak_tip", "cere": "beak",
	"cov": "back", "cov2": "cov", "bar": "cov", "flight": "cov", "prim": "flight", "edge": "flight",
	"te": "flight", "tip": "prim", "under_cov": "belly", "under_flight": "under_cov", "patagial": "under_cov",
	"wrist": "under_cov", "under_te": "under_flight", "under_tip": "under_flight",
	"tail": "back", "tail_band": "tail", "tail_spot": "tail", "tail_under": "tail", "leg": "beak",
	"fore": "back", "fore_band": "fore", "fore_spot": "fore_band", "fore_under": "fore",
	"hind": "fore", "hind_ring": "hind", "hind_spot": "hind", "hind_under": "hind", "antenna": "crown",
}
