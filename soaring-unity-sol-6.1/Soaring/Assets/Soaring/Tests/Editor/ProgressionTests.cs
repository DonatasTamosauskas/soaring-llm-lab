using NUnit.Framework;
using UnityEngine;
namespace Soaring.Tests {
public class ProgressionTests {
 [Test] public void SizeProgressionHasAdjustableEarlyAndLatePacing(){var t=new FlightTuning();float early=GameSession.NutritionGain(1,.6f,t);float late=GameSession.NutritionGain(3,.6f,t);Assert.Greater(early,late);t.nutrition*=2;Assert.AreEqual(early*2,GameSession.NutritionGain(1,.6f,t),.0001f);}
 [Test] public void GrowthTargetsAreReachableAtModerateCatchRate(){var t=new FlightTuning();float mass=1,first=0,mid=0,apex=0;for(int n=1;n<200;n++){float size=Mathf.Pow(mass,1f/3);mass+=GameSession.NutritionGain(size,size*.6f,t);size=Mathf.Pow(mass,1f/3);float seconds=n*15;if(first==0&&size>=1.2f)first=seconds;if(mid==0&&size>=2.2f)mid=seconds;if(size>=t.apexSize){apex=seconds;break;}}Assert.That(first,Is.InRange(1,120));Assert.That(mid,Is.InRange(300,480));Assert.That(apex,Is.InRange(1200,1800));}
 [Test] public void StartingWithoutCalibrationIsBlocked(){var sessionObject=new GameObject("Uncalibrated session");var playerObject=new GameObject("Uncalibrated bird");try{var session=sessionObject.AddComponent<GameSession>();session.Player=playerObject.AddComponent<BirdPlayer>();session.StartRun();Assert.IsFalse(session.IsPlaying);Assert.AreEqual(1,session.Mass);Assert.That(session.Status,Does.Contain("Calibrate"));}finally{Object.DestroyImmediate(sessionObject);Object.DestroyImmediate(playerObject);}}
}
}
