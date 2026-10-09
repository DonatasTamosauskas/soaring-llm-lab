// Soaring LLM Lab gameplay driver for 2026-08-11-unity-prime-muse-1.2 (copied into the scratch copy
// as Assets/LabCapture/LabDriver.cs by tools/capture_unity.sh; LabCapture adds it in gameplay mode).
//
// This build has no autopilot, showcase or desktop controls: its flight reads the world positions and
// rotations of the two controller transforms that WingInputTracker references (wing span, downstroke
// speed, height difference and roll for banking, controller pitch for diving). With XR off nothing
// moves them, so this driver poses them on a timeline, as arms would: flapping is a vertical
// up-and-down of both hands, banking raises one hand and rolls both, diving pitches both down.
// The head (main camera) is turned to look along the flight path, as a player would; this game steers
// thrust along the head's forward direction. The tracked-pose drivers on those three transforms are
// switched off so they cannot reset the poses. Nothing else in the game is touched.
using UnityEngine;
using Soaring.Flight;

[DefaultExecutionOrder(-900)] // before WingInputTracker and BirdFlightController read the poses
public sealed class LabDriver : MonoBehaviour
{
    WingInputTracker tracker;
    BirdFlightController flight;
    Transform left, right, head;
    float yaw;
    bool ready;

    // Timeline: (from s, flap amplitude m, bank -1..1 (+ = right hand up), pitch deg (+ = wings nose down)).
    // The world is a 220 m square. Each downstroke adds a lot of lift and gliding above ~9 m/s already
    // out-lifts gravity, so takes with steady flapping (pass 1) or a stroke every 3 s (pass 2) climbed
    // past 100 m into the haze, where the game resets the bird to its start. This take strokes once
    // every 6 s while circling, and the head looks 30 degrees down at the town, as a player flying high
    // would; the wings are pitched with the head so the game's wing-pitch input stays neutral.
    static readonly float[,] Steps =
    {
        { 0f, 0f, 0f, 0f },         // glide out from the start
        { 2f, 0.38f, 0f, 0f },      // flap
        { 4.5f, 0f, 0.5f, 0f },     // bank and circle (with a flap burst every 3 s)
        { 14f, 0f, 0f, 8f },        // level out, gentle descent
        { 17f, 0f, -0.5f, 0f },     // bank the other way (bursts every 3 s)
        { 26f, 0f, 0f, 25f },       // dive
        { 28.5f, 0.38f, 0f, -10f }, // pull up and flap
        { 31f, 0f, 0.5f, 0f },      // bank again
    };
    float amplitude;
    const float Look = 30f;

    void Start()
    {
        tracker = FindAnyObjectByType<WingInputTracker>();
        flight = FindAnyObjectByType<BirdFlightController>();
        if (!tracker || !flight || !tracker.leftController || !tracker.rightController || !tracker.head)
        {
            Debug.LogError("LAB_DRIVER wing tracker or its controller transforms not found");
            return;
        }
        left = tracker.leftController;
        right = tracker.rightController;
        head = tracker.head;
        foreach (var t in new[] { left, right, head })
            foreach (var b in t.GetComponents<Behaviour>())
                if (b.GetType().Name.Contains("TrackedPoseDriver")) { b.enabled = false; Debug.Log("LAB_DRIVER disabled " + b.GetType().Name + " on " + t.name); }
        yaw = head.eulerAngles.y;
        ready = true;
        Debug.Log($"LAB_DRIVER posing {left.name} / {right.name}, head {head.name}, rig at {flight.transform.position}");
    }

    void Update()
    {
        if (!ready) return;
        float t = LabCapture.Seconds;
        int i = 0;
        while (i + 1 < Steps.GetLength(0) && t >= Steps[i + 1, 0]) i++;
        float target = Steps[i, 1], bank = Steps[i, 2], pitch = Steps[i, 3];
        bool circling = Mathf.Abs(bank) > 0 && (i == 2 || i == 4 || i == 7);
        if (circling && (t - Steps[i, 0]) % 6f < 0.9f) target = 0.38f; // one stroke every 6 s
        // Ease the stroke size in and out so the hands never jump (a jump would read as a huge downstroke).
        amplitude = Mathf.Lerp(amplitude, target, 1 - Mathf.Exp(-8f * Time.deltaTime));

        // Look where you fly: ease the head's yaw toward the horizontal velocity.
        Vector3 v = flight.Velocity; v.y = 0;
        if (v.sqrMagnitude > 1f)
            yaw = Mathf.LerpAngle(yaw, Mathf.Atan2(v.x, v.z) * Mathf.Rad2Deg, 1 - Mathf.Exp(-2.5f * Time.deltaTime));
        head.rotation = Quaternion.Euler(Look, yaw, 0); // looking down at the town
        Quaternion body = Quaternion.Euler(0, yaw, 0);

        float stroke = amplitude * Mathf.Cos(2 * Mathf.PI * 1.15f * t); // falling half = downstroke
        float lift = bank * 0.2f;
        Vector3 shoulder = head.position + body * new Vector3(0, -0.35f, 0.15f);
        left.position = shoulder + body * new Vector3(-0.62f, stroke - lift, 0);
        right.position = shoulder + body * new Vector3(0.62f, stroke + lift, 0);
        // Wings level with the head, rolled with the bank and pitched for a dive.
        left.rotation = body * Quaternion.Euler(Look + pitch, 0, -bank * 25f);
        right.rotation = body * Quaternion.Euler(Look + pitch, 0, -bank * 25f);

        if (Mathf.Abs(t % 5f) < Time.deltaTime)
            Debug.Log($"LAB_DRIVER t={t:F1} pos={flight.transform.position} speed={flight.Speed:F1} bank={tracker.BankInput:F2} pitch={tracker.PitchInput:F2} eff={tracker.WingEfficiency:F2}");
    }
}
