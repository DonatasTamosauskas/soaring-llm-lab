
using UnityEngine;
using UnityEngine.SceneManagement;

namespace Soaring
{
    public static class RuntimeInitializer
    {
        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
        static void OnSceneLoaded()
        {
            // If flight exists, nothing
            if (Object.FindAnyObjectByType<Flight.BirdFlightController>() != null) return;
            Debug.Log("[Soaring] RuntimeInitializer: Detected missing flight setup, injecting into current scene...");
            // Find XR Origin or create
            var origin = Object.FindAnyObjectByType<Unity.XR.CoreUtils.XROrigin>();
            if (!origin)
            {
                Debug.LogWarning("[Soaring] No XROrigin found, spawning from prefab via Resources (fallback). Create manually via Soaring menu in editor.");
                // Create minimal XROrigin stub (camera offset + camera)
                var go = new GameObject("XR Origin (Runtime)");
                origin = go.AddComponent<Unity.XR.CoreUtils.XROrigin>();
                var camOff = new GameObject("Camera Offset").transform; camOff.SetParent(go.transform);
                var camHolder = new GameObject("Main Camera").transform; camHolder.SetParent(camOff);
                var cam = camHolder.gameObject.AddComponent<Camera>(); cam.tag="MainCamera";
                origin.Camera = cam;
                origin.CameraFloorOffsetObject = camOff.gameObject;
                // Add controller transforms as empty holders (XR simulator will drive)
                var left = new GameObject("Left Controller").transform; left.SetParent(camOff);
                left.localPosition = new Vector3(-0.25f, -0.15f, 0.3f);
                var right = new GameObject("Right Controller").transform; right.SetParent(camOff);
                right.localPosition = new Vector3(0.25f, -0.15f, 0.3f);
                go.transform.position = new Vector3(0,18,0);
            }

            // Ensure CharacterController etc via Bootstrap
            var flightRoot = origin.gameObject;
            if (!flightRoot.GetComponent<Soaring.Flight.FlightBootstrap>())
                flightRoot.AddComponent<Soaring.Flight.FlightBootstrap>();
            // Add WingInputTracker
            var tracker = flightRoot.GetComponent<Soaring.Flight.WingInputTracker>();
            if (!tracker) tracker = flightRoot.AddComponent<Soaring.Flight.WingInputTracker>();
            var camOff2 = origin.transform.Find("Camera Offset");
            if (camOff2)
            {
                tracker.leftController = camOff2.Find("Left Controller");
                tracker.rightController = camOff2.Find("Right Controller");
                if (!tracker.head) tracker.head = origin.Camera.transform;
            }
            if (!tracker.head && Camera.main) tracker.head = Camera.main.transform;

            var flight = flightRoot.GetComponent<Soaring.Flight.BirdFlightController>();
            if (!flight) flight = flightRoot.AddComponent<Soaring.Flight.BirdFlightController>();
            flight.tracker = tracker; flight.head = tracker.head; flight.flightRoot = flightRoot.transform;

            if (!flightRoot.GetComponent<CharacterController>())
            {
                var cc = flightRoot.AddComponent<CharacterController>();
                cc.radius=0.35f; cc.height=1.2f; cc.center=new Vector3(0,-0.6f,0); cc.skinWidth=0.06f;
            }
            var growth = flightRoot.GetComponent<Soaring.GameLoop.BirdGrowth>();
            if (!growth) growth = flightRoot.AddComponent<Soaring.GameLoop.BirdGrowth>();
            if (!flightRoot.GetComponent<SphereCollider>())
            {
                var trig = flightRoot.AddComponent<SphereCollider>(); trig.isTrigger=true; trig.radius=0.65f; trig.center=new Vector3(0,-0.2f,0);
            }
            flightRoot.tag="Player";
            int birdLayer = UnityEngine.LayerMask.NameToLayer("Bird");
            if (birdLayer>=0) flightRoot.layer=birdLayer;

            if (!flightRoot.GetComponent<Soaring.World.WorldBounds>())
            {
                var wb = flightRoot.AddComponent<Soaring.World.WorldBounds>();
                wb.flight = flight;
                wb.bootstrap = flightRoot.GetComponent<Soaring.Flight.FlightBootstrap>();
            }

            // World
            var worldGO = GameObject.Find("World");
            if (!worldGO) { worldGO=new GameObject("World"); var wb2=worldGO.AddComponent<Soaring.World.WorldBuilder>(); wb2.Generate(); }
            else if (!worldGO.GetComponent<Soaring.World.WorldBuilder>())
                worldGO.AddComponent<Soaring.World.WorldBuilder>().Generate();

            var bmGO = GameObject.Find("BirdManager");
            if (!bmGO) bmGO=new GameObject("BirdManager");
            if (!bmGO.GetComponent<Soaring.GameLoop.BirdManager>())
            {
                var bm=bmGO.AddComponent<Soaring.GameLoop.BirdManager>();
                var wbRef=Object.FindAnyObjectByType<Soaring.World.WorldBuilder>();
                if (wbRef) bm.worldBounds = new Bounds(Vector3.zero, new Vector3(wbRef.size.x,90,wbRef.size.y));
            }

            // HUD
            if (!GameObject.Find("HUD"))
            {
                var hudGO=new GameObject("HUD");
                var canvas=hudGO.AddComponent<Canvas>(); canvas.renderMode=RenderMode.ScreenSpaceOverlay;
                hudGO.AddComponent<UnityEngine.UI.CanvasScaler>(); hudGO.AddComponent<UnityEngine.UI.GraphicRaycaster>();
                var hud=hudGO.AddComponent<Soaring.UI.HUD>(); hud.flight=flight; hud.growth=growth;
                var vignetteGO=new GameObject("Vignette"); vignetteGO.transform.SetParent(hudGO.transform,false);
                var img=vignetteGO.AddComponent<UnityEngine.UI.Image>(); img.color=new Color(0,0,0,0); img.raycastTarget=false;
                var rt=img.rectTransform; rt.anchorMin=Vector2.zero; rt.anchorMax=Vector2.one; rt.offsetMin=Vector2.zero; rt.offsetMax=Vector2.zero;
                hud.vignette=img;
                // Texts
                System.Func<string,Vector2,TMPro.TextMeshProUGUI> mk = (name,anch)=>{
                    var go2=new GameObject(name); go2.transform.SetParent(hudGO.transform,false);
                    var t=go2.AddComponent<TMPro.TextMeshProUGUI>(); t.fontSize=28; t.color=Color.white; t.outlineWidth=0.18f; t.outlineColor=Color.black;
                    var r2=t.rectTransform; r2.anchorMin=anch; r2.anchorMax=anch; r2.anchoredPosition=Vector2.zero; r2.sizeDelta=new Vector2(600,50);
                    return t;
                };
                var sizeT=mk("SizeText", new Vector2(0,1)); sizeT.rectTransform.anchoredPosition=new Vector2(220,-40);
                var speedT=mk("SpeedText", new Vector2(0,1)); speedT.rectTransform.anchoredPosition=new Vector2(220,-78);
                var statusT=mk("StatusText", new Vector2(0.5f,0)); statusT.rectTransform.anchoredPosition=new Vector2(0,48); statusT.alignment=TMPro.TextAlignmentOptions.Center; statusT.fontSize=22;
                hud.sizeText=sizeT; hud.speedText=speedT; hud.statusText=statusT;
            }

            // Fog
            UnityEngine.RenderSettings.fog=true; UnityEngine.RenderSettings.fogMode=FogMode.ExponentialSquared; UnityEngine.RenderSettings.fogDensity=0.008f; UnityEngine.RenderSettings.fogColor=new Color(0.72f,0.82f,0.95f);
            flight.ForceUnperch();
            Debug.Log("[Soaring] RuntimeInitializer injection COMPLETE. Flap to fly! Bank to turn.");
        }
    }
}
