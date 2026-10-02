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

        readonly Color ink = new Color(.045f, .105f, .15f, .96f);
        readonly Color card = new Color(.085f, .18f, .22f, 1);
        readonly Color cyan = new Color(.40f, .84f, .76f, 1);
        readonly Color white = new Color(.98f, .94f, .82f, 1);
        readonly Color gold = new Color(.99f, .74f, .32f, 1);
        readonly Color muted = new Color(.59f, .72f, .73f, 1);
        readonly List<Control> controls = new List<Control>();
        readonly List<FieldInfo> fields = new List<FieldInfo>();
        RectTransform panel, hud, progressFill;
        Text hudStats, hudGrowthLabel, hudSpeed, hudCatchCount, catchToast, hudGoal, hudThreat, title, subtitle, footer, countdown;
        Image threatCard, catchCard;
        float catchAt = -10, displayedProgress;
        Sprite roundedSprite;
        Texture2D roundedTexture;
        Sprite circleSprite;
        Texture2D circleTexture;
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
            public Image Accent;
            public Text Chevron;
            public RectTransform Gauge;
            public Func<float> Fraction;
            public bool Primary;
        }

        public void Build()
        {
            if (built) return;
            built = true;
            font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");
            readableUI=new Material(Shader.Find("Soaring/UI Always Visible"));
            CreateRoundedSprite();
            Player.HapticsEnabled = PlayerPrefs.GetInt("Soaring.Haptics", 1) != 0;
            Player.ComfortVignette = PlayerPrefs.GetInt("Soaring.Vignette", 1) != 0;
            viewCamera = Player.Head.GetComponent<Camera>();
            if (!viewCamera) viewCamera = Camera.main;
            panel = CreateCanvas("Soaring menu", new Vector2(960, 770), null);
            ImageAt(panel, "Frame shadow", new Vector2(0, -10), new Vector2(980, 782), new Color(.025f, .05f, .065f, .3f));
            ImageAt(panel, "Gold rim", Vector2.zero, new Vector2(962, 772), new Color(.47f, .42f, .27f, .9f));
            ImageAt(panel, "Panel", Vector2.zero, new Vector2(956, 766), ink);
            ImageAt(panel, "Header line", new Vector2(0, 196), new Vector2(852, 1), new Color(.34f,.48f,.46f,.55f));
            var brand = TextAt(panel, "Sanctuary", "S O A R I N G   /   SKY SANCTUARY", new Vector2(-170, 348), new Vector2(520, 25), 16, cyan);
            brand.alignment = TextAnchor.MiddleLeft;
            ImageAt(panel, "Quest badge", new Vector2(350, 348), new Vector2(142, 30), new Color(.22f,.26f,.23f));
            TextAt(panel, "Quest label", "ARM-POWERED", new Vector2(350, 348), new Vector2(140, 28), 13, gold);
            title = TextAt(panel, "Title", "", new Vector2(0, 288), new Vector2(850, 70), 42, white);
            title.alignment = TextAnchor.MiddleLeft;
            title.fontStyle = FontStyle.Bold;
            subtitle = TextAt(panel, "Subtitle", "", new Vector2(0, 229), new Vector2(850, 52), 21, muted);
            subtitle.alignment = TextAnchor.MiddleLeft;
            footer = TextAt(panel, "Input help", "Point + trigger  /  stick + A or X    •    Menu / B / Y to close", new Vector2(0, -352), new Vector2(890, 32), 18, new Color(.57f, .72f, .79f));
            ImageAt(panel, "Footer line", new Vector2(0, -329), new Vector2(850, 1), new Color(.34f,.48f,.46f,.35f));
            hud = CreateCanvas("Flight HUD", new Vector2(730, 92), Player.Head);
            hud.localPosition = new Vector3(0, -.43f, 1.5f);
            hud.localRotation = Quaternion.identity;
            ImageAt(hud, "Size chip", new Vector2(-253, 12), new Vector2(218, 68), new Color(.035f,.105f,.145f,.88f));
            ImageAt(hud, "Flight chip", new Vector2(0, 12), new Vector2(280, 68), new Color(.035f,.105f,.145f,.88f));
            ImageAt(hud, "Catch chip", new Vector2(253, 12), new Vector2(218, 68), new Color(.035f,.105f,.145f,.88f));
            hudStats = TextAt(hud, "Size", "", new Vector2(-253, 19), new Vector2(190, 36), 28, white);
            hudSpeed = TextAt(hud, "Speed", "", new Vector2(0, 19), new Vector2(250, 36), 28, white);
            hudCatchCount = TextAt(hud, "Catches", "", new Vector2(253, 19), new Vector2(190, 36), 28, gold);
            hudGrowthLabel=TextAt(hud, "Size label", "TO 1.6×", new Vector2(-253, -4), new Vector2(190, 18), 12, muted);
            TextAt(hud, "Speed label", "AIR SPEED", new Vector2(0, -4), new Vector2(250, 18), 12, muted);
            TextAt(hud, "Catch label", "BIRDS CAUGHT", new Vector2(253, -4), new Vector2(190, 18), 12, muted);
            ImageAt(hud,"Goal ribbon",new Vector2(0,-45),new Vector2(738,36),new Color(.035f,.105f,.145f,.64f));
            hudGoal = TextAt(hud, "Goal", "", new Vector2(0, -45), new Vector2(714, 36), 20, white);
            threatCard = ImageAt(hud, "Threat chip", new Vector2(0, 95), new Vector2(670, 48), new Color(.3f,.105f,.09f,.9f));
            hudThreat = TextAt(threatCard.transform, "Threat", "", Vector2.zero, new Vector2(640, 38), 21, gold);
            threatCard.gameObject.SetActive(false);
            ImageAt(hud, "Growth track", new Vector2(-253, -17), new Vector2(176, 4), new Color(.22f, .35f, .4f));
            progressFill = ImageAt(hud, "Growth", new Vector2(-341, -17), new Vector2(1, 4), cyan).rectTransform;
            progressFill.pivot = new Vector2(0, .5f);
            catchCard = ImageAt(hud, "Catch celebration", new Vector2(0, 144), new Vector2(266, 46), new Color(.99f,.74f,.32f,0));
            catchToast = TextAt(catchCard.transform, "Catch toast", "+1   •   CAUGHT", Vector2.zero, new Vector2(245, 40), 20, ink);
            catchCard.gameObject.SetActive(false);
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
            if(roundedSprite)Destroy(roundedSprite);
            if(roundedTexture)Destroy(roundedTexture);
            if(circleSprite)Destroy(circleSprite);
            if(circleTexture)Destroy(circleTexture);
            if (ray && ray.sharedMaterial) Destroy(ray.sharedMaterial);
        }

        void SessionChanged()
        {
            if (!built) return;
            if (Session.Catches > previousCatches)
            {
                audioFeedback.Catch(Session.Catches, Session.Size);
                Player.Haptic(.4f, .12f);
                catchAt = Time.unscaledTime;
                catchToast.text = "+" + (Session.Catches - previousCatches) + "   •   CAUGHT";
            }
            previousCatches = Session.Catches;
            if (Session.IsDead && !observedDead) { observedDead = true; Show("death"); audioFeedback.Death(); }
            else if (Session.HasWon && !observedWin) { observedWin = true; Show("victory"); audioFeedback.Victory(); }
        }

        void Update()
        {
            if (!built) return;
            AnimateHud();
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
                var control = controls[i];
                bool active = i == focus || i == pointerHovered;
                control.Background.color = control.Primary ? (active ? new Color(.53f,.91f,.82f) : cyan) : active ? new Color(.13f,.31f,.34f) : card;
                control.Label.color = control.Primary ? ink : white;
                control.Accent.color = active ? gold : new Color(.24f,.40f,.40f,.7f);
                control.Chevron.color = control.Primary ? ink : active ? gold : muted;
                if (control.Gauge && control.Fraction != null) control.Gauge.sizeDelta = new Vector2(680 * control.Fraction(), 3);
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
            title.fontSize = 42;
            title.rectTransform.anchoredPosition = new Vector2(0, 288);
            title.rectTransform.sizeDelta = new Vector2(850, 70);
            subtitle.rectTransform.anchoredPosition = new Vector2(0, 229);
            subtitle.rectTransform.sizeDelta = new Vector2(850, 52);
            subtitle.text = note;
            footer.text = Player.DesktopMode ? "Arrow keys to focus / tune  •  Enter selects  •  Mouse clicks  •  Escape menu" : "Point + trigger  /  stick + A or X    •    Menu / B / Y to close";
            switch (page)
            {
                case "home":
                    title.text = "Small wings. Big sky.";
                    title.fontSize = 52;
                    subtitle.text = "Fly with your arms. Rise through the food chain.";
                    var intro = TextAt(panel, "Page Introduction", "Catch the smaller birds.\nBecome the biggest thing in the sky.", new Vector2(-169, 133), new Vector2(488, 64), 23, white);
                    intro.alignment = TextAnchor.MiddleLeft;
                    AddControl(Player.IsCalibrated ? "Take flight" : "Set up my wings", new Vector2(-169, 49), new Vector2(488, 68), () => { if (Player.IsCalibrated) StartFlight(); else Show("calibrateRelaxed"); }, 26);
                    AddControl("How to fly", new Vector2(-169, -31), new Vector2(488, 64), () => Show("help"), 24);
                    AddControl("Comfort & settings", new Vector2(-169, -107), new Vector2(488, 64), () => Show("settings"), 24);
                    AddControl("Flight lab", new Vector2(-169, -183), new Vector2(488, 64), () => Show("tuning"), 24);
                    HomeIllustration();
                    Body("Standing or seated. Clear some space, then spread your wings.", -285, 19);
                    break;
                case "pause":
                    title.text = "A moment in the sky";
                    subtitle.text = string.IsNullOrEmpty(note) ? "Take a breath. The valley is paused." : note;
                    Button("Resume flight", 120, Close);
                    Button("How to fly", 40, () => Show("help"));
                    Button("Settings & calibration", -40, () => Show("settings"));
                    Button("Flight lab  •  developer tuning", -120, () => Show("tuning"));
                    Button("Restart run", -200, () => Show("restart"));
                    break;
                case "restart":
                    title.text = "A fresh pair of wings";
                    subtitle.text = "Start again as a small bird. Keep your flight settings.";
                    Button("Restart run", 30, Restart);
                    Button("Keep flying", -60, Close);
                    break;
                case "help":
                    title.text = "Make the sky your playground";
                    subtitle.text = "Big strokes. Relaxed glides. Your view stays level.";
                    TutorialCard("01", "Flap to climb", "Strong downstrokes give lift\nand a burst of speed.", -215, 135);
                    TutorialCard("02", "Rest to glide", "Upper arms low, forearms out.\nKeep your shoulders relaxed.", 215, 135);
                    TutorialCard("03", "Spread to rise", "Extend briefly to balloon up.\nStay wide to slow down.", -215, 23);
                    TutorialCard("04", "Tuck for speed", "Bring your wings closer\nto dive and accelerate.", 215, 23);
                    TutorialCard("05", "Bank to turn", "Lower one wing to turn\ntoward that side.", -215, -89);
                    TutorialCard("06", "Ride the thermals", "Teal rising air gives you\na climb without flapping.", 215, -89);
                    LegendChip("GOLD  /  CATCH", -282, -185, gold);
                    LegendChip("BLUE  /  PEER", 0, -185, new Color(.44f,.66f,.86f));
                    LegendChip("CORAL  /  ESCAPE", 282, -185, new Color(.99f,.49f,.35f));
                    Body(Player.DesktopMode ? "A / D steer   •   Space flap   •   E spread   •   Shift tuck" : "Hunter behind you? Bank through a gap or escape in rising air.", -242, 19, 36);
                    Button("Got it", -290, Back, 54);
                    break;
                case "settings":
                    title.text = "Make yourself at home";
                    subtitle.text = "Comfort settings and your personal wing span.";
                    Button("Haptics: " + (Player.HapticsEnabled ? "on" : "off"), 130, () => { Player.HapticsEnabled = !Player.HapticsEnabled; PlayerPrefs.SetInt("Soaring.Haptics", Player.HapticsEnabled ? 1 : 0); BuildPage(); },58);
                    Button("Comfort vignette: " + (Player.ComfortVignette ? "on" : "off"), 58, () => { Player.ComfortVignette = !Player.ComfortVignette; PlayerPrefs.SetInt("Soaring.Vignette", Player.ComfortVignette ? 1 : 0); BuildPage(); },58);
                    Button("Sound: " + (audioFeedback.Volume<.01f?"off":audioFeedback.Volume<.5f?"soft":"full"), -14, () => { audioFeedback.SetVolume(audioFeedback.Volume<.01f?.4f:audioFeedback.Volume<.5f?.75f:0);BuildPage();},58);
                    Button("Recalibrate my wings", -86, () => Show("calibrateRelaxed"),58);
                    Button("Flight lab", -158, () => Show("tuning"),58);
                    Button("Back", -249, Back,54);
                    break;
                case "calibrateRelaxed":
                case "calibrateExtended":
                    captureExtended = page == "calibrateExtended";
                    title.text = captureExtended ? "02   Spread your wings" : "01   Find your relaxed glide";
                    subtitle.text = "Select below, then hold the pose during the countdown.";
                    CalibrationIllustration(captureExtended);
                    var pose = TextAt(panel, "Page Pose instructions", captureExtended ? "Extend both arms sideways,\ncomfortably wide.\n\nKeep your head upright.\nThis is your brief power pose." : "Rest upper arms by your sides.\nHold your forearms gently out.\n\nKeep your head upright\nin your usual playing posture.", new Vector2(142, 73), new Vector2(474, 184), 23, white);
                    pose.alignment = TextAnchor.MiddleLeft;
                    Body(Player.DesktopMode && captureExtended ? "Desktop: hold E during the countdown to spread both wings.\nKeep holding E until the capture completes." : "After selecting, you have 3 seconds to settle into position.\nStay in the same seated or standing posture for both poses.", -61, 21, 80);
                    Button("I’m ready — capture in 3 seconds", -160, BeginCapture);
                    Button("Back", -250, Back);
                    break;
                case "calibrated":
                    title.text = "Your wings are ready";
                    subtitle.text = "Relax to glide. Spread to rise. Flap to soar.";
                    Body("Start with a few strong downstrokes.\nThe small golden birds are easy food.\nYou can recalibrate or change flight feel at any time.", 61, 25, 140);
                    Button(Session.IsPlaying ? "Return to flight" : "Take flight", -100, () => { if (Session.IsPlaying) Close(); else StartFlight(); });
                    Button("How to fly", -190, () => Show("help"));
                    break;
                case "death":
                    title.text = "The sky caught you";
                    subtitle.text = Session.Status;
                    ResultCards();
                    Body("A hunter’s warning is your cue to turn.\nSlip through a gap, dive away or find rising air.", -19, 23, 92);
                    Button("Fly again", -100, Restart);
                    Button("Adjust flight feel", -190, () => Show("tuning"));
                    break;
                case "victory":
                    title.text = "The sky is yours";
                    subtitle.text = "Apex reached. The valley has become your playground.";
                    ResultCards();
                    Body("Crown circuit complete.\nFrom a small goldfinch to ruler of the sky.", -19, 25, 92);
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
            title.text = "Your flight, your way";
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
                ImageAt(control.Rect, "Gauge track", new Vector2(0, -20), new Vector2(680, 3), new Color(.22f,.35f,.36f));
                control.Gauge = ImageAt(control.Rect, "Gauge", new Vector2(-340, -20), new Vector2(1, 3), cyan).rectTransform;
                control.Gauge.pivot = new Vector2(0,.5f);
                control.Fraction = () => Mathf.InverseLerp(range.min, range.max, (float)field.GetValue(Player.Tuning));
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
            title.text = "Choose your flight feel";
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
            hudStats.text = $"{Session.Size:0.0}×";
            hudSpeed.text = $"{Player.Speed:0} <size=17>m/s</size>";
            hudCatchCount.text = Session.Catches.ToString();
            float apex = ApexSize();
            GrowthStage(out _,out float nextSize);
            hudGrowthLabel.text=Session.Size>=apex?"APEX":"TO "+nextSize.ToString("0.0")+"×";
            hudGoal.text = Session.Size >= apex ? $"APEX • {ApexGuidance()} • Crowns {Session.ApexRings}/{Mathf.RoundToInt(Player.Tuning.apexRingGoal)}" : Session.Size < 1.7f ? "Find the small golden birds. Flap down to climb." : "Chase smaller silhouettes. Bigger birds hunt you.";
            hudThreat.text = ThreatGuidance();
            if (!Player.TrackingValid && !Player.DesktopMode) hudThreat.text = "Controller tracking lost";
            hudThreat.color = Session.World != null && Session.World.ThreatIntensity > .5f ? new Color(1, .38f, .24f) : new Color(1, .74f, .35f);
            threatCard.gameObject.SetActive(!string.IsNullOrEmpty(hudThreat.text));
        }
        string ThreatGuidance()
        {
            if(Session.World==null||string.IsNullOrEmpty(Session.World.ThreatText))return "";
            NpcBird closest=null;float best=float.PositiveInfinity;
            foreach(var bird in Session.World.Birds)
            {
                if(!bird.Alive||!bird.IsHuntingPlayer)continue;
                float distance=(bird.Position-Player.Position).sqrMagnitude;
                if(distance<best){best=distance;closest=bird;}
            }
            if(!closest)return Session.World.ThreatText;
            Vector3 delta=closest.Position-Player.Position;
            float angle=Vector3.SignedAngle(Vector3.ProjectOnPlane(Player.Head.forward,Vector3.up),Vector3.ProjectOnPlane(delta,Vector3.up),Vector3.up);
            string bearing=Mathf.Abs(angle)<25?"AHEAD":Mathf.Abs(angle)>145?"BEHIND":angle>0?"RIGHT":"LEFT";
            return $"HUNTER {bearing}  /  {Mathf.RoundToInt(Mathf.Sqrt(best))}m   •   Bank away or climb";
        }
        void AnimateHud()
        {
            GrowthStage(out float stageStart,out float stageEnd);
            float target=Session.Size>=ApexSize()?1:Mathf.InverseLerp(stageStart,stageEnd,Session.Size);
            displayedProgress = Mathf.Lerp(displayedProgress, target, 1 - Mathf.Exp(-Time.unscaledDeltaTime * 6));
            if(progressFill) progressFill.sizeDelta = new Vector2(176 * displayedProgress, 4);
            float age = Time.unscaledTime - catchAt;
            bool showCatch = age < 1.1f && !MenuOpen;
            if(catchCard)
            {
                catchCard.gameObject.SetActive(showCatch);
                if(showCatch)
                {
                    float alpha = Mathf.Clamp01((1.1f - age) * 4);
                    catchCard.color = new Color(gold.r,gold.g,gold.b,.95f * alpha);
                    catchToast.color = new Color(ink.r,ink.g,ink.b,alpha);
                    catchCard.rectTransform.anchoredPosition = new Vector2(0, 161 + 18 * age);
                    catchCard.rectTransform.localScale = Vector3.one * (1 + .08f * Mathf.Exp(-age * 6));
                }
            }
            if(threatCard && threatCard.gameObject.activeSelf) threatCard.color = new Color(.3f,.105f,.09f,.85f + .1f * Mathf.Sin(Time.unscaledTime * 5));
            if(audioFeedback) audioFeedback.Flight(Player.Speed, Player.model.Flapped, Session.IsPlaying && !Session.IsPaused && !Session.IsDead && !Session.HasWon);
        }
        void GrowthStage(out float start,out float end)
        {
            float first=Mathf.Min(1.6f,ApexSize()),second=Mathf.Min(2.8f,ApexSize());
            if(Session.Size<first){start=1;end=first;}
            else if(Session.Size<second){start=first;end=second;}
            else {start=second;end=ApexSize();}
        }

        void HomeIllustration()
        {
            var sheet = ImageAt(panel, "Page Wing guide", new Vector2(292,-34), new Vector2(256, 402), new Color(.105f,.22f,.25f));
            var sun = ImageAt(sheet.transform, "Sun", new Vector2(0,104), new Vector2(112,112), new Color(.99f,.74f,.32f,.12f));
            sun.sprite = circleSprite; sun.type = Image.Type.Simple;
            WingEmblem(sheet.transform, new Vector2(0,103), 1);
            TextAt(sheet.transform, "Wing guide heading", "BORN TO SOAR", new Vector2(0,37), new Vector2(228,30), 17, gold).fontStyle = FontStyle.Bold;
            TextAt(sheet.transform, "Wing guide steps", "FLAP\nFeel the lift\n\nGLIDE\nFind your rhythm\n\nGROW\nChange your world", new Vector2(0,-83), new Vector2(226,207), 20, white);
        }
        void WingEmblem(Transform parent, Vector2 center, float scale)
        {
            for(int sign=-1;sign<=1;sign+=2)
                for(int i=0;i<4;i++)
                {
                    var feather=ImageAt(parent,"Feather",center+new Vector2(sign*(21+i*12),12-i*9)*scale,new Vector2((68-i*8)*scale,11*scale),i==0?gold:white);
                    feather.rectTransform.localRotation=Quaternion.Euler(0,0,sign*(21+i*9));
                }
            var body=ImageAt(parent,"Crest body",center+new Vector2(0,-7)*scale,new Vector2(12,31)*scale,gold);
            body.rectTransform.localRotation=Quaternion.Euler(0,0,0);
        }
        void TutorialCard(string number,string heading,string copy,float x,float y)
        {
            var tile=ImageAt(panel,"Page Lesson "+number,new Vector2(x,y),new Vector2(408,102),card);
            var badge=ImageAt(tile.transform,"Step badge",new Vector2(-164,26),new Vector2(42,30),new Color(.15f,.31f,.32f));
            TextAt(badge.transform,"Step",number,Vector2.zero,new Vector2(40,28),15,gold).fontStyle=FontStyle.Bold;
            var name=TextAt(tile.transform,"Lesson",heading,new Vector2(23,26),new Vector2(306,32),21,white);name.alignment=TextAnchor.MiddleLeft;name.fontStyle=FontStyle.Bold;
            var detail=TextAt(tile.transform,"Lesson description",copy,new Vector2(0,-19),new Vector2(366,52),18,muted);detail.alignment=TextAnchor.MiddleLeft;
        }
        void LegendChip(string text,float x,float y,Color color)
        {
            var chip=ImageAt(panel,"Page Bird legend",new Vector2(x,y),new Vector2(267,40),new Color(color.r,color.g,color.b,.12f));
            TextAt(chip.transform,"Legend",text,Vector2.zero,new Vector2(253,32),15,color).fontStyle=FontStyle.Bold;
        }
        void CalibrationIllustration(bool extended)
        {
            var tile=ImageAt(panel,"Page Pose diagram",new Vector2(-270,73),new Vector2(268,184),card);
            var head=ImageAt(tile.transform,"Head",new Vector2(0,44),new Vector2(30,30),white);head.sprite=circleSprite;head.type=Image.Type.Simple;
            ImageAt(tile.transform,"Body",new Vector2(0,-2),new Vector2(20,49),white);
            for(int side=-1;side<=1;side+=2)
            {
                var arm=ImageAt(tile.transform,"Upper arm",new Vector2(side*(extended?31:17),extended?12:-1),new Vector2(extended?48:13,extended?12:38),cyan);
                var forearm=ImageAt(tile.transform,"Forearm",new Vector2(side*(extended?70:37),extended?12:-18),new Vector2(extended?43:36,12),gold);
                if(!extended) forearm.rectTransform.localRotation=Quaternion.Euler(0,0,-side*12);
            }
            TextAt(tile.transform,"Pose caption",extended?"WIDE  /  POWER":"REST  /  GLIDE",new Vector2(0,-61),new Vector2(244,28),15,gold);
        }
        void ResultCards()
        {
            ResultCard("BIRDS CAUGHT",Session.Catches.ToString(),-282);
            ResultCard("FINAL SIZE",Session.Size.ToString("0.0")+"×",0);
            ResultCard("TIME IN THE SKY",$"{Mathf.FloorToInt(Session.Elapsed/60)}:{Mathf.FloorToInt(Session.Elapsed%60):00}",282);
        }
        void ResultCard(string label,string value,float x)
        {
            var tile=ImageAt(panel,"Page Flight result",new Vector2(x,115),new Vector2(263,116),card);
            TextAt(tile.transform,"Result",value,new Vector2(0,17),new Vector2(240,62),42,gold).fontStyle=FontStyle.Bold;
            TextAt(tile.transform,"Label",label,new Vector2(0,-31),new Vector2(240,24),14,muted);
        }

        void CreateRoundedSprite()
        {
            roundedTexture=ShapeTexture(16);
            roundedSprite=Sprite.Create(roundedTexture,new Rect(0,0,64,64),new Vector2(.5f,.5f),100,0,SpriteMeshType.FullRect,new Vector4(16,16,16,16));
            circleTexture=ShapeTexture(32);
            circleSprite=Sprite.Create(circleTexture,new Rect(0,0,64,64),new Vector2(.5f,.5f),100,0,SpriteMeshType.FullRect);
        }
        static Texture2D ShapeTexture(float radius)
        {
            var texture=new Texture2D(64,64,TextureFormat.RGBA32,false){name="Soaring UI curves",filterMode=FilterMode.Bilinear,wrapMode=TextureWrapMode.Clamp};
            var colors=new Color[4096];
            for(int y=0;y<64;y++)for(int x=0;x<64;x++)
            {
                float dx=Mathf.Max(0,Mathf.Abs(x-31.5f)-(32-radius));
                float dy=Mathf.Max(0,Mathf.Abs(y-31.5f)-(32-radius));
                colors[y*64+x]=new Color(1,1,1,Mathf.Clamp01(radius+.4f-Mathf.Sqrt(dx*dx+dy*dy)));
            }
            texture.SetPixels(colors);texture.Apply(false,true);return texture;
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
            result.sprite=roundedSprite;
            result.type=Image.Type.Sliced;
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
            bool small=size.x<300;
            var label = TextAt(background.transform, "Label", text, new Vector2(small?0:-9,0), size - new Vector2(small?24:80, 8), fontSize, white);
            label.alignment=small?TextAnchor.MiddleCenter:TextAnchor.MiddleLeft;
            var accent=ImageAt(background.transform,"Focus accent",new Vector2(-size.x*.5f+3,0),new Vector2(3,size.y-25),cyan);
            var chevron=TextAt(background.transform,"Action",small?"":"›",new Vector2(size.x*.5f-26,0),new Vector2(26,36),29,muted);
            bool primary=controls.Count==0&&page!="tuning"&&page!="settings"&&page!="presets";
            var control = new Control { Rect = background.rectTransform, Background = background, Label = label, Select = select, Accent=accent, Chevron=chevron, Primary=primary };
            controls.Add(control);
            return control;
        }
    }
}
