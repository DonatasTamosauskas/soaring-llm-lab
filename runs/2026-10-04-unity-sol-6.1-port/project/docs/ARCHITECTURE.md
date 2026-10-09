# Unity architecture

`Soaring/Assets/Soaring/Scenes/Soaring.unity` is the only gameplay scene. It holds
one `XROrigin`, one OpenXR provider, the native valley prefab, and the systems
wired by `ProjectSetup`. The runtime is isolated in `Soaring.Runtime`; editor
import/build code and tests use separate assemblies.

`SizeRules` carries the original mass and wingspan ladder, log interpolation,
catch mass ratio, dust curve, growth conversion and metabolic scaling.
`FlightModel` integrates SI-unit aerodynamic lift, induced/profile drag,
gravity, wing-normal flap forces, recoverable stalls, coordinated turns, ground
effect and thin air under the ceiling. It is a new C# implementation of the
source model's relationships, rather than an execution of GDScript. The input
layer feeds the same `WingState` from XR tracking and desktop development input.
The model advances in substeps at 144 Hz or higher. `PlayerFlight` handles swept
spherical collision, sliding, perching, launch, water and bounds.

The body can bank/pitch; the camera rig receives only smooth yaw and translation.
The XROrigin is uniformly scaled by bird span divided by calibrated human
wingspan to implement the original world's perceived shrinkage. Tracking data and calibration stay in physical metres;
collision and AI stay in the original world metres. The neutral head offset is captured at spawn/recenter; subsequent physical
head movement remains intact. The near plane scales with the rig.
The comfort vignette is stereo-aware and drawn without camera texture copies.

`GameSession` owns lifecycle, deterministic contact ordering, growth, handling,
refuge protection, grace periods, lives, danger direction, tutorial, apex goal,
statistics and records. `Ecosystem` maintains a pooled population and budgeted
AI decisions. Birds hunt each other, flee predators, flock, hide in refuges,
rest at fitting perches, and soar thermals. Separate cheap moth clouds supply
slow early food; a visual-only starling cloud adds the original murmuration. The player enters their food rules.
Only periodically directed NPC attack passes pursue the player. There is no
per-frame spawning or per-bird MonoBehaviour. Visuals use species/LOD GPU
instancing and the original articulated bird animation ported to HLSL.

`SoaringUI` uses world-space uGUI panels with either controller's ray and trigger,
the original Nunito 700/900 faces, faceted plates, source bird/emblem art,
automatic calibration and animated gesture lessons. `CurvedUIEffect` bends
native uGUI vertices once when their content changes; it avoids the original
extra UI camera and render texture. Its analytic cylinder hit test uses the same
geometry as the rendered surface. Font rectangles reserve Nunito’s 1.364 em
line height so Unity does not truncate otherwise fitting glyphs. Body text is
60 layout pixels at a 1.5 m physical viewing distance. Gesture art is exported
from the source drawing routines into transparent 12-frame atlases; no AI artwork
or approximate replacement icons are used. The lower HUD keeps species, next
tier, log growth and lives visible. Lesson/status plates fade away from protected
flight paths, prey and threats; persistent lesson obstruction can mirror the card.
Celebrations wait up to five extra seconds while outside the view. Held restart,
menu and quit buttons fill an ink progress bar over the source’s 0.8 seconds.
A short release displays a hold hint and retains the run. Menu pointing
uses OpenXR aim poses; flight uses grip poses. Menu triggers read the same
Input System device actions as the aim drivers. Simultaneous triggers select
at most one page per frame. Startup waits for valid HMD tracking before placing
the menu, and the bootstrap explicitly shuts down its
XR loader. Gameplay pause
leaves XR tracking and menus alive. `FlightAudio` pools audio voices and preserves
licensed species calls and music. `FlightEffects` draws pooled feathers and
instanced prey/threat markers, tracked first-person feathered wings and thermal
pollen. `SaveStore` replaces JSON files atomically and handles missing/corrupt
files. Settings and record progress are saved at tier changes, pause and quit.

## Frozen art bridge

`tools/export-source.sh` runs Godot on a private copy under `.godot-export/`.
It exports generated meshes, colors, all four articulation channels, all three
bird LODs, collider shapes, spawn, perches, landmarks, refuges and thermals. It
reflects Z to Unity's coordinate convention. `SourceImporter` then creates
native Unity assets; no Godot runtime, glTF plugin or network assets are required.
The original 26,821 collider shapes are baked into 1,634 spatial mesh colliders with long triangles tessellated.
A 4 m raster of the original ground-height function supplies navigation heights
without treating roofs, branches, or arches as terrain. The source geometry
and metadata are frozen in a 34 MiB ZIP archive with a SHA-256 provenance record.
Convex hulls preserve their source points; thin rounded shapes use conservative
capsule tessellation. Repeated soft vegetation is merged in 48 m chunks.

## Quest rendering

URP Forward, linear color, single-pass stereo, Vulkan, ARM64 IL2CPP, 4x MSAA,
HDR/post-processing/depth/opaque copies off, one sun, spherical harmonics ambient
lighting and vertex-color materials. One directional sun uses hard shadows,
one cascade, a 2048 map, and a 90 m shadow distance with distance fade.
The export preserves Godot’s caster flags, including 142 lightweight shadow-only
tree renderers; grass, distant vegetation, clouds and water keep their source
noncasting behavior. The native valley and articulated bird shaders include
ShadowCaster passes and sample URP’s shadow attenuation. Bird casting uses the
same deformation routine as the visible mesh; distant bird LODs do not cast.
This is an initial mobile budget, not a measured Quest Pro performance result. The lake has a cheap opaque Fresnel/specular
shader that receives the same sun shadows, including bridge shadows. Distance LODs are retained. Foveation uses Unity's SRP API and fixed
foveation, without eye-tracking permissions. Quest starts at 28 active NPCs,
with a runtime governor reducing to 20 if sustained frame times exceed budget.
This is a target configuration; simulator performance does not prove headset
frame rate or visual improvement over the Godot build.

Unity/Meta setup derives from the supplied `vr-unity-example`; versions are
pinned by `Packages/manifest.json` and `packages-lock.json`. Package caches are
not edited. The Mac development player applies the observed OpenXR 1.18 loader
placement fix and an ad-hoc signature. Android uses the native Meta Quest profile.

CLI processes select their build target explicitly. Each build reapplies the
global baseline; the native Quest profile inherits those player settings while
retaining its shader optimizations. Imported legacy profile overrides are
cleared, and settings lookup handles the native platform switch.


Reference guidance: [Unity untethered XR rendering](https://docs.unity.com/en-us/engine/6000.6/manual/xr/graphics/untethered-device-optimization),
[URP shadow shader methods](https://docs.unity3d.com/6000.0/Documentation/Manual/urp/use-built-in-shader-methods-shadows.html),
[Meta XR Simulator setup](https://developers.meta.com/vr/documentation/native/xrsim-getting-started/).
