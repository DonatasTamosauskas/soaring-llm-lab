// Soaring LLM Lab gameplay driver for 2026-10-02-unity-sol-6.1 (copied into the scratch copy as
// Assets/LabCapture/LabDriver.cs by tools/capture_unity.sh; LabCapture adds it in gameplay mode).
//
// With XR off this build runs its own desktop preview mode (BirdPlayer.DesktopMode), whose controls
// are documented in its README: Space flaps, A/D bank, E extends the wings, Shift tucks. This driver
// presses those keys on a timeline through a virtual Input System keyboard, so the flight goes
// through the build's own desktop input path and flight model.
//
// Before recording, it calibrates and starts a run the way the build's own showcase harness
// (SoaringShowcase.cs) does: relaxed hand pose -> CalibrateRelaxed(), extended pose ->
// CalibrateExtended(), then GameSession.StartRun() and BirdUI.Close(). The menu and calibration
// screens are what the start-up capture shows. The showcase harness itself is not used: it records a
// 60 s edited reel with teleported takes and accelerated growth, which the agent's own showcase.mp4
// already shows.
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.InputSystem.LowLevel;
using Soaring;

[DefaultExecutionOrder(-800)]
public sealed class LabDriver : MonoBehaviour
{
    Keyboard keyboard;
    GameSession session;
    BirdPlayer player;
    bool started;
    readonly List<Key> keys = new List<Key>();

    void Awake()
    {
        LabCapture.Hold = true;
        // Keep the virtual keyboard live if the player window loses focus.
        InputSystem.settings.backgroundBehavior = InputSettings.BackgroundBehavior.IgnoreFocus;
        keyboard = InputSystem.AddDevice<Keyboard>("LabKeyboard");
    }

    void Update()
    {
        if (!started) { TryStart(); return; }
        float t = LabCapture.Seconds;
        keys.Clear();
        // Tap rate: flaps per second. Two a second already climbs to the 150 m ceiling within 15 s,
        // so this flies on fewer taps to stay near the village and hills.
        float taps = 0;
        if (t >= 2 && t < 5) taps = 1;                                       // climb a little
        if (t >= 10 && t < 16) { keys.Add(Key.D); taps = 0.5f; }             // bank right
        if (t >= 20 && t < 26) { keys.Add(Key.A); taps = 0.5f; }             // bank left
        if (t >= 26 && t < 28) keys.Add(Key.LeftShift);                      // tuck and dive
        if (t >= 28 && t < 31) taps = 1;                                     // climb out
        if (t >= 31 && t < 32) keys.Add(Key.E);                              // spread wide to brake
        if (t >= 32) { keys.Add(Key.D); taps = 0.5f; }                       // gentle turn
        // A flap is one Space press, held for 3 frames.
        if (taps > 0 && (t * taps) % 1 < 0.1f * taps) keys.Add(Key.Space);
        InputSystem.QueueStateEvent(keyboard, new KeyboardState(keys.ToArray()));
        keyboard.MakeCurrent();
        if (Mathf.Abs(t % 5f) < Time.deltaTime)
            Debug.Log($"LAB_DRIVER t={t:F1} pos={player.Position} speed={player.Speed:F1} keys={string.Join("+", keys)} playing={session.IsPlaying} paused={session.IsPaused}");
    }

    void TryStart()
    {
        session = GameSession.Instance;
        if (session == null || session.Player == null || !session.Player.TrackingValid || session.World == null) return;
        player = session.Player;
        player.LeftHand.localPosition = new Vector3(-.35f, 1.05f, .35f);
        player.RightHand.localPosition = new Vector3(.35f, 1.05f, .35f);
        player.CalibrateRelaxed();
        player.LeftHand.localPosition = new Vector3(-.78f, 1.35f, .1f);
        player.RightHand.localPosition = new Vector3(.78f, 1.35f, .1f);
        player.CalibrateExtended();
        session.StartRun();
        var ui = FindAnyObjectByType<BirdUI>();
        if (ui) ui.Close();
        started = true;
        LabCapture.Hold = false;
        Debug.Log($"LAB_DRIVER calibrated={player.IsCalibrated} desktop={player.DesktopMode} playing={session.IsPlaying} paused={session.IsPaused} at {player.Position}");
    }
}
