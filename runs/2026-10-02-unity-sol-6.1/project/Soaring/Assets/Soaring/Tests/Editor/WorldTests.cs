using NUnit.Framework;
using UnityEngine;
namespace Soaring.Tests
{
    public sealed class WorldTests
    {
        [TestCase(0,0,0,1)]
        [TestCase(900,350,-900,5)]
        [TestCase(-250,-60,180,3)]
        public void ClosedArenaContainsOvershoot(float x,float y,float z,float size)
        {
            var go=new GameObject("Arena constraint test");
            try
            {
                var world=go.AddComponent<BirdWorld>();
                var result=world.Constrain(new Vector3(x,y,z),size);
                Assert.That(new Vector2(result.x,result.z).magnitude,Is.LessThanOrEqualTo(world.ArenaRadius-size-6+.001f));
                Assert.That(result.y,Is.InRange(3+size,world.Ceiling-size));
            }
            finally { Object.DestroyImmediate(go); }
        }
        [Test]
        public void HighSpeedCatchDoesNotSkipBirdBetweenFrames()
        {
            Assert.That(BirdWorld.DistanceToSegment(new Vector3(0,0,10),Vector3.zero,new Vector3(0,0,20)),Is.LessThan(.001f));
            Assert.That(BirdWorld.DistanceToSegment(new Vector3(2,0,10),Vector3.zero,new Vector3(0,0,20)),Is.EqualTo(2).Within(.001f));
        }
        [Test]
        public void StationarySegmentHasFiniteDistance()
        {
            Assert.That(BirdWorld.DistanceToSegment(Vector3.right,Vector3.zero,Vector3.zero),Is.EqualTo(1));
        }
        [Test]
        public void RelativeMotionCatchesCrossingBird()
        {
            Assert.That(BirdWorld.DistanceToSegment(Vector3.zero,new Vector3(-4,0,0),new Vector3(4,0,0)),Is.LessThan(.001f));
        }
    }
}
