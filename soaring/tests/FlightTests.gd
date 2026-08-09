extends SceneTree

# FlightTests — headless validation harness for Soaring flight model
# Run: godot --headless --xr-mode off --path . --script res://tests/FlightTests.gd
# Exit code 0 = all pass, 1 = fail

var player: Node
var passed: int = 0
var failed: int = 0
var total: int = 0

func _init():
    print("\n=== Soaring Flight Validation Harness ===")
    # Load and instantiate player without needing full scene
    var player_scene: PackedScene = load("res://scenes/player/BirdPlayer.tscn")
    if player_scene == null:
        printerr("FAIL: cannot load BirdPlayer.tscn")
        quit(1)
        return
    player = player_scene.instantiate()
    # Create root for physics
    var root = Node3D.new()
    root.name = "TestRoot"
    root.add_child(player)
    # We need to add root to tree
    self.root.add_child(root)
    # Wait one frame for _ready
    # Use call_deferred to start tests after ready
    call_deferred("_run_all")

func assert_true(cond: bool, msg: String):
    total += 1
    if cond:
        passed += 1
        print("[PASS] ", msg)
    else:
        failed += 1
        printerr("[FAIL] ", msg)

func assert_approx(a: float, b: float, tol: float, msg: String):
    total += 1
    var diff = abs(a - b)
    if diff <= tol:
        passed += 1
        print("[PASS] ", msg, " (got %.3f ≈ exp %.3f tol %.3f)" % [a, b, tol])
    else:
        failed += 1
        printerr("[FAIL] ", msg, " (got %.3f want %.3f tol %.3f diff %.3f)" % [a, b, tol, diff])

