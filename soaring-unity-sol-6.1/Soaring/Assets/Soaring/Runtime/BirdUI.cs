using System;
using System.Collections.Generic;
using System.Reflection;
using System.Text.RegularExpressions;
using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.UI;
using UnityEngine.XR;
using InputDevice = UnityEngine.XR.InputDevice;
using CommonUsages = UnityEngine.XR.CommonUsages;

namespace Soaring
{
    /// <summary>Self-contained, world-space UI. Both pointer and focus input work without an XR prefab.</summary>
    public sealed class BirdUI : MonoBehaviour
    {
        public GameSession Session;
        public BirdPlayer Player;
        public bool MenuOpen { get; private set; }
        public string CurrentPage => page;
        public bool CalibrationPending => calibrationCaptureAt > 0;

        readonly Color ink = new Color(.055f, .105f, .16f, .97f);
        readonly Color card = new Color(.12f, .21f, .29f, 1);
        readonly Color cyan = new Color(.34f, .92f, .89f, 1);
        readonly Color white = new Color(.92f, .97f, 1, 1);
        readonly List<Control> controls = new List<Control>();
        readonly List<FieldInfo> fields = new List<FieldInfo>();
        RectTransform panel, hud, progressFill;
        Text hudStats, hudGoal, hudThreat, title, subtitle, footer, countdown;
        Font font;
        Material readableUI;
        string page = "home";
        string note = "";
        int focus, tuningPage;
        int pointerHovered = -1;
        float calibrationCaptureAt, nextHudUpdate, nextStick;
        bool captureExtended, previousSelect, previousMenu, observedDead, observedWin;
        bool built;
        bool firstUpdate = true;
        LineRenderer ray;
        RectTransform pointer;
        Camera viewCamera;
        int previousCatches;
        BirdAudio audioFeedback;

        sealed class Control
        {
            public RectTransform Rect;
            public Image Background;
            public Text Label;
            public Action Select;
            public Action<float> Adjust;
            public Func<string> Caption;
        }

        public void Build()
        {
            if (built) return;
            built = true;
            font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");
            readableUI=new Material(Shader.Find("Soaring/UI Always Visible"));
            Player.HapticsEnabled = PlayerPrefs.GetInt("Soaring.Haptics", 1) != 0;
            Player.ComfortVignette = PlayerPrefs.GetInt("Soaring.Vignette", 1) != 0;
            viewCamera = Player.Head.GetComponent<Camera>();
            if (!viewCamera) viewCamera = Camera.main;
            panel = CreateCanvas("Soaring menu", new Vector2(960, 770), null);
            ImageAt(panel, "Panel", new Vector2(0, 0), new Vector2(960, 770), ink);
            ImageAt(panel, "Accent", new Vector2(0, 376), new Vector2(960, 8), cyan);
            title = TextAt(panel, "Title", "", new Vector2(0, 310), new Vector2(850, 74), 47, white);
            subtitle = TextAt(panel, "Subtitle", "", new Vector2(0, 245), new Vector2(850, 74), 22, new Color(.65f, .81f, .88f));
            footer = TextAt(panel, "Input help", "Point + trigger  /  stick + A or X    •    Menu / B / Y to close", new Vector2(0, -352), new Vector2(890, 32), 18, new Color(.57f, .72f, .79f));
            hud = CreateCanvas("Flight HUD", new Vector2(820, 142), Player.Head);
            hud.localPosition = new Vector3(0, -.39f, 1.5f);
            hud.localRotation = Quaternion.identity;
            ImageAt(hud, "HUD backdrop", Vector2.zero, new Vector2(820, 142), new Color(.035f, .09f, .13f, .76f));
            hudStats = TextAt(hud, "Stats", "", new Vector2(0, 36), new Vector2(780, 34), 25, white);
            hudGoal = TextAt(hud, "Goal", "", new Vector2(0, 0), new Vector2(780, 34), 21, cyan);
            hudThreat = TextAt(hud, "Threat", "", new Vector2(0, -40), new Vector2(780, 28), 21, new Color(1, .7f, .35f));
            ImageAt(hud, "Growth track", new Vector2(0, -67), new Vector2(820, 5), new Color(.22f, .35f, .4f));
            progressFill = ImageAt(hud, "Growth", new Vector2(-410, -67), new Vector2(1, 5), cyan).rectTransform;
            progressFill.pivot = new Vector2(0, .5f);
            pointer = ImageAt(panel, "Pointer", Vector2.zero, new Vector2(14, 14), cyan).rectTransform;
            pointer.gameObject.SetActive(false);
            var rayObject = new GameObject("Menu controller ray");
            rayObject.transform.SetParent(transform);
            ray = rayObject.AddComponent<LineRenderer>();
            ray.positionCount = 2;
            ray.startWidth = .002f;
            ray.endWidth = .0035f;
            ray.material = new Material(Shader.Find("Universal Render Pipeline/Unlit") ?? Shader.Find("Sprites/Default"));
            ray.startColor = new Color(.3f, .9f, .9f, .35f);
            ray.endColor = cyan;
            ray.enabled = false;
            audioFeedback = gameObject.AddComponent<BirdAudio>();
            Session.Changed += SessionChanged;
            foreach (var field in Player.Tuning.GetType().GetFields(BindingFlags.Public | BindingFlags.Instance))
                if (field.FieldType == typeof(float) && Attribute.IsDefined(field, typeof(RangeAttribute))) fields.Add(field);
            Show("home");
        }

