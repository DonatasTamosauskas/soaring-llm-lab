using System;
using System.IO;
using NUnit.Framework;
using UnityEngine;
namespace Soaring.Tests
{
    public sealed class PortTests
    {
        [Test]
        public void CurvedMenuRayHitsTheRenderedLayoutAtBothEdges()
        {
            const float radius = 1500;
            foreach (float degrees in new[] { -25f, -15f, 0f, 15f, 25f })
            {
                var flat = new Vector3(degrees * Mathf.Deg2Rad * radius, 180, 0);
                var surface = CurvedPanelGeometry.Bend(flat, radius);
                var origin = new Vector3(125, -80, -radius + 220);
                Assert.IsTrue(CurvedPanelGeometry.Hit(new Ray(origin, (surface - origin).normalized), radius, out var layout, out var hit));
                Assert.That(layout.x, Is.EqualTo(flat.x).Within(.01f));
                Assert.That(layout.y, Is.EqualTo(flat.y).Within(.01f));
                Assert.That(Vector3.Distance(hit, surface), Is.LessThan(.01f));
            }
        }
        [Test]
        public void CurvedMenuRejectsRaysFacingAwayAndParallelToItsAxis()
        {
            Assert.IsFalse(CurvedPanelGeometry.Hit(new Ray(new(0,0,-1500), Vector3.back),1500,out _,out _));
            Assert.IsFalse(CurvedPanelGeometry.Hit(new Ray(new(0,0,-1500), Vector3.up),1500,out _,out _));
        }
        [Test]
        public void SmallDecorationStaysOutOfTheSunShadowAtlas()
        {
            foreach(string name in new[] { "water", "grass_patch", "trees_far_forest", "clouds" }) Assert.IsFalse(ShadowPolicy.CastsScenery(name));
            foreach(string name in new[] { "house_wall", "bridge", "tree_near_trunk", "cliff" }) Assert.IsTrue(ShadowPolicy.CastsScenery(name));
        }
        [Test]
        public void WristTwistIgnoresArmSwingAndMirrorsTheWings()
        {
            foreach (float side in new[] { -1f, 1f })
            {
                var axis = Vector3.right * side;
                var arm = Quaternion.Euler(0, 25, 30) * axis;
                var neutral = Quaternion.Euler(20, 10, -5);
                var swing = Quaternion.FromToRotation(axis, arm);
                var current = swing * Quaternion.AngleAxis(35 * side, axis) * neutral;
                Assert.That(WingPoseMath.WristPitch(neutral, axis, current, arm, side), Is.EqualTo(31f / 51).Within(.0001));
                Assert.That(WingPoseMath.WristPitch(neutral, axis, swing * neutral, arm, side), Is.EqualTo(0).Within(.0001));
            }
        }
        [Test]
        public void MothFieldRetainsCheapFoodAtBothBudgets()
        {
            Assert.That(SkyLife.CloudCount(60, .03f), Is.EqualTo(5));
            Assert.That(SkyLife.CloudCount(28, .03f), Is.EqualTo(4));
            Assert.That(SkyLife.CloudCount(20, .03f), Is.EqualTo(4));
            Assert.That(SkyLife.CloudCount(28, .3f), Is.EqualTo(1));
            Assert.IsTrue(SizeRules.Worthwhile(.03f, .006f));
            Assert.That(SizeRules.MealGain(.03f, .006f), Is.GreaterThan(.005f));
        }
        [Test]
        public void LadderMatchesOriginalAnchors()
        {
            foreach (var sp in SizeRules.Ladder)
            {
                Assert.That(SizeRules.Span(sp.mass), Is.EqualTo(sp.span).Within(.00001));
                Assert.That(SizeRules.Ladder[SizeRules.Tier(sp.mass)].id, Is.EqualTo(sp.id));
            }
            float prev = 0;
            for (int i = 0; i < 1000; i++)
            {
                float span = SizeRules.Span(.001f * Mathf.Pow(10000, i / 999f));
                Assert.That(span, Is.GreaterThan(prev));
                prev = span;
            }
        }
        [Test]
        public void FoodRulesRejectDustAndPeers()
        {
            Assert.IsFalse(SizeRules.CanEat(.03f, .03f));
            Assert.IsTrue(SizeRules.CanEat(.03f, .012f));
            Assert.That(SizeRules.MealGain(.03f, .012f), Is.EqualTo(.01728f).Within(.000001));
            Assert.IsFalse(SizeRules.Worthwhile(3, .012f));
            Assert.IsTrue(SizeRules.Worthwhile(3, 1.3f));
        }
        [Test]
        public void CatchSweepDoesNotTunnel()
        {
            float t = CatchRule.ContactTime(Vector3.zero, new Vector3(0, 0, 10), new Vector3(0, 0, 5), new Vector3(0, 0, 5), .1f, 0, Vector3.forward, Vector3.forward, 80);
            Assert.That(t, Is.EqualTo(.49f).Within(.00001));
        }
        [Test]
        public void BehindThePlayerIsNotAFreeMeal()
        {
            Assert.That(CatchRule.ContactTime(Vector3.zero, Vector3.zero, Vector3.back, Vector3.back, 3, 0, Vector3.forward, Vector3.zero, 90), Is.LessThan(0));
        }
        [Test]
        public void CatchAssistHasBoundedFeltReach()
        {
            foreach (var sp in SizeRules.Ladder)
                Assert.That(CatchRule.ContactDistance(sp.mass, sp.mass * .25f, true, 1), Is.LessThanOrEqualTo(2.9f * sp.span + .00001f));
        }
        [Test]
        public void SweptConeFindsLateAimEntry()
        {
            Vector3 prey0 = new(1, 0, -1), prey1 = new(1, 0, 1);
            float t = CatchRule.ContactTime(Vector3.zero, Vector3.zero, prey0, prey1, 2, 0, Vector3.forward, Vector3.zero, 60, false);
            Assert.That(t, Is.EqualTo(.7886751f).Within(.00001));
        }
        [Test]
        public void FlightRatesRemainFiniteAcrossSpecies()
        {
            foreach (var sp in SizeRules.Ladder)
            {
                var model = new FlightModel { mass = sp.mass };
                model.Reset(Vector3.up * 100, Vector3.forward, true);
                var prefs = new Preferences();
                var wings = WingState.Neutral;
                for (int i = 0; i < 720; i++)
                    model.Step(wings, Vector3.zero, -100, 300, 1f / 72, prefs);
                Assert.IsTrue(float.IsFinite(model.position.sqrMagnitude), sp.id);
                Assert.That(model.velocity.magnitude, Is.LessThan(SizeRules.Cruise(sp.mass) * 4));
            }
        }
        static FlightModel Sim(float command, bool tuck = false)
        {
            var m = new FlightModel();
            m.Reset(Vector3.up * 100, Vector3.forward, true);
            var w = WingState.Neutral;
            w.pitch = w.leftPitch = w.rightPitch = command;
            w.tuck = tuck;
            if (tuck)
                w.leftExtension = w.rightExtension = .08f;
            for (int i = 0; i < 108; i++)
                m.Step(w, Vector3.zero, -1000, 1000, 1f / 72, new Preferences());
            return m;
        }
        [Test]
        public void AngleOfAttackTradesSpeedForHeight()
        {
            var neutral = Sim(0);
            var flare = Sim(.65f);
            var dive = Sim(-.7f);
            Assert.That(flare.position.y, Is.GreaterThan(neutral.position.y));
            Assert.That(flare.airspeed, Is.LessThan(neutral.airspeed));
            Assert.That(dive.airspeed, Is.GreaterThan(neutral.airspeed));
        }
        [Test]
        public void TuckReducesAreaAndAcceleratesDive()
        {
            var glide = Sim(0);
            var tuck = Sim(0, true);
            Assert.That(tuck.position.y, Is.LessThan(glide.position.y));
            Assert.That(tuck.airspeed, Is.GreaterThan(glide.airspeed));
        }
        [Test]
        public void FlatFlapsClimbAndTiltedFlapsAddThrust()
        {
            var flat = new FlightModel();
            var tilt = new FlightModel();
            flat.Reset(Vector3.up * 100, Vector3.forward);
            tilt.Reset(Vector3.up * 100, Vector3.forward);
            var a = WingState.Neutral;
            a.leftFlap = a.rightFlap = .445f;
            var b = a;
            b.leftPitch = b.rightPitch = -.65f;
            for (int i = 0; i < 144; i++)
            {
                flat.Step(a, Vector3.zero, -100, 300, 1f / 72, new Preferences());
                tilt.Step(b, Vector3.zero, -100, 300, 1f / 72, new Preferences());
            }
            Assert.That(flat.position.y, Is.GreaterThan(100));
            Assert.That(tilt.velocity.z, Is.GreaterThan(flat.velocity.z));
        }
        [Test]
        public void FullFlareCanStallAndRecover()
        {
            var m = new FlightModel();
            m.Reset(Vector3.up * 100, Vector3.forward, true);
            var w = WingState.Neutral;
            w.pitch = 1;
            bool stalled = false;
            for (int i = 0; i < 100; i++)
            {
                m.Step(w, Vector3.zero, -100, 1000, 1f / 72, new Preferences());
                stalled |= m.stalled;
            }
            Assert.IsTrue(stalled);
            w.pitch = -.4f;
            for (int i = 0; i < 720; i++)
                m.Step(w, Vector3.zero, -100, 1000, 1f / 72, new Preferences());
            Assert.IsFalse(m.stalled);
        }
        [Test]
        public void OppositeTiltsProduceCoordinatedTurn()
        {
            var m = new FlightModel();
            m.Reset(Vector3.up * 100, Vector3.forward, true);
            var w = WingState.Neutral;
            w.roll = .6f;
            for (int i = 0; i < 72; i++)
                m.Step(w, Vector3.zero, -100, 300, 1f / 72, new Preferences());
            Assert.That(m.yaw, Is.GreaterThan(.1f));
            Assert.That(m.bank, Is.GreaterThan(.2f));
        }
        [Test]
        public void FrameRateHasSmallEffectOnFlight()
        {
            Vector3 SimRate(int hz)
            {
                var m = new FlightModel();
                m.Reset(Vector3.up * 100, Vector3.forward, true);
                var w = WingState.Neutral;
                w.roll = .3f;
                w.leftFlap = w.rightFlap = .445f;
                for (int i = 0; i < hz * 4; i++)
                    m.Step(w, Vector3.zero, -100, 300, 1f / hz, new Preferences());
                return m.position;
            }
            Assert.That(Vector3.Distance(SimRate(72), SimRate(90)), Is.LessThan(.2f));
        }
        [Test]
        public void RecordsSurviveCorruptionAndAtomicSave()
        {
            string dir = Path.Combine(Path.GetTempPath(), "soaring-tests-" + Guid.NewGuid());
            SaveStore.RootOverride = dir;
            try
            {
                Directory.CreateDirectory(dir);
                File.WriteAllText(Path.Combine(dir, "records.json"), "bad json");
                Assert.That(SaveStore.Read<Records>("records").bestScore, Is.EqualTo(0));
                var stats = new RunStats { peakMass = 3, worthwhile = 5, victory = true, duration = 1200 };
                var records = new Records();
                records.Submit(stats, true);
                var loaded = SaveStore.Read<Records>("records");
                Assert.That(loaded.bestScore, Is.EqualTo(stats.Score));
                Assert.That(loaded.runs, Is.EqualTo(1));
                Assert.False(File.Exists(Path.Combine(dir, "records.json.tmp")));
            }
            finally { SaveStore.RootOverride = null; Directory.Delete(dir, true); }
        }
        [Test]
        public void ImportedContentContainsEveryDistrictAndSpecies()
        {
            var c = Resources.Load<SoaringContent>("SoaringContent");
            Assert.NotNull(c);
            Assert.That(c.species.Length, Is.EqualTo(10));
            Assert.That(c.perches.Length, Is.EqualTo(1189));
            Assert.That(c.refuges.Length, Is.EqualTo(296));
            Assert.That(c.landmarks.Length, Is.EqualTo(453));
            Assert.That(c.thermals.Length, Is.EqualTo(8));
            foreach (var s in c.species)
            {
                Assert.That(s.lods.Length, Is.EqualTo(3));
                foreach (var m in s.lods)
                    Assert.That(m.vertexCount, Is.GreaterThan(0));
            }
            Assert.That(c.valleyPrefab.GetComponentsInChildren<MeshCollider>().Length, Is.GreaterThan(100));
        }
        [Test]
        public void GroundIgnoresRoofsAndRiverWaterIsSpatial()
        {
            var c = Resources.Load<SoaringContent>("SoaringContent");
            Assert.That(c.heightMapSize, Is.EqualTo(381));
            var go = new GameObject();
            try
            {
                var world = go.AddComponent<ValleyWorld>();
                world.content = c;
                Assert.That(world.Ground(c.spawn), Is.LessThan(c.spawn.y - 3));
                Assert.IsTrue(world.Water(new Vector3(228, 0, -228)));
                Assert.IsTrue(world.Water(new Vector3(47, 0, -30)));
                Assert.IsFalse(world.Water(new Vector3(-100, -1, 100)));
            }
            finally { UnityEngine.Object.DestroyImmediate(go); }
        }
    }
}
