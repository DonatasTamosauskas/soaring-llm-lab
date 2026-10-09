using System;
using System.Collections;
using System.IO;
using UnityEngine;

namespace Soaring
{
    // Explicit CLI evidence mode. Does not run during ordinary play or XR.
    public sealed class ComparisonCapture : MonoBehaviour
    {
        [Serializable] public sealed class View
        {
            public string id, title;
            public float[] position, target, travel;
        }
        [Serializable] public sealed class Route
        {
            public int width, height, fps, secondsPerView;
            public float verticalFov, near, far;
            public View[] views;
        }
        [Serializable] sealed class Report
        {
            public string engine, renderer, mode;
            public int frameCount;
            public Route route;
        }
        static string Argument(string name)
        {
            var args = Environment.GetCommandLineArgs();
            for (int i = 0; i < args.Length - 1; i++)
                if (args[i] == name) return args[i + 1];
            return null;
        }
        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
        static void Install()
        {
            if (Argument("--comparison-route") != null)
                new GameObject("CLI comparison capture").AddComponent<ComparisonCapture>();
        }
        static Vector3 UnityVector(float[] v) => new(v[0], v[1], -v[2]);
        static void Save(string path)
        {
            var image = ScreenCapture.CaptureScreenshotAsTexture();
            try { File.WriteAllBytes(path, image.EncodeToPNG()); }
            finally { Destroy(image); }
        }
        IEnumerator Start()
        {
            var output = Path.GetFullPath(Argument("--comparison-output"));
            var frames = Path.GetFullPath(Argument("--comparison-frames"));
            SaveStore.RootOverride = Path.Combine(output, "UserData");
            var route = JsonUtility.FromJson<Route>(File.ReadAllText(Argument("--comparison-route")));
            Directory.CreateDirectory(output);
            Directory.CreateDirectory(frames);
            var game = FindAnyObjectByType<GameSession>();
            yield return new WaitUntil(() => game.ready);
            game.enabled = game.player.enabled = game.ecosystem.enabled = game.effects.enabled = game.ui.enabled = game.input.enabled = false;
            game.audio.enabled = false;
            AudioListener.volume = 0;
            foreach (var canvas in FindObjectsByType<Canvas>(FindObjectsInactive.Include)) canvas.gameObject.SetActive(false);
            foreach (var line in game.GetComponentsInChildren<LineRenderer>()) line.enabled = false;
            foreach (var mesh in game.GetComponentsInChildren<MeshRenderer>()) mesh.enabled = false;
            foreach (var cam in Camera.allCameras) { cam.enabled = false; cam.tag = "Untagged"; }
            var camera = new GameObject("Comparison camera").AddComponent<Camera>();
            camera.tag = "MainCamera";
            camera.fieldOfView = route.verticalFov;
            camera.nearClipPlane = route.near;
            camera.farClipPlane = route.far;
            camera.allowHDR = false;
            camera.allowMSAA = true;
            camera.clearFlags = CameraClearFlags.Skybox;
            Time.captureFramerate = route.fps;
            Application.targetFrameRate = -1;
            Cursor.visible = false;
            int frame = 0, count = route.fps * route.secondsPerView;
            foreach (var view in route.views)
            {
                camera.transform.position = UnityVector(view.position);
                camera.transform.LookAt(UnityVector(view.target));
                // Let native distance LOD decisions settle after each cut.
                for (int i = 0; i < 8; i++) yield return new WaitForEndOfFrame();
                Save(Path.Combine(output, view.id + ".png"));
                for (int i = 0; i < count; i++)
                {
                    camera.transform.position = UnityVector(view.position) + UnityVector(view.travel) * (i / (float)(count - 1) - .5f);
                    camera.transform.LookAt(UnityVector(view.target));
                    yield return new WaitForEndOfFrame();
                    Save(Path.Combine(frames, frame.ToString("D5") + ".png"));
                    frame++;
                }
                Debug.Log("COMPARISON_UNITY_VIEW_OK " + view.id);
            }
            File.WriteAllText(Path.Combine(output, "capture.json"), JsonUtility.ToJson(new Report {
                engine = Application.unityVersion, renderer = SystemInfo.graphicsDeviceType.ToString(), frameCount = frame, route = route,
                mode = "world only; no NPCs or HUD; native lighting and materials"
            }, true));
            Debug.Log("COMPARISON_UNITY_OK frames=" + frame);
            Application.Quit(0);
        }
    }
}
