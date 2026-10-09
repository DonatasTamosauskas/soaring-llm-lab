# Verification record

Date: 2 October 2026. Host: this Apple Silicon Mac.

| Check | Observed result |
|---|---|
| Unity CLI creates Universal 3D project | Passed, editor 6000.6.4f1, exit code 0 |
| Pinned Unity XR packages resolve and compile | Passed |
| Saved project/scene setup | Passed |
| OpenXR Standalone + Android validation | Passed, zero errors; optional Thin LTO recommendation after Quest profile activation |
| Mac ARM64 development build | Passed, zero errors; final incremental build one URP Metal warning, prior full shader rebuild three |
| Automatic Mac loader placement/signing | Passed on rebuilt app; `codesign --verify --deep --strict` exits 0 |
| Live simulator OpenXR session | Passed: `XRDisplaySubsystem.running` and `Meta XR Simulator 207.0.0` |
| Quest Pro profile | Visible in simulator UI |
| Quest Pro controller devices | Both left/right `Meta Quest Pro Touch Controller OpenXR` devices logged |
| Rendered scene | Welcome sign, table, three colored cubes and rays visible in simulator |
| Meta Quest platform/profile | Enabled in Unity Platform Browser; profile saved under Assets/Settings/Build Profiles |
| Android development APK | Passed, zero errors, two warnings; ARM64 IL2CPP libraries packaged |
| Final APK manifest | Minimum API 32, target API 36; VR launch category, required head tracking, Quest Pro (`cambria`) included |
| Android renderer selection | Only the intended `Mobile_RPAsset` included |
| Source-only bootstrap copy | Passed; pinned package manifest and native Quest profile preserved |

The first standalone launch failed to load its OpenXR loader. A copy of Unity's packaged loader at `Contents/Plugins/openxr_loader.dylib` fixed it. The checked-in build postprocessor applies this automatically, then ad-hoc signs the local Mac development app.

Source diagnostics marker:

```text
QUEST_BOOTSTRAP_XR_RUNNING loader=OpenXRLoader runtime=Meta XR Simulator version=207.0.0
QUEST_BOOTSTRAP_DEVICE Meta Quest Pro Touch Controller OpenXR ... Left
QUEST_BOOTSTRAP_DEVICE Meta Quest Pro Touch Controller OpenXR ... Right
```

Logs are under `Logs/`; generated executables are under `Builds/`. Neither is intended for source control. Controller pose discovery and rendering were verified; an end-to-end grab/teleport interaction and a physical Quest Pro session have not been verified.

The final Android build warnings are OpenXR's optional Thin LTO recommendation for non-development release builds, and URP's Vulkan `LightingPhysicallyBased` potentially uninitialized-variable warning. The APK is development-signed and has not been installed on a headset. Editor Play mode has not yet been verified; the native Mac player is the observed simulator client.
