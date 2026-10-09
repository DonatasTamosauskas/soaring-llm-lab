using System;
using System.Collections;
using System.IO;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.UI;
namespace Soaring
{
    // Opt-in visual/input checks; no effect in normal players.
    public sealed class PresentationVerification : MonoBehaviour
    {
        GameSession game; string output;
        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
        static void Install()
        {
            if(Array.Exists(Environment.GetCommandLineArgs(),a=>a=="--verify-presentation"))new GameObject("Presentation verification").AddComponent<PresentationVerification>();
        }
        static void Require(bool condition,string name)
        {
            if(!condition)throw new InvalidOperationException("PRESENTATION_FAILED "+name);
            Debug.Log("PRESENTATION_PASS "+name);
        }
        IEnumerator Shot(string name)
        {
            yield return new WaitForSecondsRealtime(.35f); yield return new WaitForEndOfFrame();
            foreach(var text in game.ui.GetComponentsInChildren<Text>())
                if(!string.IsNullOrEmpty(text.text)) Require(text.cachedTextGenerator.vertexCount>4,"visible-glyphs "+name+" "+text.text.Split('\n')[0]);
            var image=ScreenCapture.CaptureScreenshotAsTexture();
            File.WriteAllBytes(Path.Combine(output,name+".png"),image.EncodeToPNG());Destroy(image);
        }
        IEnumerator Click(string label,int hand)
        {
            Require(game.ui.ExercisePointer(label,hand,false),"button-exists "+label);
            yield return null;
            Require(game.ui.ExercisePointer(label,hand,true),"curved-pointer "+hand+" "+label);
            yield return null;
        }
        IEnumerator Start()
        {
            var args=Environment.GetCommandLineArgs(); output=Path.GetFullPath(Path.Combine(Application.dataPath,"../../../../Logs/presentation"));
            for(int i=0;i<args.Length-1;i++)if(args[i]=="--evidence")output=args[i+1];
            Directory.CreateDirectory(output);SaveStore.RootOverride=Path.Combine(output,"UserData");
            game=FindAnyObjectByType<GameSession>();yield return new WaitUntil(()=>game.ready);yield return new WaitForSecondsRealtime(2);
            bool xr=game.input.xrRunning;
            if(!Array.Exists(args,a=>a=="-no-xr")){Require(xr,"xr-running");Require(game.input.tracking,"xr-tracked");}
            game.ui.ExercisePointer("Play",0,false);
            yield return Shot("01-menu");
            yield return Click("Settings",0);Require(game.ui.CurrentPage=="settings","left-controller-settings");yield return Shot("02-settings");
            yield return Click("Tracking & calibration",1);Require(game.ui.CurrentPage=="tracking","right-controller-tracking");yield return Shot("03-tracking");
            yield return Click("Back",1);yield return Click("Back",0);
            yield return Click("How to fly",1);Require(game.ui.CurrentPage=="help","illustrated-help");
            yield return Shot("04-help-flap");yield return Click("Speed",0);yield return Shot("05-help-speed");
            yield return Click("Back",1);
            game.StartRun();game.Pause();yield return Shot("06-pause");
            float holdUntil=Time.realtimeSinceStartup+.35f;
            game.ui.ExercisePointer("Restart · hold",0,false);
            while(Time.realtimeSinceStartup<holdUntil){game.ui.ExercisePointer("Restart · hold",0,true);yield return null;}
            yield return Shot("06a-hold-progress");
            game.ui.ExercisePointer("Restart · hold",0,false);Require(game.phase==GamePhase.Paused,"short-hold-keeps-run");
            holdUntil=Time.realtimeSinceStartup+1.1f;
            while(Time.realtimeSinceStartup<holdUntil&&game.phase==GamePhase.Paused){game.ui.ExercisePointer("Restart · hold",1,true);yield return null;}
            Require(game.phase==GamePhase.Flying,"completed-hold-restarts-once");game.Pause();
            game.ui.CalibrationPanel();yield return Shot("07-calibration");
            game.Menu();
            int textCount=0;
            foreach(var text in game.ui.GetComponentsInChildren<Text>())
            {
                if(string.IsNullOrEmpty(text.text))continue;
                Require(text.fontSize>=SoaringUI.BodyFontSize,"minimum-type-size "+text.text.Split('\n')[0]);textCount++;
            }
            Require(textCount>=6,"menu-text-loaded");
            var material=game.world.content.valleyPrefab.GetComponentInChildren<MeshRenderer>().sharedMaterial;
            Require(material.FindPass("ShadowCaster")>=0,"shadow-caster-shader");
            var renderers=game.world.GetComponentsInChildren<MeshRenderer>();int proxies=0,casters=0;
            foreach(var renderer in renderers){if(renderer.shadowCastingMode==ShadowCastingMode.ShadowsOnly)proxies++;if(renderer.shadowCastingMode==ShadowCastingMode.On)casters++;}
            Require(proxies>0&&casters>0,"source-shadow-proxies");
            if(!xr)yield return CheckRenderedShadows();
            File.WriteAllText(Path.Combine(output,"presentation.json"),"{\"sourceShadowProxies\":"+proxies+",\"sceneryCasters\":"+casters+",\"menuTextElements\":"+textCount+",\"xr\":"+xr.ToString().ToLowerInvariant()+"}");
            Debug.Log("SOARING_PRESENTATION_VERIFICATION_OK");Application.Quit(0);
        }
        IEnumerator CheckRenderedShadows()
        {
            game.ui.enabled=game.effects.enabled=game.ecosystem.enabled=game.player.enabled=false;
            foreach(var canvas in game.ui.GetComponentsInChildren<Canvas>(true))canvas.gameObject.SetActive(false);
            foreach(var line in game.ui.GetComponentsInChildren<LineRenderer>())line.enabled=false;
            foreach(var renderer in game.input.GetComponentsInChildren<MeshRenderer>())renderer.enabled=false;
            game.input.eye.enabled=false;
            var cam=new GameObject("Shadow check camera").AddComponent<Camera>();cam.tag="MainCamera";cam.fieldOfView=70;cam.nearClipPlane=.05f;cam.farClipPlane=3000;
            cam.transform.position=new(-212,7.5f,-31);cam.transform.LookAt(new Vector3(-60,5.5f,-29));
            var sun=RenderSettings.sun;sun.shadows=LightShadows.Hard;
            yield return new WaitForSecondsRealtime(.5f);yield return new WaitForEndOfFrame();
            var on=ScreenCapture.CaptureScreenshotAsTexture();File.WriteAllBytes(Path.Combine(output,"08-shadows-on.png"),on.EncodeToPNG());
            sun.shadows=LightShadows.None;yield return null;yield return null;yield return new WaitForEndOfFrame();
            var off=ScreenCapture.CaptureScreenshotAsTexture();File.WriteAllBytes(Path.Combine(output,"09-shadows-off.png"),off.EncodeToPNG());
            var dark=on.GetPixels32();var bright=off.GetPixels32();int shadowPixels=0;
            for(int i=0;i<dark.Length;i++)if((bright[i].r+bright[i].g+bright[i].b)-(dark[i].r+dark[i].g+dark[i].b)>30)shadowPixels++;
            Require(shadowPixels>dark.Length/1000,"rendered-sun-shadows pixels="+shadowPixels);
            Destroy(on);Destroy(off);sun.shadows=LightShadows.Hard;
            cam.transform.position=new(20,14,35);cam.transform.LookAt(new Vector3(110,0,-150));
            yield return new WaitForSecondsRealtime(.5f);yield return new WaitForEndOfFrame();
            on=ScreenCapture.CaptureScreenshotAsTexture();File.WriteAllBytes(Path.Combine(output,"10-water-shadows-on.png"),on.EncodeToPNG());
            sun.shadows=LightShadows.None;yield return null;yield return null;yield return new WaitForEndOfFrame();
            off=ScreenCapture.CaptureScreenshotAsTexture();File.WriteAllBytes(Path.Combine(output,"11-water-shadows-off.png"),off.EncodeToPNG());
            dark=on.GetPixels32();bright=off.GetPixels32();int waterPixels=0;
            for(int i=0;i<dark.Length;i++)
                if(bright[i].b>bright[i].r*1.25f&&bright[i].g>bright[i].r*1.15f&&(bright[i].r+bright[i].g+bright[i].b)-(dark[i].r+dark[i].g+dark[i].b)>30)waterPixels++;
            Require(waterPixels>10,"rendered-water-shadows pixels="+waterPixels);
            Destroy(on);Destroy(off);sun.shadows=LightShadows.Hard;
        }
    }
}
