using UnityEngine;
namespace Soaring
{
    public enum BirdState
    {
        Cruise, Flock, Soar, Hunt, Flee, Rest, Hide
    }
    public sealed class BirdAgent
    {
        public int id, tier, flock; public float mass, stamina = 1, phase, handlingUntil, stateUntil, thinkAt, attackUntil, committedUntil;
        public Vector3 position, previous, velocity, goal, heading = Vector3.forward; public float bank, fold, flapAmount; public bool alive, hidden, attacking, pellet;
        public BirdState state; public BirdAgent target; public Perch perch; public Vector3 committedHeading;
        public float Span => SizeRules.Span(mass); public float Radius => Span * .16f;
    }
}
