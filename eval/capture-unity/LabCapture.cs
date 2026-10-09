// Soaring LLM Lab: fixed-rate screen recorder for a macOS player build.
//
// tools/capture_unity.sh copies this file into a scratch copy of a run's Unity project
// (raw/_work/<run>/Soaring/Assets/LabCapture/); it is never part of an archived build.
// It does nothing unless the player is started with -labCapture <frames dir>.
//
//   -labCapture DIR   write DIR/frame_00000.jpg ... and DIR/capture.json
//   -labFrames N      frames to record (default 360 = 12 s)
//   -labFps F         game frames per second of recorded time (default 30)
//   -labMode M        "startup" (no input) or "gameplay" (adds the per-build LabDriver component)
//
// Time.captureFramerate fixes game time at 1/F s per frame, so the recording plays back at
// real speed however long each frame takes to render and save. Frames are read from the
// screen after rendering (ScreenCapture), so they include screen-space UI.
using System;
using System.Collections;
using System.IO;
using UnityEngine;

public sealed class LabCapture : MonoBehaviour
{
    /// <summary>Index of the frame being produced (frames saved so far).</summary>
    public static int Frame { get; private set; }
    /// <summary>Recorded seconds at the frame being produced.</summary>
    public static float Seconds => Frame / (float)Fps;
    public static int Fps { get; private set; } = 30;
    /// <summary>True once recording has begun. A driver may set Hold while it prepares.</summary>
    public static bool Recording { get; private set; }
    public static bool Hold;
    public static string Mode { get; private set; }

    [Serializable]
    sealed class Summary
    {
        public string unity, mode, graphics, firstError;
        public int frames, width, height, fps, errors, exceptions, heldFrames;
        public bool driver;
    }

    string directory;
    int total;
    readonly Summary summary = new Summary();

    public static string Arg(string name, string fallback = null)
    {
        var args = Environment.GetCommandLineArgs();
        for (int i = 0; i < args.Length - 1; i++)
            if (args[i] == name) return args[i + 1];
        return fallback;
    }

    [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
    static void Install()
    {
        if (Arg("-labCapture") == null) return;
        Fps = int.Parse(Arg("-labFps", "30"));
        Time.captureFramerate = Fps;
        Application.runInBackground = true;
        var go = new GameObject("LabCapture");
        DontDestroyOnLoad(go);
        go.AddComponent<LabCapture>();
    }

    void Awake()
    {
        directory = Path.GetFullPath(Arg("-labCapture"));
        total = int.Parse(Arg("-labFrames", "360"));
        Mode = Arg("-labMode", "startup");
        Directory.CreateDirectory(directory);
        Application.logMessageReceived += OnLog;
        if (Mode == "gameplay")
        {
            foreach (var assembly in AppDomain.CurrentDomain.GetAssemblies())
            {
                var type = assembly.GetType("LabDriver");
                if (type == null || !typeof(MonoBehaviour).IsAssignableFrom(type)) continue;
                gameObject.AddComponent(type);
                summary.driver = true;
                break;
            }
            if (!summary.driver) Debug.LogError("LAB_CAPTURE no LabDriver component in this build");
        }
    }

    IEnumerator Start()
    {
        // A driver can hold the recording while it gets the game into position (at most 20 s of game time).
        while (Hold && summary.heldFrames < Fps * 20)
        {
            summary.heldFrames++;
            yield return null;
        }
        Hold = false;
        Recording = true;
        Debug.Log($"LAB_CAPTURE_START mode={Mode} frames={total} fps={Fps} screen={Screen.width}x{Screen.height} held={summary.heldFrames}");
        while (Frame < total)
        {
            yield return new WaitForEndOfFrame();
            var image = ScreenCapture.CaptureScreenshotAsTexture();
            try
            {
                File.WriteAllBytes(Path.Combine(directory, $"frame_{Frame:D5}.jpg"), image.EncodeToJPG(95));
                summary.width = image.width;
                summary.height = image.height;
            }
            finally { Destroy(image); }
            Frame++;
            if (Frame % (Fps * 5) == 0) Debug.Log($"LAB_CAPTURE_FRAME {Frame}/{total}");
        }
        summary.unity = Application.unityVersion;
        summary.mode = Mode;
        summary.graphics = SystemInfo.graphicsDeviceType.ToString();
        summary.frames = Frame;
        summary.fps = Fps;
        File.WriteAllText(Path.Combine(directory, "capture.json"), JsonUtility.ToJson(summary, true));
        Debug.Log($"LAB_CAPTURE_DONE frames={Frame} errors={summary.errors} exceptions={summary.exceptions}");
        Application.Quit(0);
    }

    void OnLog(string message, string trace, LogType type)
    {
        if (type == LogType.Exception) summary.exceptions++;
        else if (type == LogType.Error || type == LogType.Assert) summary.errors++;
        else return;
        if (summary.firstError == null) summary.firstError = message.Length > 300 ? message.Substring(0, 300) : message;
    }

    void OnDestroy() => Application.logMessageReceived -= OnLog;
}
