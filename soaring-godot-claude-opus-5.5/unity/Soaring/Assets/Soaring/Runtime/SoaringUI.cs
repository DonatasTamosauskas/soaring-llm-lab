using System;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.UI;
namespace Soaring
{
    [DefaultExecutionOrder(200)]
    public sealed class SoaringUI : MonoBehaviour
    {
        public GameSession game; public VRInput input; public PlayerFlight player;
        public const float PanelDistance = 1.5f, PixelsPerMetre = 1000;
        public const int BodyFontSize = 60;
        public const float HoldSeconds = .8f;
        Canvas panel, hud, lessonCanvas, toastCanvas;
        RectTransform panelRect, growthFill, lessonFill;
        Font font, heavy; Text speciesText, nextSpecies, lessonTitle, lessonHint, lessonCounter, noticeText, subtitle;
        SoaringUIArt speciesArt, lessonArt; CanvasGroup lessonGroup, growthGroup;
        float noticeUntil, noticeHeld, nextHud, calibrationStill, blockedSince = -1, nextSideChange, lessonClearAt, growthClearAt;
        bool lessonBlocked, growthBlocked;
        int recenterFrames, lastActionFrame = -1, lastLesson = -1, lastTier = -1, helpCard, noticeSide = 1;
        string page = "main"; bool traceInput, externalPointerHarness;
        readonly List<Entry> buttons = new(); readonly Pointer[] pointers = { new(), new() };
        readonly List<FacetGraphic> lives = new();
        readonly Color ink = Hex("16212f"), paper = Hex("fff4e0"), accent = Hex("ffc94d"), panelColor = Hex("1d2b3d"), buttonColor = Hex("2b4160"), muted = Hex("c9d6e6"), preyColor = Hex("5fe0a8");
        static readonly string[] ArtIds = { "spread", "flap", "glide", "speed", "turn", "dive", "hunt" };
        static readonly string[] LessonTitles = { "Spread your wings", "Flap to climb", "Glide", "Tilt for speed", "Bank to turn", "Tuck to dive", "Catch a smaller bird" };
        static readonly string[] LessonHints = { "Arms out, elbows relaxed.", "Sweep both arms down.", "Hold your wings still.", "Twist wrists down to go faster.", "Raise one arm or tilt opposite wrists.", "Pull your arms in, then spread.", "Fly through worthwhile prey." };
        static readonly string[] DesktopHints = { "Your wings are spread.", "Hold Space to flap.", "Let go of Space.", "W: faster. S: slow.", "A: left. D: right.", "Hold Shift, then release.", "Fly through a blue ring." };
        static readonly string[] HelpIds = { "flap", "glide", "speed", "turn", "dive", "perch", "hunt", "controls" };
        static readonly string[] HelpTabs = { "Flap", "Glide", "Speed", "Turn", "Dive", "Perch", "Hunt", "Buttons" };
        static readonly string[] HelpTitles = { "Flap to climb", "Glide", "Speed and balloon", "Bank to turn", "Tuck to dive", "Perch", "Eat or be eaten", "Buttons" };
        static readonly string[] HelpVR = {
            "Sweep both arms down hard. Tip the wings forward to push ahead too.",
            "Arms out to your sides, elbows relaxed and still. Stretch fully for a power flap.",
            "Twist both wrists. Edge up: balloon, then slow. Edge down: go faster.",
            "Left edge up, right edge down banks right. Dipping one arm works too.",
            "Pull your arms in to fall fast. Spread them again to pull out.",
            "Glide slowly onto a branch, wire or ledge. Flap to leave.",
            "Catch birds smaller than you and grow. Flee the bigger ones.",
            "Flying needs no buttons. Menu pauses. Hold A / X to recenter; Y to calibrate."
        };
        static readonly string[] HelpDesktop = {
            "Hold Space to flap; a tap is one beat. Hold W as you flap to go ahead.",
            "Let go of every key: wings out and still. Trade height for distance.",
            "W tips wings down: faster. S tips them up: balloon. Held, S stalls.",
            "A banks left, D banks right. Q or E beats one wing for a sharp turn.",
            "Hold Shift to pull the wings in and fall fast. Let go to pull out.",
            "Glide slowly onto a branch, wire or ledge. Space to leave.",
            "Catch smaller birds and grow. Blue rings mark food; magenta marks danger.",
            "Space flap, W/S tilt, A/D bank, Shift dive, mouse look, Esc menu."
        };
        static Color Hex(string value) { ColorUtility.TryParseHtmlString("#" + value, out var c); return c; }
        sealed class Entry { public RectTransform rect; public FacetGraphic image; public Text label; public Action action; public bool hold, selected; public string title; public RectTransform progress; public float hintUntil; }
        sealed class Pointer { public Entry hovered; public float hold; public bool previous, acted; public LineRenderer ray; }
        public void Initialize()
        {
            traceInput = Array.Exists(Environment.GetCommandLineArgs(), a => a == "--trace-input");
            font = Resources.Load<Font>("UI/Fonts/Nunito-Bold");
            heavy = Resources.Load<Font>("UI/Fonts/Nunito-Black");
            if (!font || !heavy) throw new InvalidOperationException("The original Nunito UI fonts are missing.");
            panel = MakeCanvas("Menus", 1360, 900, 10); panelRect = panel.GetComponent<RectTransform>();
            hud = MakeCanvas("Growth strip", 780, 172, 5);
            growthGroup = hud.gameObject.AddComponent<CanvasGroup>();
            Box(hud.transform, Vector2.zero, new(780,172), ink, true);
            speciesArt = Art(hud.transform, "bird_sparrow", new(-304,0), new(120,120));
            speciesText = Label(hud.transform, "Sparrow", new(-70,26), new(330,82), 60, TextAnchor.MiddleLeft, true); speciesText.color = accent;
            nextSpecies = Label(hud.transform, "Swallow", new(218,26), new(250,82), 60, TextAnchor.MiddleRight);
            Box(hud.transform, new(32,-44), new(540,22), buttonColor);
            growthFill = Box(hud.transform, new(32,-44), new(540,22), accent).rectTransform;
            for (int i = 0; i < 3; i++) lives.Add(Box(hud.transform,new(-343+i*30,-68),new(15,15),accent));
            lessonCanvas = MakeCanvas("Illustrated lesson", 808, 300, 6);
            Box(lessonCanvas.transform,Vector2.zero,new(808,300),ink,true);
            lessonGroup = lessonCanvas.gameObject.AddComponent<CanvasGroup>();
            lessonCounter = Label(lessonCanvas.transform,"Lesson 1 of 7",new(-112,106),new(540,64),60);
            lessonTitle = Label(lessonCanvas.transform,"Spread your wings",new(-112,38),new(540,80),60,TextAnchor.MiddleLeft,true);
            lessonHint = Label(lessonCanvas.transform,"Arms out, elbows relaxed.",new(-112,-56),new(540,138),60);
            lessonArt = Art(lessonCanvas.transform,"gesture_spread",new(288,10),new(190,240));
            Box(lessonCanvas.transform,new(-110,-130),new(544,14),buttonColor);
            lessonFill = Box(lessonCanvas.transform,new(-110,-130),new(544,14),preyColor).rectTransform;
            toastCanvas = MakeCanvas("Celebration",860,190,8);
            Box(toastCanvas.transform,Vector2.zero,new(860,190),ink,true);
            noticeText = Label(toastCanvas.transform,"",Vector2.zero,new(780,160),60,TextAnchor.MiddleCenter,true);
            foreach (var pointer in pointers)
            {
                pointer.ray = new GameObject("Menu pointer").AddComponent<LineRenderer>(); pointer.ray.transform.SetParent(transform);
                pointer.ray.positionCount = 2; pointer.ray.material = new Material(game.world.content.markerMaterial);
                pointer.ray.material.color = accent; pointer.ray.startColor = pointer.ray.endColor = accent;
                pointer.ray.numCapVertices = 3; pointer.ray.useWorldSpace = true; pointer.ray.enabled = false;
            }
            Show(game.phase);
        }
        Canvas MakeCanvas(string name,float width,float height,int order)
        {
            var go = new GameObject(name,typeof(RectTransform),typeof(Canvas)); go.transform.SetParent(transform,false);
            var canvas = go.GetComponent<Canvas>(); canvas.renderMode = RenderMode.WorldSpace; canvas.worldCamera = input.eye; canvas.sortingOrder = order;
            go.GetComponent<RectTransform>().sizeDelta = new(width,height); return canvas;
        }
        RectTransform Rect(GameObject go,Transform parent,Vector2 position,Vector2 size)
        {
            go.transform.SetParent(parent,false); var rect = go.GetComponent<RectTransform>(); rect.anchoredPosition = position; rect.sizeDelta = size; return rect;
        }
        void Curve(Graphic graphic)
        {
            var effect = graphic.gameObject.AddComponent<CurvedUIEffect>();
            effect.root = graphic.GetComponentInParent<Canvas>().GetComponent<RectTransform>(); effect.radius = PanelDistance*PixelsPerMetre;
        }
        Text Label(Transform parent,string value,Vector2 position,Vector2 size,int fontSize=60,TextAnchor alignment=TextAnchor.MiddleLeft,bool bold=false)
        {
            // Nunito ascender + descender is 1.364 em; Unity truncates the entire
            // line when the text rect is shorter, even if its visible glyphs fit.
            size.y=Mathf.Max(size.y,Mathf.Ceil(fontSize*1.4f));
            var go = new GameObject("Text",typeof(RectTransform),typeof(Text)); Rect(go,parent,position,size);
            var text = go.GetComponent<Text>(); text.font = bold ? heavy : font; text.fontSize = fontSize; text.alignment = alignment;
            text.text = value; text.color = paper; text.raycastTarget = false; text.horizontalOverflow = HorizontalWrapMode.Wrap; text.verticalOverflow = VerticalWrapMode.Truncate;
            text.lineSpacing = .88f; Curve(text); return text;
        }
        FacetGraphic Box(Transform parent,Vector2 position,Vector2 size,Color color,bool facets=false)
        {
            var go = new GameObject("Faceted plate",typeof(RectTransform),typeof(FacetGraphic)); Rect(go,parent,position,size);
            var image = go.GetComponent<FacetGraphic>(); image.color = color; image.raycastTarget = false; image.facets = facets; Curve(image); return image;
        }
        SoaringUIArt Art(Transform parent,string id,Vector2 position,Vector2 size)
        {
            var go = new GameObject(id,typeof(RectTransform),typeof(RawImage)); Rect(go,parent,position,size);
            var image = go.GetComponent<RawImage>(); image.raycastTarget = false; Curve(image);
            var art = go.AddComponent<SoaringUIArt>(); art.image = image; art.Set(id); return art;
        }
        void Clear()
        {
            buttons.Clear(); foreach (var p in pointers) { p.hovered=null; p.hold=0; p.acted=false; }
            foreach (Transform child in panel.transform) { child.gameObject.SetActive(false); Destroy(child.gameObject); }
        }
        void Background()
        {
            Clear(); var backing=Box(panel.transform,Vector2.zero,new(1360,900),panelColor,true); backing.border=3; backing.edge=accent;
        }
        void Frame(string title,string description)
        {
            Background(); Label(panel.transform,title,new(0,335),new(1232,130),84,TextAnchor.MiddleLeft,true);
            subtitle=Label(panel.transform,description,new(0,208),new(1232,166)); subtitle.color=muted;
        }
        void Button(string label,float y,Action action,bool hold=false) => ButtonAt(label,new(0,y),new(1232,86),action,hold);
        void ButtonAt(string label,Vector2 position,Vector2 size,Action action,bool hold=false)
        {
            var image=Box(panel.transform,position,size,buttonColor);
            var text=Label(image.transform,label,Vector2.zero,size-new Vector2(52,8));
            var entry=new Entry { rect=image.rectTransform,image=image,label=text,action=action,hold=hold,title=label };
            if(hold){entry.progress=Box(image.transform,new(0,-size.y*.5f+14),new(size.x-28,12),ink).rectTransform;entry.progress.gameObject.SetActive(false);}
            buttons.Add(entry);
        }
        void MainMenu()
        {
            Background(); Art(panel.transform,"emblem",new(-322,150),new(610,315));
            Label(panel.transform,"SOARING",new(-322,-48),new(640,160),132,TextAnchor.MiddleCenter,true);
            Label(panel.transform,"Fly with your arms.\nEat or be eaten.",new(-322,-195),new(640,172),60,TextAnchor.MiddleCenter);
            if (game.records != null && game.records.bestScore>0) Label(panel.transform,"Best  "+game.records.bestScore,new(-322,-344),new(600,90),60,TextAnchor.MiddleCenter);
            ButtonAt("Play",new(340,170),new(512,100),game.Play);
            ButtonAt("How to fly",new(340,44),new(512,100),HowTo);
            ButtonAt("Settings",new(340,-82),new(512,100),Settings);
            ButtonAt("Quit · hold",new(340,-208),new(512,100),()=>Application.Quit(),true);
        }
        public void Show(GamePhase phase)
        {
            if (!panel) return;
            panel.gameObject.SetActive(phase!=GamePhase.Flying); hud.gameObject.SetActive(phase==GamePhase.Flying);
            lessonCanvas.gameObject.SetActive(phase==GamePhase.Flying && game.lesson<7); toastCanvas.gameObject.SetActive(false);
            Cursor.lockState=phase==GamePhase.Flying&&!input.xrRunning?CursorLockMode.Locked:CursorLockMode.None;
            Cursor.visible=phase!=GamePhase.Flying&&!input.xrRunning; page="main"; Debug.Log("SOARING_PHASE "+phase);
            switch (phase)
            {
                case GamePhase.Menu: MainMenu(); break;
                case GamePhase.Paused:
                    Frame("Paused",$"{SizeRules.Ladder[SizeRules.Tier(player.model.mass)].name} · {game.stats.catches} caught · {game.lives} lives");
                    Button("Resume",85,game.Resume); Button("Settings",-15,Settings); Button("How to fly",-115,HowTo);
                    Button("Restart · hold",-215,game.StartRun,true); Button("Main menu · hold",-315,game.Menu,true); break;
                case GamePhase.Calibration: CalibrationPanel(); break;
                case GamePhase.Caught:
                    Frame("Caught",$"A {game.caughtBy} caught you.\n{game.lives} lives remain. A safe perch awaits.");
                    Art(panel.transform,"bird_"+game.caughtBy.ToLowerInvariant(),new(0,-155),new(310,230)); break;
                case GamePhase.Summary:
                    Frame(game.stats.victory?"The valley is yours!":"Until the next flight",$"{SizeRules.Ladder[SizeRules.Tier(game.stats.peakMass)].name} · {game.stats.duration/60:F1} min · score {game.stats.Score}");
                    Art(panel.transform,"bird_"+SizeRules.Ladder[SizeRules.Tier(game.stats.peakMass)].id,new(-405,-96),new(280,224));
                    Label(panel.transform,$"{game.stats.catches} caught\nBest streak  {game.stats.bestStreak}\nBest score  {game.records.bestScore}",new(172,-69),new(750,230));
                    ButtonAt("Fly again",new(-390,-334),new(440,96),game.StartRun);
                    if(game.stats.victory) ButtonAt("Keep soaring",new(70,-334),new(430,96),game.Continue);
                    ButtonAt("Menu",new(500,-334),new(250,96),game.Menu); break;
            }
            Recenter();
        }
        public void Recenter() { recenterFrames=2; PlacePanel(); }
        void PlacePanel()
        {
            float scale=input.origin.transform.lossyScale.x;
            var forward=Vector3.ProjectOnPlane(input.eye.transform.forward,Vector3.up).normalized;
            if(forward.sqrMagnitude<.01f)forward=player.model.Forward;
            Place(panel,Quaternion.LookRotation(forward),scale);
        }
        void Place(Canvas canvas,Quaternion rotation,float scale)
        {
            canvas.transform.SetPositionAndRotation(input.eye.transform.position+rotation*Vector3.forward*PanelDistance*scale,rotation);
            canvas.transform.localScale=Vector3.one*scale/PixelsPerMetre;
        }
        public void Notice(string text)
        {
            if(!noticeText)return; noticeText.text=text; noticeUntil=Time.unscaledTime+3.2f; noticeHeld=0;
            toastCanvas.gameObject.SetActive(true);
            var gaze=Vector3.ProjectOnPlane(input.eye.transform.forward,Vector3.up).normalized;
            if(gaze.sqrMagnitude<.01f)gaze=player.model.Forward;
            Place(toastCanvas,Quaternion.LookRotation(gaze)*Quaternion.Euler(-13,-26,0),input.origin.transform.lossyScale.x);
        }
        void Back()=>Show(game.phase);
        public void CalibrationPanel()
        {
            page="calibration"; panel.gameObject.SetActive(true); hud.gameObject.SetActive(false); lessonCanvas.gameObject.SetActive(false);
            Frame("Spread your wings","Arms out and wrists flat. Hold still for two seconds.");
            Art(panel.transform,"gesture_spread",new(-360,-128),new(320,310));
            ButtonAt("Calibrate",new(250,-24),new(660,96),()=>{ if(input.Calibrate()){Notice("Wings calibrated");if(game.phase==GamePhase.Calibration)game.StartRun();else Back();}else subtitle.text="Keep both controllers tracked, arms spread."; });
            ButtonAt("Default wings",new(250,-140),new(660,96),()=>{if(game.phase==GamePhase.Calibration)game.SkipCalibration();else Back();});
            ButtonAt("Back",new(250,-256),new(660,96),Back); calibrationStill=0; Recenter();
        }
        void Settings()
        {
            page="settings"; var p=input.preferences; Frame("Settings","Make the flight comfortable for you.");
            Button("Comfort: "+(p.comfort==0?"Off":p.comfort<.75f?"Gentle":"Strong"),85,()=>{p.comfort=p.comfort==0?.5f:p.comfort<.75f?1:0;input.Save();Settings();});
            Button("Turn speed: "+p.turnSpeed+"° / second",-15,()=>{p.turnSpeed=p.turnSpeed==90?120:p.turnSpeed==120?180:p.turnSpeed==180?240:90;input.Save();Settings();});
            Button("Sound & wing power",-115,AudioSettings); Button("Tracking & calibration",-215,TrackingSettings); Button("Back",-315,Back);
        }
        void AudioSettings()
        {
            page="audio"; var p=input.preferences; Frame("Sound & lift","Tune the mix and the effort of each wingbeat.");
            Button("Master: "+Mathf.RoundToInt(p.master*100)+"%",85,()=>{p.master=Cycle(p.master);input.Save();AudioSettings();});
            Button("Music: "+Mathf.RoundToInt(p.music*100)+"%",-15,()=>{p.music=Cycle(p.music);input.Save();AudioSettings();});
            Button("Effects: "+Mathf.RoundToInt(p.effects*100)+"%",-115,()=>{p.effects=Cycle(p.effects);input.Save();AudioSettings();});
            Button("Wing power: "+p.flapPower.ToString("F2"),-215,()=>{p.flapPower=p.flapPower>=1.5f?1:p.flapPower+.15f;input.Save();AudioSettings();}); Button("Back",-315,Settings);
        }
        static float Cycle(float value)=>value>=.99f?0:Mathf.Min(1,value+.25f);
        void TrackingSettings()
        {
            page="tracking"; var p=input.preferences; Frame("Your wings, your space","Hold A / X to recenter. Hold Y to calibrate.");
            Button("Seated: "+(p.seated?"On":"Off"),85,()=>{p.seated=!p.seated;input.Save();TrackingSettings();});
            Button("Haptics: "+(p.haptics?"On":"Off"),-10,()=>{p.haptics=!p.haptics;input.Save();TrackingSettings();});
            Button("Dominant hand: "+(p.leftHanded?"Left":"Right"),-105,()=>{p.leftHanded=!p.leftHanded;input.Save();TrackingSettings();});
            Button("Recenter",-200,()=>{input.Recenter();Recenter();}); Button("Calibrate wings",-295,CalibrationPanel); Button("Back",-390,Settings);
        }
        void HowTo()
        {
            page="help"; Background(); Label(panel.transform,"How to fly",new(-320,337),new(650,120),84,TextAnchor.MiddleLeft,true);
            ButtonAt("Back",new(516,340),new(240,90),Back);
            for(int i=0;i<HelpIds.Length;i++) { int index=i; ButtonAt(HelpTabs[i],new(-458,215-i*82),new(280,74),()=>{helpCard=index;HowTo();}); if(i==helpCard){buttons[^1].selected=true;buttons[^1].image.color=accent;buttons[^1].label.color=ink;} }
            Label(panel.transform,HelpTitles[helpCard],new(180,220),new(780,112),84,TextAnchor.MiddleCenter,true).color=accent;
            Box(panel.transform,new(180,-10),new(740,320),Hex("2f4a6b"),true);
            Art(panel.transform,"gesture_"+HelpIds[helpCard],new(180,-10),new(380,310));
            Label(panel.transform,input.xrRunning?HelpVR[helpCard]:HelpDesktop[helpCard],new(180,-286),new(800,240)); Recenter();
        }
        void Update()
        {
            if(!panel)return;
            if(panel.gameObject.activeSelf)
            {
                if(!externalPointerHarness){HandlePointer(0);HandlePointer(1);}
                if(page=="calibration"&&input.xrRunning&&input.tracking)
                {
                    float span=Vector3.Distance(input.leftHand.localPosition,input.rightHand.localPosition);
                    calibrationStill=span>.8f&&input.wings.leftFlap+input.wings.rightFlap<.03f?calibrationStill+Time.unscaledDeltaTime:0;
                    if(calibrationStill>=2&&input.Calibrate()){if(game.phase==GamePhase.Calibration)game.StartRun();else Back();}
                }
            }
            else foreach(var pointer in pointers)pointer.ray.enabled=false;
            foreach(var button in buttons)
                if(button.hintUntil>0&&Time.unscaledTime>=button.hintUntil){button.label.text=button.title;button.hintUntil=0;}
            if(toastCanvas.gameObject.activeSelf)
            {
                bool unreadable=Vector3.Angle(input.eye.transform.forward,toastCanvas.transform.forward)>45;
                if(unreadable&&noticeHeld<5){float held=Mathf.Min(Time.unscaledDeltaTime,5-noticeHeld);noticeHeld+=held;noticeUntil+=held;}
                if(Time.unscaledTime>noticeUntil)toastCanvas.gameObject.SetActive(false);
            }
            if(Time.unscaledTime<nextHud)return; nextHud=Time.unscaledTime+.1f;
            int tier=SizeRules.Tier(player.model.mass);
            float progress=tier>=9?Mathf.Clamp01(game.stats.apexCatches/3f):Mathf.Log(player.model.mass/SizeRules.Ladder[tier].mass)/Mathf.Log(SizeRules.Ladder[tier+1].mass/SizeRules.Ladder[tier].mass);
            Fill(growthFill,540,32,Mathf.Clamp01(progress));
            if(tier!=lastTier){speciesText.text=SizeRules.Ladder[tier].name; nextSpecies.text=tier>=9?"Apex":SizeRules.Ladder[tier+1].name;speciesArt.Set("bird_"+SizeRules.Ladder[tier].id);lastTier=tier;}
            for(int i=0;i<lives.Count;i++)lives[i].color=i<game.lives?accent:buttonColor;
            bool lessonOn=game.phase==GamePhase.Flying&&game.lesson<7; lessonCanvas.gameObject.SetActive(lessonOn);
            if(lessonOn)
            {
                if(lastLesson!=game.lesson){lessonCounter.text=$"Lesson {game.lesson+1} of 7";lessonTitle.text=LessonTitles[game.lesson];lessonHint.text=input.xrRunning?LessonHints[game.lesson]:DesktopHints[game.lesson];lessonArt.Set("gesture_"+ArtIds[game.lesson]);lastLesson=game.lesson;}
                Fill(lessonFill,544,-110,game.LessonCompletion);
            }
        }
        static void Fill(RectTransform rect,float width,float centre,float progress)
        {
            float fill=Mathf.Max(.01f,width*progress);rect.sizeDelta=new(fill,rect.sizeDelta.y);rect.anchoredPosition=new(centre-width*.5f+fill*.5f,rect.anchoredPosition.y);
        }
        void HandlePointer(int index)
        {
            var pointer=pointers[index];
            if(index==1&&!input.xrRunning){pointer.ray.enabled=false;return;}
            Ray ray;
            if(input.xrRunning){var hand=index==0?input.leftAim:input.rightAim;ray=new Ray(hand.position,hand.forward);}
            else {if(Mouse.current==null)return;ray=input.eye.ScreenPointToRay(Mouse.current.position.ReadValue());}
            ProcessPointer(index,ray,index==0?input.leftClick:input.rightClick,input.xrRunning);
        }
        void ProcessPointer(int index,Ray ray,bool down,bool showRay)
        {
            var pointer=pointers[index];
            float scale=input.origin.transform.lossyScale.x;
            var localRay=new Ray(panel.transform.InverseTransformPoint(ray.origin),panel.transform.InverseTransformDirection(ray.direction));
            Entry entry=null;Vector3 endpoint=ray.origin+ray.direction*2.5f*scale;
            if(CurvedPanelGeometry.Hit(localRay,PanelDistance*PixelsPerMetre,out var flat,out var hit)&&panelRect.rect.Contains(flat))
            {
                endpoint=panel.transform.TransformPoint(hit);
                if(Vector3.Distance(ray.origin,endpoint)<6*scale)
                    foreach(var button in buttons)
                    {
                        var local=button.rect.InverseTransformPoint(panel.transform.TransformPoint(new Vector3(flat.x,flat.y,0)));
                        if(button.rect.rect.Contains(new Vector2(local.x,local.y))){entry=button;break;}
                    }
            }
            pointer.ray.enabled=showRay;pointer.ray.startWidth=pointer.ray.endWidth=.0025f*scale;pointer.ray.SetPosition(0,ray.origin);pointer.ray.SetPosition(1,endpoint);
            if(entry!=pointer.hovered)
            {
                if(pointer.hovered?.progress)pointer.hovered.progress.gameObject.SetActive(false);
                pointer.hovered=entry;pointer.hold=0;pointer.acted=false;if(entry!=null)game.audio.Cue("hover");
            }
            foreach(var button in buttons)
            {
                bool hovered=button==pointers[0].hovered||button==pointers[1].hovered;
                bool active=hovered||button.selected;
                button.image.color=active?accent:buttonColor;button.label.color=active?ink:paper;
                float border=hovered?3:0;
                if(button.image.border!=border){button.image.border=border;button.image.SetVerticesDirty();}
            }
            if(traceInput&&down&&!pointer.previous)Debug.Log($"SOARING_POINTER hand={index} page={page} target={(entry!=null?entry.label.text:"none")}");
            if(entry!=null&&down&&!pointer.acted&&lastActionFrame!=Time.frameCount)
            {
                if(!pointer.previous)pointer.hold=0;
                pointer.hold+=Time.unscaledDeltaTime;
                if((!entry.hold&&!pointer.previous)||(entry.hold&&pointer.hold>=HoldSeconds))
                {
                    pointer.acted=true;lastActionFrame=Time.frameCount;game.audio.Cue("click");input.Haptic(.07f,.035f);entry.action();
                }
            }
            if(!down)
            {
                if(pointer.previous&&pointer.hold>0&&!pointer.acted&&entry!=null&&entry.hold)
                {entry.label.text="Hold to "+entry.title.Replace(" · hold","").ToLowerInvariant();entry.hintUntil=Time.unscaledTime+2.5f;}
                pointer.hold=0;pointer.acted=false;
            }
            pointer.previous=down;
            foreach(var button in buttons)
            {
                if(!button.progress)continue;
                float progress=0;
                foreach(var hand in pointers)if(hand.hovered==button&&hand.previous&&!hand.acted)progress=Mathf.Max(progress,hand.hold/HoldSeconds);
                button.progress.gameObject.SetActive(progress>0);
                if(progress>0)Fill(button.progress,button.rect.rect.width-28,0,Mathf.Clamp01(progress));
            }
        }
        public string CurrentPage => page;
        // Only the opt-in presentation harness can synthesize a pointer. It
        // uses the same curved hit test and trigger/hold logic as both devices.
        public bool ExercisePointer(string label,int hand,bool pressed)
        {
            if(!Array.Exists(Environment.GetCommandLineArgs(),a=>a=="--verify-presentation"))return false;
            externalPointerHarness=true;
            var entry=buttons.Find(b=>b.title==label);
            if(entry==null)return false;
            var flat=panel.transform.InverseTransformPoint(entry.rect.TransformPoint(Vector3.zero));
            var target=panel.transform.TransformPoint(CurvedPanelGeometry.Bend(flat,PanelDistance*PixelsPerMetre));
            float scale=input.origin.transform.lossyScale.x;
            var origin=input.eye.transform.position+input.eye.transform.right*(hand==0?-.18f:.18f)*scale-Vector3.up*.25f*scale;
            ProcessPointer(hand,new Ray(origin,(target-origin).normalized),pressed,true);
            return true;
        }
        bool DirectionCovers(Vector3 direction,Quaternion rotation,float width,float height)
        {
            var local=Quaternion.Inverse(rotation)*direction.normalized;
            return local.z>0&&Mathf.Abs(Mathf.Atan2(local.x,local.z)*Mathf.Rad2Deg)<width&&Mathf.Abs(Mathf.Asin(local.y)*Mathf.Rad2Deg)<height;
        }
        bool Protected(Quaternion rotation,float width,float height)
        {
            return Covers(game.ecosystem.prey,rotation,width,height)||Covers(game.ecosystem.threat,rotation,width,height)
                || (player.model.velocity.magnitude>1.5f*input.origin.transform.lossyScale.x&&DirectionCovers(player.model.velocity,rotation,width,height));
        }
        void Fade(CanvasGroup group,bool blocked,ref bool latched,ref float clearAt)
        {
            if(blocked){latched=true;clearAt=Time.unscaledTime+.12f;}
            else if(Time.unscaledTime>=clearAt)latched=false;
            group.alpha=Mathf.MoveTowards(group.alpha,latched?.15f:1,Time.unscaledDeltaTime/(latched?.12f:.28f));
        }
        bool Covers(BirdAgent bird,Quaternion rotation,float width,float height)
        {
            if(bird==null||!bird.alive||bird.hidden)return false;
            var direction=Quaternion.Inverse(rotation)*(bird.position-input.eye.transform.position).normalized;
            return direction.z>0&&Mathf.Abs(Mathf.Atan2(direction.x,direction.z)*Mathf.Rad2Deg)<width&&Mathf.Abs(Mathf.Asin(direction.y)*Mathf.Rad2Deg)<height;
        }
        void LateUpdate()
        {
            if(recenterFrames>0){recenterFrames--;PlacePanel();}
            if(!hud)return;
            float scale=input.origin.transform.lossyScale.x;
            var body=Quaternion.Euler(0,player.model.yaw*Mathf.Rad2Deg,0);
            var growthRotation=body*Quaternion.Euler(35,0,0);
            Place(hud,growthRotation,scale);Fade(growthGroup,Protected(growthRotation,17,6),ref growthBlocked,ref growthClearAt);
            var noticeRotation=body*Quaternion.Euler(-13,26*noticeSide,0);
            bool blocked=Protected(noticeRotation,17,8);
            if(blocked)
            {
                if(blockedSince<0)blockedSince=Time.unscaledTime;
                var mirror=body*Quaternion.Euler(-13,-26*noticeSide,0);
                if(Time.unscaledTime-blockedSince>1&&Time.unscaledTime>=nextSideChange&&!Protected(mirror,17,8))
                {noticeSide=-noticeSide;nextSideChange=Time.unscaledTime+5;blockedSince=-1;noticeRotation=mirror;blocked=false;}
            }
            else blockedSince=-1;
            Fade(lessonGroup,blocked,ref lessonBlocked,ref lessonClearAt);
            Place(lessonCanvas,noticeRotation,scale);
        }
        void OnDestroy(){foreach(var p in pointers)if(p.ray)Destroy(p.ray.material);}
    }
}