        void OnDestroy()
        {
            if (Session != null) Session.Changed -= SessionChanged;
            if(readableUI)Destroy(readableUI);
            if (ray && ray.sharedMaterial) Destroy(ray.sharedMaterial);
        }

        void SessionChanged()
        {
            if (!built) return;
            if (Session.Catches > previousCatches)
            {
                audioFeedback.Catch();
                Player.Haptic(.4f, .12f);
            }
            previousCatches = Session.Catches;
            if (Session.IsDead && !observedDead) { observedDead = true; Show("death"); audioFeedback.Death(); }
            else if (Session.HasWon && !observedWin) { observedWin = true; Show("victory"); audioFeedback.Victory(); }
        }

        void Update()
        {
            if (!built) return;
            if (firstUpdate) { firstUpdate = false; Show(page); }
            if (Time.unscaledTime >= nextHudUpdate) { nextHudUpdate = Time.unscaledTime + .12f; RefreshHud(); }
            if (!Player.DesktopMode && !Player.TrackingValid && Session.IsPlaying && !MenuOpen)
            {
                note = "Tracking lost. Reconnect your controllers, then resume.";
                Show("pause");
            }
            var left = InputDevices.GetDeviceAtXRNode(XRNode.LeftHand);
            var right = InputDevices.GetDeviceAtXRNode(XRNode.RightHand);
            bool menuPressed = Feature(left, CommonUsages.menuButton) || Feature(left, CommonUsages.secondaryButton) || Feature(right, CommonUsages.secondaryButton);
            var keyboard = Keyboard.current;
            bool escape = keyboard != null && keyboard.escapeKey.wasPressedThisFrame;
            if ((menuPressed && !previousMenu) || escape)
            {
                if (MenuOpen && Session.IsPlaying && !Session.IsDead && !Session.HasWon && !CalibrationPending) Close();
                else if (!MenuOpen) Show("pause");
                else if (!CalibrationPending) Show("home");
            }
            previousMenu = menuPressed;
            if (!MenuOpen) { previousSelect = false; return; }
            if (calibrationCaptureAt > 0)
            {
                float remaining = calibrationCaptureAt - Time.unscaledTime;
                if (countdown) countdown.text = remaining > 0 ? "Hold this pose…  " + Mathf.CeilToInt(remaining) : "Capturing…";
                if (remaining <= 0) CaptureCalibration();
                return;
            }
            int hovered = PointerTarget(left, right);
            Vector2 stick = Axis(left);
            if (stick.sqrMagnitude < .1f) stick = Axis(right);
            if (Time.unscaledTime >= nextStick && stick.sqrMagnitude > .3f)
            {
                if (Mathf.Abs(stick.y) >= Mathf.Abs(stick.x)) MoveFocus(stick.y > 0 ? -1 : 1);
                else if (controls.Count > 0) AdjustFocus(Mathf.Sign(stick.x));
                nextStick = Time.unscaledTime + .21f;
            }
            if (keyboard != null)
            {
                if (keyboard.downArrowKey.wasPressedThisFrame || keyboard.tabKey.wasPressedThisFrame) MoveFocus(1);
                if (keyboard.upArrowKey.wasPressedThisFrame) MoveFocus(-1);
                if (keyboard.leftArrowKey.wasPressedThisFrame) AdjustFocus(-1);
                if (keyboard.rightArrowKey.wasPressedThisFrame) AdjustFocus(1);
            }
            bool trigger = Feature(left, CommonUsages.triggerButton) || Feature(right, CommonUsages.triggerButton);
            bool pressed = Feature(left, CommonUsages.primaryButton) || Feature(right, CommonUsages.primaryButton) || trigger;
            bool activate = pressed && !previousSelect;
            bool pointerActivation = trigger;
            previousSelect = pressed;
            if (keyboard != null && (keyboard.enterKey.wasPressedThisFrame || keyboard.spaceKey.wasPressedThisFrame)) activate = true;
            var mouse = Mouse.current;
            if (mouse != null && mouse.leftButton.wasPressedThisFrame && hovered >= 0) { activate = true; pointerActivation = true; }
            if (activate && controls.Count > 0)
            {
                // Focus selection remains available when the controller is relaxed away from the panel.
                int chosen = pointerActivation && hovered >= 0 ? hovered : focus;
                var chosenControl = controls[chosen];
                var action = chosenControl.Select;
                audioFeedback.Click();
                Player.Haptic(.16f, .035f);
                if (pointerActivation && hovered >= 0 && chosenControl.Adjust != null)
                {
                    float x = chosenControl.Rect.InverseTransformPoint(pointer.position).x;
                    chosenControl.Adjust(x < 0 ? -1 : 1);
                    RefreshCaptions();
                }
                else action?.Invoke();
            }
            Highlight();
        }

