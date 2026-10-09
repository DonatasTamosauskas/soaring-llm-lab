# Unity 6.6 / Meta Quest bootstrap findings

Investigated on 2 October 2026 on this Mac. This is a minimal VR baseline, with optional mixed reality and Meta services added according to each future project's needs.

## Environment and pinned stack

| Component | Observed / selected |
|---|---|
| Host CPU | Apple Silicon, arm64 |
| Unity editor | 6000.6.4f1, revision 12bfff696524 |
| Meta XR Simulator | 207.0, build 207.0.0.21.123 |
| Original template | Installed Universal 3D `com.unity.template.urp-blank-17.2.1.tgz` |
| URP | 17.6.0, as resolved by the Unity 6.6 template |
| Input System | 1.20.0 |
| XR Plug-in Management | 4.7.0 |
| OpenXR | 1.18.0 |
| Unity OpenXR Meta | 2.6.1 |
| XR Interaction Toolkit | 3.6.1, official Starter Assets imported |
| Android toolchain | Installed alongside this editor |

The template archive version is not the URP runtime package version. `Packages/manifest.json` pins direct dependencies and `packages-lock.json` records the resolved graph. Unity OpenXR Meta also installs AR Foundation and composition-layer dependencies; their presence does not enable passthrough in this VR scene.

## Recommended method for this baseline

Create Universal 3D with the editor's documented `-createProject` and `-cloneFromTemplate` arguments. Resolve pinned packages, then use a checked-in editor setup method with `-executeMethod` to save settings and a scene. This produces reviewable Unity assets rather than a list of UI steps. [Unity CLI reference](https://docs.unity.com/en-us/engine/6000.5/manual/unity-editor/command-line-arguments/editor)

Unity's current 6.6 documentation recommends OpenXR with Unity OpenXR Meta, and lists Quest Pro among supported devices. The Oculus provider is deprecated. XRI supplies a standard input/interaction rig; use one tracking rig and one provider. This example uses the Unity package stack. [Unity XR packages](https://docs.unity.com/en-us/engine/6000.6/manual/xr/support/support-packages)

Meta's own alternative uses URP, OpenXR and Meta XR Core SDK, then its Project Setup Tool and Building Blocks. Choose that route when an application specifically needs Meta SDK components. This example does not install all-in-one, identity, avatars, audio or interaction SDKs merely to render basic VR. Add selected Meta packages from the platform browser/official distribution and check their version compatibility. [Meta Unity setup](https://developers.meta.com/vr/documentation/unity/unity-project-setup/)

## Simulator integration

