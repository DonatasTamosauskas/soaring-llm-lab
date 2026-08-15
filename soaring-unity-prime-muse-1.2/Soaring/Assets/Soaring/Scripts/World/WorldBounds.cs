
using UnityEngine;

namespace Soaring.World
{
    // Simple boundary visual + kill/respawn volume high above / below
    public class WorldBounds : MonoBehaviour
    {
        public Soaring.Flight.BirdFlightController flight;
        public Soaring.Flight.FlightBootstrap bootstrap;
        void Update()
        {
            if(!flight) return;
            float y = flight.transform.position.y;
            if (y < -30f || y > 120f)
            {
                bootstrap?.ReturnToStart();
                flight.ApplyPredatorImpulse(Vector3.up, 6f);
            }
            // keep inside XZ
            var p = flight.transform.position;
            if (Mathf.Abs(p.x) > 130f || Mathf.Abs(p.z) > 130f)
            {
                Vector3 dir = -new Vector3(p.x,0,p.z).normalized;
                flight.ApplyPredatorImpulse(dir*0.6f + Vector3.up*0.2f, 8f);
            }
        }
    }
}
