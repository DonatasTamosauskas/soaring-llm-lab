
using UnityEngine;
using Unity.XR.CoreUtils;

namespace Soaring.Flight
{
    /// <summary>
    /// Ensures XR Origin is set up for flight: disables any Move/Teleport providers so bird flight is exclusive.
    /// Call from Bootstrap. Safe if already disabled.
    /// </summary>
    public class FlightBootstrap : MonoBehaviour
    {
        [Header("Auto-setup")]
        public bool disableXRLocomotion = true;
        public bool enableXRSimulator = true;
        public Vector3 startPosition = new Vector3(0, 20, 0);

        void Awake()
        {
            if (disableXRLocomotion) DisableLocomotion();
            if (enableXRSimulator) EnsureSimulator();
            // place player high for first flight
            var origin = FindFirstObjectByType<Unity.XR.CoreUtils.XROrigin>();
            if (origin) origin.transform.position = startPosition;
        }

        void DisableLocomotion()
        {
            // Find and disable all locomotion providers without destroying them (so they can be toggled in debug)
            foreach(var lp in FindObjectsByType<UnityEngine.XR.Interaction.Toolkit.Locomotion.LocomotionProvider>(FindObjectsSortMode.None))
                lp.enabled = false;
            foreach(var tp in FindObjectsByType<UnityEngine.XR.Interaction.Toolkit.Locomotion.Teleportation.TeleportationProvider>(FindObjectsSortMode.None))
                tp.enabled = false;
            foreach(var mv in FindObjectsByType<UnityEngine.XR.Interaction.Toolkit.Locomotion.Movement.ContinuousMoveProvider>(FindObjectsSortMode.None))
                mv.enabled = false;
            foreach(var tn in FindObjectsByType<UnityEngine.XR.Interaction.Toolkit.Locomotion.Turning.ContinuousTurnProvider>(FindObjectsSortMode.None))
                tn.enabled = false;
            foreach(var sn in FindObjectsByType<UnityEngine.XR.Interaction.Toolkit.Locomotion.Turning.SnapTurnProvider>(FindObjectsSortMode.None))
                sn.enabled = false;
        }

        void EnsureSimulator()
        {
            // Meta XR Simulator uses SimulationLoader; ensure it's in XRGeneralSettings for editor
            // We don't need to do runtime; XR Device Simulator prefab handles fallback.
            // Spawn XR Device Simulator if present in project
            var simPrefab = Resources.Load<GameObject>("XRDeviceSimulator");
            if (simPrefab && FindFirstObjectByType<UnityEngine.XR.Interaction.Toolkit.Inputs.Simulation.XRDeviceSimulator>() == null)
            {
                // only in editor
#if UNITY_EDITOR
                Instantiate(simPrefab);
                Debug.Log("[FlightBootstrap] Spawned XRDeviceSimulator for desktop testing.");
#endif
            }
        }

        [ContextMenu("Return to Start")]
        public void ReturnToStart()
        {
            var cc = GetComponent<CharacterController>();
            if (cc) cc.enabled = false;
            var origin = FindFirstObjectByType<Unity.XR.CoreUtils.XROrigin>();
            if (origin) origin.transform.position = startPosition;
            var flight = GetComponent<BirdFlightController>();
            if (flight) { flight.ForceUnperch(); }
            if (cc) cc.enabled = true;
        }
    }
}
