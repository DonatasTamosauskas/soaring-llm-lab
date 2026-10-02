using System;
using System.IO;
using UnityEngine;
namespace Soaring {
[Serializable] public sealed class FlightTuning {
 [Range(8,36)] public float cruiseSpeed=20;
 [Range(14,60)] public float maxSpeed=38;
 [Range(1,30)] public float acceleration=12;
 [Range(2,30)] public float flapLift=16;
 [Range(0,18)] public float flapThrust=7;
 [Range(.1f,2)] public float flapThreshold=.38f;
 [Range(.05f,.5f)] public float flapCooldown=.16f;
 [Range(0,12)] public float gravity=4;
 [Range(0,12)] public float glideLift=3.8f;
 [Range(0,12)] public float extensionBalloon=5;
 [Range(.1f,3)] public float balloonDuration=.65f;
 [Range(0,.75f)] public float extensionDrag=.45f;
 [Range(10,160)] public float turnRate=90;
 [Range(.02f,.5f)] public float turnDeadZone=.14f;
 [Range(1,4)] public float turnExponent=1.8f;
 [Range(.1f,2)] public float bankSensitivity=.75f;
 [Range(.1f,2)] public float turnSmoothing=.25f;
 [Range(.1f,4)] public float verticalDrag=.65f;
 [Range(5,40)] public float maxClimb=18;
 [Range(0,.6f)] public float largeSpeedGain=.23f;
 [Range(0,1)] public float largeTurnWeight=.6f;
 [Range(0,2)] public float updraftStrength=1;
 [Range(0,1)] public float comfortStrength=.35f;
 [Range(.05f,1)] public float nutrition=.32f;
 [Range(1.2f,8)] public float apexSize=4.6f;
 [Range(1,8)] public float growthSmoothing=2;
 [Range(1,6)] public float apexRingGoal=3;
 [Range(0,15)] public float safetySeconds=7;
 [Range(.5f,2)] public float npcSpeedMultiplier=1;
 [Range(1,15)] public float threatWarningSeconds=4;
 [Range(0,1)] public float hapticStrength=.6f;
 static string PathName=>Path.Combine(Application.persistentDataPath,"flight-tuning.json");
 public void Save(){File.WriteAllText(PathName,JsonUtility.ToJson(this,true));}
 public void Load(){if(File.Exists(PathName)){try{JsonUtility.FromJsonOverwrite(File.ReadAllText(PathName),this);Sanitize();}catch(Exception e){Debug.LogWarning("Tuning load: "+e.Message);}}}
 public void ResetDefaults(){JsonUtility.FromJsonOverwrite(JsonUtility.ToJson(new FlightTuning()),this);}
 public void ApplyPreset(string name){ResetDefaults();if(name=="Arcade"){flapLift=22;flapThrust=11;cruiseSpeed=26;turnRate=115;}if(name=="Comfort"){cruiseSpeed=15;maxSpeed=28;turnRate=55;turnDeadZone=.22f;comfortStrength=.65f;}if(name=="Heavy"){largeTurnWeight=.9f;largeSpeedGain=.4f;verticalDrag=1.2f;}}
 public void Sanitize(){foreach(var f in GetType().GetFields()){var range=(RangeAttribute)Attribute.GetCustomAttribute(f,typeof(RangeAttribute));if(range==null)continue;float v=(float)f.GetValue(this);if(float.IsNaN(v)||float.IsInfinity(v))v=(float)f.GetValue(new FlightTuning());f.SetValue(this,Mathf.Clamp(v,range.min,range.max));}maxSpeed=Mathf.Max(maxSpeed,cruiseSpeed);}
}
}
