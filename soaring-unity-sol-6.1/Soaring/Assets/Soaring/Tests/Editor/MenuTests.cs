using NUnit.Framework;
using UnityEngine;
namespace Soaring.Tests {
public class MenuTests {
 [Test] public void PauseCanToggleBeforeRunWithoutStartingIt(){var go=new GameObject("Menu session");try{var s=go.AddComponent<GameSession>();s.Pause(true);Assert.IsTrue(s.IsPaused);Assert.IsFalse(s.IsPlaying);s.Pause(false);Assert.IsFalse(s.IsPaused);Assert.IsFalse(s.IsPlaying);}finally{Object.DestroyImmediate(go);}}
 [Test] public void ComfortPresetOffersSlowerSpeedAndWiderDeadzone(){var t=new FlightTuning();float speed=t.cruiseSpeed,dead=t.turnDeadZone;t.ApplyPreset("Comfort");Assert.Less(t.cruiseSpeed,speed);Assert.Greater(t.turnDeadZone,dead);}
 [Test] public void ResetRestoresEditableParameters(){var t=new FlightTuning();t.flapLift=29;t.turnDeadZone=.49f;t.nutrition=.8f;t.ResetDefaults();Assert.AreEqual(16,t.flapLift);Assert.AreEqual(.14f,t.turnDeadZone,.001f);Assert.AreEqual(.32f,t.nutrition,.001f);}
}
}
