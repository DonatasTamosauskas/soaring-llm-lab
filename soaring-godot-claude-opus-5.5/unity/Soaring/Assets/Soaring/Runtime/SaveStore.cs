using System;
using System.IO;
using UnityEngine;
namespace Soaring
{
    [Serializable]
    public sealed class Preferences
    {
        public int version = 1; public float master = 1, music = .35f, effects = .8f, comfort = .5f, turnSpeed = 180, reach = .75f;
        public bool haptics = true, seated = false, leftHanded = false, calibrated = false;
        public bool wristCaptured;
        public Quaternion neutralRotationLeft = Quaternion.identity, neutralRotationRight = Quaternion.identity;
        public Vector3 neutralArmLeft = Vector3.left, neutralArmRight = Vector3.right;
        public float neutralLeft, neutralRight, neutralHeading, flapPower = 1.15f, glideEfficiency = 1.15f;
        public void Sanitize()
        {
            master = Safe(master, 0, 1, 1);
            music = Safe(music, 0, 1, .35f);
            effects = Safe(effects, 0, 1, .8f);
            comfort = Safe(comfort, 0, 1, .5f);
            turnSpeed = Safe(turnSpeed, 90, 240, 180);
            reach = Safe(reach, .3f, 1.2f, .75f);
            flapPower = Safe(flapPower, .5f, 2, 1.15f);
            glideEfficiency = Safe(glideEfficiency, .5f, 2, 1.15f);
        }
        static float Safe(float v, float min, float max, float fallback) => float.IsFinite(v) ? Mathf.Clamp(v, min, max) : fallback;
    }
    [Serializable]
    public sealed class RunStats
    {
        public float duration, peakMass = .03f, apexAt = -1; public int catches, worthwhile, bestStreak, streak, caught, npcCatches, apexCatches, escapes; public bool victory;
        public int Score => Mathf.RoundToInt(peakMass * 1000) + 25 * worthwhile + (victory ? 3000 + Mathf.RoundToInt(3000 * Mathf.Clamp01(1 - duration / 3600)) : 0);
    }
    [Serializable]
    public sealed class Records
    {
        public int version = 1, bestScore, bestTier = -1, mostCatches, bestStreak, runs, victories; public float bestMass, fastestApex = -1, fastestVictory = -1;
        public void Submit(RunStats s, bool completed = false)
        {
            bestScore = Math.Max(bestScore, s.Score);
            bestMass = Math.Max(bestMass, s.peakMass);
            bestTier = Math.Max(bestTier, SizeRules.Tier(s.peakMass));
            mostCatches = Math.Max(mostCatches, s.catches);
            bestStreak = Math.Max(bestStreak, s.bestStreak);
            if (s.apexAt >= 0 && (fastestApex < 0 || s.apexAt < fastestApex))
                fastestApex = s.apexAt;
            if (completed)
            {
                runs++;
                if (s.victory)
                {
                    victories++;
                    if (fastestVictory < 0 || s.duration < fastestVictory)
                        fastestVictory = s.duration;
                }
            }
            SaveStore.Write("records", this);
        }
    }
    public static class SaveStore
    {
        public static string RootOverride;
        static string PathFor(string name) => Path.Combine(RootOverride ?? Application.persistentDataPath, name + ".json");
        public static T Read<T>(string name) where T : new()
        {
            try
            {
                var path = PathFor(name);
                return File.Exists(path) ? JsonUtility.FromJson<T>(File.ReadAllText(path)) ?? new T() : new T();
            }
            catch (Exception e) when (e is IOException || e is ArgumentException || e is UnauthorizedAccessException) { return new T(); }
        }
        public static void Write<T>(string name, T data)
        {
            try
            {
                var path = PathFor(name);
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                File.WriteAllText(path + ".tmp", JsonUtility.ToJson(data, true));
                if (File.Exists(path))
                    File.Replace(path + ".tmp", path, null);
                else
                    File.Move(path + ".tmp", path);
            }
            catch (Exception e) when (e is IOException || e is UnauthorizedAccessException) { Debug.LogWarning("SOARING_SAVE_FAILED " + e.Message); }
        }
    }
}
