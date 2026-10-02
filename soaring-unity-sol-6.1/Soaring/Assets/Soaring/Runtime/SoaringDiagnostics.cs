using System;
using System.Collections;
using System.IO;
using UnityEngine;
namespace Soaring {
public sealed class SoaringDiagnostics:MonoBehaviour {
 float frameSum,frameMax;int frames;float reportAt;string captureDirectory;
 IEnumerator Capture(string name){if(string.IsNullOrEmpty(captureDirectory))yield break;yield return new WaitForEndOfFrame();ScreenCapture.CaptureScreenshot(Path.Combine(captureDirectory,name+".png"));yield return new WaitForSecondsRealtime(.4f);Debug.Log("SOARING_CAPTURE "+name);}
 IEnumerator Start(){yield return new WaitForSecondsRealtime(2);var session=GameSession.Instance;var p=session.Player;var ui=GetComponent<BirdUI>();Debug.Log("SOARING_READY birds="+session.World.Birds.Count+" slice="+session.World.SliceMode);var args=Environment.GetCommandLineArgs();int capture=Array.IndexOf(args,"--capture");if(capture>=0&&capture+1<args.Length){captureDirectory=args[capture+1];Directory.CreateDirectory(captureDirectory);}
  yield return Capture("01-home");if(Array.IndexOf(args,"--smoke")<0)yield break;
  Debug.Log("SOARING_SMOKE synthetic pose calibration; live XR remains active");ui.Show("tuning");yield return Capture("02-tuning");ui.Show("calibrateRelaxed");yield return Capture("03-calibration");
  // Explicit smoke mode injects two poses through the same calibration API. It never runs in ordinary play.
  p.LeftHand.localPosition=new Vector3(-.35f,1,.3f);p.RightHand.localPosition=new Vector3(.35f,1,.3f);p.CalibrateRelaxed();p.LeftHand.localPosition=new Vector3(-.8f,1.3f,.1f);p.RightHand.localPosition=new Vector3(.8f,1.3f,.1f);p.CalibrateExtended();session.StartRun();ui.Close();Debug.Log("SOARING_SMOKE calibrated="+p.IsCalibrated+" playing="+session.IsPlaying+" paused="+session.IsPaused+" birds="+session.World.Birds.Count);
  yield return new WaitForSecondsRealtime(1);yield return Capture("04-flight");
  p.enabled=false;var prey=session.World.Birds[0];Vector3 target=p.Position;prey.Respawn(.55f,target);float before=session.Mass;yield return null;yield return null;Debug.Log("SOARING_SMOKE catch="+session.Catches+" massIncreased="+(session.Mass>before));p.enabled=true;
  yield return new WaitForSecondsRealtime(3);yield return Capture("05-growth");ui.Show("pause");Vector3 stopped=p.Position;float elapsed=session.Elapsed;yield return new WaitForSecondsRealtime(.3f);Debug.Log("SOARING_SMOKE pauseStable="+(Vector3.Distance(stopped,p.Position)<.01f&&Mathf.Abs(session.Elapsed-elapsed)<.01f));yield return Capture("06-pause");ui.Close();
  if(Array.IndexOf(args,"--verify-loop")>=0){float oldSafety=p.Tuning.safetySeconds;p.Tuning.safetySeconds=0;session.Kill("Smoke test hunter catch");yield return Capture("07-death");session.Restart();ui.Close();Debug.Log("SOARING_SMOKE restart="+(!session.IsDead&&session.Catches==0&&session.Mass==1));p.enabled=false;int attempts=0;while(session.Size<p.Tuning.apexSize&&attempts++<500)session.Catch(session.Size*.7f);Debug.Log("SOARING_SMOKE apexReachable="+(session.Size>=p.Tuning.apexSize)+" catches="+session.Catches);for(int i=0;i<Mathf.RoundToInt(p.Tuning.apexRingGoal);i++)session.ApexRing();yield return Capture("08-victory");Debug.Log("SOARING_SMOKE victory="+session.HasWon);p.Tuning.safetySeconds=oldSafety;session.Restart();ui.Show("home");p.enabled=true;}
  Debug.Log("SOARING_SMOKE_DONE");
 }
 void Update(){float dt=Time.unscaledDeltaTime;if(dt<1){frameSum+=dt;frameMax=Mathf.Max(frameMax,dt);frames++;}if(Time.realtimeSinceStartup>reportAt+10){reportAt=Time.realtimeSinceStartup;Debug.Log("SOARING_TIMING meanMs="+(frames>0?frameSum/frames*1000:0).ToString("F2")+" maxMs="+(frameMax*1000).ToString("F2")+" frames="+frames);frames=0;frameSum=frameMax=0;}}
}
}
