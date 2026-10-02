using System;
using UnityEngine;
namespace Soaring {
public sealed class GameSession:MonoBehaviour {
 public static GameSession Instance {get;private set;}
 public BirdPlayer Player; public BirdWorld World;
 public bool IsPlaying {get;private set;} public bool IsPaused {get;private set;} public bool IsDead {get;private set;} public bool HasWon {get;private set;}
 public float Mass {get;private set;}=1; public float Size=>Mathf.Pow(Mass,1f/3f); public float Elapsed{get;private set;}
 public int Catches{get;private set;} public int ApexRings{get;private set;} public string Status{get;private set;}="Welcome to the sky";
 public event Action Changed;
 void Awake(){Instance=this;}
 void Update(){if(IsPlaying&&!IsPaused&&!IsDead&&!HasWon)Elapsed+=Time.deltaTime;}
 public void StartRun(){if(!Player.IsCalibrated){Status="Calibrate relaxed and extended wings first";Changed?.Invoke();return;}Mass=1;Elapsed=0;Catches=0;ApexRings=0;IsDead=false;HasWon=false;IsPlaying=true;IsPaused=false;Status="Catch golden birds. Avoid coral hunters.";Player.ResetFlight();World.ResetPopulation();Changed?.Invoke();}
 public void Pause(bool paused){IsPaused=paused;Changed?.Invoke();}
 public void Restart(){StartRun();}
 public static bool CanEat(float hunter,float prey)=>hunter>prey*1.12f;
 public void Catch(float preySize){if(!IsPlaying||IsPaused||IsDead||HasWon||!CanEat(Size,preySize))return;Mass+=Mathf.Pow(preySize,3)*Player.Tuning.nutrition;Catches++;Status=Size>=Player.Tuning.apexSize?"APEX • fly through the golden crown gates":"Growing • find larger prey";Player.Haptic(.6f,.12f);Changed?.Invoke();}
 public void Kill(string reason){if(!IsPlaying||IsDead||HasWon||Elapsed<Player.Tuning.safetySeconds)return;IsDead=true;IsPaused=true;Status=reason;Player.Haptic(1,.3f);Changed?.Invoke();}
 public void ApexRing(){if(!IsPlaying||IsPaused||IsDead||HasWon||Size<Player.Tuning.apexSize)return;ApexRings++;Player.Haptic(.8f,.2f);if(ApexRings>=Mathf.RoundToInt(Player.Tuning.apexRingGoal)){HasWon=true;IsPaused=true;Status="CROWN OF THE SKY • you made it";}Changed?.Invoke();}
}
}
