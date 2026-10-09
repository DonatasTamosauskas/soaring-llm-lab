// Soaring LLM Lab gameplay driver for 2026-10-04-unity-sol-6.1-port (copied into the scratch copy as
// Assets/LabCapture/LabDriver.cs by tools/capture_unity.sh; LabCapture adds it in gameplay mode).
//
// The player runs with the build's own -no-xr desktop flag (set in the run's JSON). This driver uses
// the build's own input hook for its verification harness (RuntimeVerification.cs):
// VRInput.harnessOverride / harnessWings, which replace the sampled wing state each frame. Steering
// mirrors the build's desktop controls (VRInput.SampleDesktop: A/D roll, W/S pitch, Shift tucks).
// Flapping is a steady flap effort per wing: .445 in turns, the value the build's own verification
// harness and flight tests use for sustained flapping, and .7 while climbing, which by the build's VR
// mapping (VRInput.SampleXR) is a downstroke of about 2.3 m/s at the default reach. The desktop Space
// key's 1.8 Hz pulse averages about .27 and does not climb (a first take with it sank to the meadow
// within 15 s); a second take at .445 throughout climbed only 3 m before gliding down to skim the meadow. The flight goes
// through the real PlayerFlight and FlightModel. The run starts through GameSession.Play(), the menu's Play action,
// which on desktop starts the run directly; the bird begins perched and launches on the first flap.
// The hook also keeps the game from pausing if the window loses focus.
using UnityEngine;
using Soaring;

[DefaultExecutionOrder(-800)]
public sealed class LabDriver : MonoBehaviour
{
    GameSession game;
    bool started;

    void Awake() => LabCapture.Hold = true;

    void Update()
    {
        if (!started) { TryStart(); return; }
        float t = LabCapture.Seconds;
        float roll = 0, pitch = 0;
        bool flap = false, tuck = false, climb = false;
        if (t >= 1 && t < 10) flap = climb = true;                          // launch from the perch and climb
        if (t >= 13 && t < 19) { roll = .6f; flap = t % 2 < 1; }             // bank right (D), flapping on and off
        if (t >= 21 && t < 27) { roll = -.6f; flap = t % 2 < 1; }            // bank left (A)
        if (t >= 27 && t < 29) { tuck = true; pitch = -1; }                  // tuck and dive (Shift + W)
        if (t >= 29) { flap = climb = true; roll = t >= 32 ? .4f : 0; }     // climb out, gentle turn
        float effort = flap ? (climb ? .7f : .445f) : 0;
        var wings = new WingState
        {
            leftExtension = tuck ? .08f : 1,
            rightExtension = tuck ? .08f : 1,
            pitch = pitch,
            leftPitch = pitch + roll * .55f,
            rightPitch = pitch - roll * .55f,
            roll = roll,
            leftFlap = effort,
            rightFlap = effort,
            tuck = tuck,
            stretch = 1,
        };
        game.input.harnessWings = wings;
        if (Mathf.Abs(t % 5f) < Time.deltaTime)
            Debug.Log($"LAB_DRIVER t={t:F1} phase={game.phase} perched={game.player.perched} pos={game.player.model.position} airspeed={game.player.model.airspeed:F1}");
    }

    void TryStart()
    {
        game = FindAnyObjectByType<GameSession>();
        if (game == null || !game.ready) return;
        game.input.harnessOverride = true;
        game.input.harnessWings = WingState.Neutral;
        game.Play();
        started = true;
        LabCapture.Hold = false;
        Debug.Log($"LAB_DRIVER started phase={game.phase} perched={game.player.perched} xr={game.input.xrRunning}");
    }
}
