using System.Collections.Generic;
using UnityEngine;

namespace Soaring
{
    /// <summary>Procedural aviary, population and interactions. Coordinates never scale with growth.</summary>
    public sealed class BirdWorld : MonoBehaviour
    {
        public float ArenaRadius = 240f;
        public float Ceiling = 150f;
        public bool SliceMode;
        public readonly List<NpcBird> Birds = new List<NpcBird>();
        public string ThreatText { get; private set; } = "";
        public float ThreatIntensity { get; private set; }
        public int GatePasses { get; private set; }
        public int Population => Birds.Count;
        public Vector3 SpawnForward { get; private set; } = Vector3.forward;
        public Vector3 SpawnRight => Vector3.Cross(Vector3.up,SpawnForward);
        public Vector3 SliceCenter => spawnOrigin+SpawnForward*20;
        Vector3 spawnOrigin;
        public int ActivePopulation { get { int n = 0; foreach (var bird in Birds) if (bird.Alive) n++; return n; } }
        public Material PreyMaterial { get; private set; }
        public Material PredatorMaterial { get; private set; }
        public Material NeutralMaterial { get; private set; }
        public Material WingMaterial { get; private set; }
        public Material BeakMaterial { get; private set; }
        public Material WarningMaterial { get; private set; }
        public Material BirdCreamMaterial { get; private set; }
        readonly List<Vector3> updrafts = new List<Vector3>();
        public IReadOnlyList<Vector3> UpdraftCenters => updrafts;
        readonly List<Gate> gates = new List<Gate>();
        readonly List<GameObject> apexMarkers = new List<GameObject>();
        readonly Dictionary<string, Material> palette = new Dictionary<string, Material>();
        System.Random random = new System.Random(49173);
        Transform geometry;
        Transform population;
        bool built;
        Vector3 previousPlayer;
        float replenishTimer;
        float grace;
        int apexIndex;
        struct Gate { public Vector3 Position; public Vector3 Normal; public float Radius; public bool Apex; public float Cooldown; }

        public void Build()
        {
            if (built) return;
            built = true;
            geometry = new GameObject("Cloudgarden · static world").transform; geometry.SetParent(transform);
            population = new GameObject("Living sky").transform; population.SetParent(transform);
            var meadow = Mat("Meadow", new Color(.38f,.60f,.38f));
            var stone = Mat("Cliff", new Color(.47f,.52f,.47f));
            var bark = Mat("Cedar bark", new Color(.34f,.22f,.13f));
            var leaf = Mat("Cedar canopy", new Color(.18f,.42f,.26f));
            var leafLight = Mat("New leaves", new Color(.49f,.67f,.33f));
            var building = Mat("Sunlit sandstone", new Color(.93f,.80f,.60f));
            var roof = Mat("Slate roofs", new Color(.64f,.29f,.19f));
            var coral = Mat("Flight gates", new Color(1f,.48f,.31f), true);
            var wire = Mat("Power cable", new Color(.17f,.23f,.27f));
            var white = Mat("Cloud", new Color(.88f,.96f,.94f));
            var thermal = Mat("Thermal", new Color(.38f,.91f,.91f), true);
            var crown = Mat("Apex gold", new Color(1f,.83f,.28f), true);
            PreyMaterial = Mat("Goldfinch", new Color(1f,.77f,.24f));
            PredatorMaterial = Mat("Kestrel", new Color(.75f,.31f,.30f));
            NeutralMaterial = Mat("Peer bird", new Color(.48f,.64f,.76f));
            WingMaterial = Mat("Flight feathers", new Color(.12f,.23f,.31f));
            BeakMaterial = Mat("Beak", new Color(1f,.48f,.18f));
            WarningMaterial = Mat("Hunt warning", new Color(1f,.22f,.10f), true);
            BirdCreamMaterial = Mat("Bird ivory plumage",new Color(1,.92f,.72f));
            Disc("Island meadow", 238, -1, meadow);
            // An unmistakable closed bowl: soft boundary begins before the cliffs.
            for (int i=0; i<44; i++)
            {
                float a=i*Mathf.PI*2/44; float r=ArenaRadius+5;
                var p=new Vector3(Mathf.Sin(a)*r,7+Rand(0,14),Mathf.Cos(a)*r);
                Boulder("Sanctuary ridge",p,new Vector3(39,34+Rand(0,31),31),stone,true);
                Boulder("Grassy ridge cap",p+Vector3.up*18,new Vector3(31,12,26),meadow,false);
            }
            RidgeSkirt();
            // Grove left of the clear starting flight lane.
            for(int i=0;i<36;i++)
            {
                float a=Rand(0,Mathf.PI*2); float r=Rand(45,180);
                var p=new Vector3(Mathf.Cos(a)*r,0,Mathf.Sin(a)*r);
                if (Mathf.Abs(p.x)<23 && p.z>-30 && p.z<95) p.x-=40;
                Tree(p,Rand(18,39),bark,i%3==0?leafLight:leaf);
            }
            // Village: hollow window frames invite intentional fly-throughs.
            Tower(new Vector3(76,0,65),26,48,building,roof);
            Tower(new Vector3(117,0,93),30,72,building,roof);
            Tower(new Vector3(-92,0,78),22,42,building,roof);
            Tower(new Vector3(-131,0,-45),27,61,building,roof);
            Tower(new Vector3(62,0,-103),24,58,building,roof);
            for(int i=0;i<5;i++)
            {
                var p=new Vector3(-75+i*33,0,-56);
                Cylinder("Utility pole", p+Vector3.up*18,new Vector3(.8f,36,.8f),bark,true);
                Primitive("Pole crossarm",PrimitiveType.Cube,p+Vector3.up*34,new Vector3(8,.55f,.55f),bark,true);
                if(i<4) for(int j=-1;j<=1;j++) Beam("Power line",p+new Vector3(j*3,33,0),p+new Vector3(33+j*3,33,0),.10f,wire,true);
            }
            // Nest hoops sit beside cedar branches; several are tight at larger sizes.
            for(int i=0;i<5;i++)
            {
                var p=new Vector3(-57-i*18,28+i*6,35+i*17);
                Nest(p,Quaternion.Euler(0,24+i*20,0),bark);
            }
            AddGate(new Vector3(0,25,40),Vector3.forward,6,coral,false);
            AddGate(new Vector3(12,34,91),new Vector3(.3f,.2f,1).normalized,7,coral,false);
            AddGate(new Vector3(55,44,120),Vector3.right,8,coral,false);
            AddGate(new Vector3(-42,45,-24),Vector3.forward,5,coral,false);
            AddGate(new Vector3(-108,63,101),Vector3.right,5,coral,false);
            AddGate(new Vector3(149,87,-35),Vector3.forward,16,crown,true);
            AddGate(new Vector3(-126,109,-97),Vector3.right,18,crown,true);
            AddGate(new Vector3(0,125,148),Vector3.forward,20,crown,true);
            AddThermal(new Vector3(-33,0,80),thermal);
            AddThermal(new Vector3(87,0,-38),thermal);
            AddThermal(new Vector3(-126,0,-97),thermal);
            // High clouds outline the flight ceiling while preserving open sightlines.
            for(int i=0;i<20;i++)
            {
                float a=i*Mathf.PI*2/20; var p=new Vector3(Mathf.Sin(a)*Rand(145,225),Rand(154,178),Mathf.Cos(a)*Rand(145,225));
                Boulder("Cloud bank",p,new Vector3(Rand(24,40),7,Rand(14,25)),white,false);
                Boulder("Cloud billow",p+new Vector3(6,3,0),new Vector3(17,9,14),white,false);
            }
            // Lighting and sky are configured by bootstrap; world supplies only scenery.
            var stream=Mat("Glacial brook",new Color(.26f,.62f,.68f));
            Brook(stream);
            MeadowBanks();
            for(int i=0;i<32;i++)
            {
                float a=Rand(0,Mathf.PI*2),r=Rand(65,205);var p=new Vector3(Mathf.Cos(a)*r,1,Mathf.Sin(a)*r);
                if(Mathf.Abs(p.x)<20 && p.z>-20 && p.z<100)continue;
                Boulder("Meadow granite",p,new Vector3(Rand(3,8),Rand(2,5),Rand(3,7)),stone,true);
                ContactShade(p,4);
            }
            ConsolidateVisuals();
            StaticBatchingUtility.Combine(geometry.gameObject);
        }