        static bool Feature(InputDevice device, InputFeatureUsage<bool> usage) => device.TryGetFeatureValue(usage, out bool value) && value;
        static Vector2 Axis(InputDevice device) => device.TryGetFeatureValue(CommonUsages.primary2DAxis, out Vector2 value) ? value : Vector2.zero;

        int PointerTarget(InputDevice left, InputDevice right)
        {
            int hovered = -1;
            Vector2 local;
            bool hasPoint = false;
            if (Player.DesktopMode && Mouse.current != null && viewCamera)
            {
                var mouse = Mouse.current;
                hasPoint = RectTransformUtility.ScreenPointToLocalPointInRectangle(panel, mouse.position.ReadValue(), viewCamera, out local);
                ray.enabled = false;
            }
            else
            {
                Transform hand = right.isValid ? Player.RightHand : Player.LeftHand;
                var direction = hand.forward;
                var plane = new Plane(panel.forward, panel.position);
                var inputRay = new Ray(hand.position, direction);
                if (plane.Raycast(inputRay, out float distance) && distance < 6 * Player.Size)
                {
                    local = panel.InverseTransformPoint(inputRay.GetPoint(distance));
                    hasPoint = panel.rect.Contains(local);
                    ray.SetPosition(0, hand.position);
                    ray.SetPosition(1, inputRay.GetPoint(distance));
                }
                else { local = Vector2.zero; ray.SetPosition(0, hand.position); ray.SetPosition(1, hand.position + direction * 2 * Player.Size); }
                ray.enabled = hasPoint;
            }
            if (hasPoint)
            {
                for (int i = 0; i < controls.Count; i++)
                {
                    Vector3 world = panel.TransformPoint(local);
                    Vector2 point = controls[i].Rect.InverseTransformPoint(world);
                    if (controls[i].Rect.rect.Contains(point)) { hovered = i; break; }
                }
                pointer.anchoredPosition = local;
            }
            pointer.gameObject.SetActive(hasPoint);
            pointer.SetAsLastSibling();
            pointerHovered = hovered;
            return hovered;
        }

