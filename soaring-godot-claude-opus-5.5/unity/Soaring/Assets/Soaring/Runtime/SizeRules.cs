using System;
using UnityEngine;
namespace Soaring
{
    [Serializable]
    public struct Species
    {
        public string id, name; public float mass, span; public Mesh[] lods;
        public Species(string id, string name, float mass, float span)
        {
            this.id = id;
            this.name = name;
            this.mass = mass;
            this.span = span;
            lods = null;
        }
    }
    public static class SizeRules
    {
        public const float EatRatio = 1.25f, StartMass = .03f, MaximumMass = 4.5f;
        public static readonly Species[] Ladder = {
            new("moth","Moth",.004f,.08f), new("wren","Wren",.012f,.16f),
            new("sparrow","Sparrow",.03f,.24f), new("swallow","Swallow",.055f,.33f),
            new("starling","Starling",.1f,.4f), new("pigeon","Pigeon",.3f,.66f),
            new("crow","Crow",.5f,.95f), new("gull","Gull",.85f,1.3f),
            new("hawk","Hawk",1.3f,1.6f), new("eagle","Eagle",3f,2.1f) };
        public static int Tier(float mass)
        {
            int tier = 0;
            for (int i = 0; i < Ladder.Length; i++)
                if (mass >= Ladder[i].mass * .999f)
                    tier = i;
            return tier;
        }
        public static bool CanEat(float predator, float prey) => predator >= prey * EatRatio;
        public static float Span(float mass)
        {
            mass = Mathf.Max(mass, .0001f);
            if (mass <= Ladder[0].mass)
                return Ladder[0].span * Mathf.Pow(mass / Ladder[0].mass, 1f / 3);
            for (int i = 1; i < Ladder.Length; i++)
                if (mass <= Ladder[i].mass)
                    return Mathf.Exp(Mathf.Lerp(Mathf.Log(Ladder[i - 1].span), Mathf.Log(Ladder[i].span), Mathf.Log(mass / Ladder[i - 1].mass) / Mathf.Log(Ladder[i].mass / Ladder[i - 1].mass)));
            return Ladder[^1].span * Mathf.Pow(mass / Ladder[^1].mass, 1f / 3);
        }
        public static float Smooth(float lo, float hi, float value)
        {
            float x = Mathf.Clamp01((value - lo) / (hi - lo));
            return x * x * (3 - 2 * x);
        }
        public static float MealValue(float eater, float prey) => CanEat(eater, prey) ? .8f * prey / eater * Smooth(.03f, .25f, prey / eater) : 0;
        public static bool Worthwhile(float eater, float prey) => MealValue(eater, prey) >= .02f;
        public static float MealGain(float eater, float prey) => MealValue(eater, prey) * eater * 1.8f * Mathf.Min(1, Mathf.Pow(eater / .03f, -.42f));
        public static float Cruise(float mass) => 9 * Mathf.Pow(Mathf.Max(mass, .0001f) / .03f, 1f / 6);
        public static float TurnRate(float mass) => 220 * Mathf.Deg2Rad * Mathf.Pow(mass / .03f, -.26f);
        public static float Climb(float mass) => 4 * Mathf.Pow(mass / .03f, -.09f);
        public static float TimeScale(float mass) => Mathf.Clamp(Span(mass) / .24f / (Cruise(mass) / 9), 1, 4);
    }
}