        public void ResetPopulation()
        {
            if(!built) Build();
            Physics.SyncTransforms();
            foreach(var bird in Birds) if(bird) Destroy(bird.gameObject);
            Birds.Clear(); random=new System.Random(49173); ThreatText=""; ThreatIntensity=0; grace=GameSession.Instance && GameSession.Instance.Player && GameSession.Instance.Player.Tuning != null ? GameSession.Instance.Player.Tuning.safetySeconds : 7; replenishTimer=0; apexIndex=0; GatePasses=0;
            var session=GameSession.Instance;
            previousPlayer=session && session.Player?session.Player.Position:new Vector3(0,24,0);
            spawnOrigin=previousPlayer;
            SpawnForward=session && session.Player && session.Player.Head?Vector3.ProjectOnPlane(session.Player.Head.forward,Vector3.up).normalized:Vector3.forward;
            if(SpawnForward.sqrMagnitude<.1f)SpawnForward=Vector3.forward;
            int count=SliceMode?1:72;
            for(int i=0;i<count;i++)
            {
                float size=i<44?Rand(.38f,.78f):i<60?Rand(1.18f,2.15f):Rand(2.3f,5.6f);
                Vector3 position=RandomAirPosition();
                if(i<14) position=previousPlayer+SpawnRight*Rand(-20,20)+Vector3.up*Rand(-6,7)+SpawnForward*Rand(12,65);
                if(i==0) { size=.55f; position=previousPlayer+SpawnForward*13; }
                var go=new GameObject(i==0?"First goldfinch":"Bird "+i); go.transform.SetParent(population);
                var bird=go.AddComponent<NpcBird>(); bird.Initialize(this,size,Constrain(position,1),i); Birds.Add(bird);
            }
            for(int i=0;i<gates.Count;i++) { var gate=gates[i];gate.Cooldown=0;gates[i]=gate; }
            RefreshApexMarkers();
        }

