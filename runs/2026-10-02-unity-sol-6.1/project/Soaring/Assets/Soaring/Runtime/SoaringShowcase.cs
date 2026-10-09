using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using UnityEngine;
using UnityEngine.Rendering.Universal;

namespace Soaring
{
    /// <summary>Opt-in footage harness. Curated takes use the game's flight model, scenery, AI and contacts.</summary>
    [DefaultExecutionOrder(-150)]
    public sealed class SoaringShowcase : MonoBehaviour
    {
        const int Fps = 30, Width = 1920, Height = 1080;
        const float Duration = 60;
        [Serializable] public sealed class Shot { public float start, end; public string name; public Shot(float a,float b,string n){start=a;end=b;name=n;} }
        [Serializable] public sealed class SoundEvent { public float time, gain; public string clip; }
        [Serializable] public sealed class Stats { public int contactCatches, finalCatches, crowns; public bool won; public string runtime = "Meta XR Simulator / scripted takes"; }
        [Serializable] public sealed class Manifest { public int fps=Fps,width=Width,height=Height,frames; public float duration; public Shot[] shots; public List<SoundEvent> events=new List<SoundEvent>(); public Stats stats=new Stats(); }
        readonly float[] cuts = {0,4,11,19,25,31,37,40,43,46,49,52,56,60};
        readonly string[] names = {"sanctuary","flight","chase","escape","windows","thermal","mid-growth","apex-growth","crown1","crown2","crown3","flightLab","outro"};
        GameSession session;
        BirdPlayer player;
        BirdUI ui;
        Camera camera;
        RenderTexture target, resolved;
        Texture2D pixels;
        string directory;
        Manifest manifest = new Manifest();
        int frame, take=-1, previousCatches;
        float scale=1, previousLeftY, previousRightY, lastFlap=-1;
        bool recording, loadingGrowth, victoryRecorded;

        IEnumerator Start()
        {
            var args=Environment.GetCommandLineArgs();int arg=Array.IndexOf(args,"--showcase");
            if(arg<0 || arg+1>=args.Length){enabled=false;yield break;}
            directory=Path.GetFullPath(args[arg+1]);Directory.CreateDirectory(directory);
            session=GameSession.Instance;player=session.Player;ui=GetComponent<BirdUI>();
            yield return new WaitForSecondsRealtime(2);
            float timeout=Time.realtimeSinceStartup+12;
            while(!player.TrackingValid && Time.realtimeSinceStartup<timeout)yield return null;
            if(!player.TrackingValid){Debug.LogError("SOARING_SHOWCASE_FAILED controller tracking missing");Application.Quit(1);yield break;}
            player.Tuning.ResetDefaults();player.Tuning.safetySeconds=1000;
            player.ComfortVignette=false;player.HapticsEnabled=false;
            player.LeftHand.localPosition=new Vector3(-.35f,1.15f,.45f);player.RightHand.localPosition=new Vector3(.35f,1.15f,.45f);player.CalibrateRelaxed();
            player.LeftHand.localPosition=new Vector3(-.78f,1.3f,.3f);player.RightHand.localPosition=new Vector3(.78f,1.3f,.3f);player.CalibrateExtended();
            session.StartRun();ui.Close();player.enabled=false;
            ExportAudio();session.Changed+=RecordSound;
            target=new RenderTexture(Width,Height,24,RenderTextureFormat.ARGB32){antiAliasing=4,name="Showcase four-sample render"};target.Create();
            resolved=new RenderTexture(Width,Height,0,RenderTextureFormat.ARGB32){name="Showcase resolved colour"};resolved.Create();
            pixels=new Texture2D(Width,Height,TextureFormat.RGB24,false);
            camera=new GameObject("Showcase mono capture camera").AddComponent<Camera>();
            camera.CopyFrom(player.Head.GetComponent<Camera>());camera.tag="Untagged";
            camera.stereoTargetEye=StereoTargetEyeMask.None;camera.targetTexture=target;camera.depth=100;
            camera.fieldOfView=65;camera.enabled=true;camera.GetUniversalAdditionalCameraData().allowXRRendering=false;
            manifest.shots=new Shot[names.Length];for(int i=0;i<names.Length;i++)manifest.shots[i]=new Shot(cuts[i],cuts[i+1],names[i]);
            Time.captureFramerate=Fps;recording=true;
            Debug.Log("SOARING_SHOWCASE_START 1920x1080 / 30fps / in-engine / scripted poses / curated NPC placement / accelerated progression");
            while(frame<Fps*Duration)
            {
                yield return new WaitForEndOfFrame();
                Graphics.Blit(target,resolved);var previous=RenderTexture.active;RenderTexture.active=resolved;
                pixels.ReadPixels(new Rect(0,0,Width,Height),0,0,false);pixels.Apply(false,false);RenderTexture.active=previous;
                File.WriteAllBytes(Path.Combine(directory,$"frame_{frame:D5}.png"),pixels.EncodeToPNG());
                frame++;
                if(frame%Fps==0)Debug.Log("SOARING_SHOWCASE_FRAME "+frame+" / "+Fps*Duration);
            }
            recording=false;manifest.frames=frame;manifest.duration=frame/(float)Fps;
            manifest.stats.finalCatches=session.Catches;manifest.stats.crowns=session.ApexRings;manifest.stats.won=session.HasWon;
            File.WriteAllText(Path.Combine(directory,"manifest.json"),JsonUtility.ToJson(manifest,true));
            Debug.Log("SOARING_SHOWCASE_DONE frames="+frame+" contacts="+manifest.stats.contactCatches+" crowns="+session.ApexRings+" won="+session.HasWon);
            Application.Quit(manifest.stats.contactCatches>0 && session.HasWon?0:1);
        }

