# Assets and third-party notices

The world, player wings, five bird models, icon, interface and synthesized audio are original procedural work in this repository. No itch.io assets, external textures, music or borrowed bird models are used.

The OpenXR action map and vendor-extension distribution were adapted/copied from the existing local `meta-demo` example for compatible controller bindings and Android packaging. Gameplay, world and UI code are new.

## Godot OpenXR Vendors 5.1.0

`addons/godotopenxrvendors/` contains the Godot XR Contributors' vendor extension, distributed under the MIT license. Original project: <https://github.com/GodotVR/godot_openxr_vendors>. Upstream license: <https://github.com/GodotVR/godot_openxr_vendors/blob/master/LICENSE>. `docs/licenses/GodotOpenXRVendors-MIT.txt` preserves its notice.

Vendor-specific licenses remain alongside the corresponding loaders:

- `addons/godotopenxrvendors/meta/LICENSE-LOADER`: Apache 2.0.
- `addons/godotopenxrvendors/meta/LICENSE-SDK`: Meta/Oculus SDK license notice.
- Other included vendors retain their own notices in their addon subdirectories. The Quest export enables the Meta plugin only.

Godot 4.7.2's runtime and Android export templates are MIT licensed and embed the engine's normal third-party notices. See <https://godotengine.org/license/>. Meta XR Simulator is a separately installed testing tool; it is not bundled in the game or APK.

The runtime RPC test client imports `grpcio` (Apache 2.0) and `protobuf` (BSD 3-Clause) into a separate development environment. They are not game dependencies and are not exported into the APK.
