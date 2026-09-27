# Quest / OpenXR platform research (Godot 4.7.2, Meta Quest Pro)

Research for the `vr`, `integration`, `world`, `birds` and `ui` areas. It covers
project settings, what `world_scale` actually does, input and haptics, performance
budgets, Android export and driving the Meta XR Simulator from a script.

The facts come from three kinds of source. The Godot **4.7.2-stable** source (cited as
`file:line` at tag `4.7.2-stable`). The installed addons and simulator on this Mac.
Live simulator runs made during this research (marked **[verified]**). Items that
need the real headset are marked **[device]**.

---

## 0. Top actions (ranked)

1. **Upgrade `addons/godotopenxrvendors` from 3.1.2 to 5.1.0-stable** before the
   first Android export. Version 3.1.2 targets Godot 4.3. Its Meta AAR ships its own
   `jni/arm64-v8a/libopenxr_loader.so` **[verified: `unzip -l`]**. Godot 4.6+ already adds the
   Khronos loader through its gradle template (`openxrLoaderVersion: '1.1.53'` in
   `platform/android/java/app/config.gradle`). Expect a duplicate-`.so` merge failure.
   Vendors 5.0.0 changelog: "Don't include the OpenXR loader because it's added by
   Godot now". Version 3.1.2 also turns on about 20 Meta extensions we don't use
   (passthrough, scene, body/face tracking, and more; see the simulator log from any
   run). Versions 4.0+ gate these behind project settings. Download:
   <https://github.com/GodotVR/godot_openxr_vendors/releases/download/5.1.0-stable/godotopenxrvendorsaddon.zip>
   (5.1 needs Godot ≥ 4.6).
2. **Make foveation actually work on the Mobile renderer.** Add `rendering/vrs/mode=2`
   (XR). Without it, `xr/openxr/foveation_level=2` does nothing: the Mobile renderer only
   uses the runtime's fragment density map when the viewport VRS mode is `VRS_XR`
   (`servers/rendering/renderer_rd/forward_mobile/render_forward_mobile.cpp:237-240`,
   and `render_scene_buffers_rd.cpp:205` creates no VRS buffer when the mode is disabled).
3. For v1, set `xr/openxr/foveation_eye_tracked=false` and
   `xr/openxr/foveation_with_subsampled_images=false`. Both default to **true** in
   4.7.2. Switch them on only after an A/B test on the Quest Pro (see §1.3).
4. Keep the Mobile renderer's **single-pass subpass post-processing** path. It needs
   no glow, auto-exposure, DOF, FXAA/SMAA/TAA, 3D scaling ≠ 1, SCREEN/DEPTH_TEXTURE
   reads, compositor effects or canvas background
   (`render_forward_mobile.cpp:891-1025`). Breaking it costs an extra full-screen pass
   per eye and turns subsampled images off.
5. Read wing orientation from the **grip** pose, in raw tracking space
   (`XRPose.transform`), and compute stroke velocity by finite differences. Don't use
   `XRPose.linear_velocity`: it is unscaled, and the simulator reports zero velocity
   for key-driven motion (§3).
6. Scale `XRCamera3D.near` with `world_scale`. Also scale everything parented to the
   controllers (wing and hand meshes) by `world_scale` yourself. The engine scales
   positions only (§2).
7. Refresh rate: make it a setting. Default to 72 Hz on the device until profiled,
   and allow 90 Hz when the frame budget holds (§1.2). Re-apply the physics tick on
   `refresh_rate_changed`.
8. Leave Application SpaceWarp, frame synthesis and depth submission **off** for v1 (§1.4).
9. Install the 4.7.2 export templates (only 4.7.1 is installed) and create
   `export_presets.cfg` (§5).
10. Drive simulator controllers from tests through the simulator's own gRPC server
    **[verified]** (§6). This can move one controller through a real downstroke and
    upstroke at 3 m/s, or roll it about its axis, and Godot sees it.

---

## 1. Project settings for Quest

### 1.1 Recommended `project.godot` deltas

