using System.Collections.Generic;
using UnityEngine;

namespace Soaring
{
    /// <summary>A compact, collider-free flock actor. World owns player catch decisions.</summary>
    public sealed class NpcBird : MonoBehaviour
    {
        public float Size { get; private set; }
        public bool Alive { get; private set; }
        public Vector3 Position => transform.position;
        public Vector3 Velocity { get; private set; }
        public Vector3 PreviousPosition { get; private set; }
        public bool IsHuntingPlayer { get; private set; }
        public float HuntSeconds { get; private set; }
        public string AIState { get; private set; } = "Roam";
        BirdWorld world;
        Transform leftWing,rightWing;
        MeshRenderer bodyRenderer;
        GameObject warning;
        Vector3 steer,target;
        NpcBird prey;
        float thinkTimer,respawnTimer,phase,turnRate;
        int identity;
        bool obstacleNearby;
        static Mesh bodyMesh,wingMesh,beakMesh,darkDetailsMesh,creamDetailsMesh;

        public void Initialize(BirdWorld owner,float size,Vector3 position,int index)
        {
            world=owner;identity=index;phase=index*1.79f;
            EnsureMeshes();
            bodyRenderer=Part("Faceted body",bodyMesh,owner.PreyMaterial,transform,Vector3.zero).GetComponent<MeshRenderer>();
            Part("Pointed beak",beakMesh,owner.BeakMaterial,transform,new Vector3(0,.12f,.69f));
            Part("Eyes and fanned tail",darkDetailsMesh,owner.WingMaterial,transform,Vector3.zero);
            Part("Ivory breast and eye highlights",creamDetailsMesh,owner.BirdCreamMaterial,transform,Vector3.zero);
            leftWing=Part("Left wing",wingMesh,owner.WingMaterial,transform,new Vector3(-.14f,0,0)).transform;leftWing.localScale=new Vector3(-1,1,1);
            rightWing=Part("Right wing",wingMesh,owner.WingMaterial,transform,new Vector3(.14f,0,0)).transform;
            warning=Part("Hunter crown",beakMesh,owner.WarningMaterial,transform,new Vector3(0,.9f,0));warning.transform.localRotation=Quaternion.Euler(-90,0,0);warning.transform.localScale=Vector3.one*.9f;warning.SetActive(false);
            Respawn(size,position);
        }
        public void Respawn(float size,Vector3 position)
        {
            Size=size;Alive=true;IsHuntingPlayer=false;HuntSeconds=0;prey=null;respawnTimer=0;target=world.RandomAirPosition();thinkTimer=0;turnRate=63/(1+Mathf.Max(0,size-1)*.6f);AIState="Roam";obstacleNearby=false;steer=Vector3.forward;
            position=world.FindClearAirPosition(position,size*.35f);
            transform.position=position;PreviousPosition=position;transform.localScale=Vector3.one*size;
            var session=GameSession.Instance;
            bodyRenderer.sharedMaterial=ClassificationMaterial(session);
            Velocity=Quaternion.Euler(0,identity*137.5f,0)*Vector3.forward*Cruise();
            if(identity==0 || identity<14) Velocity=world.SpawnForward*Cruise()*.72f;
            gameObject.SetActive(true);foreach(var renderer in GetComponentsInChildren<Renderer>())renderer.enabled=true;warning.SetActive(false);
        }
        public void Eaten(float delay)
        {
            Alive=false;IsHuntingPlayer=false;HuntSeconds=0;respawnTimer=delay;AIState="Dormant";
            foreach(var renderer in GetComponentsInChildren<Renderer>())renderer.enabled=false;
        }
        Material ClassificationMaterial(GameSession session)
        {
            if(!session || GameSession.CanEat(session.Size,Size))return world.PreyMaterial;
            return GameSession.CanEat(Size,session.Size)?world.PredatorMaterial:world.NeutralMaterial;
        }
        float Cruise()
        {
            var tuning=GameSession.Instance && GameSession.Instance.Player?GameSession.Instance.Player.Tuning:null;
            float playerCruise=tuning!=null?tuning.cruiseSpeed*FlightModel.SizeSpeed(Mathf.Max(1,Size),tuning):20*(1+Mathf.Max(0,Size-1)*.23f);
            return Mathf.Min(13*Mathf.Sqrt(Size),playerCruise*.78f);
        }
        void Update()
        {
            var session=GameSession.Instance;
            if(!session || !session.Player || !session.IsPlaying || session.IsPaused || session.IsDead || session.HasWon)return;
            float dt=Time.deltaTime;
            if(!Alive)
            {
                respawnTimer-=dt;
                if(respawnTimer<=0 && !world.SliceMode)
                {
                    float size=identity<44?Mathf.Clamp(session.Size*(.4f+Mathf.Repeat(identity*.137f, .35f)),.38f,4.15f):identity<60?Mathf.Max(1.2f,session.Size*.88f):Mathf.Clamp(session.Size*1.2f,2.3f,6.2f);
                    Respawn(size,world.RandomAirPosition());foreach(var renderer in GetComponentsInChildren<Renderer>())renderer.enabled=true;
                }
                return;
            }
            thinkTimer-=dt;if(thinkTimer<=0){Think(session);thinkTimer=.18f;}
            if(IsHuntingPlayer) HuntSeconds+=dt;else HuntSeconds=0;
            warning.SetActive(IsHuntingPlayer);
            if(IsHuntingPlayer)warning.transform.localScale=Vector3.one*(.7f+Mathf.Sin(Time.time*8)*.12f);
            float cruise=Cruise();
            if(IsHuntingPlayer || prey)cruise*=1.06f;
            float speedMultiplier=session.Player.Tuning != null ? session.Player.Tuning.npcSpeedMultiplier : 1;
            if (session.Player.Tuning != null) turnRate=session.Player.Tuning.turnRate*.7f/(1+Mathf.Max(0,Size-1)*session.Player.Tuning.largeTurnWeight);
            cruise*=speedMultiplier;
            // The equal-size player always keeps a speed advantage at normal tuning.
            Vector3 wanted=steer.sqrMagnitude>.01f?steer.normalized:transform.forward;
            Vector3 direction=Vector3.RotateTowards(Velocity.normalized,wanted,turnRate*Mathf.Deg2Rad*dt,0);
            Velocity=Vector3.Lerp(Velocity,direction*cruise,1-Mathf.Exp(-dt*3));
            var movement=Velocity*dt;
            if(obstacleNearby && world.ObstacleAhead(Position,direction,movement.magnitude+.6f*Size,.25f*Size,out var hit))
            {
                Velocity=Vector3.ProjectOnPlane(Velocity,hit.normal)+hit.normal*2;
                movement=Vector3.ClampMagnitude(Velocity*dt,Mathf.Max(0,hit.distance-.15f));
            }
            PreviousPosition=Position;transform.position=world.Constrain(Position+movement,.35f*Size);
            if(Velocity.sqrMagnitude>.1f)
            {
                float bank=Mathf.Clamp(Vector3.Dot(Vector3.Cross(transform.forward,direction),Vector3.up)*-150,-35,35);
                transform.rotation=Quaternion.Slerp(transform.rotation,Quaternion.LookRotation(Velocity.normalized,Vector3.up)*Quaternion.Euler(0,0,bank),dt*5);
            }
            float flap=Mathf.Sin(Time.time*(6/Mathf.Sqrt(Size))+phase)*27;
            leftWing.localRotation=Quaternion.Euler(0,0,-flap);rightWing.localRotation=Quaternion.Euler(0,0,flap);
            if(prey && prey.Alive && Vector3.Distance(Position,prey.Position)<(Size+prey.Size)*.53f)prey.Eaten(4);
            var material=ClassificationMaterial(session);if(bodyRenderer.sharedMaterial!=material)bodyRenderer.sharedMaterial=material;
        }
        void Think(GameSession session)
        {
            Vector3 pos=Position,escape=Vector3.zero,separation=Vector3.zero;
            float nearestPrey=60*60,nearestThreat=70*70;prey=null;
            var player=session.Player;
            float playerDistance=(pos-player.Position).sqrMagnitude;
            bool playerHunt=Size>player.Size*1.12f && playerDistance<65*65 && !world.SliceMode;
            // Only a few hunters can select the player. Others keep the ecosystem alive.
            if(playerHunt)
            {
                int closerHunters=0;
                foreach(var bird in world.Birds)if(bird!=this && bird.Alive && bird.IsHuntingPlayer && (bird.Position-player.Position).sqrMagnitude<playerDistance)closerHunters++;
                if(closerHunters>=2)playerHunt=false;
            }
            if(player.Size>Size*1.12f && playerDistance<nearestThreat)
            {nearestThreat=playerDistance;escape=(pos-player.Position).normalized;}
            foreach(var bird in world.Birds)
            {
                if(bird==this || !bird.Alive)continue;
                var delta=pos-bird.Position;float distance=delta.sqrMagnitude;
                if(distance<Mathf.Pow((Size+bird.Size)*2,2) && distance>.001f)separation+=delta.normalized/(1+distance*.1f);
                if(bird.Size>Size*1.12f && distance<nearestThreat){nearestThreat=distance;escape=delta.normalized;}
                if(Size>bird.Size*1.12f && distance<nearestPrey){nearestPrey=distance;prey=bird;}
            }
            IsHuntingPlayer=playerHunt && nearestThreat>25*25;
            Vector3 desired;
            if(nearestThreat<45*45)
            {
                AIState="Flee";desired=escape*2.3f+Vector3.up*.23f;
                IsHuntingPlayer=false;prey=null;
            }
            else if(IsHuntingPlayer)
            {
                AIState="Hunt player";
                float warning=player.Tuning != null ? Mathf.Max(3, player.Tuning.threatWarningSeconds) : 4;
                // Telegraph from a safe standoff. Committed hunters only close after the warning.
                var intercept=player.Position+Vector3.ClampMagnitude(player.Velocity*1.2f,20);
                desired=(intercept-pos).normalized;
                if(HuntSeconds<warning && playerDistance<24*24)desired=Vector3.Cross(desired,Vector3.up)+Vector3.up*.2f;
            }
            else if(prey){AIState="Hunt bird";desired=(prey.Position+prey.Velocity*.7f-pos).normalized;}
            else
            {
                AIState="Roam";if(Vector3.Distance(pos,target)<12)target=world.RandomAirPosition();
                desired=(target-pos).normalized;
            }
            if(world.SliceMode)
            {
                // The first goldfinch circles slowly in a clear lane, easy to see and catch.
                AIState="Slice";var center=world.SliceCenter;target=center+world.SpawnRight*(Mathf.Sin(Time.time*.22f)*8)+Vector3.up*(Mathf.Sin(Time.time*.31f)*2)+world.SpawnForward*(Mathf.Cos(Time.time*.22f)*6);desired=(target-pos).normalized;
                if(nearestThreat<9*9)desired=escape*.4f+desired;
            }
            desired+=world.BoundarySteering(pos)+separation*.55f;
            obstacleNearby=world.ObstacleAhead(pos,Velocity,Mathf.Max(8,Velocity.magnitude*.35f+Size),Size*.35f,out var obstacle);
            if(obstacleNearby)desired+=obstacle.normal*3+Vector3.up*1.4f;
            steer=desired;
        }
        static GameObject Part(string name,Mesh mesh,Material material,Transform parent,Vector3 position)
        {
            var go=new GameObject(name);go.transform.SetParent(parent,false);go.transform.localPosition=position;go.AddComponent<MeshFilter>().sharedMesh=mesh;var renderer=go.AddComponent<MeshRenderer>();renderer.sharedMaterial=material;renderer.shadowCastingMode=UnityEngine.Rendering.ShadowCastingMode.Off;renderer.receiveShadows=false;return go;
        }
        static void EnsureMeshes()
        {
            if(bodyMesh)return;
            var bodyVertices=new List<Vector3>();var bodyFaces=new List<int>();
            Ellipsoid(bodyVertices,bodyFaces,new Vector3(0,0,-.08f),new Vector3(.52f,.52f,1.13f));
            Ellipsoid(bodyVertices,bodyFaces,new Vector3(0,.21f,.48f),new Vector3(.47f,.47f,.48f));
            bodyMesh=Faceted("Rounded bird body and head",bodyVertices.ToArray(),bodyFaces.ToArray());
            var darkVertices=new List<Vector3>();var darkFaces=new List<int>();
            for(int side=-1;side<=1;side+=2)Ellipsoid(darkVertices,darkFaces,new Vector3(side*.224f,.26f,.58f),new Vector3(.10f,.13f,.12f));
            for(int i=-1;i<=1;i++){int n=darkVertices.Count;darkVertices.AddRange(new[]{new Vector3(i*.045f,0,-.48f),new Vector3(i*.19f-.07f,-.06f,-1.0f),new Vector3(i*.19f+.07f,-.06f,-1.0f),new Vector3(i*.06f,.07f,-.5f)});darkFaces.AddRange(new[]{n,n+1,n+2,n,n+2,n+3,n+2,n+1,n,n+3,n+2,n});}
            darkDetailsMesh=Faceted("Bright eyes and three tail feathers",darkVertices.ToArray(),darkFaces.ToArray());
            var creamVertices=new List<Vector3>();var creamFaces=new List<int>();
            Ellipsoid(creamVertices,creamFaces,new Vector3(0,-.13f,.13f),new Vector3(.38f,.3f,.71f));
            for(int side=-1;side<=1;side+=2)Ellipsoid(creamVertices,creamFaces,new Vector3(side*.265f,.284f,.59f),new Vector3(.035f,.035f,.035f));
            creamDetailsMesh=Faceted("Ivory breast and eye shine",creamVertices.ToArray(),creamFaces.ToArray());
            var wingVertices=new List<Vector3>();var wingFaces=new List<int>();
            wingVertices.AddRange(new[]{Vector3.zero,new Vector3(.75f,.05f,.04f),new Vector3(.95f,-.03f,-.44f),new Vector3(.1f,-.02f,-.46f),new Vector3(.40f,.16f,-.13f)});
            wingFaces.AddRange(new[]{0,4,1,1,4,2,2,4,3,3,4,0,0,1,2,0,2,3});
            for(int i=0;i<6;i++){float f=i/5f;int n=wingVertices.Count;float rootX=.54f+f*.22f,rootZ=.04f-f*.41f,tipX=1.5f-f*.20f,tipZ=-.10f-f*.47f;wingVertices.AddRange(new[]{new Vector3(rootX,0,rootZ+.04f),new Vector3(tipX,-.045f,tipZ+.045f),new Vector3(tipX+.02f,-.035f,tipZ-.055f),new Vector3(rootX,-.015f,rootZ-.095f),new Vector3((rootX+tipX)*.5f,.065f,(rootZ+tipZ)*.5f)});wingFaces.AddRange(new[]{n,n+4,n+1,n+1,n+4,n+2,n+2,n+4,n+3,n+3,n+4,n,n,n+1,n+2,n,n+2,n+3});}
            wingMesh=Faceted("Six sculpted flight feathers",wingVertices.ToArray(),wingFaces.ToArray());
            beakMesh=Faceted("Beak tetrahedron",new[]{new Vector3(-.11f,0,0),new Vector3(.11f,0,0),new Vector3(0,.15f,0),new Vector3(0,0,.3f)},new[]{0,2,1,0,1,3,1,2,3,2,0,3});
        }
        static void Ellipsoid(List<Vector3> vertices,List<int> faces,Vector3 center,Vector3 scale)
        {
            const int rows=5,columns=10;int offset=vertices.Count;
            for(int y=0;y<=rows;y++)for(int i=0;i<columns;i++){float a=i*Mathf.PI*2/columns,b=y*Mathf.PI/rows;vertices.Add(center+Vector3.Scale(new Vector3(Mathf.Sin(b)*Mathf.Cos(a),Mathf.Cos(b),Mathf.Sin(b)*Mathf.Sin(a)),scale*.5f));}
            for(int y=0;y<rows;y++)for(int i=0;i<columns;i++){int a=offset+y*columns+i,b=offset+y*columns+(i+1)%columns,c=offset+(y+1)*columns+i,d=offset+(y+1)*columns+(i+1)%columns;faces.AddRange(new[]{a,b,c,b,d,c});}
        }
        static Mesh Faceted(string name,Vector3[] source,int[] faces)
        {
            var vertices=new List<Vector3>();var triangles=new List<int>();foreach(int face in faces){triangles.Add(vertices.Count);vertices.Add(source[face]);}var mesh=new Mesh{name=name};mesh.SetVertices(vertices);mesh.SetTriangles(triangles,0);mesh.RecalculateNormals();mesh.RecalculateBounds();return mesh;
        }
    }
}
