using System;
using InputDevice = UnityEngine.XR.InputDevice;
using CommonUsages = UnityEngine.XR.CommonUsages;
using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.InputSystem.XR;
using UnityEngine.XR;
using Unity.XR.CoreUtils;
namespace Soaring
{
    public sealed class VRInput : MonoBehaviour
    {
        public XROrigin origin; public Camera eye; public Transform leftHand, rightHand, leftAim, rightAim;
        [NonSerialized] public WingState wings = WingState.Neutral; public bool xrRunning, tracking = true, leftClick, rightClick, pausePressed, recenterPressed, recalibratePressed;
        [NonSerialized] public InputDevice leftDevice, rightDevice;
        InputActionMap actions; Vector3 previousL, previousR; float bHold, recenterHold, yHold, phase, mouseYaw, mousePitch, lastL, lastR; bool priorMenu, priorPause, priorRecenter, priorY, previousTracking;
        public Action recenterRig;
        InputAction leftTriggerAction, rightTriggerAction;
        public Preferences preferences; [NonSerialized] public bool harnessOverride; [NonSerialized] public WingState harnessWings; public bool DesktopFlapping => Keyboard.current?.spaceKey.isPressed == true;
        void Awake()
        {
            preferences = SaveStore.Read<Preferences>("settings");
            preferences.Sanitize();
            // Construct the entire map before assigning direct actions to pose
            // drivers: their property setters enable the actions immediately.
            actions = new InputActionMap("Soaring XR");
            actions.AddAction("HeadPosition", InputActionType.Value, "<XRHMD>/centerEyePosition", expectedControlLayout: "Vector3");
            actions.AddAction("HeadRotation", InputActionType.Value, "<XRHMD>/centerEyeRotation", expectedControlLayout: "Quaternion");
            actions.AddAction("HeadTracking", InputActionType.Value, "<XRHMD>/trackingState", expectedControlLayout: "Integer");
            foreach (string usage in new[] { "LeftHand", "RightHand" })
            {
                string path = "<XRController>{" + usage + "}";
                actions.AddAction(usage + "Position", InputActionType.Value, path + "/devicePosition", expectedControlLayout: "Vector3");
                actions.AddAction(usage + "Rotation", InputActionType.Value, path + "/deviceRotation", expectedControlLayout: "Quaternion");
                actions.AddAction(usage + "Tracking", InputActionType.Value, path + "/trackingState", expectedControlLayout: "Integer");
                actions.AddAction(usage + "AimPosition", InputActionType.Value, path + "/pointerPosition", expectedControlLayout: "Vector3");
                actions.AddAction(usage + "AimRotation", InputActionType.Value, path + "/pointerRotation", expectedControlLayout: "Quaternion");
                actions.AddAction(usage + "AimTracking", InputActionType.Value, path + "/trackingState", expectedControlLayout: "Integer");
                foreach (string control in new[] { "trigger", "grip", "primaryButton", "secondaryButton", "menu", "thumbstick" })
                    actions.AddAction(usage + control, InputActionType.PassThrough, path + "/" + control);
            }
            leftTriggerAction = actions.FindAction("LeftHandtrigger");
            rightTriggerAction = actions.FindAction("RightHandtrigger");
            RegisterPose(eye.transform, "Head");
            RegisterPose(leftHand, "LeftHand");
            RegisterPose(rightHand, "RightHand");
            RegisterPose(leftAim, "LeftHandAim");
            RegisterPose(rightAim, "RightHandAim");
            actions.Enable();
        }
        void RegisterPose(Transform tracked, string usage)
        {
            var driver = tracked.gameObject.AddComponent<TrackedPoseDriver>();
            driver.positionInput = new InputActionProperty(actions.FindAction(usage + "Position"));
            driver.rotationInput = new InputActionProperty(actions.FindAction(usage + "Rotation"));
            driver.trackingStateInput = new InputActionProperty(actions.FindAction(usage + "Tracking"));
            driver.updateType = TrackedPoseDriver.UpdateType.UpdateAndBeforeRender;
        }
        readonly System.Collections.Generic.List<XRDisplaySubsystem> displays = new();
        void Update()
        {
            SubsystemManager.GetSubsystems(displays);
            xrRunning = displays.Exists(d => d.running);
            leftDevice = InputDevices.GetDeviceAtXRNode(XRNode.LeftHand);
            rightDevice = InputDevices.GetDeviceAtXRNode(XRNode.RightHand);
            if (xrRunning)
                SampleXR(Time.unscaledDeltaTime);
            else
                SampleDesktop(Time.unscaledDeltaTime);
            if (harnessOverride)
                wings = harnessWings;
        }
        static bool Button(InputDevice d, InputFeatureUsage<bool> usage) => d.TryGetFeatureValue(usage, out bool value) && value;
        public float Trigger(bool left)
        {
            // Use the same OpenXR action devices as the aim pose drivers.
            // This avoids a second button source through the legacy XR bridge.
            return (left ? leftTriggerAction : rightTriggerAction).ReadValue<float>();
        }
        void SampleXR(float dt)
        {
            var headDevice = InputDevices.GetDeviceAtXRNode(XRNode.Head);
            tracking = headDevice.isValid && (!headDevice.TryGetFeatureValue(CommonUsages.isTracked, out bool ht) || ht) && leftDevice.isValid && rightDevice.isValid && (!leftDevice.TryGetFeatureValue(CommonUsages.isTracked, out bool lt) || lt) && (!rightDevice.TryGetFeatureValue(CommonUsages.isTracked, out bool rt) || rt);
            var l = leftHand.localPosition - eye.transform.localPosition;
            var r = rightHand.localPosition - eye.transform.localPosition;
            float reach = preferences.reach;
            float speedL = tracking && previousTracking && dt > 0 ? -(l.y - previousL.y) / dt : 0, speedR = tracking && previousTracking && dt > 0 ? -(r.y - previousR.y) / dt : 0;
            previousTracking = tracking;
            previousL = l;
            previousR = r;
            float lp = preferences.wristCaptured ? WingPoseMath.WristPitch(preferences.neutralRotationLeft, preferences.neutralArmLeft, leftHand.localRotation, l + new Vector3(.17f, .2f, .05f), -1) : Wrist(leftHand.localRotation, -1) - preferences.neutralLeft;
            float rp = preferences.wristCaptured ? WingPoseMath.WristPitch(preferences.neutralRotationRight, preferences.neutralArmRight, rightHand.localRotation, r + new Vector3(-.17f, .2f, .05f), 1) : Wrist(rightHand.localRotation, 1) - preferences.neutralRight;
            float extL = Mathf.Clamp01(new Vector2(l.x, l.z).magnitude / reach), extR = Mathf.Clamp01(new Vector2(r.x, r.z).magnitude / reach);
            Vector3 handLine = r - l;
            Vector3 bodyForward = Vector3.Cross(handLine, Vector3.up).normalized;
            float bodySteer = Mathf.Clamp(Mathf.DeltaAngle(preferences.neutralHeading, Mathf.Atan2(bodyForward.x, bodyForward.z) * Mathf.Rad2Deg) / 65, -1, 1) * .4f;
            float flapL = tracking ? Mathf.Clamp01((speedL - .15f) / (reach * 4.2f)) : 0, flapR = tracking ? Mathf.Clamp01((speedR - .15f) / (reach * 4.2f)) : 0;
            wings = new WingState { leftExtension = extL, rightExtension = extR, leftPitch = lp, rightPitch = rp, pitch = Mathf.Clamp(.5f * (lp + rp), -1, 1), roll = Mathf.Clamp((lp - rp) * .7f + (l.y - r.y) / reach * .6f + bodySteer, -1, 1), leftFlap = flapL, rightFlap = flapR, tuck = (extL + extR) < .7f, stretch = Mathf.Clamp01((extL + extR) * .5f) };
            if (wings.tuck)
            {
                wings.leftExtension = .05f;
                wings.rightExtension = .05f;
            }
            leftClick = Trigger(true) > .5f;
            rightClick = Trigger(false) > .5f;
            bool menu = Button(leftDevice, CommonUsages.menuButton) || Button(rightDevice, CommonUsages.menuButton);
            bHold = Button(rightDevice, CommonUsages.secondaryButton) ? bHold + dt : 0;
            bool pause = menu || bHold >= .8f;
            pausePressed = pause && !priorPause;
            priorPause = pause;
            priorMenu = menu;
            recenterHold = (Button(leftDevice, CommonUsages.primaryButton) || Button(rightDevice, CommonUsages.primaryButton)) ? recenterHold + dt : 0;
            bool recenter = recenterHold >= 1;
            recenterPressed = recenter && !priorRecenter;
            priorRecenter = recenter;
            yHold = Button(leftDevice, CommonUsages.secondaryButton) ? yHold + dt : 0;
            bool y = yHold >= 1.5f;
            recalibratePressed = y && !priorY;
            priorY = y;
        }
        static float Wrist(Quaternion rotation, float side)
        {
            Vector3 normal = rotation * Vector3.up;
            return Mathf.Clamp(Mathf.Atan2(normal.z, normal.y) * Mathf.Rad2Deg / 55, -1, 1);
        }
        void SampleDesktop(float dt)
        {
            tracking = true;
            var k = Keyboard.current;
            var mouse = Mouse.current;
            float sweep = k?.leftCtrlKey.isPressed == true ? .12f : k?.xKey.isPressed == true ? -.12f : 0;
            float pitchCommand = k == null ? 0 : (k.sKey.isPressed ? 1 : 0) - (k.wKey.isPressed ? 1 : 0), roll = k == null ? 0 : (k.dKey.isPressed ? 1 : 0) - (k.aKey.isPressed ? 1 : 0);
            pitchCommand = Mathf.Clamp(pitchCommand + sweep, -1, 1);
            bool tuck = k?.leftShiftKey.isPressed == true;
            phase += dt * 1.8f;
            float flap = phase % 1 < .42f ? Mathf.Sin(Mathf.PI * (phase % 1) / .42f) : 0;
            wings = new()
            {
                leftExtension = tuck ? .08f : 1,
                rightExtension = tuck ? .08f : 1,
                pitch = pitchCommand,
                leftPitch = pitchCommand + roll * .55f,
                rightPitch = pitchCommand - roll * .55f,
                roll = roll,
                leftFlap = (k?.spaceKey.isPressed == true || k?.qKey.isPressed == true) ? flap : 0,
                rightFlap = (k?.spaceKey.isPressed == true || k?.eKey.isPressed == true) ? flap : 0,
                tuck = tuck,
                stretch = 1
            };
            if (Cursor.lockState == CursorLockMode.Locked && mouse != null)
            {
                var delta = mouse.delta.ReadValue();
                mouseYaw += delta.x * .08f;
                mousePitch = Mathf.Clamp(mousePitch - delta.y * .08f, -70, 70);
            }
            eye.transform.localPosition = new(0, preferences.seated ? 1.1f : 1.65f, 0);
            eye.transform.localRotation = Quaternion.Euler(mousePitch, mouseYaw, 0);
            float beat = Mathf.Cos(phase * Mathf.PI * 2) * .2f;
            leftHand.localPosition = eye.transform.localPosition + new Vector3(tuck ? -.15f : -reachDefault, -.25f + beat, -.12f);
            rightHand.localPosition = eye.transform.localPosition + new Vector3(tuck ? .15f : reachDefault, -.25f + beat, -.12f);
            leftHand.localRotation = Quaternion.identity;
            rightHand.localRotation = Quaternion.identity;
            pausePressed = k?.escapeKey.wasPressedThisFrame == true;
            recenterPressed = k?.rKey.wasPressedThisFrame == true;
            recalibratePressed = false;
            leftClick = mouse?.leftButton.isPressed == true;
            rightClick = false;
        }
        const float reachDefault = .65f;
        public void Recenter()
        {
            foreach (var subsystem in GetTrackingSubsystems())
                subsystem.TryRecenter();
            mouseYaw = mousePitch = 0;
            recenterRig?.Invoke();
        }
        static System.Collections.Generic.List<XRInputSubsystem> GetTrackingSubsystems()
        {
            var list = new System.Collections.Generic.List<XRInputSubsystem>();
            SubsystemManager.GetSubsystems(list);
            return list;
        }
        public bool Calibrate()
        {
            if (!xrRunning)
            {
                preferences.calibrated = true;
                Save();
                return true;
            }
            if (!tracking)
                return false;
            float span = Vector3.Distance(leftHand.localPosition, rightHand.localPosition);
            if (span < .6f)
                return false;
            var bodyForward = Vector3.Cross(rightHand.localPosition - leftHand.localPosition, Vector3.up).normalized;
            preferences.neutralHeading = Mathf.Atan2(bodyForward.x, bodyForward.z) * Mathf.Rad2Deg;
            preferences.reach = Mathf.Clamp(span * .5f, .3f, 1.2f);
            preferences.neutralLeft = Wrist(leftHand.localRotation, -1);
            preferences.neutralRight = Wrist(rightHand.localRotation, 1);
            preferences.neutralRotationLeft = leftHand.localRotation;
            preferences.neutralRotationRight = rightHand.localRotation;
            preferences.neutralArmLeft = leftHand.localPosition - eye.transform.localPosition + new Vector3(.17f, .2f, .05f);
            preferences.neutralArmRight = rightHand.localPosition - eye.transform.localPosition + new Vector3(-.17f, .2f, .05f);
            preferences.wristCaptured = true;
            preferences.calibrated = true;
            Save();
            return true;
        }
        public void Haptic(float strength, float duration = .08f)
        {
            if (!preferences.haptics || !xrRunning)
                return;
            leftDevice.SendHapticImpulse(0, Mathf.Clamp01(strength), duration);
            rightDevice.SendHapticImpulse(0, Mathf.Clamp01(strength), duration);
        }
        public void Save()
        {
            preferences.Sanitize();
            SaveStore.Write("settings", preferences);
        }
        void OnDestroy()
        {
            actions?.Dispose();
        }
    }
}
