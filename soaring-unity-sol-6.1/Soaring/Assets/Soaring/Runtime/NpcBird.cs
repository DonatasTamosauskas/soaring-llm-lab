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
        BirdWorld world;
        Transform leftWing,rightWing;
        MeshRenderer bodyRenderer;
        GameObject warning;
        Vector3 steer,target;
        NpcBird prey;
        float thinkTimer,respawnTimer,phase,turnRate;
        int identity;
        bool obstacleNearby;
        static Mesh bodyMesh,wingMesh,beakMesh;

        public void Initialize(BirdWorld owner,float size,Vector3 position,int index)
        {
            world=owner;identity=index;phase=index*1.79f;
            EnsureMeshes();
            bodyRenderer=Part("Faceted body",bodyMesh,owner.PreyMaterial,transform,Vector3.zero).GetComponent<MeshRenderer>();
            Part("Pointed beak",beakMesh,owner.BeakMaterial,transform,new Vector3(0,0,.65f));
            leftWing=Part("Left wing",wingMesh,owner.WingMaterial,transform,new Vector3(-.14f,0,0)).transform;leftWing.localScale=new Vector3(-1,1,1);
            rightWing=Part("Right wing",wingMesh,owner.WingMaterial,transform,new Vector3(.14f,0,0)).transform;
            warning=Part("Hunter crown",beakMesh,owner.WarningMaterial,transform,new Vector3(0,.9f,0));warning.transform.localRotation=Quaternion.Euler(-90,0,0);warning.transform.localScale=Vector3.one*.9f;warning.SetActive(false);
            Respawn(size,position);
        }
        public void Respawn(float size,Vector3 position)
        {
            Size=size;Alive=true;IsHuntingPlayer=false;HuntSeconds=0;prey=null;respawnTimer=0;target=world.RandomAirPosition();thinkTimer=.1f+identity*.007f;turnRate=63/(1+Mathf.Max(0,size-1)*.6f);
            transform.position=position;PreviousPosition=position;transform.localScale=Vector3.one*size;
            var session=GameSession.Instance;
            bodyRenderer.sharedMaterial=session && size>session.Size*1.12f?world.PredatorMaterial:world.PreyMaterial;
            Velocity=Quaternion.Euler(0,identity*137.5f,0)*Vector3.forward*Cruise();
            if(identity==0 || identity<14) Velocity=Vector3.forward*Cruise()*.72f;
            gameObject.SetActive(true);warning.SetActive(false);
        }
        public void Eaten(float delay)
        {
            Alive=false;IsHuntingPlayer=false;HuntSeconds=0;respawnTimer=delay;
            foreach(var renderer in GetComponentsInChildren<Renderer>())renderer.enabled=false;
        }
        float Cruise() => Mathf.Min(13*Mathf.Sqrt(Size),20*(1+(Size-1)*.23f)*.78f);
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
            var material=Size>session.Size*1.12f?world.PredatorMaterial:world.PreyMaterial;if(bodyRenderer.sharedMaterial!=material)bodyRenderer.sharedMaterial=material;
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
                desired=escape*2.3f+Vector3.up*.23f;
                IsHuntingPlayer=false;prey=null;
            }
            else if(IsHuntingPlayer)
            {
                float warning=player.Tuning != null ? Mathf.Max(3, player.Tuning.threatWarningSeconds) : 4;
                // Telegraph from a safe standoff. Committed hunters only close after the warning.
                var intercept=player.Position+Vector3.ClampMagnitude(player.Velocity*1.2f,20);
                desired=(intercept-pos).normalized;
                if(HuntSeconds<warning && playerDistance<24*24)desired=Vector3.Cross(desired,Vector3.up)+Vector3.up*.2f;
            }
            else if(prey)desired=(prey.Position+prey.Velocity*.7f-pos).normalized;
            else
            {
                if(Vector3.Distance(pos,target)<12)target=world.RandomAirPosition();
                desired=(target-pos).normalized;
            }
            if(world.SliceMode)
            {
                // The first goldfinch circles slowly in a clear lane, easy to see and catch.
                var center=new Vector3(0,24,20);target=center+new Vector3(Mathf.Sin(Time.time*.22f)*8,Mathf.Sin(Time.time*.31f)*2,Mathf.Cos(Time.time*.22f)*6);desired=(target-pos).normalized;
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
            bodyMesh=Faceted("Bird body",new[]{new Vector3(0,.30f,0),new Vector3(0,-.25f,0),new Vector3(-.28f,0,0),new Vector3(.28f,0,0),new Vector3(0,0,.67f),new Vector3(0,0,-.70f)},new[]{0,4,3,0,2,4,0,5,2,0,3,5,1,3,4,1,4,2,1,2,5,1,5,3});
            wingMesh=Faceted("Swept wing",new[]{Vector3.zero,new Vector3(1.45f,-.06f,-.13f),new Vector3(.92f,-.02f,-.55f),new Vector3(.15f,.04f,-.40f),new Vector3(.6f,.12f,-.22f)},new[]{0,4,1,1,4,2,2,4,3,3,4,0,1,2,0,2,3,0});
            beakMesh=Faceted("Beak tetrahedron",new[]{new Vector3(-.11f,0,0),new Vector3(.11f,0,0),new Vector3(0,.15f,0),new Vector3(0,0,.3f)},new[]{0,2,1,0,1,3,1,2,3,2,0,3});
        }
        static Mesh Faceted(string name,Vector3[] source,int[] faces)
        {
            var vertices=new List<Vector3>();var triangles=new List<int>();foreach(int face in faces){triangles.Add(vertices.Count);vertices.Add(source[face]);}var mesh=new Mesh{name=name};mesh.SetVertices(vertices);mesh.SetTriangles(triangles,0);mesh.RecalculateNormals();mesh.RecalculateBounds();return mesh;
        }
    }
}
