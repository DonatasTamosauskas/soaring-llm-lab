using UnityEngine;
using UnityEngine.Rendering.Universal;
namespace Soaring {
public sealed class SoaringBootstrap:MonoBehaviour {
 public bool SliceMode=true;
 void Awake(){Application.targetFrameRate=90;var session=gameObject.AddComponent<GameSession>();var rig=new GameObject("Bird • tracked flight origin");var player=rig.AddComponent<BirdPlayer>();var head=new GameObject("Head");head.transform.SetParent(rig.transform,false);head.transform.localPosition=new Vector3(0,1.6f,0);var camera=head.AddComponent<Camera>();camera.tag="MainCamera";camera.nearClipPlane=.06f;camera.farClipPlane=650;camera.clearFlags=CameraClearFlags.SolidColor;camera.backgroundColor=new Color(.59f,.79f,.83f);camera.allowHDR=false;camera.GetUniversalAdditionalCameraData().renderPostProcessing=false;head.AddComponent<AudioListener>();player.Head=head.transform;player.LeftHand=new GameObject("Left wing controller").transform;player.LeftHand.SetParent(rig.transform,false);player.RightHand=new GameObject("Right wing controller").transform;player.RightHand.SetParent(rig.transform,false);rig.AddComponent<QuestRuntimeDiagnostics>();rig.AddComponent<BirdComfort>();session.Player=player;var world=new GameObject("Sky sanctuary").AddComponent<BirdWorld>();world.SliceMode=SliceMode;session.World=world;world.Build();var ui=gameObject.AddComponent<BirdUI>();ui.Session=session;ui.Player=player;ui.Build();gameObject.AddComponent<SoaringDiagnostics>();}
}
}
