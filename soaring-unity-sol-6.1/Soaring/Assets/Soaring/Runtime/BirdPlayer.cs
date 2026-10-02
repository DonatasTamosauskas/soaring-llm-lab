using System;
using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.XR;
using UnityEngine.XR.Management;
using CommonUsages = UnityEngine.XR.CommonUsages;
namespace Soaring {
public sealed class BirdPlayer:MonoBehaviour {
 public FlightTuning Tuning=new FlightTuning(); public Transform Head,LeftHand,RightHand;
 public bool ComfortVignette=true,HapticsEnabled=true;
 public Vector3 Position=>Head.position; public Vector3 Velocity=>model.Velocity; public float Speed=>model.Velocity.magnitude;public float Size=>GameSession.Instance!=null?GameSession.Instance.Size:1;
 public bool IsCalibrated {get;private set;} public bool TrackingValid{get;private set;} public bool DesktopMode{get;private set;}
 public float Extension=>model.Extension; public float TurnInput=>model.TurnInput;
 public float RelaxedSpan{get;private set;}=.7f;public float ExtendedSpan{get;private set;}=1.45f;
 public readonly FlightModel model=new FlightModel();
 Vector3 previousLeft,previousRight; bool previousValid,relaxedCaptured; float currentScale=1,desktopFlapUntil; InputAction leftPos,rightPos,headPos,leftRot,rightRot,headRot;Material wingMaterial;Transform wingL,wingR;
 void Start(){Tuning.Load();DesktopMode=Array.IndexOf(Environment.GetCommandLineArgs(),"--desktop")>=0||XRGeneralSettings.Instance?.Manager?.activeLoader==null; SetupActions();BuildWings();ResetFlight();}
 void SetupActions(){leftPos=Action("<XRController>{LeftHand}/devicePosition","Vector3");rightPos=Action("<XRController>{RightHand}/devicePosition","Vector3");headPos=Action("<XRHMD>/centerEyePosition","Vector3");leftRot=Action("<XRController>{LeftHand}/deviceRotation","Quaternion");rightRot=Action("<XRController>{RightHand}/deviceRotation","Quaternion");headRot=Action("<XRHMD>/centerEyeRotation","Quaternion");}
 InputAction Action(string path,string type){var a=new InputAction(type:InputActionType.Value,binding:path,expectedControlType:type);a.Enable();return a;}
 void OnDestroy(){leftPos?.Dispose();rightPos?.Dispose();headPos?.Dispose();leftRot?.Dispose();rightRot?.Dispose();headRot?.Dispose();if(wingMaterial!=null)Destroy(wingMaterial);}
 void BuildWings(){wingMaterial=new Material(Shader.Find("Universal Render Pipeline/Simple Lit")){color=new Color(.06f,.42f,.45f)};wingL=Wing(LeftHand,-1);wingR=Wing(RightHand,1);}
 Transform Wing(Transform hand,int sign){var pivot=new GameObject("Feathered wing").transform;pivot.SetParent(hand,false);for(int i=0;i<5;i++){var feather=GameObject.CreatePrimitive(PrimitiveType.Cube);Destroy(feather.GetComponent<Collider>());feather.transform.SetParent(pivot,false);feather.transform.localPosition=new Vector3(sign*(.04f+i*.045f),0,.03f+i*.018f);feather.transform.localScale=new Vector3(.07f,.022f,.23f-i*.024f);feather.transform.localRotation=Quaternion.Euler(0,sign*(i*7),0);feather.GetComponent<Renderer>().sharedMaterial=wingMaterial;}return pivot;}
 void ReadPoses(){
  if(DesktopMode){Head.localPosition=new Vector3(0,1.6f,0);LeftHand.localPosition=new Vector3(-.35f,1.05f,.35f);RightHand.localPosition=new Vector3(.35f,1.05f,.35f);TrackingValid=true;var k=Keyboard.current;if(k!=null){if(k.eKey.isPressed){LeftHand.localPosition=new Vector3(-.78f,1.35f,.1f);RightHand.localPosition=new Vector3(.78f,1.35f,.1f);}if(k.spaceKey.wasPressedThisFrame)desktopFlapUntil=Time.unscaledTime+.18f;float look=(k.rightArrowKey.isPressed?1:0)-(k.leftArrowKey.isPressed?1:0);Head.localRotation=Quaternion.Euler(0,Head.localEulerAngles.y+look*60*Time.unscaledDeltaTime,0);}return;}
  var l=InputDevices.GetDeviceAtXRNode(XRNode.LeftHand);var r=InputDevices.GetDeviceAtXRNode(XRNode.RightHand);var h=InputDevices.GetDeviceAtXRNode(XRNode.Head);
  bool lt=false,rt=false,ht=false;l.TryGetFeatureValue(CommonUsages.isTracked,out lt);r.TryGetFeatureValue(CommonUsages.isTracked,out rt);h.TryGetFeatureValue(CommonUsages.isTracked,out ht);TrackingValid=lt&&rt&&ht;
  if(h.TryGetFeatureValue(CommonUsages.devicePosition,out Vector3 hp))Head.localPosition=hp;else Head.localPosition=headPos.ReadValue<Vector3>();
  if(h.TryGetFeatureValue(CommonUsages.deviceRotation,out Quaternion hr))Head.localRotation=hr;else Head.localRotation=headRot.ReadValue<Quaternion>();
  if(l.TryGetFeatureValue(CommonUsages.devicePosition,out Vector3 lp))LeftHand.localPosition=lp;else LeftHand.localPosition=leftPos.ReadValue<Vector3>();
  if(r.TryGetFeatureValue(CommonUsages.devicePosition,out Vector3 rp))RightHand.localPosition=rp;else RightHand.localPosition=rightPos.ReadValue<Vector3>();
  if(l.TryGetFeatureValue(CommonUsages.deviceRotation,out Quaternion lr))LeftHand.localRotation=lr;
  if(r.TryGetFeatureValue(CommonUsages.deviceRotation,out Quaternion rr))RightHand.localRotation=rr;
 }
 public void CalibrateRelaxed(){if(!TrackingValid)return;RelaxedSpan=Vector3.Distance(LeftHand.localPosition,RightHand.localPosition);relaxedCaptured=true;IsCalibrated=false;Haptic(.3f,.1f);}
 public void CalibrateExtended(){if(!TrackingValid||!relaxedCaptured)return;float span=Vector3.Distance(LeftHand.localPosition,RightHand.localPosition);if(span<RelaxedSpan+.12f)return;ExtendedSpan=span;IsCalibrated=true;previousValid=false;Haptic(.5f,.15f);}
 public void ResetFlight(){transform.position=new Vector3(0,24,0);transform.rotation=Quaternion.identity;currentScale=1;transform.localScale=Vector3.one;model.Reset();previousValid=false;}
 void Update(){
  ReadPoses();var session=GameSession.Instance;if(session==null)return;
  if(!TrackingValid&&!DesktopMode&&session.IsPlaying&&!session.IsPaused){session.Pause(true);Debug.LogWarning("SOARING_TRACKING_LOST paused");}
  Vector3 left=LeftHand.localPosition-Head.localPosition,right=RightHand.localPosition-Head.localPosition;float dt=Time.deltaTime;
  if(!session.IsPlaying||session.IsPaused||session.IsDead||session.HasWon||!IsCalibrated||!TrackingValid){previousLeft=left;previousRight=right;previousValid=false;return;}
  var sample=new WingSample{Valid=previousValid,LeftDown=previousValid?Mathf.Clamp((previousLeft.y-left.y)/Mathf.Max(.001f,dt),-8,8):0,RightDown=previousValid?Mathf.Clamp((previousRight.y-right.y)/Mathf.Max(.001f,dt),-8,8):0,Extension=Mathf.InverseLerp(RelaxedSpan,ExtendedSpan,Vector3.Distance(left,right)),Bank=(left.y-right.y)/.45f};
  if(DesktopMode){sample.Valid=true;sample.LeftDown=sample.RightDown=Time.unscaledTime<desktopFlapUntil?1.5f:0;var k=Keyboard.current;sample.Bank=k!=null?((k.dKey.isPressed?1:0)-(k.aKey.isPressed?1:0)):0;}
  previousLeft=left;previousRight=right;previousValid=true;
  model.Step(sample,Size,session.World.UpdraftAt(Position),dt,Tuning);
  if(model.Flapped)Haptic(.2f,.035f);
  currentScale=Mathf.Lerp(currentScale,Size,1-Mathf.Exp(-dt*Tuning.growthSmoothing));
  Vector3 oldHead=Position;transform.localScale=Vector3.one*currentScale;transform.position+=oldHead-Position;
  Vector3 beforeYaw=Position;transform.rotation=Quaternion.Euler(0,model.Yaw,0);transform.position+=beforeYaw-Position;
  Vector3 delta=model.Velocity*dt;float radius=.28f*currentScale;
  if(delta.sqrMagnitude>.00001f&&Physics.SphereCast(Position,radius,delta.normalized,out RaycastHit hit,delta.magnitude,~0,QueryTriggerInteraction.Ignore)){
   delta=delta.normalized*Mathf.Max(0,hit.distance-.05f);model.Velocity=Vector3.ProjectOnPlane(model.Velocity,hit.normal)*.7f;Haptic(.4f,.06f);
  }
  transform.position+=delta;Vector3 bounded=session.World.Constrain(Position,radius);if(Vector3.Distance(bounded,Position)>.01f){model.Velocity*=.9f;transform.position+=bounded-Position;}
 }
 public void Haptic(float strength,float duration){if(!HapticsEnabled)return;foreach(var node in new[]{XRNode.LeftHand,XRNode.RightHand}){var d=InputDevices.GetDeviceAtXRNode(node);if(d.TryGetHapticCapabilities(out var c)&&c.supportsImpulse)d.SendHapticImpulse(0,Mathf.Clamp01(strength*Tuning.hapticStrength),duration);}}
}
}