        void MoveFocus(int step) { if (controls.Count > 0) focus = (focus + step + controls.Count) % controls.Count; }
        void AdjustFocus(float direction)
        {
            if (controls.Count == 0) return;
            controls[focus].Adjust?.Invoke(direction);
            if (controls[focus].Caption != null) controls[focus].Label.text = controls[focus].Caption();
        }
        void Highlight()
        {
            for (int i = 0; i < controls.Count; i++)
            {
                controls[i].Background.color = i == focus ? new Color(.18f, .42f, .48f) : i == pointerHovered ? new Color(.18f, .32f, .39f) : card;
                controls[i].Label.color = i == focus ? cyan : white;
            }
        }

        public void Show(string destination)
        {
            page = destination;
            MenuOpen = true;
            Session.Pause(true);
            panel.gameObject.SetActive(true);
            hud.gameObject.SetActive(false);
            var forward = Vector3.ProjectOnPlane(Player.Head.forward, Vector3.up).normalized;
            if (forward.sqrMagnitude < .1f) forward = Vector3.forward;
            float size = Mathf.Max(1, Player.Size);
            panel.position = Player.Head.position + forward * (1.8f * size) + Vector3.down * (.08f * size);
            panel.rotation = Quaternion.LookRotation(forward, Vector3.up);
            panel.localScale = Vector3.one * (.0016f * size);
            BuildPage();
        }

        public void Close()
        {
            if(Session.IsDead){Show("death");return;}
            if(Session.HasWon){Show("victory");return;}
            if (!Player.IsCalibrated) { Show("calibrateRelaxed"); return; }
            if (!Player.DesktopMode && !Player.TrackingValid) { note = "Controllers are not tracked yet."; Show("pause"); return; }
            MenuOpen = false;
            panel.gameObject.SetActive(false);
            ray.enabled = false;
            hud.gameObject.SetActive(true);
            Session.Pause(false);
        }