func _run_all():
    await process_frame
    # Put player at known state
    player.global_position = Vector3(0, 30, 0)
    player.velocity = Vector3.ZERO
    player.is_perched = false
    # Ensure test override is cleared then set
    # Test 1: No-spurious-flap when hands move <0.12 amplitude at low speed
    print("\n-- Test 1: Amplitude gated (small wiggle must not flap) --")
    player._test_clear_override()
    player.global_position = Vector3(0, 30, 0)
    player.velocity = Vector3(5, 0, 0) # level flight 5 m/s
    player.flap_count = 0
    var base_left = Vector3(-0.67, 0.0, -0.45)
    var base_right = Vector3(0.67, 0.0, -0.45)
    var head = Basis.IDENTITY
    # small wiggle 0.08 m amplitude at ~6Hz for 2 sec
    var delta = 1.0/90.0
    for i in range(180):
        var t = i * delta
        var wig = sin(t * 6.0 * TAU) * 0.08
        var ly = base_left; ly.y += wig
        var ry = base_right; ry.y += wig
        player._test_set_hand_local(ly, ry, head)
        player._physics_process(delta)
        # also call global position update via XROrigin? Not needed for test
        if i % 45 == 0:
            pass
    var count_small = player.flap_count
    assert_true(count_small == 0, "small 0.08m wiggle over 2s should produce 0 flaps (got %d)" % count_small)

    print("\n-- Test 2: Intentional large flap should trigger --")
    player.flap_count = 0
    # Reset state machines
    player._has_prev = false
    player._left_hand_state = player.HandFlapState.new()
    player._right_hand_state = player.HandFlapState.new()
    player._flap_timer = 0.0
    # Large downstroke 0.32 amplitude at ~1.4Hz (real flap)
    for i in range(120):
        var t = i * delta
        # single flap: down for 0.22s, up for 0.22s etc. Use saw-like
        var phase = fmod(t, 0.55)
        var ly = base_left
        var ry = base_right
        if phase < 0.18:
            # down stroke fast 0.32m drop
            var frac = phase / 0.18
            ly.y = base_left.y - frac * 0.32
            ry.y = base_right.y - frac * 0.32
        elif phase < 0.38:
            var frac = (phase - 0.18) / 0.20
            ly.y = (base_left.y - 0.32) + frac * 0.32
            ry.y = (base_right.y - 0.32) + frac * 0.32
        else:
            ly.y = base_left.y
            ry.y = base_right.y
        player._test_set_hand_local(ly, ry, head)
        player._physics_process(delta)
    var count_large = player.flap_count
    assert_true(count_large >= 1 and count_large <= 4, "large 0.32m flaps over ~1.3s should produce 1-4 flaps (got %d)" % count_large)
    if count_large >= 1:
        assert_true(player.velocity.y > 2.0, "after large flap, vertical velocity should jump (>2 m/s) got %.2f" % player.velocity.y)

    print("\n-- Test 3: Wing tuck reduces lift --")
    # Level flight 12 m/s, compare spread 1.0 vs 0.28 (tucked)
    var lift_vals = []
    for spread_test in [1.0, 0.28]:
        player.global_position = Vector3(0, 30, 0)
        player.velocity = Vector3(12, 0, 0)
        player._bank_smooth = 0.0
        player._pitch_smooth = 0.0
        player.is_perched = false
        var dist = spread_test * 1.35
        var left_t = Vector3(-dist*0.5, 0.0, -0.45)
        var right_t = Vector3(dist*0.5, 0.0, -0.45)
        player._test_set_hand_local(left_t, right_t, Basis.IDENTITY)
        # One physics tick to compute accel's lift contribution? Instead measure velocity.y after 0.8s without flaps
        # Track delta y velocity over time
        var vy0 = player.velocity.y
        for i in range(72): # 0.8s
            player._physics_process(delta)
            # keep hands same
            player._test_set_hand_local(left_t, right_t, Basis.IDENTITY)
            # zero out spurious flap timer so not flapping
            # flap timer will be >0 from previous, ensure stays >0
            player._flap_timer = 0.5
        var dv = player.velocity.y - vy0 # should be negative sink
        lift_vals.append(dv)
        print("  spread %.2f -> deltaVy %.3f, sink rate %.3f" % [spread_test, dv, -dv/0.8])
    # tucked should sink faster (more negative) than spread
    assert_true(lift_vals[1] < lift_vals[0] - 1.0, "tucked (0.28) must sink at least 1.0 m/s faster than spread (1.0): got tucked dv %.2f vs spread dv %.2f" % [lift_vals[1], lift_vals[0]])
    assert_true(lift_vals[0] < -0.3 and lift_vals[0] > -6.0, "spread 1.0 at 12 m/s should sink gently (-0.3 to -6) got %.2f" % lift_vals[0])

    print("\n-- Test 4: Dive converts altitude to speed (energy) --")
    player.global_position = Vector3(0, 35, 0)
    player.velocity = Vector3(0, 0, -12) # forward is -Z, but our forward is -head_basis.z. Use velocity matching forward
    # In player physics, forward is -head_basis.z. To dive, head pitch -30deg (looking down)
    var dive_basis = Basis.from_euler(Vector3(deg_to_rad(-30), 0, 0))
    var level_basis = Basis.IDENTITY
    # Level 0.9s
    player.velocity = Vector3(12, 0, 0) # airspeed magnitude 12
    # Actually player uses velocity vector rotated, but for test we just set airspeed 12 and pitch
    var left_dive = Vector3(-0.67, 0.0, -0.45)
    var right_dive = Vector3(0.67, 0.0, -0.45)
    player.global_position = Vector3(0, 35, 0)
    player.velocity = Vector3(12, 0, 0)
    player._bank_smooth = 0.0
    player._pitch_smooth = 0.0
    player._test_set_hand_local(left_dive, right_dive, level_basis)
    var speed_level_start = player.velocity.length()
    var y_level_start = player.global_position.y
    for i in range(81): # 0.9s
        player._test_set_hand_local(left_dive, right_dive, level_basis)
        player._physics_process(delta)
        # integrate position manually (move_and_slide moves body, but in test tree root at 0,0,0 without ground collisions it will move)
        # For headless we use move_and_slide which needs physics; but we set position manually after?
        # Use global_position += velocity*delta for approximation if move_and_slide didn't move (no collision)
        # However player is CharacterBody, so global_position updated by move_and_slide. We'll record velocity magnitude instead of position.
    var speed_level_end = player.velocity.length()
    var dv_level = speed_level_end - speed_level_start

    # Dive same duration
    player.global_position = Vector3(0, 35, 0)
    player.velocity = Vector3(12, 0, 0)
    player._bank_smooth = 0.0
    player._pitch_smooth = 0.0
    player._test_set_hand_local(left_dive, right_dive, dive_basis)
    var speed_dive_start = player.velocity.length()
    for i in range(81):
        player._test_set_hand_local(left_dive, right_dive, dive_basis)
        player._physics_process(delta)
    var speed_dive_end = player.velocity.length()
    var dv_dive = speed_dive_end - speed_dive_start

    print("  level dv %.3f, dive dv %.3f (dive should gain more speed)" % [dv_level, dv_dive])
    assert_true(dv_dive > dv_level + 0.8, "dive (-30deg) must gain at least 0.8 m/s more than level (level dv %.2f dive dv %.2f)" % [dv_level, dv_dive])
    # Also dive should sink more
    # Use vertical velocity: dive should have more negative vy
    player.global_position = Vector3(0, 35, 0)
    player.velocity = Vector3(12, 0, 0)
    player._test_set_hand_local(left_dive, right_dive, dive_basis)
    for i in range(81):
        player._test_set_hand_local(left_dive, right_dive, dive_basis)
        player._physics_process(delta)
    var vy_dive = player.velocity.y
    player.global_position = Vector3(0, 35, 0)
    player.velocity = Vector3(12, 0, 0)
    player._test_set_hand_local(left_dive, right_dive, level_basis)
    for i in range(81):
        player._test_set_hand_local(left_dive, right_dive, level_basis)
        player._physics_process(delta)
    var vy_level = player.velocity.y
    print("  vy dive %.3f vs level vy %.3f (dive must be lower/more negative)" % [vy_dive, vy_level])
    assert_true(vy_dive < vy_level - 0.6, "dive vy %.2f must be at least 0.6 below level vy %.2f" % [vy_dive, vy_level])

    print("\n-- Test 5: Bank turn yaws player --")
    player.global_position = Vector3(0, 30, 0)
    player.velocity = Vector3(0, 0, -12) # need forward along -Z to see yaw effect as x
    player._bank_smooth = 0.0
    player._test_set_hand_local(Vector3(-0.67, 0.0, -0.45), Vector3(0.67, 0.0, -0.45), Basis.IDENTITY)
    # bank 30deg via hand diff 0.42m
    var left_bank = Vector3(-0.67, -0.21, -0.45)
    var right_bank = Vector3(0.67, 0.21, -0.45)
    player.velocity = Vector3(12, 0, 0)
    var yaw_start = player.rotation.y
    var vel_start_x = player.velocity.x
    for i in range(90): # 1s
        player._test_set_hand_local(left_bank, right_bank, Basis.IDENTITY)
        player._physics_process(delta)
    var yaw_end = player.rotation.y
    var yaw_delta = yaw_end - yaw_start
    print("  yaw delta %.3f rad (should be ~0.6-1.4 for 30deg bank at 12m/s over 1s)" % yaw_delta)
    assert_true(abs(yaw_delta) > 0.25, "bank 30deg must produce at least 0.25 rad yaw in 1s, got %.3f" % yaw_delta)
    assert_true(abs(yaw_delta) < 2.2, "bank yaw should be bounded <2.2 rad, got %.3f" % yaw_delta)

    print("\n-- Test 6: No lift when airspeed ~0 (stall) must fall --")
    player.global_position = Vector3(0, 30, 0)
    player.velocity = Vector3(0.8, 0, 0) # near stall
    player._test_set_hand_local(Vector3(-0.67, 0.0, -0.45), Vector3(0.67, 0.0, -0.45), Basis.IDENTITY)
    var vy0_stall = player.velocity.y
    for i in range(45):
        player._test_set_hand_local(Vector3(-0.67, 0.0, -0.45), Vector3(0.67, 0.0, -0.45), Basis.IDENTITY)
        player._physics_process(delta)
    var vy_after = player.velocity.y
    assert_true(vy_after < -2.5, "at near-zero speed with stalled lift, must fall fast (vy < -2.5), got %.2f" % vy_after)

    print("\n=== Results: %d/%d passed, %d failed ===" % [passed, total, failed])
    if failed > 0:
        printerr("FLIGHT TESTS FAILED")
        quit(1)
    else:
        print("ALL FLIGHT TESTS PASSED")
        quit(0)
