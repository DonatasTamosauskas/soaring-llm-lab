# Quest Bootstrap example

A reusable Unity 6.6 VR baseline for Meta Quest 2, Quest Pro, Quest 3 and Quest 3S, with a native Apple Silicon Meta XR Simulator workflow.

## Start here

Unity project: `QuestBootstrap/`. Open it with Unity **6000.6.4f1**. The initial scene is `Assets/QuestBootstrap/Scenes/QuestExample.unity`.

From this directory, with the Unity project closed:

```bash
./scripts/unity.sh setup       # Apply settings; create scene only when absent
./scripts/unity.sh validate    # Settings report in Logs/validation.txt
./scripts/unity.sh play        # Open Unity and enter Play in the simulator
```

If Unity is already open, use **Quest Bootstrap > Play in Meta XR Simulator**. The menu sets the simulator runtime for the editor process. It does not change the global runtime. The simulator app should show the scene when its OpenXR session connects.

For a standalone simulator app, with the editor closed:

```bash
./scripts/unity.sh build-mac
./scripts/run-simulator.sh
```

Stop the app normally to end the session. Only run one simulator client at a time. For input controls, use the simulator's Inputs and Inputs binding panels; do not add Unity's XR Device Simulator to this scene.

## Example scene

The official XRI 3.6.1 Starter Assets XR Origin supplies controller poses, action bindings, near/far interaction, teleport, snap turn and controller visuals. The scene adds three physics grab cubes, a table, a teleport floor and a welcome sign. Tracking origin is Floor. Smooth movement is disabled in the example for comfort.

Grip grabs a cube. Controller thumbsticks operate teleporting and snap turning; the simulator's input bindings panel maps these to keyboard/mouse. Change the simulated Device to **Quest Pro**, then restart the application/Play mode to capture that profile.

The runtime logs `QUEST_BOOTSTRAP_XR_RUNNING` only after an XR display subsystem actually runs. `QUEST_BOOTSTRAP_XR_FAILED` indicates failure, even if a flat camera image is visible. Editor output is `Logs/play.log`; standalone output is `Logs/player.log`.

## Android headset build

This machine has Android Build Support, SDK, NDK and OpenJDK installed. With the editor closed:

```bash
./scripts/unity.sh profile         # Ensure the included Meta Quest profile exists
./scripts/unity.sh build-android   # Builds/QuestBootstrap.apk (development build)
```

For interactive development, select **File > Build Profiles > Meta Quest** and switch to that platform. The CLI Android builder uses the included Meta Quest profile and its configured OpenXR feature to produce a Quest-compatible APK. On a fresh editor installation, enable Meta Quest in the Platform Browser once if it is disabled. Simulator previews remain native macOS; the simulator does not execute the Android APK.

Deploy the APK with Meta Quest Developer Hub or `adb install -r Builds/QuestBootstrap.apk` after pairing a headset and enabling Developer Mode. Use a distinct application identifier before a real project is distributed; this example uses `com.example.questbootstrap` and default development signing. Store signing, entitlement checks and a Meta application ID are application-specific.

## Bootstrap another project

```bash
./scripts/bootstrap.sh /absolute/path/to/MyQuestExample
/absolute/path/to/MyQuestExample/scripts/unity.sh setup
/absolute/path/to/MyQuestExample/scripts/unity.sh play
```

The destination must not exist. This copies source assets, settings and pinned packages, with their `.meta` files, and omits Library, logs and build artifacts. Rename the product/application identifier for the new app. Commit `Assets`, `Packages` (including `packages-lock.json`) and `ProjectSettings`. Never commit `Library` or generated builds.

Scripts accept `UNITY_EDITOR` and `META_XR_SIMULATOR_JSON` path overrides. The pinned version in `ProjectVersion.txt` determines the default editor path. A running Unity editor locks its project; use the menu or close it before running batch commands.

See [FINDINGS.md](FINDINGS.md) for choices, sources, troubleshooting and verification limits.