        void BuildPage()
        {
            foreach (var item in controls) Destroy(item.Rect.gameObject);
            controls.Clear();
            for (int i = panel.childCount - 1; i >= 0; i--) if (panel.GetChild(i).name.StartsWith("Page ")) Destroy(panel.GetChild(i).gameObject);
            focus = 0;
            pointerHovered = -1;
            countdown = null;
            subtitle.text = note;
            footer.text = Player.DesktopMode ? "Arrow keys to focus / tune  •  Enter selects  •  Mouse clicks  •  Escape menu" : "Point + trigger  /  stick + A or X    •    Menu / B / Y to close";
            switch (page)
            {
                case "home":
                    title.text = "SOARING";
                    subtitle.text = "Your arms are wings. The sky is a food chain.";
                    Body("Catch smaller birds. Escape the larger ones.\nGrow until the whole valley fits beneath your wings.", 147, 24);
                    Button(Player.IsCalibrated ? "Take flight" : "Set up my wings", 40, () => { if (Player.IsCalibrated) StartFlight(); else Show("calibrateRelaxed"); });
                    Button("How to fly", -40, () => Show("help"));
                    Button("Settings", -120, () => Show("settings"));
                    Button("Flight lab  •  developer tuning", -200, () => Show("tuning"));
                    Body("Designed for standing or seated play. Keep your arms clear.", -283, 19);
                    break;
                case "pause":
                    title.text = "A MOMENT IN THE SKY";
                    subtitle.text = string.IsNullOrEmpty(note) ? "Take a breath. The valley is paused." : note;
                    Button("Resume flight", 120, Close);
                    Button("How to fly", 40, () => Show("help"));
                    Button("Settings & calibration", -40, () => Show("settings"));
                    Button("Flight lab  •  developer tuning", -120, () => Show("tuning"));
                    Button("Restart run", -200, () => Show("restart"));
                    break;
                case "restart":
                    title.text = "A FRESH PAIR OF WINGS";
                    subtitle.text = "Start again as a small bird. Keep your flight settings.";
                    Button("Restart run", 30, Restart);
                    Button("Keep flying", -60, Close);
                    break;
                case "help":
                    title.text = "FLY WITH YOUR BODY";
                    subtitle.text = "Big strokes. Relaxed glides. Your view stays level.";
                    Body("1   Flap down hard for immediate lift and speed.\n2   Rest upper arms low, forearms out to glide.\n3   Spread both wings briefly to rise and slow down.\n4   Tuck your wings to dive and accelerate.\n5   Lower one wing to bank toward that side.\n6   Fly through rising air to climb without flapping.", 50, 23, 330);
                    Body("Smaller birds = food. Larger birds = danger.\nWhen hunted: turn through a gap or flee through an updraft.", -161, 22, 72);
                    if (Player.DesktopMode) Body("Desktop: A / D steer   •   Space flap   •   E spread wings", -233, 19);
                    Button("Got it", -290, Back, 54);
                    break;
                case "settings":
                    title.text = "MAKE YOURSELF AT HOME";
                    subtitle.text = "Comfort settings and your personal wing span.";
                    Button("Haptics: " + (Player.HapticsEnabled ? "on" : "off"), 110, () => { Player.HapticsEnabled = !Player.HapticsEnabled; PlayerPrefs.SetInt("Soaring.Haptics", Player.HapticsEnabled ? 1 : 0); BuildPage(); });
                    Button("Comfort vignette: " + (Player.ComfortVignette ? "on" : "off"), 30, () => { Player.ComfortVignette = !Player.ComfortVignette; PlayerPrefs.SetInt("Soaring.Vignette", Player.ComfortVignette ? 1 : 0); BuildPage(); });
                    Button("Recalibrate my wings", -50, () => Show("calibrateRelaxed"));
                    Button("Flight lab", -130, () => Show("tuning"));
                    Button("Back", -210, Back);
                    break;
                case "calibrateRelaxed":
                case "calibrateExtended":
                    captureExtended = page == "calibrateExtended";
                    title.text = captureExtended ? "2 / 2   SPREAD YOUR WINGS" : "1 / 2   YOUR RELAXED GLIDE";
                    subtitle.text = "Select below, then hold the pose during the countdown.";
                    Body(captureExtended ? "Extend both arms sideways, comfortably wide.\nKeep your head upright and shoulders relaxed.\nThis is a momentary power pose during flight." : "Let your upper arms rest by your sides.\nHold your forearms gently out like short wings.\nKeep your head upright in your usual playing posture.", 80, 25, 185);
                    Body(Player.DesktopMode && captureExtended ? "Desktop: hold E during the countdown to spread both wings.\nKeep holding E until the capture completes." : "After selecting, you have 3 seconds to settle into position.\nStay in the same seated or standing posture for both poses.", -61, 21, 80);
                    Button("I’m ready — capture in 3 seconds", -160, BeginCapture);
                    Button("Back", -250, Back);
                    break;
                case "calibrated":
                    title.text = "YOUR WINGS ARE READY";
                    subtitle.text = "Relax to glide. Spread to rise. Flap to soar.";
                    Body("Start with a few strong downstrokes.\nThe small golden birds are easy food.\nYou can recalibrate or change flight feel at any time.", 61, 25, 140);
                    Button(Session.IsPlaying ? "Return to flight" : "Take flight", -100, () => { if (Session.IsPlaying) Close(); else StartFlight(); });
                    Button("How to fly", -190, () => Show("help"));
                    break;
                case "death":
                    title.text = "THE SKY CAUGHT YOU";
                    subtitle.text = Session.Status;
                    Body(RunSummary() + "\nWatch for the orange hunter warning. Bank into a gap to escape.", 60, 24, 140);
                    Button("Fly again", -100, Restart);
                    Button("Adjust flight feel", -190, () => Show("tuning"));
                    break;
                case "victory":
                    title.text = "THE SKY IS YOURS";
                    subtitle.text = "Apex reached. The valley has become your playground.";
                    Body(RunSummary() + "\nYou conquered the skyline circuit.", 60, 27, 140);
                    Button("A new flight", -100, Restart);
                    Button("Flight lab", -190, () => Show("tuning"));
                    break;
                case "tuning": BuildTuning(); break;
            }
            Highlight();
        }

