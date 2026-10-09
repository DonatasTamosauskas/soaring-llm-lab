using System;
using UnityEngine;
namespace Soaring
{
    // Cheap food swarms and visual-only starling mass, matching the source's
    // separate moth field / murmuration budgets. No brains or GameObjects.
    public sealed class SkyLife
    {
        public const int MothStart = 96;
        public readonly BirdAgent[] murmuration = new BirdAgent[45];
        readonly Ecosystem eco;
        readonly Vector3[] slots = new Vector3[45];
        sealed class Cloud
        {
            public Vector3 centre; public bool placed; public float emptyAt = -1;
        }
        readonly Cloud[] clouds = new Cloud[6];
        System.Random random; float nextPlacement; Vector3 oldCentre; bool swarmActive;
        public SkyLife(Ecosystem ecosystem)
        {
            eco = ecosystem;
            for (int i = 0; i < clouds.Length; i++)
                clouds[i] = new Cloud();
            var rng = new System.Random(7);
            for (int i = 0; i < murmuration.Length; i++)
            {
                var v = new Vector3((float)rng.NextDouble() * 2 - 1, (float)rng.NextDouble() * 2 - 1, (float)rng.NextDouble() * 2 - 1).normalized;
                slots[i] = v * Mathf.Pow((float)rng.NextDouble(), 1f / 3);
                murmuration[i] = new BirdAgent { tier = 4, mass = .1f, phase = (float)rng.NextDouble() };
            }
        }
        public static int CloudCount(int budget, float playerMass) => SizeRules.Worthwhile(playerMass, .006f) ? Mathf.Clamp(Mathf.RoundToInt(5 * Mathf.Pow(budget / 60f, .25f)), 2, 5) : 1;
        public void Reset()
        {
            random = new System.Random(10);
            nextPlacement = 0;
            swarmActive = false;
            foreach (var c in clouds)
            {
                c.placed = false;
                c.emptyAt = -1;
            }
            for (int i = MothStart; i < eco.birds.Length; i++)
            {
                var b = eco.birds[i];
                b.pellet = true;
                b.tier = 0;
                b.mass = .006f;
                b.alive = false;
                b.hidden = false;
            }
        }
        float Range(float a, float b) => Mathf.Lerp(a, b, (float)random.NextDouble());
        void Place(int index, bool lesson)
        {
            var player = eco.player;
            Vector3 centre = Vector3.zero;
            bool found = false;
            for (int attempt = 0; attempt < 20; attempt++)
            {
                float angle = lesson ? Range(-12, 12) : (random.Next(2) == 0 ? -1 : 1) * Range(48, 72);
                float distance = lesson ? 45 : Range(65, 95);
                centre = player.model.position + Quaternion.Euler(0, angle, 0) * player.model.Forward * distance;
                centre.y = Mathf.Max(eco.world.Ground(centre) + 7, player.model.position.y + Range(-3, 3));
                if (new Vector2(centre.x, centre.z).magnitude < eco.world.content.bounds - 10 && centre.y < eco.world.content.ceiling - 10 && !Physics.CheckSphere(centre, 3, ValleyWorld.SolidMask, QueryTriggerInteraction.Ignore))
                {
                    found = true;
                    break;
                }
            }
            if (!found)
                return;
            var cloud = clouds[index];
            cloud.centre = centre;
            cloud.placed = true;
            cloud.emptyAt = -1;
            for (int j = 0; j < 8; j++)
            {
                var b = eco.birds[MothStart + index * 8 + j];
                b.alive = !lesson || j < 5;
                b.hidden = false;
                b.mass = .006f;
                b.tier = 0;
                b.goal = new Vector3(Range(-2, 2), Range(-1, 1), Range(-2, 2));
                b.position = b.previous = centre + b.goal;
                b.velocity = Vector3.zero;
                b.phase = Range(0, 1);
                b.flapAmount = 1;
            }
        }
        public void Step(float dt, float time)
        {
            int count = CloudCount(eco.population, eco.player.model.mass);
            bool lesson = eco.game.phase == GamePhase.Flying && eco.game.lesson == 6;
            for (int i = 0; i < 6; i++)
            {
                bool active = i < count || i == 5 && lesson;
                if (!active)
                {
                    clouds[i].placed = false;
                    for (int j = 0; j < 8; j++)
                        eco.birds[MothStart + i * 8 + j].alive = false;
                    continue;
                }
                var cloud = clouds[i];
                Vector3 relative = cloud.centre - eco.player.model.position;
                int alive = 0;
                for (int j = 0; j < 8; j++)
                    if (eco.birds[MothStart + i * 8 + j].alive)
                        alive++;
                if (alive == 0 && cloud.emptyAt < 0)
                    cloud.emptyAt = time;
                bool behind = Vector3.Dot(relative, eco.player.model.Forward) < -90;
                bool lost = relative.magnitude > (i == 5 ? 90 : 170) || behind;
                if ((!cloud.placed || lost || alive == 0 && time - cloud.emptyAt > 4) && time >= nextPlacement)
                {
                    Place(i, i == 5);
                    nextPlacement = time + (i == 5 ? .25f : 1);
                }
                if (!cloud.placed)
                    continue;
                for (int j = 0; j < 8; j++)
                {
                    var b = eco.birds[MothStart + i * 8 + j];
                    if (!b.alive)
                        continue;
                    b.previous = b.position;
                    float phase = time * .7f + j * 2.3f + i;
                    var want = cloud.centre + b.goal + new Vector3(Mathf.Sin(phase), Mathf.Sin(phase * .73f) * .5f, Mathf.Cos(phase)) * .7f;
                    b.velocity = Vector3.Lerp(b.velocity, (want - b.position) * 1.5f, 1 - Mathf.Exp(-dt / .35f));
                    b.position += b.velocity * dt;
                    if (b.velocity.sqrMagnitude > .01f)
                        b.heading = b.velocity.normalized;
                    b.phase = Mathf.Repeat(b.phase + dt * 7, 1);
                }
            }
            StepMurmuration(dt, time);
        }
        void StepMurmuration(float dt, float time)
        {
            BirdAgent anchor = null;
            for (int i = 0; i < eco.population; i++)
            {
                var b = eco.birds[i];
                if (b.alive && !b.hidden && b.tier == 4 && (b.state == BirdState.Flock || b.state == BirdState.Cruise))
                {
                    anchor = b;
                    break;
                }
            }
            int count = Mathf.Clamp(Mathf.RoundToInt(eco.population * .75f), 16, 45);
            bool snap = !swarmActive || anchor != null && (anchor.position - oldCentre).sqrMagnitude > 60 * 60;
            swarmActive = anchor != null;
            var rotation = Quaternion.AngleAxis(time * .45f * Mathf.Rad2Deg, new Vector3(Mathf.Sin(time * .13f) * .6f, 1, Mathf.Cos(time * .169f) * .6f).normalized);
            for (int i = 0; i < murmuration.Length; i++)
            {
                var b = murmuration[i];
                b.alive = anchor != null && i < count;
                if (!b.alive)
                    continue;
                var slot = rotation * slots[i];
                slot.y *= .45f;
                slot += anchor.heading * Vector3.Dot(slot, anchor.heading) * .3f;
                var want = anchor.position + slot * (4.5f * (1 + .25f * Mathf.Sin(time * 1.1f + i * 2.3f)));
                if (snap)
                {
                    b.position = want;
                    b.velocity = anchor.velocity;
                }
                var velocity = Vector3.Lerp(b.velocity, (want - b.position) * 2.2f + anchor.velocity, 1 - Mathf.Exp(-dt / .35f));
                var acceleration = (velocity - b.velocity) / dt;
                b.velocity = velocity;
                b.position += velocity * dt;
                b.heading = velocity.sqrMagnitude > .01f ? velocity.normalized : anchor.heading;
                b.bank = Mathf.Clamp(-Vector3.Dot(acceleration, Vector3.Cross(b.heading, Vector3.up)) / 20, -.9f, .9f);
                b.phase = Mathf.Repeat(b.phase + dt * 1.75f, 1);
                b.flapAmount = .55f + .35f * Mathf.Sin(time * .9f + i);
            }
            if (anchor != null)
                oldCentre = anchor.position;
        }
    }
}
