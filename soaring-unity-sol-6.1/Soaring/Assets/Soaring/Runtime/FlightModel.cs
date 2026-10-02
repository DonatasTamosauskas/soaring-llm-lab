using UnityEngine;
namespace Soaring {
public struct WingSample { public float LeftDown,RightDown,Extension,Bank; public bool Valid; }
public sealed class FlightModel {
 public Vector3 Velocity; public float Yaw,Extension,TurnInput; float cooldown,balloon,previousExtension,filteredBank;
 public bool Flapped {get;private set;}
 public void Reset(float yaw=0){Velocity=Vector3.zero;Yaw=yaw;cooldown=0;balloon=0;previousExtension=0;filteredBank=0;}
 public static float TurnResponse(float input,FlightTuning t){float a=Mathf.Abs(input);if(a<=t.turnDeadZone)return 0;return Mathf.Sign(input)*Mathf.Pow(Mathf.Clamp01((a-t.turnDeadZone)/(1-t.turnDeadZone)),t.turnExponent);}
 public static float SizeSpeed(float size,FlightTuning t)=>1+Mathf.Max(0,size-1)*t.largeSpeedGain;
 public void Step(WingSample s,float size,float updraft,float dt,FlightTuning t){
  Flapped=false;if(!s.Valid||dt<=0)return;dt=Mathf.Min(dt,.05f);size=Mathf.Max(1,size);
  Extension=Mathf.Clamp01(s.Extension);cooldown=Mathf.Max(0,cooldown-dt);
  if(Extension>.72f && previousExtension<=.72f)balloon=t.balloonDuration;
  previousExtension=Extension;balloon=Mathf.Max(0,balloon-dt);
  filteredBank=Mathf.Lerp(filteredBank,Mathf.Clamp(s.Bank*t.bankSensitivity,-1,1),1-Mathf.Exp(-dt/Mathf.Max(.02f,t.turnSmoothing)));
  TurnInput=TurnResponse(filteredBank,t);Yaw+=TurnInput*t.turnRate/(1+(size-1)*t.largeTurnWeight)*dt;
  Vector3 forward=Quaternion.Euler(0,Yaw,0)*Vector3.forward;
  float speedScale=SizeSpeed(size,t);float target=t.cruiseSpeed*speedScale*(1-Extension*t.extensionDrag);
  Vector3 horizontal=new Vector3(Velocity.x,0,Velocity.z);
  float horizontalSpeed=Mathf.MoveTowards(horizontal.magnitude,target,t.acceleration*speedScale*dt);
  Vector3 direction=horizontal.sqrMagnitude>.01f?Vector3.RotateTowards(horizontal.normalized,forward,t.turnRate*Mathf.Deg2Rad/(1+(size-1)*t.largeTurnWeight)*dt,0):forward;
  horizontal=direction*horizontalSpeed;
  float down=(Mathf.Max(0,s.LeftDown)+Mathf.Max(0,s.RightDown))*.5f;
  float vertical=Velocity.y;
  if(down>t.flapThreshold&&cooldown<=0){float power=Mathf.Clamp(down/t.flapThreshold,1,3);vertical+=t.flapLift*power*.38f;horizontal+=forward*t.flapThrust*power*.32f;cooldown=t.flapCooldown;Flapped=true;}
  float lift=t.glideLift-t.gravity+(balloon>0?t.extensionBalloon:0)+updraft*t.updraftStrength;
  vertical=(vertical+lift*dt)/(1+t.verticalDrag*dt);
  horizontal=Vector3.ClampMagnitude(horizontal,t.maxSpeed*speedScale);
  Velocity=horizontal+Vector3.up*Mathf.Clamp(vertical,-12,t.maxClimb);
 }
}
}