        void StartFlight() { observedDead = observedWin = false; previousCatches = 0; Session.StartRun(); note = ""; Close(); }
        void Restart() { observedDead = observedWin = false; previousCatches = 0; Session.Restart(); note = ""; if (Player.IsCalibrated) Close(); else Show("calibrateRelaxed"); }
        void Back() { note = ""; Show(Session.IsPlaying && !Session.IsDead && !Session.HasWon ? "pause" : "home"); }
        string RunSummary() => $"{Session.Catches} catches   •   size {Session.Size:0.0}×   •   {Mathf.FloorToInt(Session.Elapsed / 60)}m {Mathf.FloorToInt(Session.Elapsed % 60):00}s";

        void BeginCapture()
        {
            calibrationCaptureAt = Time.unscaledTime + 3.1f;
            foreach (var control in controls) control.Rect.gameObject.SetActive(false);
            countdown = TextAt(panel, "Page Countdown", "Hold this pose…  3", new Vector2(0, -176), new Vector2(800, 74), 34, cyan);
            ray.enabled = false;
            pointer.gameObject.SetActive(false);
            // Panel stays at the position set before countdown: no moving cue changes the measured pose.
        }
        void CaptureCalibration()
        {
            calibrationCaptureAt = 0;
            if (!Player.DesktopMode && !Player.TrackingValid)
            {
                note = "Both controllers must be tracked. Try the pose again.";
                BuildPage();
                subtitle.text = note;
                return;
            }
            if (captureExtended)
            {
                Player.CalibrateExtended();
                if (Player.IsCalibrated) { note = ""; Show("calibrated"); audioFeedback.Click(); }
                else { note = "Spread your wings wider than the relaxed pose, then try again."; BuildPage(); subtitle.text = note; }
            }
            else { Player.CalibrateRelaxed(); note = ""; Show("calibrateExtended"); }
            Player.Haptic(.24f, .1f);
        }

