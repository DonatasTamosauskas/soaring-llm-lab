using System;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.InputSystem;
namespace Soaring
{
    public enum GamePhase
    {
        Menu, Calibration, Flying, Paused, Caught, Summary
    }
    [DefaultExecutionOrder(100)]
    public sealed class GameSession : MonoBehaviour
    {
        public PlayerFlight player; public Ecosystem ecosystem; public ValleyWorld world; public VRInput input; public SoaringUI ui; public FlightAudio audio; public FlightEffects effects;
        public GamePhase phase = GamePhase.Menu; public RunStats stats = new(); public Records records; public int lives = 3, lesson; public bool endless; [NonSerialized] public bool ready;
        public float sinceCatch, catchAssist, dangerAssist; float beatUntil, handlingUntil, lastTierAt = -30, nextAttack = 75, lessonProgress;
        public float LessonCompletion => Mathf.Clamp01(lessonProgress / (lesson == 1 ? .1f : lesson == 6 ? .01f : .7f));
        float lostTracking;
        bool submitted; public string caughtBy = ""; struct Contact
        {
            public BirdAgent predator, prey; public bool playerPredator, playerPrey; public float time;
        }
        readonly List<Contact> contacts = new(400); static readonly Comparison<Contact> byTime = (a, b) => a.time.CompareTo(b.time);
        public void Initialize()
        {
            records = SaveStore.Read<Records>("records");
            player.Spawn(true);
            ecosystem.Initialize();
            ui.Show(phase);
        }
        public void Play()
        {
            if (input.xrRunning && !input.preferences.calibrated)
            {
                phase = GamePhase.Calibration;
                ui.Show(phase);
            }
            else
                StartRun();
        }
        public void StartRun()
        {
            stats = new();
            lives = 3;
            lesson = 0;
            lessonProgress = 0;
            submitted = false;
            endless = false;
            sinceCatch = dangerAssist = catchAssist = 0;
            lastTierAt = -30;
            handlingUntil = 0;
            nextAttack = 75;
            player.Spawn(true);
            ecosystem.ResetPopulation();
            phase = GamePhase.Flying;
            ui.Show(phase);
            input.Haptic(.25f);
            audio.Cue("start");
        }
        public void Pause()
        {
            if (phase == GamePhase.Flying)
            {
                phase = GamePhase.Paused;
                ui.Show(phase);
                SaveProgress();
            }
            else if (phase == GamePhase.Paused)
                Resume();
        }
        public void Resume()
        {
            phase = GamePhase.Flying;
            ui.Show(phase);
        }
        public void Menu()
        {
            if (phase != GamePhase.Menu && phase != GamePhase.Calibration)
                Complete(false);
            phase = GamePhase.Menu;
            player.Spawn(true);
            ecosystem.ResetPopulation();
            ui.Show(phase);
        }
        public void Continue()
        {
            endless = true;
            phase = GamePhase.Flying;
            player.protectionUntil = stats.duration + 5;
            ui.Show(phase);
        }
        public void Calibrated()
        {
            if (input.Calibrate())
            {
                input.Haptic(.4f);
                StartRun();
            }
            else
                ui.Notice("Spread both wings and hold still");
        }
        public void SkipCalibration()
        {
            input.preferences.calibrated = true;
            input.Save();
            StartRun();
        }
        public void Caught(string species)
        {
            if (phase != GamePhase.Flying || stats.duration < player.protectionUntil)
                return;
            caughtBy = species;
            stats.caught++;
            stats.streak = 0;
            lives--;
            dangerAssist = Mathf.Clamp01(dangerAssist + .5f);
            player.model.mass = Mathf.Max(SizeRules.StartMass, player.model.mass * (1 - .3f * (1 - .5f * dangerAssist)));
            phase = GamePhase.Caught;
            beatUntil = Time.unscaledTime + 2.5f;
            foreach (var b in ecosystem.birds)
                b.attacking = false;
            nextAttack = stats.duration + 60;
            input.Haptic(.75f, .22f);
            audio.Cue("caught");
            ui.Show(phase);
        }
        void Update()
        {
            if (!ready)
                return;
            if (phase == GamePhase.Flying && input.xrRunning && !input.tracking)
            {
                lostTracking += Time.unscaledDeltaTime;
                if (lostTracking > 1.5f)
                {
                    Pause();
                    ui.Notice("Tracking lost · check your headset and controllers");
                }
            }
            else
                lostTracking = 0;
            if (input.pausePressed)
                Pause();
            if (input.recenterPressed)
            {
                input.Recenter();
                ui.Recenter();
                ui.Notice("View recentered");
            }
            if (input.recalibratePressed && phase == GamePhase.Flying)
            {
                Pause();
                ui.CalibrationPanel();
            }
            if (phase == GamePhase.Caught && Time.unscaledTime >= beatUntil)
            {
                if (lives <= 0)
                    Complete(false);
                else
                {
                    player.Spawn();
                    player.protectionUntil = stats.duration + 5 + 10 * dangerAssist;
                    phase = GamePhase.Flying;
                    ui.Show(phase);
                }
            }
        }
        void FixedUpdate()
        {
            if (!ready || phase != GamePhase.Flying || input.xrRunning && !input.tracking)
                return;
            float dt = Time.fixedDeltaTime;
            stats.duration += dt;
            sinceCatch += dt;
            dangerAssist = Mathf.Max(0, dangerAssist - dt / 180);
            catchAssist = SizeRules.Smooth(30, 120, sinceCatch);
            if (SizeRules.Tier(player.model.mass) == 9 && stats.apexAt < 0)
                stats.apexAt = stats.duration;
            if (stats.duration >= nextAttack && SizeRules.Tier(player.model.mass) < 9)
            {
                ecosystem.SendAttacker();
                float size = SizeRules.Tier(player.model.mass) / 9f;
                nextAttack = stats.duration + 110 * Mathf.Lerp(1, .55f, size) * (1 + dangerAssist * 2);
            }
            ResolveContacts();
            UpdateLesson(dt);
            if (ecosystem.threatLevel > .25f && Time.frameCount % 35 == 0)
                input.Haptic(.1f + ecosystem.threatLevel * .2f, .05f);
        }
        void ResolveContacts()
        {
            contacts.Clear();
            foreach (var b in ecosystem.birds)
            {
                if (!b.alive || b.hidden)
                    continue;
                if (SizeRules.CanEat(player.model.mass, b.mass) && stats.duration >= handlingUntil && !world.Protected(b.position, player.Span))
                {
                    float contact = CatchRule.ContactDistance(player.model.mass, b.mass, true, catchAssist), overlap = (player.Radius + b.Radius) * .6f;
                    float time = CatchRule.ContactTime(player.previousPosition, player.model.position, b.previous, b.position, contact, overlap, player.model.Forward, player.model.velocity.normalized, 80 + 10 * catchAssist);
                    if (time >= 0 && world.Clear(player.model.position, b.position, .001f))
                        contacts.Add(new()
                        {
                            playerPredator = true,
                            prey = b,
                            time = time
                        });
                }
                if (b.attacking && SizeRules.CanEat(b.mass, player.model.mass) && stats.duration >= player.protectionUntil && !world.Protected(player.model.position, b.Span))
                {
                    float contact = CatchRule.ContactDistance(b.mass, player.model.mass, false, 0, true) * (1 - .5f * dangerAssist);
                    float time = CatchRule.ContactTime(b.previous, b.position, player.previousPosition, player.model.position, contact, -1, b.heading, Vector3.zero, 55 - 20 * dangerAssist, false);
                    if (time >= 0)
                        contacts.Add(new()
                        {
                            predator = b,
                            playerPrey = true,
                            time = time
                        });
                }
            }
            for (int i = 0; i < ecosystem.population; i++)
            {
                var p = ecosystem.birds[i];
                if (!p.alive || p.hidden || p.handlingUntil > stats.duration)
                    continue;
                for (int j = 0; j < ecosystem.birds.Length; j++)
                {
                    var q = ecosystem.birds[j];
                    if (p == q || !q.alive || q.hidden || !SizeRules.CanEat(p.mass, q.mass) || world.Protected(q.position, p.Span))
                        continue;
                    float contact = CatchRule.ContactDistance(p.mass, q.mass, false);
                    if ((p.position - q.position).sqrMagnitude > Mathf.Pow(contact + (p.velocity - q.velocity).magnitude * Time.fixedDeltaTime, 2))
                        continue;
                    float time = CatchRule.ContactTime(p.previous, p.position, q.previous, q.position, contact, (p.Radius + q.Radius) * .6f, p.heading, Vector3.zero, 55, false);
                    if (time >= 0 && world.Clear(p.position, q.position, .001f))
                        contacts.Add(new()
                        {
                            predator = p,
                            prey = q,
                            time = time
                        });
                }
            }
            contacts.Sort(byTime);
            foreach (var c in contacts)
            {
                if (phase != GamePhase.Flying)
                    break;
                if (c.playerPredator)
                {
                    if (!c.prey.alive || stats.duration < handlingUntil || !SizeRules.CanEat(player.model.mass, c.prey.mass))
                        continue;
                    Eat(c.prey);
                }
                else if (c.playerPrey)
                {
                    if (c.predator.alive && SizeRules.CanEat(c.predator.mass, player.model.mass))
                        Caught(SizeRules.Ladder[c.predator.tier].name);
                }
                else
                {
                    if (!c.predator.alive || !c.prey.alive || c.predator.handlingUntil > stats.duration || !SizeRules.CanEat(c.predator.mass, c.prey.mass))
                        continue;
                    c.predator.mass += Mathf.Min(c.predator.mass * .04f, SizeRules.MealGain(c.predator.mass, c.prey.mass) * .5f);
                    c.predator.tier = SizeRules.Tier(c.predator.mass);
                    c.predator.handlingUntil = stats.duration + 1.2f;
                    ecosystem.Remove(c.prey);
                    stats.npcCatches++;
                }
            }
        }
        public void Eat(BirdAgent prey)
        {
            bool worthwhile = SizeRules.Worthwhile(player.model.mass, prey.mass);
            int tierBefore = SizeRules.Tier(player.model.mass);
            float gain = SizeRules.MealGain(player.model.mass, prey.mass) * Mathf.Pow(60f / Mathf.Max(ecosystem.population, 1), .08f);
            float mass = Mathf.Min(SizeRules.MaximumMass, player.model.mass + gain);
            if (stats.duration - lastTierAt < 30 && tierBefore < 9)
                mass = Mathf.Min(mass, SizeRules.Ladder[tierBefore + 1].mass * .99f);
            player.model.mass = Mathf.Max(player.model.mass, mass);
            stats.catches++;
            stats.streak++;
            stats.bestStreak = Mathf.Max(stats.streak, stats.bestStreak);
            stats.peakMass = Mathf.Max(stats.peakMass, player.model.mass);
            if (worthwhile)
            {
                stats.worthwhile++;
                if (stats.worthwhile % 5 == 0 && lives < 3)
                {
                    lives++;
                    ui.Notice("A life restored");
                }
                if (tierBefore == 9)
                    stats.apexCatches++;
            }
            int tierAfter = SizeRules.Tier(player.model.mass);
            if (tierAfter > tierBefore)
            {
                lastTierAt = stats.duration;
                lives = Mathf.Min(3, lives + 1);
                player.protectionUntil = stats.duration + 3;
                ui.Notice("You are a " + SizeRules.Ladder[tierAfter].name);
                audio.Cue("grow");
                input.Haptic(.55f, .15f);
                SaveProgress();
            }
            effects.Burst(prey.position, prey.Span);
            ecosystem.Remove(prey);
            audio.Cue("catch");
            input.Haptic(.35f, .1f);
            sinceCatch = 0;
            handlingUntil = stats.duration + Mathf.Max(.2f, Mathf.Min(1.2f, 2.5f * gain / Mathf.Max(player.model.mass, .0001f)));
            if (stats.apexCatches >= 3 && !endless)
                Complete(true);
        }
        void UpdateLesson(float dt)
        {
            var w = input.wings;
            bool met = lesson switch
            {
                0 => w.Spread > .8f,
                1 => w.leftFlap + w.rightFlap > .35f,
                2 => !player.perched && w.Spread > .8f && w.leftFlap + w.rightFlap < .1f,
                3 => Mathf.Abs(w.pitch) > .35f,
                4 => Mathf.Abs(w.roll) > .35f,
                5 => w.tuck,
                6 => stats.catches > 0,
                _ => false
            };
            lessonProgress = met ? lessonProgress + dt : Mathf.Max(0, lessonProgress - dt * .5f);
            if (lessonProgress > (lesson == 1 ? .1f : lesson == 6 ? .01f : .7f))
            {
                lesson++;
                lessonProgress = 0;
                audio.Cue("lesson");
            }
        }
        public void Complete(bool won)
        {
            if (phase == GamePhase.Menu)
                return;
            stats.victory |= won;
            if (!submitted)
            {
                records.Submit(stats, true);
                submitted = true;
            }
            else
                records.Submit(stats);
            phase = GamePhase.Summary;
            ui.Show(phase);
            audio.Cue(won ? "victory" : "end");
        }
        void SaveProgress()
        {
            if (records != null && stats.duration > 0)
                records.Submit(stats);
            input.Save();
        }
        void OnApplicationPause(bool paused)
        {
            if (paused)
            {
                if (phase == GamePhase.Flying)
                    Pause();
                SaveProgress();
            }
        }
        void OnApplicationFocus(bool focused)
        {
            if (!focused && phase == GamePhase.Flying && !input.harnessOverride && (!input.xrRunning || Application.platform == RuntimePlatform.Android))
                Pause();
        }
        void OnApplicationQuit() => SaveProgress();
    }
}