        void Update()
        {
            var session=GameSession.Instance;
            if(!built || !session || !session.Player || !session.IsPlaying || session.IsPaused || session.IsDead || session.HasWon) return;
            float dt=Time.deltaTime; grace=Mathf.Max(0,grace-dt); var player=session.Player; var position=player.Position;
            ThreatIntensity=0; ThreatText="";
            foreach(var bird in Birds)
            {
                if(!bird.Alive) continue;
                float contact=(player.Size+bird.Size)*.62f;
                float distance=DistanceToSegment(Vector3.zero,bird.PreviousPosition-previousPlayer,bird.Position-position);
                if(player.Size>bird.Size*1.12f && distance<contact)
                {
                    session.Catch(bird.Size); bird.Eaten(2.5f); player.Haptic(.6f,.10f); continue;
                }
                if(bird.IsHuntingPlayer && bird.HuntSeconds>0)
                {
                    float danger=Mathf.Clamp01(1-Vector3.Distance(position,bird.Position)/60);
                    if(danger>ThreatIntensity) { ThreatIntensity=danger;ThreatText=bird.HuntSeconds<Mathf.Max(3,player.Tuning.threatWarningSeconds)?"HUNTER ALERT · spread wings and climb":"HUNTER CLOSE · dive, turn or find an updraft"; }
                    if(grace<=0 && bird.HuntSeconds>=Mathf.Max(3,player.Tuning.threatWarningSeconds) && distance<contact && bird.Size>player.Size*1.12f)
                    { session.Kill("Caught by a kestrel. Bank hard or climb in an updraft when a hunter appears."); player.Haptic(1,.25f); break; }
                }
            }
            for(int i=0;i<gates.Count;i++)
            {
                var gate=gates[i]; gate.Cooldown=Mathf.Max(0,gate.Cooldown-dt);
                float before=Vector3.Dot(previousPlayer-gate.Position,gate.Normal),after=Vector3.Dot(position-gate.Position,gate.Normal);
                if(gate.Cooldown<=0 && before*after<0 && Mathf.Abs(after-before)>.001f)
                {
                    var crossing=Vector3.Lerp(previousPlayer,position,before/(before-after));
                    if(Vector3.Distance(crossing,gate.Position)<gate.Radius-player.Size*.5f)
                    {
                        gate.Cooldown=5;
                        if(!gate.Apex) { GatePasses++; player.Haptic(.25f,.06f); }
                        else if(player.Size>=player.Tuning.apexSize && i==ApexGateIndex(apexIndex % 3)) { session.ApexRing(); apexIndex++; RefreshApexMarkers(); player.Haptic(.85f,.14f); }
                    }
                }
                gates[i]=gate;
            }
            previousPlayer=position;
            replenishTimer+=dt;
            if(!SliceMode && replenishTimer>4)
            {
                replenishTimer=0; int easy=0;
                foreach(var bird in Birds) if(bird.Alive && bird.Size<player.Size*.78f && Vector3.Distance(bird.Position,position)<65) easy++;
                if(easy<7)
                {
                    foreach(var bird in Birds)
                    {
                        if(!bird.Alive || Vector3.Distance(bird.Position,position)>140)
                        {
                            var forward=Vector3.ProjectOnPlane(player.Head?player.Head.forward:Vector3.forward,Vector3.up).normalized;
                            bird.Respawn(Mathf.Clamp(player.Size*Rand(.40f,.72f),.38f,3.4f),Constrain(position+forward*Rand(24,52)+new Vector3(Rand(-18,18),Rand(-7,12),0),1));
                            if(++easy>=7) break;
                        }
                    }
                }
            }
        }

        int ApexGateIndex(int stage) { int n=0; for(int i=0;i<gates.Count;i++) if(gates[i].Apex) { if(n++==stage)return i; } return -1; }
        void RefreshApexMarkers() { for(int i=0;i<apexMarkers.Count;i++) apexMarkers[i].SetActive(i==apexIndex % 3); }
        public Vector3 NextApexPosition { get { int i=ApexGateIndex(apexIndex % 3);return i>=0?gates[i].Position:Vector3.zero; } }
        public Vector3 RandomAirPosition() { float a=Rand(0,Mathf.PI*2),r=Mathf.Sqrt(Rand(0,1))*ArenaRadius*.78f;return new Vector3(Mathf.Cos(a)*r,Rand(16,114),Mathf.Sin(a)*r); }
        /// <summary>Spawn centers are clear of solid scenery, including at larger sizes.</summary>
        public Vector3 FindClearAirPosition(Vector3 preferred,float radius)
        {
            radius=Mathf.Max(.15f,radius);
            var candidate=Constrain(preferred,radius);
            if(!Physics.CheckSphere(candidate,radius,~0,QueryTriggerInteraction.Ignore))return candidate;
            for(int i=0;i<28;i++)
            {
                // Nearby retries preserve the food placement; random retries cover crowded groves.
                candidate=Constrain(i<12?preferred+new Vector3(Rand(-16,16),Rand(-9,18),Rand(-16,16)):RandomAirPosition(),radius);
                if(!Physics.CheckSphere(candidate,radius,~0,QueryTriggerInteraction.Ignore))return candidate;
            }
            // The open upper central sky is free of all generated static scenery.
            return new Vector3(0,Ceiling-radius-2,0);
        }
        public Vector3 Constrain(Vector3 position,float radius)
        {
            float bound=Mathf.Max(8,ArenaRadius-radius-6); var planar=new Vector2(position.x,position.z);
            if(planar.magnitude>bound) { planar=planar.normalized*bound;position.x=planar.x;position.z=planar.y; }
            position.y=Mathf.Clamp(position.y,3+radius,Ceiling-radius);return position;
        }
        public Vector3 BoundarySteering(Vector3 position)
        {
            var planar=new Vector3(position.x,0,position.z);var force=Vector3.zero;
            if(planar.magnitude>ArenaRadius-48)force-=planar.normalized*Mathf.InverseLerp(ArenaRadius-48,ArenaRadius-8,planar.magnitude)*3;
            if(position.y<12)force.y+=(12-position.y)*.2f;
            if(position.y>Ceiling-18)force.y-=(position.y-(Ceiling-18))*.2f;
            return force;
        }
        public float UpdraftAt(Vector3 position)
        {
            float lift=0;foreach(var center in updrafts) { float d=new Vector2(position.x-center.x,position.z-center.z).magnitude;if(d<17 && position.y<130) lift=Mathf.Max(lift,11*(1-d/17)*Mathf.Clamp01((137-position.y)/15)); } return lift;
        }
        public bool ObstacleAhead(Vector3 origin,Vector3 direction,float distance) => Physics.SphereCast(origin,.65f,direction.normalized,out _,distance,~0,QueryTriggerInteraction.Ignore);
        public bool ObstacleAhead(Vector3 origin,Vector3 direction,float distance,float radius,out RaycastHit hit) => Physics.SphereCast(origin,radius,direction.normalized,out hit,distance,~0,QueryTriggerInteraction.Ignore);
        public static float DistanceToSegment(Vector3 point,Vector3 a,Vector3 b) { var delta=b-a;float t=delta.sqrMagnitude>.0001f?Mathf.Clamp01(Vector3.Dot(point-a,delta)/delta.sqrMagnitude):0; return Vector3.Distance(point,a+delta*t); }
        float Rand(float min,float max)=>min+(float)random.NextDouble()*(max-min);

