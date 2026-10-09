# Soaring visual comparison

Open [index.html](index.html) for the wipe slider, recordings, and screenshots.

Captured on 4 October 2026 on the local Apple M1 Pro Mac. Godot 4.7.2 and Unity 6000.6.4f1 (Unity 6.6). All capture helpers, private Godot-copy changes, and output stay under `unity/`.

## Deliverables

- `side-by-side-tour.mp4`: 20 seconds, 30 fps, 2560 × 816; two original 1280 × 720 views with captions outside the captured rectangles.
- `godot-tour.mp4`, `unity-tour.mp4`: each engine’s 20-second 1280 × 720 recording.
- Five world comparison PNGs: overview, village, forest, lake, canyon. Each 2592 × 846; the two native images remain at original resolution.
- `menu-comparison.png`, `flight-comparison.png`: native menu and first-flight HUD views.
- `world-contact-sheet.jpg`: compact overview of the five world comparisons.
- `raw/{godot,unity}/`: original screenshot PNGs and capture metadata.
- `verification.json`: SHA-256 hashes and successful pixel-preservation checks for the paired screenshots.

## Visual revision

The current Unity captures include the restored sun shadows and UI. The earlier
comparison is retained in [first-pass/index.html](first-pass/index.html).
The world cameras and original Godot footage are unchanged; Unity’s world tour
and native UI shots were recaptured from the revised player.

The scene uses one hard-shadow sun, a 2048 map, one cascade and 90 m shadow
range. It imports the source’s lightweight tree casters and casting flags;
near bird LODs use their animated geometry for shadows. Distant scenery remains
outside this initial shadow budget.

The interface restores Nunito, the original emblem and species icons, animated
gesture artwork, curved plates, growth/lives, lesson progress and hold feedback.
The additional `presentation/` captures show settings, help, calibration, held
restart and the same village with shadows enabled/disabled. The player harness
checks both pointer paths, rendered glyphs, short/complete holds and visible
shadow pixels. The pointers are synthetic inputs to the same hit/action logic;
physical controller interaction still requires a headset playtest.

## Method and limits

World cameras use the shared `tools/comparison-route.json`: seed 1 valley, same position and target, 70° vertical FOV, 0.05–3000 m clipping, 1280 × 720, 4× MSAA. Godot coordinates are reflected on Z for Unity, matching the mesh port. Each tour chapter applies the same linear camera translation about the static screenshot position. There are 120 saved frames per chapter and 600 per engine. Eight settling frames and the static screenshot frame are excluded from the movie.

The world harness renders the existing scenery with each engine’s current lighting, fog, sky, vegetation LOD, water and ambient decoration. NPCs and HUD are excluded so a different AI population cannot obscure geometry. The Unity harness disables game input and flight after startup; ordinary gameplay is unaffected unless `--comparison-route` is explicitly supplied. The Unity player retains its development-build watermark.

Godot uses Forward+ on Vulkan/MoltenVK; Unity uses the project’s mobile URP asset on Metal. The original `scripts/core/capture.gd` specifically recommends Forward+ for Mac captures because Mobile/MoltenVK produces magenta tiles locally. **These images do not compare Android GPU output or measure Quest Pro performance.** They show the currently implemented visual differences; no claim of superior image quality follows from changing engines alone.

The UI shots run the actual main scenes and existing integration/verification harnesses. Both cameras now use 90° vertical FOV. Godot’s harness explicitly selects VR panel mode with synthetic controller pointers and XR disabled. Unity’s desktop capture uses its curved VR panels with desktop instruction text. Their spawn views and input paths differ. Godot’s bot flies an orbit over the village; Unity’s synthetic wing input launches above its spawn. UI captures therefore compare layouts and readable game states, not matched movement or controller tracking. The Unity verification sequence also forces catches, tier changes, and victory after the saved first-flight image.

Video timing comes from saved frame sequences, not real-time screen recording. Godot uses `--fixed-fps 30`; Unity sets `Time.captureFramerate = 30` during the tour. Movies are silent H.264/yuv420p encodes. No color grading, sharpening, retouching, or image overlays are applied within the screenshot rectangles. The JPEG contact sheet is resized for browsing; raw PNGs preserve native pixels.

Godot reports a pipeline-cache write diagnostic during first warmup and an ObjectDB cleanup warning on shutdown; all requested frames and screenshots were saved and the process exited successfully. See the capture logs for the unfiltered diagnostics.

## Reproduce

Run from the repository root. `export-source.sh` creates the private Godot copy if it does not already exist. It also regenerates frozen source assets, so normally retain the existing copy for recaptures.

```sh
unity/tools/unity.sh build-mac
unity/tools/capture-godot.sh
unity/tools/capture-unity.sh
/Users/don/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 unity/tools/compose-comparison.py
```

The compositor needs Pillow, ffmpeg with libx264/drawtext, and macOS Avenir Next. The bundled workspace Python supplies Pillow on this machine. Frame sequences and logs are retained in ignored `unity/Logs/comparison/`. Captures time out after bounded intervals and terminate automatically.

For a browser served over HTTP:

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory unity/docs/comparison
```

Then open `http://localhost:8765`. The viewer also works as a local HTML file; it has no external dependencies.
