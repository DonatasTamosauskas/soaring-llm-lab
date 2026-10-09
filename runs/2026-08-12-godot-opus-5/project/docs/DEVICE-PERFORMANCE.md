# Quest Pro: measured, and what to do about it

The v1 build runs on a Quest Pro. It boots, enters XR, tracks both controllers,
plays, and looks the way it looks on desktop. It is also **GPU-bound and missing
its frame budget**, and that is the one thing standing between this and a
comfortable session.

Everything below was measured on hardware (Quest Pro, Adreno 650, Forward
Mobile, 1440×1584 per eye, foveation level 3 dynamic) on build `8faa72b-150136`.

## The numbers

| | value |
|---|---|
| display refresh | 90 Hz |
| achieved | **61–65 fps** |
| app GPU time | **13.5–14.3 ms** (budget at 90 Hz is 11.1 ms) |
| GPU utilisation | **97–100%** |
| reprojected frames | **~30 per second** |
| draw calls | 49–63 |
| primitives | 88k–235k |
| world build on device | ~17 s |

Roughly a third of every second is being reprojected rather than rendered. In a
game about flying fast past close geometry, that judder is the worst thing you
can hand someone's inner ear.

## What to try, in order

1. **Drop the render target to ~0.9** — `OpenXRInterface.render_target_size_multiplier`.
   The scene is fragment-bound, so ~19% fewer pixels is close to ~19% less GPU,
   which is about what the gap needs. Resolution is the right lever here rather
   than MSAA: the art is flat-shaded with hard edges on thin spires and wires,
   and dropping MSAA in VR makes those crawl badly.
2. **Ask for 72 Hz** and hold it, rather than missing 90. A locked 72 is far
   more comfortable than a torn 90. See the caveat below — the refresh-rate list
   currently comes back empty, so this needs the vendor plugin first.
3. **Then re-measure**, and only then consider draw distance, shadow splits or
   cloud fill.

## Two things that block measuring it properly

**An unworn headset idles the app.** Left on a desk, HorizonOS logs
`ResolveUserPresence: change from Rendering to Idle` and the same scene drops to
`App=0.42 ms, GPU 17%` — a 33× difference that has nothing to do with the build.
Any performance number taken from a headset that nobody is wearing is worthless.
**Measure while wearing it.**

**Instrumenting from the host destabilised the game.** A runtime sweep that
cycled MSAA, shadows and draw distances (`PerfSweep`) was written for this and
then removed: it never advanced past its first configuration on device, and
carrying it in the tree made `tests/firstcontact.sh` hang reproducibly (4/4)
where the clean tree passes (3/3). The measurement tool was doing more damage
than the thing it measured. If it is rebuilt, it needs to be driven from inside
a worn session, not from adb.

## A real defect found on the way

`res://addons/godotopenxrvendors/plugin.gdextension` **fails to load on device**:

```
ERROR: Can't open GDExtension dynamic library:
       'res://addons/godotopenxrvendors/plugin.gdextension'
```

The library it points at, `.bin/android/template_debug/arm64/libgodotopenxrvendors.so`,
does not exist in this checkout — only the `.aar` files do — and the export
preset has `xr_features/enable_meta_plugin=false`, so the AAR is not packaged
either. `libgodotopenxrvendors.so` is absent from the APK; only
`libopenxr_loader.so` ships.

The consequence is concrete: `get_available_display_refresh_rates()` returns an
empty array, so the game cannot choose 72 Hz, and no Meta-specific OpenXR
extension is available. XR itself still works, because Godot's own loader
handles the session.

Fixing this means enabling the Meta vendor plugin in the export preset (and
therefore changing which OpenXR loader ships), which is not a change to make
without a headset on and time to test it.

## Not measured

- Anything with the headset actually worn. Every number here was taken in the
  seconds before HorizonOS idled the app.
- Haptics, comfort, and whether the flight gestures feel right in the hand.
  Nobody has flown this build.
- Whether the render-scale change above actually recovers the frame budget. It
  was written, then withdrawn unverified rather than shipped on a guess.
