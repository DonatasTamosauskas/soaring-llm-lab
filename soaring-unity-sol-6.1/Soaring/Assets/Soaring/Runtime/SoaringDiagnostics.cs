using System;
using System.Collections;
using System.IO;
using UnityEngine;
using Unity.Profiling;
namespace Soaring {
public sealed class SoaringDiagnostics:MonoBehaviour {
 ProfilerRecorder drawCalls,triangles;
 void Awake(){drawCalls=ProfilerRecorder.StartNew(ProfilerCategory.Render,"Draw Calls Count",1);triangles=ProfilerRecorder.StartNew(ProfilerCategory.Render,"Triangles Count",1);}
 void OnDestroy(){drawCalls.Dispose();triangles.Dispose();}
 float frameSum,frameMax;int frames;float reportAt;string captureDirectory;
 IEnumerator Capture(string name){if(string.IsNullOrEmpty(captureDirectory))yield break;yield return new WaitForEndOfFrame();ScreenCapture.CaptureScreenshot(Path.Combine(captureDirectory,name+".png"));yield return new WaitForSecondsRealtime(.4f);Debug.Log("SOARING_CAPTURE "+name);}
 IEnumerator Start(){yield return new WaitForSecondsRealtime(2);var session=GameSession.Instance;var p=session.Player;var ui=GetComponent<BirdUI>();Debug.Log("SOARING_READY birds="+session.World.Birds.Count+" slice="+session.World.SliceMode);var args=Environment.GetCommandLineArgs();int capture=Array.IndexOf(args,"--capture");if(capture>=0&&capture+1<args.Length){captureDirectory=args[capture+1];Directory.CreateDirectory(captureDirectory);}
  yield return Capture("01-home");if(Array.IndexOf(args,"--smoke")<0)yield break;
  Debug.Log("SOARING_SMOKE synthetic pose calibration; live XR remains active");ui.Show("tuning");yield return Capture("02-tuning");ui.Show("calibrateRelaxed");yield return Capture("03-calibration");
  // Explicit smoke mode injects two poses through the same calibration API. It never runs in ordinary play.
  p.LeftHand.localPosition=new Vector3(-.35f,1,.3f);p.RightHand.localPosition=new Vector3(.35f,1,.3f);p.CalibrateRelaxed();p.LeftHand.localPosition=new Vector3(-.8f,1.3f,.1f);p.RightHand.localPosition=new Vector3(.8f,1.3f,.1f);p.CalibrateExtended();session.StartRun();ui.Close();Debug.Log("SOARING_SMOKE calibrated="+p.IsCalibrated+" playing="+session.IsPlaying+" paused="+session.IsPaused+" birds="+session.World.Birds.Count);
  yield return new WaitForSecondsRealtime(1);yield return Capture("04-flight");
  p.enabled=false;var prey=session.World.Birds[0];Vector3 target=p.Position;prey.Respawn(.55f,target);float before=session.Mass;yield return null;yield return null;Debug.Log("SOARING_SMOKE catch="+session.Catches+" massIncreased="+(session.Mass>before));p.enabled=true;
  yield return new WaitForSecondsRealtime(3);Debug.Log("SOARING_ECOSYSTEM alive="+session.World.ActivePopulation+" hunters="+CountHunters()+" visibleBirdRenderers="+CountBirdRenderers()+" ai="+AiCounts());yield return Capture("05-growth");ui.Show("pause");Vector3 stopped=p.Position;float elapsed=session.Elapsed;yield return new WaitForSecondsRealtime(.3f);Debug.Log("SOARING_SMOKE pauseStable="+(Vector3.Distance(stopped,p.Position)<.01f&&Mathf.Abs(session.Elapsed-elapsed)<.01f));yield return Capture("06-pause");ui.Close();
  if(Array.IndexOf(args,"--verify-loop")>=0){float oldSafety=p.Tuning.safetySeconds;p.Tuning.safetySeconds=0;session.Kill("Smoke test hunter catch");yield return Capture("07-death");session.Restart();ui.Close();Debug.Log("SOARING_SMOKE restart="+(!session.IsDead&&session.Catches==0&&session.Mass==1));p.enabled=false;int attempts=0;while(session.Size<p.Tuning.apexSize&&attempts++<500)session.Catch(session.Size*.7f);Debug.Log("SOARING_SMOKE apexReachable="+(session.Size>=p.Tuning.apexSize)+" catches="+session.Catches);float oldAcceleration=p.Tuning.acceleration;float oldGravity=p.Tuning.gravity;float oldGlide=p.Tuning.glideLift;p.Tuning.acceleration=0;p.Tuning.gravity=0;p.Tuning.glideLift=0;p.model.Velocity=Vector3.zero;p.enabled=true;yield return new WaitForSecondsRealtime(2);yield return Capture("08-apex-scale");p.enabled=false;
  for(int i=0;i<Mathf.RoundToInt(p.Tuning.apexRingGoal);i++){var gate=session.World.NextApexPosition;var normal=i%3==1?Vector3.right:Vector3.forward;p.transform.position+=gate-normal*8-p.Position;yield return null;yield return null;p.transform.position+=gate+normal*8-p.Position;yield return null;yield return null;}yield return Capture("09-victory");p.Tuning.acceleration=oldAcceleration;p.Tuning.gravity=oldGravity;p.Tuning.glideLift=oldGlide;Debug.Log("SOARING_SMOKE victory="+session.HasWon);p.Tuning.safetySeconds=oldSafety;session.Restart();ui.Show("home");p.enabled=true;}
  Debug.Log("SOARING_SMOKE_DONE");
 }
 string AiCounts(){var counts=new System.Collections.Generic.Dictionary<string,int>();foreach(var b in GameSession.Instance.World.Birds){if(!counts.ContainsKey(b.AIState))counts[b.AIState]=0;counts[b.AIState]++;}string result="";foreach(var c in counts)result+=c.Key+":"+c.Value+",";return result;}
 int CountHunters(){int n=0;foreach(var bird in GameSession.Instance.World.Birds)if(bird.IsHuntingPlayer)n++;return n;}
 int CountBirdRenderers(){int n=0;foreach(var bird in GameSession.Instance.World.Birds)foreach(var r in bird.GetComponentsInChildren<Renderer>())if(r.enabled)n++;return n;}
 void Update(){float dt=Time.unscaledDeltaTime;if(dt<1){frameSum+=dt;frameMax=Mathf.Max(frameMax,dt);frames++;}if(Time.realtimeSinceStartup>reportAt+10){reportAt=Time.realtimeSinceStartup;Debug.Log("SOARING_TIMING meanMs="+(frames>0?frameSum/frames*1000:0).ToString("F2")+" maxMs="+(frameMax*1000).ToString("F2")+" frames="+frames+" draws="+(drawCalls.Valid?drawCalls.LastValue:-1)+" triangles="+(triangles.Valid?triangles.LastValue:-1));frames=0;frameSum=frameMax=0;}}
}
}
