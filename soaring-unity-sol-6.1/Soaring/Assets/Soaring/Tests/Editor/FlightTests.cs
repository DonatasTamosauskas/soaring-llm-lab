using NUnit.Framework;
using UnityEngine;
namespace Soaring.Tests {
public class FlightTests {
 [Test] public void LargeFlapLiftsImmediately(){var t=new FlightTuning();var f=new FlightModel();f.Step(new WingSample{Valid=true,LeftDown=2,RightDown=2},1,0,.016f,t);Assert.Greater(f.Velocity.y,10);Assert.IsTrue(f.Flapped);}
 [Test] public void InvalidTrackingCannotMove(){var f=new FlightModel();f.Step(new WingSample{Valid=false,LeftDown=9,RightDown=9},1,0,.02f,new FlightTuning());Assert.AreEqual(Vector3.zero,f.Velocity);}
 [Test] public void RelaxedPoseCruisesWithoutArmExtension(){var f=new FlightModel();var t=new FlightTuning();for(int i=0;i<250;i++)f.Step(new WingSample{Valid=true},1,0,.02f,t);Assert.Greater(f.Velocity.z,19);Assert.Less(Mathf.Abs(f.Velocity.y),1);}
 [Test] public void ExtensionBalloonsThenSlows(){var t=new FlightTuning();var f=new FlightModel();f.Step(new WingSample{Valid=true,Extension=1},1,0,.05f,t);Assert.Greater(f.Velocity.y,0);for(int i=0;i<250;i++)f.Step(new WingSample{Valid=true,Extension=1},1,0,.02f,t);Assert.Less(f.Velocity.z,t.cruiseSpeed*.7f);Assert.Less(f.Velocity.y,.2f);}
 [Test] public void TurnDeadzoneAndCurve(){var t=new FlightTuning();Assert.AreEqual(0,FlightModel.TurnResponse(.1f,t));Assert.Greater(FlightModel.TurnResponse(.8f,t),FlightModel.TurnResponse(.5f,t)*2);Assert.AreEqual(-FlightModel.TurnResponse(.8f,t),FlightModel.TurnResponse(-.8f,t));}
 [Test] public void BigIsFasterAndHeavier(){var t=new FlightTuning();var small=new FlightModel();var big=new FlightModel();for(int i=0;i<250;i++){var s=new WingSample{Valid=true,Bank=1};small.Step(s,1,0,.02f,t);big.Step(s,4,0,.02f,t);}Assert.Greater(big.Velocity.magnitude,small.Velocity.magnitude);Assert.Less(big.Yaw,small.Yaw);}
 [Test] public void UpdraftRaisesPlayerWithoutFlapping(){var f=new FlightModel();for(int i=0;i<100;i++)f.Step(new WingSample{Valid=true},1,8,.02f,new FlightTuning());Assert.Greater(f.Velocity.y,7);}
 [Test] public void TuckingAcceleratesAndDives(){var t=new FlightTuning();var f=new FlightModel();for(int i=0;i<300;i++)f.Step(new WingSample{Valid=true,Tuck=1},1,0,.02f,t);Assert.Greater(f.Velocity.z,t.cruiseSpeed*1.25f);Assert.Less(f.Velocity.y,-2);}
 [Test] public void EatingHasSizeMargin(){Assert.IsTrue(GameSession.CanEat(1,.8f));Assert.IsFalse(GameSession.CanEat(1,1));Assert.IsFalse(GameSession.CanEat(1,.95f));}
 [Test] public void RepeatedFlapCannotExceedSpeedCaps(){var t=new FlightTuning();var f=new FlightModel();for(int i=0;i<2000;i++)f.Step(new WingSample{Valid=true,LeftDown=8,RightDown=8},1,0,.02f,t);Assert.LessOrEqual(new Vector2(f.Velocity.x,f.Velocity.z).magnitude,t.maxSpeed+.01f);Assert.LessOrEqual(f.Velocity.y,t.maxClimb);}
 [Test] public void TuningSanitizesBadInput(){var t=new FlightTuning{turnDeadZone=float.NaN,maxSpeed=14,cruiseSpeed=30};t.Sanitize();Assert.IsFalse(float.IsNaN(t.turnDeadZone));Assert.GreaterOrEqual(t.maxSpeed,t.cruiseSpeed);}
}
}