        Material Mat(string name,Color color,bool glow=false)
        {
            if(palette.TryGetValue(name,out var existing))return existing;
            var shader=Shader.Find("Universal Render Pipeline/Simple Lit");if(!shader)shader=Shader.Find("Universal Render Pipeline/Lit");if(!shader)shader=Shader.Find("Standard");
            var mat=new Material(shader){name=name,color=color};if(mat.HasProperty("_BaseColor"))mat.SetColor("_BaseColor",color);if(glow){mat.EnableKeyword("_EMISSION");mat.SetColor("_EmissionColor",color*.35f);}if(mat.HasProperty("_Smoothness"))mat.SetFloat("_Smoothness",0);if(mat.HasProperty("_SpecColor"))mat.SetColor("_SpecColor",Color.black);if(mat.HasProperty("_Glossiness"))mat.SetFloat("_Glossiness",0);mat.enableInstancing=true;palette.Add(name,mat);return mat;
        }
        GameObject Primitive(string name,PrimitiveType kind,Vector3 position,Vector3 scale,Material material,bool solid,Quaternion rotation=default)
        {
            var go=GameObject.CreatePrimitive(kind);go.name=name;go.transform.SetParent(geometry);go.transform.position=position;go.transform.localScale=scale;if(rotation!=default)go.transform.rotation=rotation;
            var renderer=go.GetComponent<Renderer>();renderer.sharedMaterial=material;renderer.shadowCastingMode=UnityEngine.Rendering.ShadowCastingMode.Off;renderer.receiveShadows=false;
            if(!solid){var collider=go.GetComponent<Collider>();if(collider){collider.enabled=false;Destroy(collider);}}
            go.isStatic=true;return go;
        }
        void Cylinder(string name,Vector3 position,Vector3 scale,Material material,bool solid)=>Primitive(name,PrimitiveType.Cylinder,position,new Vector3(scale.x,scale.y*.5f,scale.z),material,solid);
        void Beam(string name,Vector3 a,Vector3 b,float width,Material material,bool solid) { Primitive(name,PrimitiveType.Cube,(a+b)*.5f,new Vector3(width,width,(b-a).magnitude),material,solid,Quaternion.LookRotation(b-a)); }
        void Tree(Vector3 p,float h,Material bark,Material leaves)
        {
            ContactShade(p,7);
            Cylinder("Tapered cedar trunk",p+Vector3.up*h*.42f,new Vector3(1.6f,h*.84f,1.6f),bark,true);
            var shadowLeaf=Mat("Deep canopy",new Color(.12f,.32f,.22f));
            var tips=Mat("Canopy sunlight",new Color(.47f,.65f,.31f));
            for(int i=0;i<4;i++)
            {
                float a=Rand(0,Mathf.PI*2);var tip=p+new Vector3(Mathf.Cos(a)*Rand(6,11),h*(.46f+i*.13f),Mathf.Sin(a)*Rand(6,11));
                Beam("Cedar climbing branch",p+Vector3.up*h*(.40f+i*.13f),tip,.55f,bark,true);
                Boulder("Layered leafy crown",tip+Vector3.up*2,new Vector3(13-i*.8f,7,12-i*.8f),i%2==0?leaves:shadowLeaf,false);
                Boulder("Sunlit leaves",tip+new Vector3(-1,4,1),new Vector3(9,4,8),tips,false);
            }
            Boulder("Cedar summit",p+Vector3.up*h,new Vector3(10,9,10),leaves,false);
            for(int i=0;i<3;i++){float a=i*2.1f;Beam("Cedar exposed root",p+Vector3.up*1.3f,p+new Vector3(Mathf.Cos(a)*3,0,Mathf.Sin(a)*3),.65f,bark,true);}
        }
        void Tower(Vector3 p,float width,float h,Material stone,Material roof)
        {
            ContactShade(p,width*.72f);
            float opening=11,baseHeight=h*.38f,apertureHeight=14;
            var trim=Mat("Ivory architectural trim",new Color(1,.91f,.73f));
            var dark=Mat("Shaded window recess",new Color(.30f,.37f,.35f));
            var timber=Mat("Balcony timber",new Color(.38f,.26f,.16f));
            Primitive("Sanctuary tower base",PrimitiveType.Cube,p+Vector3.up*baseHeight*.5f,new Vector3(width,baseHeight,width),stone,true);
            for(int side=-1;side<=1;side+=2)Primitive("Fly through window pier",PrimitiveType.Cube,p+new Vector3(side*(width+opening)*.25f,baseHeight+apertureHeight*.5f,0),new Vector3((width-opening)*.5f,apertureHeight,width),stone,true);
            float top=h-baseHeight-apertureHeight;
            Primitive("Window lintel",PrimitiveType.Cube,p+Vector3.up*(baseHeight+apertureHeight+top*.5f),new Vector3(width,top,width),stone,true);
            Primitive("Foundation plinth",PrimitiveType.Cube,p+Vector3.up*1.1f,new Vector3(width+2.2f,2.2f,width+2.2f),trim,true);
            Primitive("Roof cornice",PrimitiveType.Cube,p+Vector3.up*(h-.7f),new Vector3(width+1.5f,1.5f,width+1.5f),trim,false);
            GableRoof(p+Vector3.up*h,width+5,width+5,10,roof);
            Primitive("Roof ridge cap",PrimitiveType.Cube,p+Vector3.up*(h+10.2f),new Vector3(.8f,.7f,width+6),roof,false);
            Primitive("Chimney",PrimitiveType.Cube,p+new Vector3(width*.25f,h+8,width*.19f),new Vector3(2,7,2),stone,true);
            for(int facing=-1;facing<=1;facing+=2)
            {
                float z=facing*(width*.5f+.35f);
                for(int side=-1;side<=1;side+=2)
                {
                    Primitive("Ivory window jamb",PrimitiveType.Cube,p+new Vector3(side*6,baseHeight+7,z),new Vector3(1.2f,15.5f,1),trim,false);
                    Primitive("Timber shutter",PrimitiveType.Cube,p+new Vector3(side*8.2f,baseHeight+7,z+.15f*facing),new Vector3(2.6f,12,.45f),timber,false,Quaternion.Euler(0,side*facing*16,0));
                }
                Primitive("Window sill",PrimitiveType.Cube,p+new Vector3(0,baseHeight-.4f,z),new Vector3(14,1,2.2f),trim,false);
                Primitive("Window architrave",PrimitiveType.Cube,p+new Vector3(0,baseHeight+14.3f,z),new Vector3(14,1.3f,1.2f),trim,false);
                for(int row=0;row<2;row++)for(int column=-1;column<=1;column+=2)
                {
                    var wp=p+new Vector3(column*width*.27f,5+row*7,z);
                    Primitive("Inset village window",PrimitiveType.Cube,wp,new Vector3(3.4f,4,.35f),dark,false);
                    Primitive("Village window crossbar",PrimitiveType.Cube,wp+Vector3.forward*facing*.2f,new Vector3(3.6f,.22f,.2f),trim,false);
                    Primitive("Village window mullion",PrimitiveType.Cube,wp+Vector3.forward*facing*.2f,new Vector3(.22f,4.2f,.2f),trim,false);
                }
            }
            // Flower boxes and covered lower roofs give each tower a inhabited silhouette.
            Primitive("Balcony deck",PrimitiveType.Cube,p+new Vector3(0,baseHeight-1,-width*.5f-2),new Vector3(16,.8f,5),timber,true);
            for(int side=-1;side<=1;side+=2)Boulder("Balcony trailing leaves",p+new Vector3(side*7,baseHeight-2,-width*.5f-3),new Vector3(3,4,3),Mat("Balcony greens",new Color(.27f,.48f,.25f)),false);
        }
        void GableRoof(Vector3 p,float width,float depth,float h,Material material)
        {
            var vertices=new[]{new Vector3(-width/2,0,-depth/2),new Vector3(width/2,0,-depth/2),new Vector3(0,h,-depth/2),new Vector3(-width/2,0,depth/2),new Vector3(width/2,0,depth/2),new Vector3(0,h,depth/2)};
            MeshObject("Terracotta gabled roof",p,Quaternion.identity,FlatMesh(vertices,new[]{0,2,1,3,4,5,0,3,5,0,5,2,1,2,5,1,5,4}),material,false);
        }
        void Nest(Vector3 p,Quaternion rotation,Material bark)
        {
            var straw=Mat("Sunlit woven straw",new Color(.66f,.46f,.23f));
            var stem=p+new Vector3(-13,-7,4);
            Cylinder("Nest cedar support",new Vector3(stem.x,(stem.y+5)*.5f,stem.z),new Vector3(1.3f,stem.y+5,1.3f),bark,true);
            Beam("Nest carrying bough",stem,p+rotation*new Vector3(0,-3.8f,1),.75f,bark,true);
            Boulder("Nest cedar foliage",stem+Vector3.up*7,new Vector3(13,8,12),Mat("Nest cedar leaves",new Color(.30f,.52f,.29f)),false);
            ContactShade(new Vector3(stem.x,0,stem.z),5);
            Ring("Nest hollow entrance",p,rotation,3.2f,.58f,straw,true,32);
            Ring("Nest backing rim",p+rotation*new Vector3(0,0,2),rotation,3.5f,.72f,bark,true,28);
            Ring("Nest bowl rim",p+rotation*new Vector3(0,-2.9f,1.2f),rotation*Quaternion.Euler(90,0,0),3.8f,.65f,straw,true,28);
            Boulder("Nest bowl base",p+rotation*new Vector3(0,-3.6f,1.2f),new Vector3(7,1.5f,6),bark,true);
            for(int i=0;i<14;i++)
            {float a=i*Mathf.PI*2/14;var start=p+rotation*new Vector3(Mathf.Cos(a)*3.5f,Mathf.Sin(a)*3.5f,0);var end=p+rotation*new Vector3(Mathf.Cos(a+.42f)*3.7f,Mathf.Sin(a+.42f)*3.7f,2.4f);Beam("Woven nest twig",start,end,.15f,i%2==0?bark:straw,false);}
        }
        void AddThermal(Vector3 p,Material material)
        {
            updrafts.Add(p);
            Ring("Thermal meadow marker",p+Vector3.up*.3f,Quaternion.Euler(90,0,0),12,.11f,material,false,40);
            // Presentation supplies sparse rising flecks for an animated thermal cue.
            for(int i=0;i<7;i++){float a=i*Mathf.PI*2/7;Boulder("Thermal spring stones",p+new Vector3(Mathf.Cos(a)*8,0,Mathf.Sin(a)*8),new Vector3(3,1.2f,2),Mat("Warm spring stone",new Color(.66f,.63f,.45f)),false);}
        }
        void AddGate(Vector3 p,Vector3 normal,float radius,Material mat,bool apex)
        {
            var frame=Mat(apex?"Crown frame":"Verdigris flight gate",apex?new Color(.93f,.72f,.24f):new Color(.40f,.72f,.66f));
            float thickness=apex?.64f:.43f;var rotation=Quaternion.LookRotation(normal);
            Ring(apex?"Sculpted apex crown":"Sanctuary carved flight gate",p,rotation,radius,thickness,frame,true,48);
            Ring("Gate luminous front inlay",p-normal*(thickness+.06f),rotation,radius-.12f,.10f,mat,false,48);
            Ring("Gate luminous back inlay",p+normal*(thickness+.06f),rotation,radius-.12f,.10f,mat,false,48);
            for(int i=0;i<8;i++)
            {float a=i*Mathf.PI*2/8;var point=p+rotation*new Vector3(Mathf.Cos(a)*(radius+.12f),Mathf.Sin(a)*(radius+.12f),0);Boulder("Gate carved keystone",point,Vector3.one*(apex?1.3f:.9f),frame,false);}
            if(!apex)
            {
                var foot=p-Vector3.up*(radius+.4f);
                Cylinder("Gate carved pedestal",new Vector3(foot.x,foot.y*.5f,foot.z),new Vector3(1.5f,Mathf.Max(1,foot.y),1.5f),frame,true);
                Boulder("Gate mossy foundation",new Vector3(foot.x,.6f,foot.z),new Vector3(6,2.5f,5),Mat("Gate moss stone",new Color(.38f,.51f,.34f)),true);
                Ring("Gate foot ornament",foot,Quaternion.Euler(90,0,0),1.7f,.3f,frame,false,24);
            }
            gates.Add(new Gate{Position=p,Normal=normal,Radius=radius,Apex=apex});
            if(apex){var marker=Boulder("Apex beacon",p+Vector3.up*(radius+5),Vector3.one*2.2f,mat,false);apexMarkers.Add(marker);}
        }
        GameObject Ring(string name,Vector3 p,Quaternion rotation,float radius,float width,Material material,bool solid,int segments)
        {
            const int sides=6;var vertices=new List<Vector3>();var triangles=new List<int>();
            for(int i=0;i<segments;i++)for(int j=0;j<sides;j++)
            {float a=i*Mathf.PI*2/segments,b=(i+1)*Mathf.PI*2/segments,c=j*Mathf.PI*2/sides,d=(j+1)*Mathf.PI*2/sides;int n=vertices.Count;
                vertices.Add(TorusPoint(a,c,radius,width));vertices.Add(TorusPoint(b,c,radius,width));vertices.Add(TorusPoint(b,d,radius,width));vertices.Add(TorusPoint(a,d,radius,width));triangles.AddRange(new[]{n,n+1,n+2,n,n+2,n+3});}
            return MeshObject(name,p,rotation,FlatMesh(vertices.ToArray(),triangles.ToArray()),material,solid);
        }
        static Vector3 TorusPoint(float a,float b,float radius,float width)=>new Vector3(Mathf.Cos(a)*(radius+Mathf.Cos(b)*width),Mathf.Sin(a)*(radius+Mathf.Cos(b)*width),Mathf.Sin(b)*width);
        void AirRibbon(Vector3 p,float radius,Material material,float phase)
        {
            var vertices=new List<Vector3>();var faces=new List<int>();for(int i=0;i<14;i++){float a=i*.16f+phase;var center=new Vector3(Mathf.Cos(a)*radius,i*.33f,Mathf.Sin(a)*radius);vertices.Add(center+Vector3.up*.07f);vertices.Add(center-Vector3.up*.07f);if(i>0){int n=i*2;faces.AddRange(new[]{n-2,n,n+1,n-2,n+1,n-1,n+1,n,n-2,n-1,n+1,n-2});}}
            MeshObject("Rising air curl",p,Quaternion.identity,FlatMesh(vertices.ToArray(),faces.ToArray()),material,false);
        }
        GameObject Boulder(string name,Vector3 position,Vector3 scale,Material material,bool solid)
        {
            const int rings=5,sides=9;var vertices=new List<Vector3>();var faces=new List<int>();
            for(int y=0;y<=rings;y++)for(int i=0;i<sides;i++){float latitude=y*Mathf.PI/rings,a=i*Mathf.PI*2/sides;float wobble=1+.07f*Mathf.Sin(i*4.2f+y*2.9f);vertices.Add(Vector3.Scale(new Vector3(Mathf.Sin(latitude)*Mathf.Cos(a)*wobble,Mathf.Cos(latitude),Mathf.Sin(latitude)*Mathf.Sin(a)*wobble),scale*.5f));}
            for(int y=0;y<rings;y++)for(int i=0;i<sides;i++){int a=y*sides+i,b=y*sides+(i+1)%sides,c=(y+1)*sides+i,d=(y+1)*sides+(i+1)%sides;faces.AddRange(new[]{a,b,c,b,d,c});}
            return MeshObject(name,position,Quaternion.Euler(0,Rand(0,360),0),FlatMesh(vertices.ToArray(),faces.ToArray()),material,solid);
        }
        static Mesh FlatMesh(Vector3[] source,int[] faces)
        {
            var vertices=new Vector3[faces.Length];var indices=new int[faces.Length];for(int i=0;i<faces.Length;i++){vertices[i]=source[faces[i]];indices[i]=i;}var mesh=new Mesh();mesh.vertices=vertices;mesh.triangles=indices;mesh.RecalculateNormals();mesh.RecalculateBounds();return mesh;
        }
        GameObject MeshObject(string name,Vector3 p,Quaternion rotation,Mesh mesh,Material material,bool solid)
        {
            var go=new GameObject(name);go.transform.SetParent(geometry);go.transform.SetPositionAndRotation(p,rotation);go.AddComponent<MeshFilter>().sharedMesh=mesh;var renderer=go.AddComponent<MeshRenderer>();renderer.sharedMaterial=material;renderer.shadowCastingMode=UnityEngine.Rendering.ShadowCastingMode.Off;renderer.receiveShadows=false;if(solid)go.AddComponent<MeshCollider>().sharedMesh=mesh;go.isStatic=true;return go;
        }
        void Brook(Material material)
        {
            var vertices=new List<Vector3>();var faces=new List<int>();for(int i=0;i<90;i++){float z=-220+i*5,x=BrookX(z);vertices.Add(new Vector3(x-5,-.6f,z));vertices.Add(new Vector3(x+5,-.6f,z));if(i>0){int n=i*2;faces.AddRange(new[]{n-2,n,n+1,n-2,n+1,n-1});}}
            MeshObject("Winding sanctuary brook",Vector3.zero,Quaternion.identity,FlatMesh(vertices.ToArray(),faces.ToArray()),material,false);
        }
        void Cone(string name,Vector3 p,float radius,float height,Material material)
        {
            int sides=7;var vertices=new List<Vector3>();var triangles=new List<int>();
            for(int i=0;i<sides;i++) { float a=i*Mathf.PI*2/sides,b=(i+1)*Mathf.PI*2/sides;int n=vertices.Count;vertices.Add(new Vector3(Mathf.Cos(a)*radius,-height*.5f,Mathf.Sin(a)*radius));vertices.Add(new Vector3(0,height*.5f,0));vertices.Add(new Vector3(Mathf.Cos(b)*radius,-height*.5f,Mathf.Sin(b)*radius));triangles.Add(n);triangles.Add(n+1);triangles.Add(n+2); }
            var go=new GameObject(name);go.transform.SetParent(geometry);go.transform.position=p;var mesh=new Mesh{name="Seven sided canopy"};mesh.SetVertices(vertices);mesh.SetTriangles(triangles,0);mesh.RecalculateNormals();go.AddComponent<MeshFilter>().sharedMesh=mesh;go.AddComponent<MeshRenderer>().sharedMaterial=material;go.isStatic=true;
        }
        static float BrookX(float z)=>-34+Mathf.Sin(z*.018f)*20+Mathf.Sin(z*.048f)*5;
        void RidgeSkirt()
        {
            for(int layer=0;layer<2;layer++)
            {
                const int sides=96;var vertices=new List<Vector3>();var faces=new List<int>();float inner=layer==0?237:284,ridge=layer==0?272:321,outer=layer==0?320:380;
                for(int i=0;i<=sides;i++)
                {
                    float a=i*Mathf.PI*2/sides;float height=(layer==0?65:106)+Mathf.Sin(a*7+.4f)*14+Mathf.Sin(a*13+1.7f)*11+Mathf.Sin(a*3)*8;
                    var radial=new Vector3(Mathf.Cos(a),0,Mathf.Sin(a));vertices.Add(radial*inner+Vector3.down*4);vertices.Add(radial*ridge+Vector3.up*height);vertices.Add(radial*outer+Vector3.down*8);
                    if(i>0){int n=i*3;faces.AddRange(new[]{n-3,n,n+1,n-3,n+1,n-2,n-2,n+1,n+2,n-2,n+2,n-1});}
                }
                var material=Mat(layer==0?"Sage mountain ridge":"Distant blue mountain ridge",layer==0?new Color(.39f,.51f,.43f):new Color(.37f,.51f,.58f));
                MeshObject("Continuous sanctuary mountain ridge",Vector3.zero,Quaternion.identity,FlatMesh(vertices.ToArray(),faces.ToArray()),material,false);
            }
        }
        void MeadowBanks()
        {
            var lush=Mat("Lush bank meadow",new Color(.34f,.54f,.31f));var sunlight=Mat("Sunlit meadow variation",new Color(.46f,.63f,.37f));var sage=Mat("Sage meadow variation",new Color(.40f,.57f,.35f));var sand=Mat("Brook sandstone bank",new Color(.68f,.67f,.46f));
            var bankVertices=new List<Vector3>();var bankFaces=new List<int>();
            for(int side=-1;side<=1;side+=2)
            {
                int start=bankVertices.Count;
                for(int i=0;i<90;i++){float z=-220+i*5,x=BrookX(z)+side*5;bankVertices.Add(new Vector3(x,-.56f,z));bankVertices.Add(new Vector3(x+side*2.1f,-.55f,z));if(i>0){int n=start+i*2;if(side>0)bankFaces.AddRange(new[]{n-2,n,n+1,n-2,n+1,n-1});else bankFaces.AddRange(new[]{n-2,n+1,n,n-2,n-1,n+1});}}
            }
            MeshObject("Winding sandstone brook banks",Vector3.zero,Quaternion.identity,FlatMesh(bankVertices.ToArray(),bankFaces.ToArray()),sand,false);
            for(int i=0;i<28;i++)
            {
                float z=-202+i*15;int side=i%2==0?1:-1;float x=BrookX(z)+side*13;GroundPatch(new Vector3(x,0,z),Rand(7,13),Rand(12,20),i%2==0?lush:sage);
                if(i%2==0)
                {
                    var bush=new Vector3(BrookX(z)+side*8,GroundHeight(BrookX(z)+side*8,z)+1,z);Boulder("Brook bank rounded vegetation",bush,new Vector3(3.5f,2.4f,4.5f),lush,false);
                    ReedClump(new Vector3(BrookX(z)+side*6.4f,-.65f,z+2),lush);
                }
            }
            for(int i=0;i<22;i++)
            {
                float a=Rand(0,Mathf.PI*2),r=Rand(35,212);var p=new Vector3(Mathf.Cos(a)*r,0,Mathf.Sin(a)*r);
                if(Mathf.Abs(p.x-BrookX(p.z))<20)continue;GroundPatch(p,Rand(14,29),Rand(16,31),i%3==0?sunlight:sage);
            }
        }
        void GroundPatch(Vector3 p,float xRadius,float zRadius,Material material)
        {
            var vertices=new List<Vector3>{new Vector3(p.x,GroundHeight(p.x,p.z)+.055f,p.z)};var faces=new List<int>();
            for(int i=0;i<14;i++){float a=i*Mathf.PI*2/14,r=.85f+.14f*Mathf.Sin(i*4.3f+p.z);float x=p.x+Mathf.Cos(a)*xRadius*r,z=p.z+Mathf.Sin(a)*zRadius*r;vertices.Add(new Vector3(x,GroundHeight(x,z)+.065f,z));}
            for(int i=0;i<14;i++)faces.AddRange(new[]{0,1+(i+1)%14,1+i});MeshObject("Organic meadow variation",Vector3.zero,Quaternion.identity,FlatMesh(vertices.ToArray(),faces.ToArray()),material,false);
        }
        void ReedClump(Vector3 p,Material material)
        {
            var vertices=new List<Vector3>();var faces=new List<int>();
            for(int i=0;i<7;i++){float a=i*2.4f,h=.8f+Mathf.Repeat(i*.37f,.9f);var basePoint=new Vector3(Mathf.Cos(a)*.45f,0,Mathf.Sin(a)*.45f);var tip=basePoint+new Vector3(Mathf.Sin(a)*.3f,h,Mathf.Cos(a)*.3f);int n=vertices.Count;vertices.AddRange(new[]{basePoint-new Vector3(.07f,0,0),basePoint+new Vector3(.07f,0,0),tip,basePoint-new Vector3(0,0,.07f),basePoint+new Vector3(0,0,.07f),tip});faces.AddRange(new[]{n,n+2,n+1,n+1,n+2,n,n+3,n+4,n+5,n+5,n+4,n+3});}
            MeshObject("Low brook reeds",p,Quaternion.identity,FlatMesh(vertices.ToArray(),faces.ToArray()),material,false);
        }
        static float GroundHeight(float x,float z)
        {
            float brook=BrookX(z),river=Mathf.Clamp01((Mathf.Abs(x-brook)-14)/20),lane=Mathf.Clamp01((Mathf.Abs(x)-12)/25);
            return -1+(1+Mathf.Sin(x*.024f)*Mathf.Cos(z*.027f))*3.5f*river*lane;
        }
        void ContactShade(Vector3 p,float radius)
        {
            var shade=Mat("Soft contact shade",new Color(.25f,.41f,.27f));var vertices=new List<Vector3>{new Vector3(p.x,GroundHeight(p.x,p.z)+.025f,p.z)};var faces=new List<int>();
            for(int i=0;i<12;i++){float a=i*Mathf.PI*2/12,r=radius*(.8f+.17f*Mathf.Sin(i*4.7f));float x=p.x+Mathf.Cos(a)*r,z=p.z+Mathf.Sin(a)*r;vertices.Add(new Vector3(x,GroundHeight(x,z)+.03f,z));}
            for(int i=0;i<12;i++)faces.AddRange(new[]{0,1+(i+1)%12,1+i});MeshObject("Meadow contact shade",Vector3.zero,Quaternion.identity,FlatMesh(vertices.ToArray(),faces.ToArray()),shade,false);
        }
        void ConsolidateVisuals()
        {
            // Preserve independent apex beacons; consolidate decorative scenery in spatial chunks.
            // Colliders stay on their original objects, so gameplay openings are unchanged.
            var groups=new Dictionary<string,List<CombineInstance>>();var materials=new Dictionary<string,Material>();
            foreach(var renderer in geometry.GetComponentsInChildren<MeshRenderer>())
            {
                if(apexMarkers.Contains(renderer.gameObject))continue;var filter=renderer.GetComponent<MeshFilter>();if(!filter || !filter.sharedMesh)continue;
                var p=renderer.bounds.center;string key=renderer.sharedMaterial.GetEntityId()+":"+Mathf.FloorToInt(p.x/90)+":"+Mathf.FloorToInt(p.z/90);
                if(!groups.TryGetValue(key,out var list)){list=new List<CombineInstance>();groups.Add(key,list);materials.Add(key,renderer.sharedMaterial);}
                list.Add(new CombineInstance{mesh=filter.sharedMesh,transform=filter.transform.localToWorldMatrix});renderer.enabled=false;Destroy(renderer);Destroy(filter);
            }
            foreach(var pair in groups)
            {
                var mesh=new Mesh{name="Sanctuary scenery batch",indexFormat=UnityEngine.Rendering.IndexFormat.UInt32};mesh.CombineMeshes(pair.Value.ToArray(),true,true);
                var go=new GameObject("Scenery chunk");go.transform.SetParent(geometry);var renderer=go.AddComponent<MeshRenderer>();go.AddComponent<MeshFilter>().sharedMesh=mesh;renderer.sharedMaterial=materials[pair.Key];renderer.shadowCastingMode=UnityEngine.Rendering.ShadowCastingMode.Off;renderer.receiveShadows=false;go.isStatic=true;
            }
        }
        void Disc(string name,float radius,float y,Material material)
        {
            const int rings=40,sides=120;var source=new List<Vector3>{new Vector3(0,y,0)};
            for(int r=1;r<=rings;r++)for(int i=0;i<sides;i++)
            {float a=i*Mathf.PI*2/sides,rr=r*radius/rings;float x=Mathf.Cos(a)*rr,z=Mathf.Sin(a)*rr;float height=GroundHeight(x,z);source.Add(new Vector3(x,height,z));}
            var vertices=new List<Vector3>();var colors=new List<Color>();var faces=new List<int>();
            System.Action<int,int,int> triangle=(a,b,c)=>{int n=vertices.Count;vertices.Add(source[a]);vertices.Add(source[b]);vertices.Add(source[c]);faces.AddRange(new[]{n,n+1,n+2});};
            for(int i=0;i<sides;i++)triangle(0,1+(i+1)%sides,1+i);
            for(int r=1;r<rings;r++)for(int i=0;i<sides;i++){int a=1+(r-1)*sides+i,b=1+(r-1)*sides+(i+1)%sides,c=1+r*sides+i,d=1+r*sides+(i+1)%sides;triangle(a,d,c);triangle(a,b,d);}
            MeshObject(name,Vector3.zero,Quaternion.identity,FlatMesh(vertices.ToArray(),faces.ToArray()),material,true);
        }

    }
}
