using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.XR;
using UnityEngine.XR.Management;
using UnityEngine.XR.OpenXR;

// Keep diagnostics in the example so a rendered flat camera cannot be mistaken for XR success.
public sealed class QuestRuntimeDiagnostics : MonoBehaviour
{
    IEnumerator Start()
    {
        for (int attempt = 0; attempt < 30; attempt++)
        {
            var displays = new List<XRDisplaySubsystem>();
            SubsystemManager.GetSubsystems(displays);
            if (displays.Exists(d => d.running))
            {
                var devices = new List<InputDevice>();
                InputDevices.GetDevices(devices);
                Debug.Log("QUEST_BOOTSTRAP_XR_RUNNING loader=" + XRGeneralSettings.Instance.Manager.activeLoader?.name +
                    " runtime=" + OpenXRRuntime.name + " version=" + OpenXRRuntime.version);
                foreach (var device in devices) Debug.Log("QUEST_BOOTSTRAP_DEVICE " + device.name + " " + device.characteristics);
                yield break;
            }
            yield return new WaitForSecondsRealtime(1);
        }
        Debug.LogError("QUEST_BOOTSTRAP_XR_FAILED: no running XR display after 30 seconds. Check runtime activation and the Unity OpenXR log.");
    }
}
