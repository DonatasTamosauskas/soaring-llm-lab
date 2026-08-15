
#if UNITY_EDITOR
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.UI;
using Unity.XR.CoreUtils;
using UnityEngine.SceneManagement;

namespace Soaring.Editor
{
    public static class SoaringSceneSetup
    {
        [InitializeOnLoadMethod]
        static void AutoSetupOnLoad()
        {
            // Defer one frame to let editor finish compiling
            EditorApplication.delayCall += () =>
            {
                if (Object.FindFirstObjectByType<Soaring.Flight.BirdFlightController>() == null)
                {
                    Debug.Log("[Soaring] Auto-setup triggered (no BirdFlightController found). Running setup...");
                    Setup();
                }
            };
        }

        [MenuItem("Soaring/Setup Flight Scene (Bird Flight + World)")]
        public static void Setup()
        {
            var scene = SceneManager.GetActiveScene();
            Debug.Log($"[Soaring] Setup on scene {scene.name}");

            var origin = Object.FindFirstObjectByType<Unity.XR.CoreUtils.XROrigin>();
            if (!origin)
            {
                var prefab = AssetDatabase.LoadAssetAtPath<GameObject>("Assets/Samples/XR Interaction Toolkit/3.4.1/Starter Assets/Prefabs/XR Origin (XR Rig).prefab");
                if (prefab) { var go = (GameObject)PrefabUtility.InstantiatePrefab(prefab); go.name="XR Origin (XR Rig)"; origin = go.GetComponent<Unity.XR.CoreUtils.XROrigin>(); Debug.Log("[Soaring] Spawned XR Origin"); }
            }
            if (!origin) { Debug.LogError("[Soaring] No XR Origin found and prefab missing"); return; }

            foreach(var lp in Object.FindObjectsByType<UnityEngine.XR.Interaction.Toolkit.Locomotion.LocomotionProvider>(FindObjectsSortMode.None)) lp.enabled=false;
            foreach(var tp in Object.FindObjectsByType<UnityEngine.XR.Interaction.Toolkit.Locomotion.Teleportation.TeleportationProvider>(FindObjectsSortMode.None)) tp.enabled=false;

            Transform camOff = origin.transform.Find("Camera Offset");
            Transform leftCtrl = camOff ? camOff.Find("Left Controller") : null;
            Transform rightCtrl = camOff ? camOff.Find("Right Controller") : null;
            Transform head = origin.Camera ? origin.Camera.transform : camOff ? camOff.Find("Main Camera") : null;
            if (!head && Camera.main) head = Camera.main.transform;

            var flightRoot = origin.gameObject;
            var cc = flightRoot.GetComponent<CharacterController>();
            if (!cc) cc = flightRoot.AddComponent<CharacterController>();
            cc.radius = 0.35f; cc.height = 1.2f; cc.center = new Vector3(0, -0.6f, 0); cc.skinWidth = 0.06f;

            var tracker = flightRoot.GetComponent<Soaring.Flight.WingInputTracker>();
            if (!tracker) tracker = flightRoot.AddComponent<Soaring.Flight.WingInputTracker>();
            tracker.leftController = leftCtrl;
            tracker.rightController = rightCtrl;
            tracker.head = head;

            var flight = flightRoot.GetComponent<Soaring.Flight.BirdFlightController>();
            if (!flight) flight = flightRoot.AddComponent<Soaring.Flight.BirdFlightController>();
            flight.tracker = tracker; flight.head = head; flight.flightRoot = flightRoot.transform;

            var growth = flightRoot.GetComponent<Soaring.GameLoop.BirdGrowth>();
            if (!growth) growth = flightRoot.AddComponent<Soaring.GameLoop.BirdGrowth>();
            var trig = flightRoot.GetComponent<SphereCollider>();
            if (!trig) { trig = flightRoot.AddComponent<SphereCollider>(); trig.isTrigger=true; trig.radius=0.65f; trig.center=new Vector3(0,-0.2f,0); }
            flightRoot.tag = "Player"; 
            int birdLayer = LayerMask.NameToLayer("Bird");
            flightRoot.layer = birdLayer >=0 ? birdLayer : 0;

            var boot = flightRoot.GetComponent<Soaring.Flight.FlightBootstrap>();
            if (!boot) boot = flightRoot.AddComponent<Soaring.Flight.FlightBootstrap>();
            boot.startPosition = new Vector3(0, 18, 0);

            var wb_comp = flightRoot.GetComponent<Soaring.World.WorldBounds>();
            if (!wb_comp) wb_comp = flightRoot.AddComponent<Soaring.World.WorldBounds>();
            wb_comp.flight = flight; wb_comp.bootstrap = boot;

            var worldGO = GameObject.Find("World");
            if (!worldGO) worldGO = new GameObject("World");
            var wb = worldGO.GetComponent<Soaring.World.WorldBuilder>();
            if (!wb) wb = worldGO.AddComponent<Soaring.World.WorldBuilder>();
            wb.Generate();

            var bmGO = GameObject.Find("BirdManager");
            if (!bmGO) bmGO = new GameObject("BirdManager");
            var bm = bmGO.GetComponent<Soaring.GameLoop.BirdManager>();
            if (!bm) bm = bmGO.AddComponent<Soaring.GameLoop.BirdManager>();
            bm.worldBounds = new Bounds(Vector3.zero, new Vector3(wb.size.x, 90, wb.size.y));

            var hudGO = GameObject.Find("HUD");
            if (!hudGO)
            {
                hudGO = new GameObject("HUD");
                var canvas = hudGO.AddComponent<Canvas>(); canvas.renderMode=RenderMode.ScreenSpaceOverlay;
                hudGO.AddComponent<CanvasScaler>(); hudGO.AddComponent<GraphicRaycaster>();
                var hud = hudGO.AddComponent<Soaring.UI.HUD>(); hud.flight=flight; hud.growth=growth;

                var vignetteGO = new GameObject("Vignette");
                vignetteGO.transform.SetParent(hudGO.transform,false);
                var img = vignetteGO.AddComponent<UnityEngine.UI.Image>(); img.color=new Color(0,0,0,0); img.raycastTarget=false;
                var rt = img.rectTransform; rt.anchorMin=Vector2.zero; rt.anchorMax=Vector2.one; rt.offsetMin=Vector2.zero; rt.offsetMax=Vector2.zero;
                hud.vignette = img;

                System.Func<string,Vector2,TMPro.TextMeshProUGUI> mk = (name,anch)=>{
                    var go2=new GameObject(name); go2.transform.SetParent(hudGO.transform,false);
                    var t=go2.AddComponent<TMPro.TextMeshProUGUI>(); t.fontSize=28; t.color=Color.white; t.outlineWidth=0.18f; t.outlineColor=Color.black;
                    var r2=t.rectTransform; r2.anchorMin=anch; r2.anchorMax=anch; r2.anchoredPosition=Vector2.zero; r2.sizeDelta=new Vector2(600,50);
                    return t;
                };
                var sizeT = mk("SizeText", new Vector2(0,1)); sizeT.rectTransform.anchoredPosition=new Vector2(220,-40);
                var speedT = mk("SpeedText", new Vector2(0,1)); speedT.rectTransform.anchoredPosition=new Vector2(220,-78);
                var statusT = mk("StatusText", new Vector2(0.5f,0)); statusT.rectTransform.anchoredPosition=new Vector2(0,48); statusT.alignment=TMPro.TextAlignmentOptions.Center; statusT.fontSize=22;
                hud.sizeText=sizeT; hud.speedText=speedT; hud.statusText=statusT;
            }

            RenderSettings.fog = true; RenderSettings.fogMode=FogMode.ExponentialSquared; RenderSettings.fogDensity=0.008f; RenderSettings.fogColor=new Color(0.72f,0.82f,0.95f);
            RenderSettings.ambientMode=UnityEngine.Rendering.AmbientMode.Skybox;

            origin.transform.position = boot.startPosition;
            flight.ForceUnperch();

            EditorSceneManager.MarkSceneDirty(scene);
            AssetDatabase.SaveAssets();
            Debug.Log("[Soaring] Setup COMPLETE. Enter Play with Meta XR Simulator. Flap controllers DOWN to fly!");
        }

        [MenuItem("Soaring/Enable Meta XR Simulator")]
        public static void EnableSimulator()
        {
            Debug.Log("[Soaring] Ensure Meta XR Simulator is installed: Window > Package Manager > Meta XR Simulator, and XR Plug-in Management > OpenXR enabled with Meta Quest feature. For desktop testing, XR Device Simulator is auto-spawned.");
        }
    }
}
#endif