        void BuildTuning()
        {
            const int perPage = 5;
            int totalPages = Mathf.Max(1, Mathf.CeilToInt(fields.Count / (float)perPage));
            tuningPage = Mathf.Clamp(tuningPage, 0, totalPages - 1);
            title.text = "FLIGHT LAB";
            subtitle.text = $"Live tuning   •   {tuningPage + 1} / {totalPages}   •   click left / right to adjust";
            footer.text = Player.DesktopMode ? "← / → adjust  •  Shift = fine control  •  Enter selects  •  Escape menu" : "Stick adjusts  •  Grip = fine control  •  Point + trigger  •  Menu to close";
            for (int i = tuningPage * perPage; i < Mathf.Min(fields.Count, (tuningPage + 1) * perPage); i++)
            {
                var field = fields[i];
                var range = field.GetCustomAttribute<RangeAttribute>();
                Func<string> caption = () => Pretty(field.Name) + "     ‹  " + ((float)field.GetValue(Player.Tuning)).ToString("0.###") + "  ›";
                Action<float> adjust = sign =>
                {
                    float value = (float)field.GetValue(Player.Tuning);
                    var keyboard = Keyboard.current;
                    bool fine = keyboard != null && (keyboard.leftShiftKey.isPressed || keyboard.rightShiftKey.isPressed);
                    var device = InputDevices.GetDeviceAtXRNode(XRNode.RightHand);
                    fine |= Feature(device, CommonUsages.gripButton);
                    float step = (range.max - range.min) / (fine ? 200 : 40);
                    field.SetValue(Player.Tuning, Mathf.Clamp(value + sign * step, range.min, range.max));
                    Player.Tuning.Sanitize();
                };
                var control = Button(caption(), 152 - (i % perPage) * 60, () => { adjust(1); RefreshCaptions(); }, 52);
                control.Adjust = adjust;
                control.Caption = caption;
            }
            SmallButton("‹ Previous", -270, -169, () => { tuningPage = (tuningPage - 1 + totalPages) % totalPages; BuildPage(); });
            SmallButton("Next ›", 0, -169, () => { tuningPage = (tuningPage + 1) % totalPages; BuildPage(); });
            SmallButton("Presets", 270, -169, () => BuildPresetPage());
            SmallButton("Save", -270, -231, () => { Player.Tuning.Save(); subtitle.text = "Saved. Your flight settings will persist between sessions."; });
            SmallButton("Load", 0, -231, () => { Player.Tuning.Load(); RefreshCaptions(); subtitle.text = "Loaded your saved flight settings."; });
            SmallButton("Reset defaults", 270, -231, () => { Player.Tuning.ResetDefaults(); RefreshCaptions(); subtitle.text = "Default flight restored. Select Save to keep it."; });
            Button("Back", -297, Back, 50);
        }
        void BuildPresetPage()
        {
            page = "presets";
            foreach (var control in controls) Destroy(control.Rect.gameObject);
            controls.Clear();
            focus = 0;
            title.text = "CHOOSE YOUR FLIGHT FEEL";
            subtitle.text = "A starting point. Fine-tune any value in the flight lab.";
            foreach (var preset in new[] { "Comfort", "Arcade", "Heavy" })
            {
                string chosen = preset;
                float y = chosen == "Comfort" ? 100 : chosen == "Arcade" ? 10 : -80;
                Button(chosen, y, () => { Player.Tuning.ApplyPreset(chosen); page = "tuning"; BuildPage(); subtitle.text = chosen + " preset applied. Select Save to keep it."; });
            }
            Button("Back to flight lab", -210, () => { page = "tuning"; BuildPage(); });
            Highlight();
        }
        void RefreshCaptions() { foreach (var control in controls) if (control.Caption != null) control.Label.text = control.Caption(); }
        static string Pretty(string value) {var words=Regex.Replace(value, "([a-z])([A-Z])", "$1 $2");return char.ToUpperInvariant(words[0])+words.Substring(1);}

