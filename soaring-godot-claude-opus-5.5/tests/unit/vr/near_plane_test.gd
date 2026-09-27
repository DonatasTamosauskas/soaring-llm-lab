extends TestCase
## The camera's near plane (WorldScaleDriver.NEAR_K x world_scale) never
## clips the player's own first-person wings, in any pose a player flies or
## looks at their wings in (integration round 1).
##
## Why it matters: the Quest's Mobile renderer draws into a 24-bit fixed-point
## depth buffer (Godot 4.7 prefers D24_UNORM_S8 on the non-storage path; this
## Mac's MoltenVK has no D24 and uses D32F, so no run here shows it). With
## reverse-Z in a fixed-point buffer one depth step at view depth z is about
## z^2 / (near * 2^24): the precision far away is set by the near plane.
## 0.03 x world_scale (a sparrow: 4.2 mm) left distant coplanar-ish surfaces
## (the street slab 10 cm over the ground, water over a shallow shore)
## within a step of each other from ~80 m. NEAR_K 0.06 is 2x finer (0.10,
## 3.3x, would cut the wing roots at the shoulder: 8.1 cm). This
## test pins that the larger near plane costs nothing the player sees: over
## every rig pose (the pose puppet's gestures and a whole flap cycle) and
## head looks (ahead, at each wing, down at the hands, up), every sampled
## point of every feather inside the eye's view (the Quest Pro's ~106 x 96
## deg, with a margin) is at least MARGIN x near in front of the eye.

const Env := preload("res://scenes/dev/vr_dev_env.gd")
const MemoryStore := preload("res://tests/unit/vr/vr_memory_store.gd")
const DT := 1.0 / 90.0
## Half-angles of the view checked (deg): wider than one Quest Pro eye's
## frustum (~53 deg out, ~48 deg up/down).
const HALF_H := 60.0
const HALF_V := 55.0
const MARGIN := 1.25

var rig: Dictionary
var extras: VRRigExtras
var wings: FirstPersonWings
var puppet: VRPosePuppet


func before_all() -> void:
	rig = Env.build_rig(self, Vector3(0, 3, 0), MemoryStore.new(), true, false)
	await wait_frames(3)
	extras = rig["extras"]
	wings = extras.wings
	puppet = rig["puppet"]
	puppet.set_process(false)
	extras.calibration.auto_tick = false
	wings.auto_update = false
	extras.world_scale_driver.enabled = false
	_pose(&"spread", 0.0, 0.0, 0.0)
	extras.calibration.start_manual()
	for i in int(2.0 / DT):
		extras.calibration.tick(DT)


func after_all() -> void:
	(rig["player"] as Node).queue_free()
	puppet.queue_free()
	(rig["origin"] as XROrigin3D).world_scale = 1.0


func _pose(g: StringName, t: float, yaw_deg: float, pitch_deg: float) -> void:
	puppet.look_yaw = deg_to_rad(yaw_deg)
	puppet.look_pitch = deg_to_rad(pitch_deg)
	puppet.pose_for(g, t)
	puppet.apply()
	extras.calibration.tick(DT)
	wings.update_wings(1.0)


## The nearest in-view feather point: [depth (m, tracking scale), what].
func _nearest_in_view() -> Array:
	var origin := rig["origin"] as Node3D
	var cam := rig["camera"] as Node3D
	var ws := (origin as XROrigin3D).world_scale
	var to_cam := (origin.global_transform.affine_inverse() * cam.global_transform).affine_inverse()
	var tan_h := tan(deg_to_rad(HALF_H))
	var tan_v := tan(deg_to_rad(HALF_V))
	var best := [INF, ""]
	for k in FirstPersonWings.PER_WING * 2:
		var xf := wings.feather_transform(k)
		for u: float in FirstPersonWings.STATIONS:
			for w: float in [-0.5, 0.0, 0.5]:
				var p := to_cam * (xf * Vector3(u, 0.0, w))
				var depth := -p.z / ws
				if depth <= 0.0:
					continue
				if absf(p.x) / ws > depth * tan_h or absf(p.y) / ws > depth * tan_v:
					continue
				if depth < float(best[0]):
					best = [depth, "feather %d" % k]
	return best


func test_the_wings_are_never_clipped_by_the_near_plane() -> void:
	check(extras.calibration.calibrator.calibrated, "(setup) the rig is calibrated")
	var near := WorldScaleDriver.NEAR_K
	var looks := [[0.0, 0.0], [0.0, -30.0], [0.0, -60.0], [0.0, 20.0], [55.0, -25.0], [-55.0, -25.0],
		[80.0, -10.0], [-80.0, -10.0], [30.0, -45.0], [-30.0, -45.0]]
	var gestures := [&"spread", &"glide", &"tuck", &"wings_forward", &"superman", &"spread_high", &"held",
		&"bank_left", &"bank_right", &"twist_up", &"twist_down"]
	var worst := [INF, ""]
	var cases := 0
	for ws: float in [1.0, 0.14]:
		(rig["origin"] as XROrigin3D).world_scale = ws
		for g: StringName in gestures + [&"flap"]:
			var phases := [0.0] if g != &"flap" else [0.0, 0.15, 0.3, 0.45, 0.6, 0.75, 0.9, 1.05]
			for ph: float in phases:
				for lk: Array in looks:
					_pose(g, ph, lk[0], lk[1])
					var n := _nearest_in_view()
					cases += 1
					if Paths.arg("near_dump", "") != "" and float(n[0]) < 0.12:
						print("[vr] near-case %.3f %s t=%.2f look %s ws %.2f %s" % [n[0], g, ph, str(lk), ws, n[1]])
					if float(n[0]) < float(worst[0]):
						worst = [n[0], "%s t=%.2f look %s ws %.2f (%s)" % [g, ph, str(lk), ws, n[1]]]
	print("[vr] nearest first-person wing point in view: %.3f m (%s) over %d cases; near plane %.3f m" % [worst[0], worst[1], cases, near])
	metric("nearest_wing_in_view_m", snappedf(float(worst[0]), 0.001))
	metric("nearest_case", worst[1])
	metric("near_k", near)
	gt(float(worst[0]), MARGIN * near, "every feather in view is at least %.2f x the near plane away (nearest %.3f m: %s)" % [MARGIN, worst[0], worst[1]])
	(rig["origin"] as XROrigin3D).world_scale = 1.0


## The player scene's own camera starts at the game's near plane (integration
## round 2, the Quest verifier: player.tscn said 0.03, so until the rig
## extras attached - the first frames, the loading card - the camera ran at
## half the game's near plane; at world_scale 1, NEAR_K x 1).
func test_the_player_scene_camera_starts_at_the_games_near_plane() -> void:
	var scene := load("res://scenes/player/player.tscn") as PackedScene
	var p := scene.instantiate()
	var cam := p.get_node(^"XROrigin3D/XRCamera3D") as XRCamera3D
	near(cam.near, WorldScaleDriver.NEAR_K, 1e-6, "player.tscn camera near %.3f = NEAR_K %.3f x world_scale 1" % [cam.near, WorldScaleDriver.NEAR_K])
	near(PlayerBird.NEAR_PER_WORLD_SCALE, WorldScaleDriver.NEAR_K, 1e-6, "flight's own near constant agrees")
	p.free()