Use the installed **standalone** Meta XR Simulator. Its old Unity package is deprecated and unnecessary for OpenXR projects. On macOS, OpenXR 1.13+ is required. Device selection is available after an application connects; restart the client after changing device. [Meta simulator setup](https://developers.meta.com/vr/documentation/unity/unity-simulate-xrsim/)

Observed runtime manifest:

`/Applications/MetaXRSimulator.app/Contents/Resources/MetaXRSimulator/meta_openxr_simulator.json`

Its relative library path resolves to the adjacent `SIMULATOR.so`. The machine already has a global active-runtime symlink to this manifest. The launch scripts also set `XR_RUNTIME_JSON` and `XR_SELECTED_RUNTIME_JSON` for the launched process, making the dependency explicit without changing machine-wide state. Do not move/copy just the JSON away from its library.

The Mac player uses Metal and arm64. The Android build uses Vulkan and ARM64/IL2CPP. These are different executable targets using the same scene. Simulator 207 supports Metal on macOS and OpenXR API 1.0–1.1; a running window alone is insufficient evidence of a connected XR app. [Simulator requirements](https://developers.meta.com/vr/documentation/unity/xrsim-intro/)

Meta VR CLI 1.7+ can also query sessions/FPS, change profiles and manage runtimes. It was not on this shell's PATH, and installing it was unnecessary to create and launch the example through the installed Unity CLI. Prefer its official commands if future automation needs simulator control beyond application launch. [Meta CLI tools](https://developers.meta.com/vr/essentials/metavr-environment/)

## Device defaults and performance

Configured: OpenXR auto-init for Standalone and Android; Input System; single-pass instanced stereo; linear color; Android ARM64/IL2CPP; minimum Android API 32; automatic target API selection; Vulkan only on Android and Metal on Mac. Android enables Meta Quest Support and excludes original Quest 1. Touch, Touch Pro and Touch Plus interaction profiles are enabled on both targets.

Rendering baseline: the template's Mobile URP Forward renderer, 4x MSAA, HDR/post-processing off, no depth/opaque camera textures, no main-light shadows or additional per-pixel lights. This is a conservative starting point for this simple scene; profile actual workloads before choosing foveation, render scale, shadows or additional lights. [Unity untethered XR rendering](https://docs.unity.com/en-us/engine/6000.6/manual/xr/graphics/untethered-device-optimization)

Quest Pro support does not automatically enable eye/face tracking. Add an appropriate OpenXR feature and runtime capability checks only when needed. Eye tracking requires the manifest permission plus a user grant; retain controller fallback. This baseline requests neither eye nor face data. [Meta eye tracking](https://developers.meta.com/vr/documentation/native/android/move-eye-tracking/)

## Implementation findings

- The official XRI Starter Assets teleport interactor uses **interaction layer bit 31**. Assign the floor's `TeleportationArea` that same mask. Physics layers and XRI interaction layers are separate systems.
- Floor tracking avoids treating the initial camera height as a fixed headset height. The rig falls back according to XROrigin when the runtime lacks a floor origin.
- Some OpenXR 1.18 Meta validation predicates read `EditorUserBuildSettings.selectedBuildTargetGroup` even when passed another group. The setup temporarily selects the validated group and restores it. The Android build also selects Android around the BuildPipeline call, avoiding a null reference in the package's own pre-build validation.
- The Meta Quest platform must be enabled once in Unity's Platform Browser. The example includes its native build profile, including the Quest shader optimization settings. The profile initially copies its own PlayerSettings defaults; the CLI build synchronizes the selected baseline fields into those overrides before building.
- Enabling that platform also adds a global `Meta Quest (Build Profile)` quality level pointing to a package-default URP asset. The builder aligns every quality level with the mobile renderer. The final Android build includes only `Mobile_RPAsset`, avoiding the extra renderer and package-asset mutation warning observed in the first build.
- Unity 6.6 exposes some URP settings as read-only properties. Setup changes their serialized editor properties and saves the asset.
- Initial Unity execution inside the restricted tool sandbox could not open its service database. Running the installed editor with normal host access allowed licensing/package resolution. The checked-in scripts run as ordinary user commands.
- `setup` re-applies baseline project settings and preserves an existing scene; it corrects the example teleport floor mask. Run it deliberately when adopting the baseline, not automatically on every editor open.
- The example imports Unity's complete Starter Assets sample to preserve prefab/script dependencies. Its original package license is retained in `THIRD_PARTY_NOTICES.md`.

## Mac standalone loader workaround

Observed with OpenXR 1.18.0: the Mac build places `libopenxr_loader.dylib` in `Contents/Plugins/ARM64`, while the player requests `Contents/Plugins/openxr_loader.dylib`. Adding a byte-identical copy at the requested path allowed the same app to connect immediately. `MacOpenXRLoaderFix.cs` performs that step on Mac builds. It uses Unity's loader and leaves the package cache unchanged. Re-evaluate this workaround when upgrading Unity/OpenXR.

Both packaged loader paths failed `codesign --verify` on this host. The postprocessor ad-hoc signs the completed Mac app for local simulator development. This updates code signatures; it does not provide a production signing identity or notarization. Apply the application's distribution signing workflow after this development step if distributing a Mac build.

Disabling camera post-processing alone still caused URP to instantiate stripped post-process shaders in the development player. Setup also removes the unused Mobile renderer post-process data to keep this VR baseline free of those warnings.

## Verification

See `VERIFICATION.md` for observed outcomes. Logs and binaries are local generated artifacts under `Logs/` and `Builds/`. Runtime diagnostics explicitly check `XRDisplaySubsystem.running` and record the runtime and input devices.

Physical headset behavior, thermal/frame-time performance, permissions, passthrough and store submission requirements need device testing. Simulator frame rate and synthetic input cannot establish Quest Pro performance or tracking quality. For each release, validate with a physical target device, select current Android target API requirements and release signing, and test suspend/resume plus tracking loss.