        void Update()
        {
            if(!recording)return;
            float time=frame/(float)Fps;int next=0;while(next<names.Length-1 && time>=cuts[next+1])next++;
            if(next!=take){take=next;BeginTake();}
            float local=time-cuts[take];float bank=0,tuck=0,extension=0,flap=0,look=0;
            if(take==1){flap=local<.75f?.21f:0;extension=local>3 && local<3.65f?1:0;bank=local>4.5f?.6f:0;}
            if(take==2)
            {
                // Golden actors flee and the relative swept collision in BirdWorld earns every contact catch.
                if(frame%60==0 || local<1f/Fps){var bird=session.World.Birds[Mathf.FloorToInt(local/2)%4];bird.Respawn(.72f,player.Position+player.Head.forward*12-Vector3.up*1.4f);}
                tuck=.25f;
            }
            if(take==3){look=local<2?-22:0;bank=local>2?.8f:0;flap=local>2 && local<2.75f?.23f:0;tuck=local<2?.3f:0;}
            if(take==5)bank=1.4f;
            if(take==6)bank=.6f;
            if(take==7)bank=-.5f;
            if(take!=0 && take!=11 && take!=12 && !session.IsPaused)Fly(bank,tuck,extension,flap,look,local);
            if(take==0)
            {
                var from=new Vector3(-56,47,-82);var to=new Vector3(-38,43,-56);
                camera.transform.position=Vector3.Lerp(from,to,local/4);
                camera.transform.rotation=Quaternion.LookRotation(new Vector3(17,26,55)-camera.transform.position);
            }
            else if(take==12)
            {
                var from=new Vector3(14,92,-70);var to=new Vector3(30,100,-28);
                camera.transform.position=Vector3.Lerp(from,to,local/4);
                camera.transform.rotation=Quaternion.LookRotation(new Vector3(60,40,80)-camera.transform.position);
            }
            else {camera.transform.SetPositionAndRotation(player.Head.position,player.Head.rotation);}
        }

        void BeginTake()
        {
            Debug.Log("SOARING_SHOWCASE_TAKE "+names[take]);camera.fieldOfView=65;
            if(take==0){SetTake(new Vector3(0,24,-70),0);ShowCanvases(false);}
            if(take==1){ShowCanvases(true);SetTake(new Vector3(0,22,-70),0);}
            if(take==2)SetTake(new Vector3(0,31,-25),0);
            if(take==3)
            {
                SetTake(new Vector3(-5,28,-89),0);
                session.World.Birds[71].Respawn(5.6f,player.Position+new Vector3(-17,4,28));
            }
            if(take==4)SetTake(new Vector3(76,25.24f,29),0);
            if(take==5)SetTake(new Vector3(-45,27,80),0);
            if(take==6){GrowTo(2.2f);SetTake(new Vector3(-78,63,-10),60);}
            if(take==7){GrowTo(player.Tuning.apexSize);SetTake(new Vector3(-85,94,-65),42);}
            if(take>=8 && take<=10)
            {
                var normal=take==9?Vector3.right:Vector3.forward;
                SetTake(session.World.NextApexPosition-normal*44,take==9?90:0);
            }
            if(take==11){ui.Show("tuning");camera.fieldOfView=48;}
            if(take==12)ShowCanvases(false);
        }

        void SetTake(Vector3 position,float yaw)
        {
            player.Head.localPosition=new Vector3(0,1.6f,0);player.Head.localRotation=Quaternion.identity;
            player.transform.rotation=Quaternion.Euler(0,yaw,0);
            player.transform.position+=position-player.Position;
            player.model.Reset(yaw);player.model.Velocity=Quaternion.Euler(0,yaw,0)*Vector3.forward*player.Tuning.cruiseSpeed*FlightModel.SizeSpeed(session.Size,player.Tuning);
            previousLeftY=previousRightY=1.15f;
            typeof(BirdWorld).GetField("previousPlayer",BindingFlags.NonPublic|BindingFlags.Instance).SetValue(session.World,player.Position);
        }

