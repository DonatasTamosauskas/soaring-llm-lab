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
        public int ActivePopulation { get { int n = 0; foreach (var bird in Birds) if (bird.Alive) n++; return n; } }
        public Material PreyMaterial { get; private set; }
        public Material PredatorMaterial { get; private set; }
        public Material WingMaterial { get; private set; }
        public Material BeakMaterial { get; private set; }
        public Material WarningMaterial { get; private set; }
        readonly List<Vector3> updrafts = new List<Vector3>();
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
            var meadow = Mat("Meadow", new Color(.28f,.48f,.38f));
            var stone = Mat("Cliff", new Color(.29f,.39f,.43f));
            var bark = Mat("Cedar bark", new Color(.35f,.25f,.20f));
            var leaf = Mat("Cedar canopy", new Color(.22f,.48f,.38f));
            var leafLight = Mat("New leaves", new Color(.39f,.63f,.45f));
            var building = Mat("Sunlit sandstone", new Color(.80f,.67f,.48f));
            var roof = Mat("Slate roofs", new Color(.23f,.36f,.42f));
            var coral = Mat("Flight gates", new Color(1f,.48f,.31f), true);
            var wire = Mat("Power cable", new Color(.17f,.23f,.27f));
            var white = Mat("Cloud", new Color(.88f,.96f,.94f));
            var thermal = Mat("Thermal", new Color(.38f,.91f,.91f), true);
            var crown = Mat("Apex gold", new Color(1f,.83f,.28f), true);
            PreyMaterial = Mat("Goldfinch", new Color(1f,.77f,.24f));
            PredatorMaterial = Mat("Kestrel", new Color(.75f,.31f,.30f));
            WingMaterial = Mat("Flight feathers", new Color(.12f,.23f,.31f));
            BeakMaterial = Mat("Beak", new Color(1f,.48f,.18f));
            WarningMaterial = Mat("Hunt warning", new Color(1f,.22f,.10f), true);
            Disc("Island meadow", 238, -1, meadow);
            // An unmistakable closed bowl: soft boundary begins before the cliffs.
            for (int i=0; i<44; i++)
            {
                float a=i*Mathf.PI*2/44; float r=ArenaRadius+5;
                var p=new Vector3(Mathf.Sin(a)*r,7+Rand(0,14),Mathf.Cos(a)*r);
                Primitive("Boundary crag", PrimitiveType.Cube, p, new Vector3(39,28+Rand(0,24),27), stone, true, Quaternion.Euler(Rand(-8,8),-a*Mathf.Rad2Deg,Rand(-7,7)));
                Primitive("Cliff grass",PrimitiveType.Cube,p+Vector3.up*19,new Vector3(37,3,26),meadow,false,Quaternion.Euler(0,-a*Mathf.Rad2Deg,0));
            }
            // Grove left of the clear starting flight lane.
            for(int i=0;i<24;i++)
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
                Ring("Woven nest entrance",p,Quaternion.Euler(0,24+i*20,0),3.2f,.36f,bark,true,16);
                Primitive("Nest perch",PrimitiveType.Cube,p+new Vector3(0,-3,2),new Vector3(7,.7f,7),bark,true);
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
                Primitive("Cloud bank",PrimitiveType.Sphere,p,new Vector3(Rand(16,27),5,Rand(10,18)),white,false);
            }
            var sun = new GameObject("Late afternoon sun"); sun.transform.SetParent(geometry); var light=sun.AddComponent<Light>(); light.type=LightType.Directional; light.color=new Color(1,.9f,.72f); light.intensity=1.3f; light.shadows=LightShadows.None; sun.transform.rotation=Quaternion.Euler(43,-32,0);
            RenderSettings.ambientMode=UnityEngine.Rendering.AmbientMode.Flat; RenderSettings.ambientLight=new Color(.58f,.72f,.78f); RenderSettings.fog=true; RenderSettings.fogColor=new Color(.59f,.79f,.85f); RenderSettings.fogMode=FogMode.Linear; RenderSettings.fogStartDistance=145; RenderSettings.fogEndDistance=370;
            if(Camera.main) { Camera.main.clearFlags=CameraClearFlags.SolidColor; Camera.main.backgroundColor=RenderSettings.fogColor; }
            StaticBatchingUtility.Combine(geometry.gameObject);
        }

        public void ResetPopulation()
        {
            if(!built) Build();
            foreach(var bird in Birds) if(bird) Destroy(bird.gameObject);
            Birds.Clear(); random=new System.Random(49173); ThreatText=""; ThreatIntensity=0; grace=GameSession.Instance && GameSession.Instance.Player && GameSession.Instance.Player.Tuning != null ? GameSession.Instance.Player.Tuning.safetySeconds : 7; replenishTimer=0; apexIndex=0; GatePasses=0;
            var session=GameSession.Instance;
            previousPlayer=session && session.Player?session.Player.Position:new Vector3(0,24,0);
            int count=SliceMode?1:72;
            for(int i=0;i<count;i++)
            {
                float size=i<44?Rand(.38f,.78f):i<60?Rand(1.18f,2.15f):Rand(2.3f,5.6f);
                Vector3 position=RandomAirPosition();
                if(i<14) position=previousPlayer+new Vector3(Rand(-20,20),Rand(-6,7),Rand(12,65));
                if(i==0) { size=.55f; position=previousPlayer+new Vector3(0,0,13); }
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
            var mat=new Material(shader){name=name,color=color};if(mat.HasProperty("_BaseColor"))mat.SetColor("_BaseColor",color);if(glow){mat.EnableKeyword("_EMISSION");mat.SetColor("_EmissionColor",color*.35f);}mat.enableInstancing=true;palette.Add(name,mat);return mat;
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
            Cylinder("Cedar trunk",p+Vector3.up*h*.45f,new Vector3(2.1f,h*.9f,2.1f),bark,true);
            for(int i=0;i<3;i++)
            {
                float a=Rand(0,Mathf.PI*2);var tip=p+new Vector3(Mathf.Cos(a)*Rand(8,14),h*(.45f+i*.17f),Mathf.Sin(a)*Rand(8,14));
                Beam("Acrobatic branch",p+Vector3.up*h*(.40f+i*.16f),tip,.65f,bark,true);
                Cone("Cedar crown",tip+Vector3.up*4,Rand(6,10),12,leaves);
            }
            Cone("Cedar top",p+Vector3.up*h,8,17,leaves);
        }
        void Tower(Vector3 p,float width,float h,Material stone,Material roof)
        {
            float opening=11;float baseHeight=h*.38f;float apertureHeight=14;
            Primitive("Village tower base",PrimitiveType.Cube,p+Vector3.up*baseHeight*.5f,new Vector3(width,baseHeight,width),stone,true);
            for(int side=-1;side<=1;side+=2)Primitive("Window side pier",PrimitiveType.Cube,p+new Vector3(side*(width+opening)*.25f,baseHeight+apertureHeight*.5f,0),new Vector3((width-opening)*.5f,apertureHeight,width),stone,true);
            float top=h-baseHeight-apertureHeight;
            Primitive("Window lintel",PrimitiveType.Cube,p+Vector3.up*(baseHeight+apertureHeight+top*.5f),new Vector3(width,top,width),stone,true);
            Cone("Village pointed roof",p+Vector3.up*(h+6),width*.74f,12,roof);
            Ring("Window trim",p+new Vector3(0,baseHeight+apertureHeight*.5f,-width*.5f-.15f),Quaternion.identity,5.8f,.13f,BeakMaterial,false,4);
        }
        void AddThermal(Vector3 p,Material material)
        {
            updrafts.Add(p);for(int i=0;i<6;i++)Ring("Rising air",p+Vector3.up*(9+i*16),Quaternion.Euler(90,0,0),7+i*.6f,.08f,material,false,12);
            Ring("Thermal source",p+Vector3.up*.4f,Quaternion.Euler(90,0,0),13,.3f,material,false,16);
        }
        void AddGate(Vector3 p,Vector3 normal,float radius,Material mat,bool apex)
        {
            var gate=Ring(apex?"Apex sky crown":"Flight gate",p,Quaternion.LookRotation(normal),radius,apex?.48f:.22f,mat,true,24);
            gates.Add(new Gate{Position=p,Normal=normal,Radius=radius,Apex=apex});
            if(apex) { var marker=Primitive("Apex beacon",PrimitiveType.Sphere,p+Vector3.up*(radius+5),Vector3.one*2.2f,mat,false);apexMarkers.Add(marker); }
        }
        GameObject Ring(string name,Vector3 p,Quaternion rotation,float radius,float width,Material material,bool solid,int segments)
        {
            var parent=new GameObject(name);parent.transform.SetParent(geometry);parent.transform.SetPositionAndRotation(p,rotation);
            for(int i=0;i<segments;i++) { float a=i*Mathf.PI*2/segments,b=(i+1)*Mathf.PI*2/segments;var start=p+rotation*new Vector3(Mathf.Cos(a)*radius,Mathf.Sin(a)*radius,0);var end=p+rotation*new Vector3(Mathf.Cos(b)*radius,Mathf.Sin(b)*radius,0);Beam(name+" segment",start,end,width,material,solid); }
            return parent;
        }
        void Cone(string name,Vector3 p,float radius,float height,Material material)
        {
            int sides=7;var vertices=new List<Vector3>();var triangles=new List<int>();
            for(int i=0;i<sides;i++) { float a=i*Mathf.PI*2/sides,b=(i+1)*Mathf.PI*2/sides;int n=vertices.Count;vertices.Add(new Vector3(Mathf.Cos(a)*radius,-height*.5f,Mathf.Sin(a)*radius));vertices.Add(new Vector3(0,height*.5f,0));vertices.Add(new Vector3(Mathf.Cos(b)*radius,-height*.5f,Mathf.Sin(b)*radius));triangles.Add(n);triangles.Add(n+1);triangles.Add(n+2); }
            var go=new GameObject(name);go.transform.SetParent(geometry);go.transform.position=p;var mesh=new Mesh{name="Seven sided canopy"};mesh.SetVertices(vertices);mesh.SetTriangles(triangles,0);mesh.RecalculateNormals();go.AddComponent<MeshFilter>().sharedMesh=mesh;go.AddComponent<MeshRenderer>().sharedMaterial=material;go.isStatic=true;
        }
        void Disc(string name,float radius,float y,Material material)
        {
            var go=new GameObject(name);go.transform.SetParent(geometry);go.transform.position=Vector3.up*y;var vertices=new List<Vector3>{Vector3.zero};var triangles=new List<int>();for(int i=0;i<64;i++){float a=i*Mathf.PI*2/64;vertices.Add(new Vector3(Mathf.Cos(a)*radius,0,Mathf.Sin(a)*radius));}for(int i=0;i<64;i++){triangles.Add(0);triangles.Add(1+(i+1)%64);triangles.Add(i+1);}var mesh=new Mesh();mesh.SetVertices(vertices);mesh.SetTriangles(triangles,0);mesh.RecalculateNormals();go.AddComponent<MeshFilter>().sharedMesh=mesh;go.AddComponent<MeshRenderer>().sharedMaterial=material;var collider=go.AddComponent<MeshCollider>();collider.sharedMesh=mesh;go.isStatic=true;
        }
    }
}
