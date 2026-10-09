using System;
using System.Collections;
using System.IO;
using UnityEngine;
namespace Soaring
{
    // Opt-in player harness; never runs in normal play. Exercises the actual
    // lifecycle with the real valley and pooled ecosystem and saves evidence.
    public sealed class RuntimeVerification : MonoBehaviour
    {
        public GameSession game; public bool active; string output; bool runtimeError;
        IEnumerator Start()
        {
            var args = Environment.GetCommandLineArgs();
            active = Array.Exists(args, a => a == "--verify-soaring");
            if (!active)
                yield break;
            output = Path.GetFullPath(Path.Combine(Application.dataPath, "../../../../Logs"));
            for (int i = 0; i < args.Length - 1; i++)
                if (args[i] == "--evidence")
                    output = args[i + 1];
            Application.logMessageReceived += OnLog;
            Directory.CreateDirectory(output);
            SaveStore.RootOverride = Path.Combine(output, "UserData");
            yield return new WaitUntil(() => game.ready);
            yield return new WaitForSecondsRealtime(3);
            if (!Array.Exists(args, a => a == "-no-xr"))
            {
                Require(game.input.xrRunning, "xr-display-running");
                Require(game.input.tracking, "xr-controllers-tracked");
            }
            yield return new WaitForEndOfFrame();
            ScreenCapture.CaptureScreenshot(Path.Combine(output, "01-menu.png"));
            game.input.harnessOverride = true;
            game.input.harnessWings = WingState.Neutral;
            game.input.harnessWings.leftFlap = game.input.harnessWings.rightFlap = .445f;
            game.StartRun();
            game.player.perched = false;
            game.player.model.Reset(game.world.content.spawn + Vector3.up * 10, game.world.content.spawnFacing, true);
            for (int i = 0; i < 720; i++)
            {
                yield return new WaitForFixedUpdate();
            }
            Require(float.IsFinite(game.player.model.position.sqrMagnitude), "finite-flight");
            Require(Vector3.Distance(game.player.model.position, game.world.content.spawn) > 1, "flight-movement");
            Require(game.stats.duration > 8, "flight-clock");
            int moths = 0;
            foreach (var b in game.ecosystem.birds)
                if (b.pellet && b.alive)
                    moths++;
            Require(moths > 0, "moth-food-field");
            game.Pause();
            float paused = game.stats.duration;
            float grace = game.player.protectionUntil - paused;
            yield return new WaitForSecondsRealtime(.5f);
            Require(game.stats.duration == paused, "pause-freezes-game");
            Require(game.player.protectionUntil - game.stats.duration == grace, "pause-preserves-grace");
            game.Resume();
            yield return new WaitForEndOfFrame();
            ScreenCapture.CaptureScreenshot(Path.Combine(output, "02-flight.png"));
            var bird = game.ecosystem.birds[0];
            bird.alive = true;
            bird.hidden = false;
            bird.mass = .012f;
            bird.tier = 1;
            game.Eat(bird);
            Require(game.stats.catches >= 1 && game.player.model.mass > .03f, "catch-growth");
            game.player.protectionUntil = 0;
            game.Caught("Hawk");
            Require(game.lives == 2, "life-loss");
            yield return new WaitForSecondsRealtime(2.8f);
            Require(game.phase == GamePhase.Flying, "respawn");
            for (int tier = 3; tier <= 9; tier++)
            {
                game.player.model.mass = SizeRules.Ladder[tier].mass;
                game.stats.peakMass = game.player.model.mass;
                yield return new WaitForSecondsRealtime(.12f);
            }
            game.stats.apexCatches = 2;
            bird = game.ecosystem.birds[1];
            bird.alive = true;
            bird.hidden = false;
            bird.mass = 1.3f;
            bird.tier = 8;
            game.Eat(bird);
            Require(game.phase == GamePhase.Summary && game.stats.victory, "apex-victory");
            yield return new WaitForEndOfFrame();
            ScreenCapture.CaptureScreenshot(Path.Combine(output, "03-victory.png"));
            yield return new WaitForSecondsRealtime(.5f);
            File.WriteAllText(Path.Combine(output, "runtime-verification.json"), JsonUtility.ToJson(game.stats, true));
            Require(!runtimeError, "no-runtime-errors");
            Debug.Log("SOARING_RUNTIME_VERIFICATION_OK");
            Application.Quit(0);
        }
        void OnLog(string message, string trace, LogType type)
        {
            if (type == LogType.Exception || type == LogType.Error || type == LogType.Assert)
                runtimeError = true;
        }
        void OnDestroy() => Application.logMessageReceived -= OnLog;
        static void Require(bool condition, string name)
        {
            if (!condition)
                throw new InvalidOperationException("SOARING_VERIFY_FAILED " + name);
            Debug.Log("SOARING_VERIFY_PASS " + name);
        }
    }
}