        void RefreshHud()
        {
            if (!hudStats) return;
            hudStats.text = $"SIZE  {Session.Size:0.0}×       SPEED  {Player.Speed:0} m/s       CATCHES  {Session.Catches}";
            float apex = ApexSize();
            float progress = Mathf.InverseLerp(1, apex, Session.Size);
            progressFill.sizeDelta = new Vector2(820 * progress, 5);
            hudGoal.text = Session.Size >= apex ? $"APEX • {ApexGuidance()} • Crowns {Session.ApexRings}/{Mathf.RoundToInt(Player.Tuning.apexRingGoal)}" : Session.Size < 1.7f ? "Find the small golden birds. Flap down to climb." : "Chase smaller silhouettes. Bigger birds hunt you.";
            hudThreat.text = Session.World != null && !string.IsNullOrEmpty(Session.World.ThreatText) ? Session.World.ThreatText : "";
            if (!Player.TrackingValid && !Player.DesktopMode) hudThreat.text = "Controller tracking lost";
            hudThreat.color = Session.World != null && Session.World.ThreatIntensity > .5f ? new Color(1, .38f, .24f) : new Color(1, .74f, .35f);
        }
        string ApexGuidance(){Vector3 delta=Session.World.NextApexPosition-Player.Position;float angle=Vector3.SignedAngle(Vector3.ProjectOnPlane(Player.Head.forward,Vector3.up),Vector3.ProjectOnPlane(delta,Vector3.up),Vector3.up);string direction=Mathf.Abs(angle)<15?"AHEAD":Mathf.Abs(angle)>150?"BEHIND":angle>0?"RIGHT":"LEFT";return direction+" "+Mathf.RoundToInt(delta.magnitude)+"m / "+(delta.y>4?"climb "+Mathf.RoundToInt(delta.y)+"m":delta.y<-4?"descend "+Mathf.RoundToInt(-delta.y)+"m":"level");}
        float ApexSize()
        {
            return Mathf.Max(1.1f, Player.Tuning.apexSize);
        }

        RectTransform CreateCanvas(string name, Vector2 size, Transform parent)
        {
            var go = new GameObject(name, typeof(RectTransform), typeof(Canvas));
            go.transform.SetParent(parent ? parent : transform, false);
            var rect = go.GetComponent<RectTransform>();
            rect.sizeDelta = size;
            rect.localScale = Vector3.one * .0016f;
            var canvas = go.GetComponent<Canvas>();
            canvas.renderMode = RenderMode.WorldSpace;
            canvas.worldCamera = viewCamera;
            canvas.sortingOrder = name.Contains("HUD") ? 10 : 20;
            return rect;
        }
        Image ImageAt(Transform parent, string name, Vector2 position, Vector2 size, Color color)
        {
            var go = new GameObject(name, typeof(RectTransform), typeof(Image));
            go.transform.SetParent(parent, false);
            var rect = go.GetComponent<RectTransform>();
            rect.anchoredPosition = position;
            rect.sizeDelta = size;
            var result = go.GetComponent<Image>();
            result.material=readableUI;
            result.color = color;
            result.raycastTarget = false;
            return result;
        }
        Text TextAt(Transform parent, string name, string content, Vector2 position, Vector2 size, int fontSize, Color color)
        {
            var go = new GameObject(name, typeof(RectTransform), typeof(Text));
            go.transform.SetParent(parent, false);
            var rect = go.GetComponent<RectTransform>();
            rect.anchoredPosition = position;
            rect.sizeDelta = size;
            var result = go.GetComponent<Text>();
            result.material=readableUI;
            result.font = font;
            result.fontSize = fontSize;
            result.text = content;
            result.color = color;
            result.alignment = TextAnchor.MiddleCenter;
            result.raycastTarget = false;
            result.horizontalOverflow = HorizontalWrapMode.Wrap;
            result.verticalOverflow = VerticalWrapMode.Truncate;
            return result;
        }
        Text Body(string text, float y, int size, float height = 82) => TextAt(panel, "Page Body", text, new Vector2(0, y), new Vector2(860, height), size, white);
        Control Button(string text, float y, Action select, float height = 68) => AddControl(text, new Vector2(0, y), new Vector2(790, height), select, 25);
        Control SmallButton(string text, float x, float y, Action select) => AddControl(text, new Vector2(x, y), new Vector2(250, 52), select, 21);
        Control AddControl(string text, Vector2 position, Vector2 size, Action select, int fontSize)
        {
            var background = ImageAt(panel, "Control " + text, position, size, card);
            var label = TextAt(background.transform, "Label", text, Vector2.zero, size - new Vector2(24, 4), fontSize, white);
            var control = new Control { Rect = background.rectTransform, Background = background, Label = label, Select = select };
            controls.Add(control);
            return control;
        }
    }
}