| Setting | Now | Recommend | Why |
|---|---|---|---|
| `rendering/renderer/rendering_method` | `mobile` | keep | The Godot 4.7 docs recommend Mobile for standalone headsets ("use the Mobile renderer for … a standalone headset like the Meta Quest 3"). Compatibility (GLES3) is the fallback if Vulkan overhead bites. The simulator can't run GL. |
| `rendering/anti_aliasing/quality/msaa_3d` | `2` (4x) | keep | MSAA resolves on-tile on Adreno. The docs note foveation is disabled on **non-Android** when MSAA is on, so the simulator never shows foveation (expected). |
| `rendering/vrs/mode` | unset (0) | **`2`** (XR) | Needed for foveation on Mobile/Forward+ (see §0.2 and the `OpenXRInterface.vrs_*` docs: "Requires Viewport.vrs_mode = VRS_XR"). |
| `xr/openxr/foveation_level` | `2` | `3` (high) with dynamic on | Fixed foveated rendering (FFR) on Quest Pro saves 26–36% GPU at default resolution ([UploadVR](https://www.uploadvr.com/quest-pro-foveated-rendering-performance/)). Dynamic keeps it low until GPU load rises. |
| `xr/openxr/foveation_dynamic` | `true` | keep | Scales between low and `foveation_level` by framerate. |
| `xr/openxr/foveation_eye_tracked` | default **true** | **`false`** for v1 | See §1.3. |
| `xr/openxr/foveation_with_subsampled_images` | default **true** | **`false`** for v1 | Open bug [#123406](https://github.com/godotengine/godot/issues/123406) (Quest 3, Godot 4.7.1 + vendors 5.1.0: renders wrong at high foveation). Worth about 1 ms on Quest 3 ([PR #116220](https://github.com/godotengine/godot/pull/116220)). Test it on the Pro later. |
| `xr/openxr/submit_depth_buffer` | default false | keep false | Costs depth store bandwidth. Only needed for ASW or frame synthesis. |
| `xr/openxr/reference_space` | `2` (Local Floor) | keep | Standing play with real floor height. Seated mode is handled in WingCalibration. |
| `xr/openxr/extensions/user_presence` | default false | `true` | `user_presence_changed` lets us pause when the headset comes off. |
| `physics/common/physics_ticks_per_second` | 72 | keep; VR overrides it at runtime | See §1.5. |
| `physics/common/physics_interpolation` | off | keep off | The tick matches the display. XR nodes force interpolation off (`scene/3d/xr/xr_nodes.cpp:223,478`). |
| `rendering/scaling_3d/scale` | 1.0 | **keep 1.0** | Any 3D scaling kills the Mobile subpass path (`render_forward_mobile.cpp:973-975`). |
| `rendering/lights_and_shadows/directional_shadow/size.mobile` | 2048 | 1024–2048 | At most one directional shadow, 2 splits, short `shadow_max_distance`. |
| `rendering/textures/vram_compression/import_etc2_astc` | true | keep | ASTC on Quest. |

Keep `rendering_device/driver.macos="vulkan"`. The simulator is Vulkan-only, and the
magenta-tile rule in ARCHITECTURE §2 still applies to screenshots.

**`render_target_size_multiplier`** "must be set before the interface has been
initialized" (`OpenXRInterface` docs). With `xr/openxr/enabled=true` that happens at
engine start, and 4.7.2 has no `xr/` project setting for it (full list checked in
`doc/classes/ProjectSettings.xml`). Treat it as fixed at 1.0. After upgrading, the
runtime-driven safety valve is the vendors plugin's Meta **Dynamic Resolution**
(`XR_META_recommended_layer_resolution`, on by default in vendors ≥ 4.0).

**CPU/GPU levels:** `OpenXRInterface.set_cpu_level()` and `set_gpu_level()` take
`PERF_SETTINGS_LEVEL_SUSTAINED_HIGH` (via `XR_EXT_performance_settings`, which is
already enabled in our runs). Call both in `_on_session_begun()` **[device: confirm with
OVR Metrics]**.

### 1.2 Refresh rate: 72 or 90

- Quest Pro displays run at 72 and 90 Hz. The simulator's "Meta Quest Pro" profile
  reports `[30, 60, 72, 80, 90]` **[verified: `get_available_display_refresh_rates()`]**,
  a superset of the device list.
- Meta puts Quest 2 and Quest Pro in the same budget tier (§4). The minimum for
  interactive apps is 72 FPS ([Meta perf targets](https://developers.meta.com/horizon/documentation/unity/unity-perf/)).
- For a flight game, 90 Hz reduces judder in fast optic flow. It costs 2.8 ms of frame
  budget (11.1 ms instead of 13.9 ms), and the main thread runs GDScript simulation for
  up to 60 birds.
- **Recommendation:** add a `Settings` key `vr/refresh_rate`. Default it to 72 on
  Android, and offer 90 once OVR Metrics shows steady headroom (GPU under about 9 ms,
  no stale frames) **[device]**. `vr_manager.gd` currently always picks 90 when it is
  available. Change it to read the setting.
- Also connect `OpenXRInterface.refresh_rate_changed` and re-apply
  `Engine.physics_ticks_per_second`. The runtime can change the rate, for example on
  thermal throttling.

### 1.3 Fixed or eye-tracked foveation on Quest Pro

- Measured savings on Quest Pro at default resolution: FFR 26–36%, eye-tracked
  foveated rendering (ETFR) 33–45%. That is "little gain over fixed foveation", and
  Quest Pro eye tracking has about 50 ms latency
  ([UploadVR](https://www.uploadvr.com/quest-pro-foveated-rendering-performance/),
  [Meta ETFR blog](https://developers.meta.com/horizon/blog/save-gpu-with-eye-tracked-foveated-rendering/)).
- ETFR also needs `com.oculus.permission.EYE_TRACKING`. In vendors,
  `meta_xr_features/eye_tracking` adds it to the manifest (`meta_export_plugin.cpp:340`).
  The user must accept the permission and have eye tracking enabled, otherwise ETFR
  silently isn't used.
- Godot's Vulkan eye-tracked path has a bug history. [#112988](https://github.com/godotengine/godot/issues/112988)
  (Quest Pro: wrong fragment density map offsets; Quest 3: no frames) was fixed by
  [#112994](https://github.com/godotengine/godot/pull/112994) for 4.6. [#113778](https://github.com/godotengine/godot/issues/113778)
  (ETFR + MSAA renders everything at lowest density; seen on Galaxy XR, not on the Pro)
  is still open.
- **Decision for v1:** FFR high + dynamic, with ETFR off. Later, A/B ETFR on the Pro
  using OVR Metrics GPU time and a look at the periphery **[device]**.

### 1.4 Application SpaceWarp / frame synthesis: not for v1

- **Not available with the installed vendors 3.1.2.** Its binary has no
  `XR_FB_space_warp` symbols **[verified: `strings`]**. ASW arrived in vendors 4.1 ("only
  with Godot 4.5+"). It crashed on Godot 4.7
  ([#118902](https://github.com/godotengine/godot/issues/118902)), which vendors
  5.0.1/4.3.1 fixed. Core 4.7 also has `xr/openxr/extensions/frame_synthesis`
  (`XR_EXT_frame_synthesis`, "should not be enabled in conjunction with ASW"). The
  simulator advertises both extensions. Quest device support for frame synthesis is
  unverified.
- **Why not:** the game renders at 36/45 Hz and the runtime extrapolates. Our content
  is the worst case for that: fast rig translation, thin geometry (wires, twigs), many
  small fast birds (all need correct motion vectors), and transparent VFX. Game logic
  and flap detection would also run at half rate unless decoupled. Depth submission
  becomes mandatory as well.
- Keep it as a later lever if we end up GPU-bound. Meta's sample:
  `meta-space-warp-sample.zip` in the 5.1.0 release.

### 1.5 Physics tick = refresh (already done; keep)

- `vr_manager.gd` sets `Engine.physics_ticks_per_second` to the display rate at
  `session_begun`. This matters because `XROrigin3D` pushes its global transform to
  `XRServer.world_origin` on every transform change (`xr_nodes.cpp:759,837`). It only
  interpolates when physics interpolation is on (`:843`). A 72 Hz tick on a 90 Hz
  display moves the rig in steps and judders the whole world.
- Keep `max_physics_steps_per_frame=4`. Keep `physics_jitter_fix=0.5`, which snaps
  to one step per frame when the rates match.
- Keep `PROCESS_MODE_ALWAYS` under XROrigin3D. On `session_visible` (the system menu
  is open) and on `user_presence_changed(false)`, request `Game.PAUSED`.
- On `pose_recentered`, call `XRServer.center_on_hmd(XRServer.RESET_BUT_KEEP_TILT, true)`
  ([Godot "better XR start script"](https://docs.godotengine.org/en/stable/tutorials/xr/a_better_xr_start_script.html)).

### 1.6 What to avoid (Quest + Mobile renderer)

- Glow, auto-exposure, DOF, FXAA/SMAA/TAA, a canvas background, and any 3D scaling
  below 1 (each drops the subpass post-process path).
- Shaders reading `SCREEN_TEXTURE`, `DEPTH_TEXTURE` or `NORMAL_ROUGHNESS_TEXTURE`
  (refraction, soft particles, water depth fades). Also `CompositorEffect`s.
- SSAO/SSR/SSIL/SDFGI/VoxelGI and volumetric fog. The Mobile renderer doesn't support
  them anyway.
- Real-time omni/spot lights, especially with shadows. A shadowed omni light adds
  several shadow draw passes per lit object. Use the sun only, plus unshaded emissive
  materials for "lights".
- Alpha-blended overdraw: big transparent quads, stacked particles, fog cards. Use
  alpha scissor or opaque meshes with vertex-colour fades.
- Per-frame `SubViewport` UI renders: set `render_target_update_mode` to update only on
  change. Consider `OpenXRCompositionLayerQuad` for menu panels (sharper text,
  composited by the runtime).

---

## 2. What `XROrigin3D.world_scale` does in Godot 4.7

All citations are at tag `4.7.2-stable`.

- **It is global.** `XROrigin3D.set_world_scale` forwards to `XRServer.set_world_scale`
  (`scene/3d/xr/xr_nodes.cpp:733-738`), which clamps it to **[0.01, 1000]**
  (`servers/xr/xr_server.cpp:130-138`).
- **Controllers and trackers:** `XRNode3D` sets its transform from
  `XRPose.get_adjusted_transform()`. That function multiplies **only the origin** by
  `world_scale`, then applies the reference frame (`servers/xr/xr_pose.cpp:90-102`).
  `XRController3D.position` in the origin's space is therefore real metres × world_scale,
  and its rotation is unchanged. **Velocities are not scaled**: `XRPose.linear_velocity`
  and `angular_velocity` come back raw.
- **Camera and eyes:** `OpenXRInterface.get_camera_transform()` scales the head origin
  (`modules/openxr/openxr_interface.cpp:1076-1089`). `get_transform_for_view()` scales
  each eye's origin, so the **IPD scales too**. It returns
  `world_origin * reference_frame * eye` (`:1091-1110`).
  - The renderer ignores the `XRCamera3D` node's transform. It rebuilds each eye from
    `XRServer.world_origin` with fresh tracking (`servers/rendering/renderer_scene_cull.cpp:2749-2755`,
    comment: "We ignore our camera position … take our origin point and have our XR
    interface add fresh tracking data").
  - Effect: `world_scale = 2` means 1 m of real head movement becomes 2 m in the game,
    and the eyes are twice as far apart, so the world looks half size.
    `world_scale = 0.15` (sparrow-sized, if 1 unit = a 1.6 m human arm span) makes the
    world look 6.7× bigger.
- **Near and far planes are NOT scaled.** The renderer passes `camera->znear/zfar`
  straight to `get_projection_for_view()`, and OpenXR builds the projection from them
  (`renderer_scene_cull.cpp:2755`, `openxr_interface.cpp:1112+`). A fixed near plane
  of 0.05 feels like 0.05/s metres. At s = 0.1 that clips everything within 0.5 m of
  the eye; at s = 1.3 it feels like 4 cm.
  - Set `XRCamera3D.near = 0.05 * world_scale` (at least 0.001) every time the scale
    changes. This matches ARCHITECTURE §7.5.
  - Leave `far` in world units (2000–3000). The map doesn't change size.
  - RD renderers use reverse-Z, so a small near plane costs little precision.
- **Why scaling the XROrigin3D node (or an ancestor) is unsupported.** The editor
  warns: "Changing the scale on the XROrigin3D node is not supported. Change the World
  Scale instead." (`xr_nodes.cpp:702-704`).
  - The origin's **global** transform, scale included, becomes `XRServer.world_origin`
    (`:759,837,843`) and is multiplied into every eye's view transform (see above).
  - Scaled view matrices are non-orthonormal. The renderer's camera, culling and
    lighting code assumes rigid view transforms; the sky pass, normals in view space and
    frustum culling all break. That is the "flat sky/ground colour" seen in the sibling
    attempt.
  - Meanwhile the compositor reprojects with the real, unscaled head pose.
- **Consequences for our code:**
  - Anything parented to `XRController3D` (wing meshes, hand colliders) is positioned
    correctly but **not sized**. Give those children `scale = Vector3.ONE * world_scale`.
    Scaling children of the controllers is fine; only the origin and its ancestors must
    stay unscaled.
  - UI panels "1.5–2 m away" go at `1.5 * world_scale` world units.
  - Audio (`AudioStreamPlayer3D.unit_size` and max distance) should scale with
    `world_scale` too, so a moth hears the world at human-like distances.
  - `WingInput` should read raw tracking-space poses (`XRPose.transform`: unscaled,
    before the reference frame). Alternatively, divide node positions by `world_scale`.

---

## 3. Input, haptics and grip-pose axes

### 3.1 Our action map (`openxr_action_map.tres`)

There is one action set, `godot`. Interaction profiles present:
`/interaction_profiles/khr/generic_controller`, `/interaction_profiles/oculus/touch_controller`,
`/interaction_profiles/bytedance/pico4_controller` and `/interaction_profiles/ext/hand_interaction_ext`.

| Action (Godot name) | Type | Touch binding (`oculus/touch_controller`) | Read with |
|---|---|---|---|
| `trigger` | float | `…/input/trigger/value` | `ctrl.get_float("trigger")` |
| `trigger_click` | bool | `…/input/trigger/value` (runtime threshold) | `is_button_pressed` / `button_pressed` signal |
| `trigger_touch` | bool | `…/input/trigger/touch` | |
| `grip` | float | `…/input/squeeze/value` | `get_float("grip")` (perch and cling) |
| `grip_click` | bool | `…/input/squeeze/value` | |
| `grip_force` | float | *unbound on Touch* | |
| `primary` | vec2 | `…/input/thumbstick` | `get_vector2("primary")` |
| `primary_click` / `primary_touch` | bool | `…/thumbstick/click` / `…/touch` | |
| `secondary*` | | *unbound on Touch* | |
| `menu_button` | bool | **left only**: `/user/hand/left/input/menu/click` | pause |
| `select_button` | bool | `…/input/system/click` (both). The system button is reserved by the Meta runtime, so it never fires. | don't use |
| `ax_button` / `ax_touch` | bool | X (left) / A (right) click/touch | |
| `by_button` / `by_touch` | bool | Y (left) / B (right) click/touch | |
| `default_pose` → pose `"default"` | pose | `aim/pose` | the default `XRController3D.pose` is the **aim** pose |
| `aim_pose` → `"aim"` | pose | `aim/pose` | |
| `grip_pose` → `"grip"` | pose | `grip/pose` | **use this for wings** |
| `palm_pose` → `"palm_pose"` (not renamed) | pose | `grip_surface/pose` | |
| `haptic` | vibration | `…/output/haptic` | `trigger_haptic_pulse("haptic", …)` |

Godot renames only `default_pose`, `aim_pose` and `grip_pose`
(`openxr_interface.cpp:436-452`). `palm_pose` keeps its name.

- **Pause** is therefore the **left** menu (≡) button only; the right ☰/Oculus button
  belongs to the system. Offer a secondary pause gesture (for example a long press on
  B/Y) for players who expect the right hand.
- **Touch Pro controllers:** Godot 4.7.2 knows `/interaction_profiles/meta/touch_pro_controller`
  (`modules/openxr/extensions/openxr_meta_controller_extension.cpp:37,111-152`). The
  profile adds `trigger_curl`, `trigger_slide`, thumbrest force, stylus force,
  `haptic_trigger` and `haptic_thumb`.
  - We don't bind it, so the runtime should use our `oculus/touch_controller` bindings
    for the Pro. The simulator's Quest Pro profile reports exactly
    `oculus/touch_controller` for both hands **[verified: InfoService/GetInteractionProfiles]**.
  - Add a touch_pro profile later only if we want the localized haptics **[device]**.

### 3.2 Haptics

- API: `XRController3D.trigger_haptic_pulse(action_name: String, frequency: float, amplitude: float, duration_sec: float, delay_sec: float)`
  (declared on `XRNode3D`, `xr_nodes.cpp:266,357-366`). Use `action_name = "haptic"`.
- Path: `OpenXRInterface.trigger_haptic_pulse` converts seconds to nanoseconds, then
  `xrApplyHapticFeedback` (`openxr_interface.cpp:621-642`, `openxr_api.cpp:4016-4050`).
- **`delay_sec` is ignored.** The source says "TODO OpenXR does not support delay".
  Schedule patterns in game code with timers.
- **`frequency` is ignored on Quest's simple haptics.** Meta: "the
  `XrHapticVibration::frequency` member is ignored"
  ([Meta haptics](https://developers.meta.com/horizon/documentation/native/android/mobile-openxr-haptic/)).
  Pass `0.0`. Only **amplitude (0–1) × duration** shape the feel. Variable frequency
  needs PCM or parametric haptics (`XR_FB_haptic_pcm`, `XR_EXT_haptic_parametric`),
  which Godot doesn't expose.
- A new pulse **replaces** the one playing (OpenXR semantics). A `0.0` amplitude pulse
  stops it.
- The simulator gives no haptic feedback. Test haptics by wrapping the call in a
  `Haptics` service and recording calls in tests.
- Suggested distinct patterns (tune on the device):

| Pattern | Pulses |
|---|---|
| Wingbeat thump | 1 × 35 ms @ 0.5–0.8, scaled by stroke speed, at the downstroke peak |
| Catch | 3 × 40 ms @ 0.9, 70 ms apart |
| Collision | 1 × 90 ms @ 1.0 |
| Stall buffet | 20 ms @ 0.25–0.45, jittered every 70–110 ms while stalled |
| Updraft hum | 12 ms @ 0.12 every 150 ms |
| Danger | Heartbeat pair (2 × 30 ms, 120 ms gap), repeat rate and amplitude rise with proximity |

  Never send a continuous buzz.

### 3.3 Grip-pose axes: reading wrist roll as wing tilt

The OpenXR spec ([semantic paths](https://github.com/KhronosGroup/OpenXR-Docs/blob/main/specification/sources/chapters/semantic_paths.adoc))
defines the grip orientation. Godot uses the same right-handed, +Y up, -Z forward
axes and does not flip them.

- **+X**: "normal to the user's palm (**away from the palm in the left hand, into the palm in the right hand**)".
- **−Z**: "the ray that goes through the center of the tube formed by your non-thumb
  fingers, in the direction of little finger to thumb", which on a controller runs
  roughly along the handle.
- **+Y**: completes the right-handed frame.

In the **"wings spread, palms down"** pose, worked through for both hands:

- `-grip.z` points **forward**: the wing's leading-edge (chord) direction, the same for
  both hands.
- `+grip.y` points **along the arm towards the shoulder** for both hands. Wrist
  twist (pronation and supination) is rotation about this axis.
- The wing's **upper-surface normal** (back of the hand) is `+grip.x` for the right
  hand and `-grip.x` for the left.

```gdscript
# Raw tracking-space pose: metres, unscaled, before reference frame (scale-free WingInput).
var t := XRServer.get_tracker(&"right_hand") as XRPositionalTracker
var p := t.get_pose(&"grip")            # XRPose; check p.has_tracking_data
var b := p.transform.basis
var chord := -b.z                       # leading-edge direction
var arm_in := b.y                       # hand -> shoulder
var up_n := b.x                         # right hand; use -b.x for the left hand
# chord pitch (AoA offset): elevation of the chord in the body frame, minus the calibrated neutral
var pitch := asin(clampf(chord.dot(body_up), -1.0, 1.0)) - cal.neutral_pitch_right
# a downstroke pushes air along -up_n, so the reaction force is +up_n:
#   leading edge down tilts up_n forward, which gives lift plus thrust (requirement 1)
```

- People hold a flat wing at different wrist angles, and the grip pose is the runtime's
  approximation of the hand. Keep the neutral-roll and neutral-pitch calibration in
  `WingCalibration`.
- **Stroke velocity:** difference the grip positions yourself (tracking space,
  divided by the physics dt). Don't rely on `XRPose.linear_velocity`. The simulator's
  pose stream reports `linearVelocityValid=true` with zero velocity for key-driven
  motion **[verified]**, so a velocity-based flap detector would never fire there.
- **Simulator orientation:** the simulated controllers start at identity rotation
  (`-Z` forward, `+Y` up). Calibrate "neutral" on that pose in simulator tests and test
  tilts of about ±30° from it (§6).

---

## 4. Performance budgets and practices (Quest Pro, Godot Mobile)

**Meta targets** ([Testing and performance analysis](https://developers.meta.com/horizon/documentation/unity/unity-perf/)).
Quest 2 **and Quest Pro** are one tier:

- Draw calls: **80–200** for a "busy simulation", 200–300 medium, 400–600 light.
- Triangles: **750k–1M**.
- At least 72 FPS.

Quest 3 is about 1.5–2× higher.

**Our budget (ARCHITECTURE §7.4): ≤ 150 draw calls, ≤ 300k triangles, ≤ 60 NPC
birds.** Keep it. It is deliberately below Meta's busy-simulation tier because Godot's
per-draw CPU cost and our GDScript simulation share the main thread. Godot's default
thread model runs rendering on the main thread (`rendering/driver/threads/thread_model=1`;
"Separate" is marked experimental).

- **Measure per frame, not per eye.** XR uses multiview, so one draw call renders both
  eyes. Read `Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME` and
  `RENDER_TOTAL_PRIMITIVES_IN_FRAME`, which include shadow passes, from a
  representative camera in `tests/shots` and budget against those.
- **CPU rule of thumb (estimate; verify on the device):** a Quest Pro
  (Snapdragon XR2+ Gen 1, 865-class cores at headset clocks) is roughly **3–4× slower
  single-threaded** than this M1 Pro.
  - Target ≤ 1.5 ms of game logic per physics tick on the Mac, which is about 5–6 ms on
    the Pro, leaving room for render submission in a 13.9 ms (72 Hz) frame.
  - NPCs far from the player should step their brains and flight at 15–30 Hz with
    interpolated visuals, not at 90 Hz.

Practices for the Godot Mobile renderer:

- **One material wherever possible:** vertex colours or a small palette texture
  (e.g. 256×8 ASTC) on a shared `StandardMaterial3D`. Get the flat low-poly look from
  per-face (split) normals; `SHADING_MODE_PER_VERTEX` is a cheaper lighting option for
  distant or small meshes. Material and shader switches cost more
  CPU than extra draws ([Meta draw-call analysis](https://developers.meta.com/horizon/documentation/unity/po-draw-call-analysis/)).
- **MultiMesh** for trees, foliage, fences, pole insulators and feathers, **chunked
  spatially** (e.g. 64–128 m cells). A MultiMesh is culled as one AABB. One chunk
  costs one draw per pass.
- **Merge static meshes** per district chunk (buildings, rooftops, poles) with
  `SurfaceTool`/`ArrayMesh` at generation time. Keep collision separate and simple.
- **Visibility ranges** (`GeometryInstance3D.visibility_range_end` plus fade, or
  HLOD `visibility_parent`) for small props and distant district detail. Imported
  meshes get automatic LODs; procedural `ArrayMesh`es don't unless built via
  `ImporterMesh.generate_lods`.
- **Shadows:** one `DirectionalLight3D`, 2 PSSM splits, `shadow_max_distance` about
  60–120 m (world units, larger for bigger birds), `cast_shadow = OFF` on terrain,
  foliage MultiMeshes and distant chunks. Every shadow split re-draws its casters.
  Blob shadows under birds are cheaper and help depth reading.
- **Occlusion culling:** not worth its CPU cost in a mostly open 1.5 km arena. At most,
  try it inside the town district.
- **Birds:** 60 NPCs at one skinned mesh each is too many draws. Use a small number of
  low-poly meshes with wing animation in the vertex shader (flap phase via
  `INSTANCE_CUSTOM`). Draw with one MultiMesh per species, or at least share a single
  material.
- **Fog:** depth and height fog on `Environment` is fine (computed per material).
  Volumetric fog is unavailable on Mobile.
- **Sky:** a `ProceduralSkyMaterial` is fine. Use a small radiance size (32–64) and
  static sky. Changing sky parameters every frame re-renders radiance.
- **Profiling on the device:** OVR Metrics Tool overlay, or `adb logcat -s VrApi`
  (per-second `FPS=…,Stale=…,GPU%` lines) **[device: confirm the lines appear for
  OpenXR apps]**. Lock CPU and GPU levels before comparing runs.

---

## 5. Android / Quest export

**Export templates (4.7.2).** Only `4.7.1.stable` is installed. **[verified URL and size]**

- URL: <https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_export_templates.tpz>
- Size: 1,281,349,702 bytes
- sha256: `f298490b8d44d934be425a5a65a51bf15f422428b229a06a6e11d9ffea248011`

```bash
T=~/Library/Application\ Support/Godot/export_templates/4.7.2.stable
curl -L -o /tmp/tpl472.tpz https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_export_templates.tpz
shasum -a 256 /tmp/tpl472.tpz        # expect f298490b…8011
mkdir -p "$T" && unzip -j /tmp/tpl472.tpz 'templates/android_*' 'templates/version.txt' -d "$T"   # Android only; saves ~1 GB
cat "$T/version.txt"                  # 4.7.2.stable
```

**Toolchain.** The Godot 4.7.2 gradle template (`platform/android/java/app/config.gradle`)
uses:

- compileSdk 36, targetSdk 36, minSdk 24 (29 is the default when using Vulkan:
  `export_plugin.cpp:303-305`)
- buildTools `36.1.0` and platform `android-36`: both installed
- ndkVersion `29.0.14206865`: **not installed** (only 26.1). If gradle asks for it, run
  `sdkmanager "ndk;29.0.14206865"`.
- JDK 17 and the debug keystore are already in the editor settings.

**Gradle build is required.** Vendors is a v2 Android plugin (AAR).

**`export_presets.cfg`** (preset `Meta Quest`). Option names come from Godot 4.7.2
`platform/android/export/export_plugin.cpp` and vendors 5.1.0 `meta_export_plugin.cpp`.
`/Users/don/Projects/meta-demo/export_presets.cfg` is a full example for the older
plugin: it has `xr_mode=0` and the Meta plugin off, so don't copy those two lines.

```ini
[preset.0]
name="Meta Quest"
platform="Android"
runnable=true
export_filter="all_resources"
exclude_filter="tests/*, artifacts/*, scenes/dev/*"
export_path="build/soaring-quest.apk"

[preset.0.options]
gradle_build/use_gradle_build=true
gradle_build/export_format=0              ; APK
gradle_build/min_sdk=""                   ; 29 is the Vulkan default
gradle_build/target_sdk=""                ; 36 default
architectures/arm64-v8a=true              ; all others false
package/unique_name="com.<you>.soaring"
package/name="Soaring"
package/signed=true
package/show_in_app_library=true
screen/immersive_mode=true
xr_features/xr_mode=1                     ; OpenXR
xr_features/enable_meta_plugin=true       ; exactly one vendor
meta_xr_features/quest_2_support=true
meta_xr_features/quest_3_support=true
meta_xr_features/quest_pro_support=true
meta_xr_features/hand_tracking=0          ; none (controllers only)
meta_xr_features/passthrough=0
meta_xr_features/render_model=0
meta_xr_features/eye_tracking=0           ; 1 (optional) only when trying ETFR
permissions/internet=false                ; no other permissions needed
```

- `xr_mode=1` also passes `--xr_mode_openxr` so the APK enables OpenXR even if a
  non-XR preset exists (`export_plugin.cpp:3247-3255`).
- Supported-device metadata goes into `com.oculus.supportedDevices`
  (`meta_export_plugin.cpp:207-227,498`).
- Remove or leave unused `addons/godot_meta_toolkit` (Platform SDK: entitlements and
  achievements). It isn't needed for sideloading, and its AAR adds build surface.

**Build and deploy.** `tools/gd.sh` excludes `/android/` and `/build/`, so the
template installs inside the sandbox:

```bash
tools/gd.sh export --headless --install-android-build-template \
    --export-debug "Meta Quest" "$PWD/build/soaring-quest.apk"
adb install -r build/soaring-quest.apk
adb shell am start -n com.<you>.soaring/com.godot.game.GodotAppLauncher   # GodotApp itself is exported=false
adb logcat -s godot:V
```

---

## 6. Driving the Meta XR Simulator from scripts (macOS)

There are three routes, from most to least useful for our tests.
Simulator **v207.0** runs at `/Applications/MetaXRSimulator.app`. Its runtime JSON
points at `…/Resources/MetaXRSimulator/SIMULATOR.so`, which **loads inside the Godot
process**.

### 6.1 SimRpc gRPC: move controllers from a test **[verified]**

When an OpenXR app starts, the runtime (inside our Godot process) starts a gRPC server:

- The log is `~/Library/Application Support/MetaXR/MetaXrSimulator/logs/meta_xrsim_<date>_<godot pid>.log`
- It contains the line `SimRpc server started on port <N>`
- The server exists only while the app runs.

The simulator window's frontend uses the same API. I decoded the service definitions
from the protobuf descriptors embedded in `SIMULATOR.so`. There is no server
reflection, and none is needed. `curl --http2-prior-knowledge` is a sufficient client,
so Python 3.9 with the standard library works; no grpcio.

Relevant RPCs (package `openxr_simulator.rpc.proto`):

| RPC | Shape | Use |
|---|---|---|
| `Input/SendKey` | **client-stream** of `SendKeyRequest{repeated KeyboardKey keys_down=1}`. Each message is the full set of keys held. | Hold and release simulator keybindings. |
| `Input/SetInputPluginSettings` | `InputPluginSettings{float movement_speed=1; bool use_body_locked_controller=2; bool left_controller_active=3; bool right_controller_active=4; bool headset_active=5; float dolly_scroll_speed=6}` | Choose which device the keys move, and the speed in m/s. |
| `Input/GetInputPluginSettings` | unary | Defaults are `{1.0, false, true, true, true, 10.0}`. |
| `InputPositioning/GetInputPositioning` | **server-stream** (~10 Hz) of head/left/right `PoseData{position, orientation (Euler°), velocities…}` | Closed-loop checks. |
| `Input/SendMouse`, `Input/SetBindings`/`GetBindings`, `Input/SetInputSource` | | Mouse, keybinding overrides, controller vs hands. |
| `DeviceService/SetRefreshRate`, `GetDeviceSettings`, `SetUserPresent` | unary | Test refresh-rate switching and headset-off pause. |
| `GraphicsService/GetFPS` | server-stream `{current,min,avg,avg10s,…}` | Simulator-side fps. |
| `SessionCapture/GotoRecord{recordPath}`, `GotoReplay{recordPath,replayPath}`, `GetState` | unary | Start record/replay without the UI (§6.2). |

Wire format: a gRPC frame is `0x00 + uint32 big-endian length + protobuf`. Minimal
client:

```python
import struct, subprocess
def frame(m: bytes) -> bytes: return b'\x00' + struct.pack('>I', len(m)) + m
def curl(port, method, *extra):
    return ['curl', '-s', '-N', '--http2-prior-knowledge', '-X', 'POST', '-H', 'content-type: application/grpc',
            '-H', 'te: trailers', *extra, f'http://[::1]:{port}/openxr_simulator.rpc.proto.{method}']
def unary(port, method, msg=b''):
    return subprocess.run(curl(port, method, '--data-binary', '@-'), input=frame(msg), capture_output=True).stdout
def settings(port, speed, left, right, head, dolly=10.0):
    unary(port, 'Input/SetInputPluginSettings', b'\x0d' + struct.pack('<f', speed)
          + bytes([0x10, 0, 0x18, left, 0x20, right, 0x28, head]) + b'\x35' + struct.pack('<f', dolly))
keys = subprocess.Popen(curl(port, 'Input/SendKey', '-T', '-'), stdin=subprocess.PIPE)   # keep open
def hold(*codes):                                   # KeyboardKey enum values; hold() = release all
    keys.stdin.write(frame(b''.join(b'\x08' + bytes([c]) for c in codes))); keys.stdin.flush()
```

`KeyboardKey` codes (from `sim_buttons.proto`): `A`=34 … `Z`=59 (so `D`=37, `E`=38,
`F`=39, `Q`=50, `R`=51, `S`=52, `W`=56), `LeftArrow`=1, `RightArrow`=2, `UpArrow`=3,
`DownArrow`=4, `Space`=12. The meaning comes from `keybindings.json`:

| Key | Action |
|---|---|
| R / F | MOVE_UP / MOVE_DOWN |
| W / S | forward / back |
| A / D | left / right |
| Q / E | TILT_LEFT / TILT_RIGHT (roll about the device's forward axis) |
| ↑ ↓ | pitch |
| ← → | yaw |
| B / N | A-X / B-Y |
| M | menu |
| T | trigger |
| U | grip |
| Y / H / G / J | thumbstick |
| Space | reset controller poses |

**Verified behaviour** (runs `artifacts/xr/run_20260925_201822*` and `…_203453*`, with
Godot `--xrdiag` agreeing with the simulator stream):

- With default settings, keys move **the headset and both controllers together** (the
  body).
- `settings(port, 3.0, 1, 1, 0)` (both controllers, headset frozen, 3 m/s) then F for
  0.4 s moved both hands 1.4 → 0.2 m; R for 0.4 s moved them back. That is a
  **two-wing downstroke and upstroke at 3 m/s with the head still**. Godot saw
  `left_hand y 1.4 → 0.2 → 1.43 → 0.23 → 1.47` over two flaps.
- `settings(port, 1.0, 1, 0, 0)` then Q for 0.3 s rolled **only the left controller**
  by −25° in place, at about 80°/s; E rolled it back. This is wing tilt. In an earlier
  run, holding Q for 0.6 s stopped at −30°, so there may be a roll limit.
  Use tilts ≤ 30° from neutral.
- Latency from SendKey to pose change is about 0.1–0.2 s, and the pose stream is about
  10 Hz. Drive strokes **closed-loop** (hold until `GetInputPositioning` reaches the
  target), not by sleep timing, and assert on Godot-side telemetry.
- **Caveats:**
  - Don't call `Input/SetActionInput`. In the one run that did, Godot's poses diverged
    from the simulator stream (no motion during the probe, then a phantom held R). If
    the in-engine poses and the stream disagree, restart the session.
  - `SetInputPluginSettings` **persists** to `persistent_data.json` (keys
    `movement_speed`, `dolly_scroll_speed`, `input_simulation.body_lock_controllers`,
    `action_input`). Restore `{1.0, false, true, true, true, 10.0}` at the end of every
    harness run. The probes for this research left `"dolly_scroll_speed": 0.0` in that
    file (default 10.0). Scroll-wheel dolly in the simulator UI stays disabled until it
    is restored.
  - One simulator session per machine: `tools/xr.sh` holds the lock.

**Suggested harness** (`vr` owns `tests/sim/`): `tools/xr.sh` starts the scene. A
sidecar Python driver waits for the log line, runs a named script, restores settings,
and exits. The scene asserts `PlayerBird.telemetry()` (e.g. `flapping > 0` and
`vertical_speed > 0` after a downstroke; `bank` sign after an opposite tilt) and writes
a PASS/FAIL line.

### 6.2 Session capture (record once, replay deterministically)

- The recorder hooks the app's `XrAction`s and records head and input motion into a
  `.vrs` file. Replay feeds the same motion every run
  ([Meta docs](https://developers.meta.com/horizon/documentation/native/xrsim-session-capture/)).
- Automatic replay: add to `persistent_data.json`:
  `"session_capture": {"delay_start_ms": 1000, "exec_state": "replay", "quit_buffer_ms": 5000, "quit_when_complete": true, "record_path": "/abs/rec.vrs", "replay_path": "/abs/replay.vrs"}`.
  Or call `SessionCapture/GotoRecord` / `GotoReplay` over SimRpc.
- Recordings are tied to our action names, so re-record if the action map changes.
- Good for "real hands" regression flights captured once, for example over data
  forwarding.
- **Unverified here.** Try it once the gRPC path is in place.

### 6.3 Other routes

- **Keyboard via the OS** (`osascript` / System Events): needs Accessibility
  permission and window focus. SimRpc `SendKey` does the same thing without either.
  Not recommended.
- **Data forwarding:** the XrSimDataForwardingServer APK on a USB-connected Quest
  streams real controller and head tracking into the simulator
  (`DataForwardingService/*`). Useful once the Quest Pro arrives, to feel flight on the
  Mac before building an APK.
- **In-process injection:** the simulator advertises `XR_EXT_conformance_automation`
  (set input device state and location), `XR_METAX2_simulator_head_pose` and
  `XR_METAX1_simulator_compositor_output_capture`, which could capture the actual
  compositor frames. None of these can be called from GDScript: they need a small C++
  GDExtension using `OpenXRAPIExtension.get_instance_proc_addr`. Only worth it if
  SimRpc proves flaky.
- **In-engine scripted poses** (ARCHITECTURE: swappable pose sources through the same
  `WingInput`) remain the primary, deterministic, headless test path. The simulator
  path proves the XR plumbing end to end: action map → `XRController3D`/tracker →
  WingInput → flight.

---

## 7. Open items for the device (Quest Pro)

- [ ] 72 vs 90 Hz headroom with FFR high + dynamic (OVR Metrics). Set the default.
- [ ] ETFR on/off A/B. Subsampled images on/off on the Pro.
- [ ] Touch Pro falls back to `oculus/touch_controller` bindings, and the left ≡ opens
      pause.
- [ ] Haptic pattern feel. The simple-haptics frequency is ignored.
- [ ] `VrApi` logcat lines present for Godot OpenXR apps. Stale-frame count at budget.
- [ ] `set_cpu_level`/`set_gpu_level(SUSTAINED_HIGH)` takes effect.

## Sources

- Godot 4.7.2 source (tag `4.7.2-stable`): `servers/xr/xr_pose.cpp`, `servers/xr/xr_server.cpp`,
  `scene/3d/xr/xr_nodes.cpp`, `modules/openxr/openxr_interface.cpp`, `modules/openxr/openxr_api.cpp`,
  `modules/openxr/extensions/openxr_fb_foveation_extension.cpp`, `modules/openxr/extensions/openxr_meta_controller_extension.cpp`,
  `servers/rendering/renderer_scene_cull.cpp`, `servers/rendering/renderer_rd/forward_mobile/render_forward_mobile.cpp`,
  `servers/rendering/renderer_rd/storage_rd/render_scene_buffers_rd.cpp`, `platform/android/export/export_plugin.cpp`,
  `platform/android/java/app/config.gradle`, `doc/classes/ProjectSettings.xml`, `modules/openxr/doc_classes/OpenXRInterface.xml`
- [Godot docs: OpenXR settings](https://docs.godotengine.org/en/stable/tutorials/xr/openxr_settings.html),
  [Setting up XR](https://docs.godotengine.org/en/stable/tutorials/xr/setting_up_xr.html),
  [Deploying to Android](https://docs.godotengine.org/en/stable/tutorials/xr/deploying_to_android.html),
  [A better XR start script](https://docs.godotengine.org/en/stable/tutorials/xr/a_better_xr_start_script.html),
  [XRNode3D](https://docs.godotengine.org/en/stable/classes/class_xrnode3d.html)
- Vendors plugin: [releases](https://github.com/GodotVR/godot_openxr_vendors/releases),
  [CHANGES.md](https://github.com/GodotVR/godot_openxr_vendors/blob/master/CHANGES.md),
  [docs](https://godotvr.github.io/godot_openxr_vendors/), [v5.1 announcement](https://godotengine.org/article/godot-xr-update-may-2026/),
  `plugin/src/main/cpp/export/meta_export_plugin.cpp` (5.1.0-stable)
- Godot issues/PRs: [#112988](https://github.com/godotengine/godot/issues/112988), [#112994](https://github.com/godotengine/godot/pull/112994),
  [#113778](https://github.com/godotengine/godot/issues/113778), [#116220](https://github.com/godotengine/godot/pull/116220),
  [#118902](https://github.com/godotengine/godot/issues/118902), [#123406](https://github.com/godotengine/godot/issues/123406)
- Meta: [performance targets](https://developers.meta.com/horizon/documentation/unity/unity-perf/),
  [draw-call cost](https://developers.meta.com/horizon/documentation/unity/po-draw-call-analysis/),
  [OpenXR haptics](https://developers.meta.com/horizon/documentation/native/android/mobile-openxr-haptic/),
  [ETFR blog](https://developers.meta.com/horizon/blog/save-gpu-with-eye-tracked-foveated-rendering/),
  [XR Simulator session capture](https://developers.meta.com/horizon/documentation/native/xrsim-session-capture/)
- [OpenXR spec: standard pose identifiers](https://github.com/KhronosGroup/OpenXR-Docs/blob/main/specification/sources/chapters/semantic_paths.adoc)
- [UploadVR: Quest Pro foveated rendering measurements](https://www.uploadvr.com/quest-pro-foveated-rendering-performance/),
  [Godot forum: standalone XR performance](https://forum.godotengine.org/t/performance-considerations-for-stand-alone-xr/52324)
- Local: `addons/godotopenxrvendors` (3.1.2 changelog, `strings` on the binary, AAR listing),
  `SIMULATOR.so` embedded protobuf descriptors (`sim_input.proto`, `sim_buttons.proto`,
  `sim_input_positioning.proto`, `sim_device.proto`, `sim_session_capture.proto`,
  `sim_graphics.proto`), simulator logs, and `artifacts/xr/run_2026092*_*.app.log`
