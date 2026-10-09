using System;
using System.Collections;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.XR;
using UnityEngine.XR.Management;
using UnityEngine.XR.OpenXR;
namespace Soaring
{
    public sealed class SoaringBootstrap : MonoBehaviour
    {
        public GameSession game;
        public IEnumerator Start()
        {
            // Simulator input lives in a separate native window on macOS.
            // Real headset focus transitions are handled by GameSession.
            Application.runInBackground = true;
            bool desktop = Array.Exists(Environment.GetCommandLineArgs(), a => a == "-no-xr");
            if (!desktop)
            {
                var manager = XRGeneralSettings.Instance?.Manager;
                if (manager != null)
                {
                    yield return manager.InitializeLoader();
                    if (manager.activeLoader != null)
                        manager.StartSubsystems();
                }
            }
            // A running XR display can precede the first valid HMD pose by
            // several seconds. Anchor only after tracking is ready, then let
            // the XROrigin settle its requested floor tracking space.
            if (!desktop && XRGeneralSettings.Instance?.Manager.activeLoader != null)
            {
                float deadline = Time.realtimeSinceStartup + 10;
                while (Time.realtimeSinceStartup < deadline)
                {
                    var head = InputDevices.GetDeviceAtXRNode(XRNode.Head);
                    if (head.isValid && head.TryGetFeatureValue(CommonUsages.isTracked, out bool tracked) && tracked)
                        break;
                    yield return null;
                }
            }
            game.input.origin.enabled = true;
            yield return null;
            yield return null;
            game.input.recenterRig = game.player.RecenterRig;
            QualitySettings.vSyncCount = 0;
            Application.targetFrameRate = 72;
            Time.fixedDeltaTime = 1f / 72;
            Time.maximumDeltaTime = .08f;
            if (Application.platform == RuntimePlatform.Android)
            {
                var displays = new System.Collections.Generic.List<XRDisplaySubsystem>();
                SubsystemManager.GetSubsystems(displays);
                foreach (var display in displays)
                    display.foveatedRenderingLevel = .5f;
            }
            game.audio.Initialize();
            game.effects.Initialize();
            game.ui.Initialize();
            game.Initialize();
            game.ready = true;
            Debug.Log("SOARING_READY Unity=" + Application.unityVersion + " population=" + game.ecosystem.population);
            InvokeRepeating(nameof(LogXR), 2, 20);
        }
        void OnApplicationQuit()
        {
            CancelInvoke();
            game.input.origin.enabled = false;
            var manager = XRGeneralSettings.Instance?.Manager;
            if (manager?.activeLoader != null)
            {
                manager.StopSubsystems();
                manager.DeinitializeLoader();
            }
        }
        void LogXR()
        {
            var list = new System.Collections.Generic.List<XRDisplaySubsystem>();
            SubsystemManager.GetSubsystems(list);
            foreach (var display in list)
                if (display.running)
                {
                    Debug.Log("SOARING_TRACKING head=" + game.input.eye.transform.localPosition + " hands=" + game.input.tracking);
                    Debug.Log("SOARING_XR_RUNNING runtime=" + OpenXRRuntime.name + " version=" + OpenXRRuntime.version + " loader=" + XRGeneralSettings.Instance.Manager.activeLoader?.name);
                    var devices = new System.Collections.Generic.List<InputDevice>();
                    InputDevices.GetDevices(devices);
                    foreach (var d in devices)
                        Debug.Log("SOARING_XR_DEVICE " + d.name + " " + d.characteristics);
                    return;
                }
            Debug.Log("SOARING_DESKTOP_READY");
        }
    }
}