        void Fly(float bank,float tuck,float extension,float flap,float look,float local)
        {
            float dt=1f/Fps;
            float span=Mathf.Lerp(.35f,.78f,extension)*(1-tuck*.7f);
            float stroke=flap*Mathf.Sin(local*Mathf.PI*2*1.5f);
            float leftY=1.15f+stroke+bank*.225f,rightY=1.15f+stroke-bank*.225f;
            player.Head.localRotation=Quaternion.Euler(0,look,0);
            player.LeftHand.localPosition=new Vector3(-span,leftY,.45f);player.RightHand.localPosition=new Vector3(span,rightY,.45f);
            player.LeftHand.localRotation=Quaternion.Euler(0,-15,-12);player.RightHand.localRotation=Quaternion.Euler(0,15,12);
            var sample=new WingSample{Valid=local>0,LeftDown=(previousLeftY-leftY)/dt,RightDown=(previousRightY-rightY)/dt,Extension=extension,Tuck=tuck,Bank=bank};
            previousLeftY=leftY;previousRightY=rightY;
            player.model.Step(sample,session.Size,session.World.UpdraftAt(player.Position),dt,player.Tuning);
            if(player.model.Flapped && frame/(float)Fps-lastFlap>.12f){AddSound("flap",.08f);lastFlap=frame/(float)Fps;}
            scale=Mathf.Lerp(scale,session.Size,1-Mathf.Exp(-dt*player.Tuning.growthSmoothing));
            var before=player.Position;player.transform.localScale=Vector3.one*scale;player.transform.position+=before-player.Position;
            before=player.Position;player.transform.rotation=Quaternion.Euler(0,player.model.Yaw,0);player.transform.position+=before-player.Position;
            var delta=player.model.Velocity*dt;float radius=.28f*scale;
            if(delta.sqrMagnitude>.00001f && Physics.SphereCast(player.Position,radius,delta.normalized,out var hit,delta.magnitude,~0,QueryTriggerInteraction.Ignore))
            {delta=delta.normalized*Mathf.Max(0,hit.distance-.05f);player.model.Velocity=Vector3.ProjectOnPlane(player.model.Velocity,hit.normal)*.7f;}
            player.transform.position+=delta;
            var bounded=session.World.Constrain(player.Position,radius);player.transform.position+=bounded-player.Position;
        }

        void GrowTo(float size)
        {
            loadingGrowth=true;int guard=0;
            while(session.Size<size && guard++<100)session.Catch(session.Size*.7f);
            loadingGrowth=false;AddSound("growth",.25f);
        }
        void ShowCanvases(bool visible){foreach(var canvas in UnityEngine.Object.FindObjectsByType<Canvas>())canvas.enabled=visible;}
        void RecordSound()
        {
            if(session.Catches>previousCatches && !loadingGrowth){manifest.stats.contactCatches+=session.Catches-previousCatches;AddSound("catch"+((session.Catches-1)%5),.4f);}
            if(session.HasWon && !victoryRecorded){AddSound("victory",.4f);victoryRecorded=true;}
            previousCatches=session.Catches;
        }
        void AddSound(string clip,float gain){manifest.events.Add(new SoundEvent{time=frame/(float)Fps,clip=clip,gain=gain});}
        void ExportAudio()
        {
            var audio=GetComponent<BirdAudio>();string folder=Path.Combine(directory,"audio");Directory.CreateDirectory(folder);
            foreach(var field in typeof(BirdAudio).GetFields(BindingFlags.NonPublic|BindingFlags.Instance))
            {
                var value=field.GetValue(audio);
                if(value is AudioClip clip)WriteWave(Path.Combine(folder,field.Name+".wav"),clip);
                if(value is AudioClip[] clips)for(int i=0;i<clips.Length;i++)WriteWave(Path.Combine(folder,"catch"+i+".wav"),clips[i]);
            }
        }
        static void WriteWave(string path,AudioClip clip)
        {
            var samples=new float[clip.samples*clip.channels];clip.GetData(samples,0);
            using(var writer=new BinaryWriter(File.Create(path)))
            {
                writer.Write(System.Text.Encoding.ASCII.GetBytes("RIFF"));writer.Write(36+samples.Length*2);writer.Write(System.Text.Encoding.ASCII.GetBytes("WAVEfmt "));
                writer.Write(16);writer.Write((short)1);writer.Write((short)clip.channels);writer.Write(clip.frequency);writer.Write(clip.frequency*clip.channels*2);writer.Write((short)(clip.channels*2));writer.Write((short)16);
                writer.Write(System.Text.Encoding.ASCII.GetBytes("data"));writer.Write(samples.Length*2);foreach(float sample in samples)writer.Write((short)(Mathf.Clamp(sample,-1,1)*32767));
            }
        }
        void OnDestroy()
        {
            if(session)session.Changed-=RecordSound;Time.captureFramerate=0;
            if(target){target.Release();Destroy(target);}if(resolved){resolved.Release();Destroy(resolved);}if(pixels)Destroy(pixels);
        }
    }
}
