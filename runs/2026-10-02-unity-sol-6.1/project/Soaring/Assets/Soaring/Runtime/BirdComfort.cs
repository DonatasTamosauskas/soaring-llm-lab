using UnityEngine;
using UnityEngine.Rendering;
namespace Soaring {
// A binocular peripheral shade leaves the horizon and central flight view unobstructed.
public sealed class BirdComfort:MonoBehaviour {
 BirdPlayer player;MeshRenderer shade;Material material;Mesh mesh;
 void Start(){player=GetComponent<BirdPlayer>();var go=new GameObject("Peripheral comfort shade");go.transform.SetParent(player.Head,false);go.transform.localPosition=Vector3.forward*.12f;mesh=new Mesh();int n=48;var vertices=new Vector3[n*2];var indices=new int[n*6];for(int i=0;i<n;i++){float a=i*Mathf.PI*2/n;var v=new Vector3(Mathf.Cos(a)*1.25f,Mathf.Sin(a),0);vertices[i]=v*.105f;vertices[i+n]=v*.8f;int j=(i+1)%n;int k=i*6;indices[k]=i;indices[k+1]=j;indices[k+2]=i+n;indices[k+3]=j;indices[k+4]=j+n;indices[k+5]=i+n;}mesh.vertices=vertices;mesh.triangles=indices;mesh.RecalculateBounds();go.AddComponent<MeshFilter>().sharedMesh=mesh;shade=go.AddComponent<MeshRenderer>();material=new Material(Resources.Load<Material>("ComfortShader")??new Material(Shader.Find("Universal Render Pipeline/Unlit")));material.SetFloat("_Surface",1);material.SetFloat("_SrcBlend",(float)BlendMode.SrcAlpha);material.SetFloat("_DstBlend",(float)BlendMode.OneMinusSrcAlpha);material.SetFloat("_ZWrite",0);material.SetFloat("_Cull",0);material.EnableKeyword("_SURFACE_TYPE_TRANSPARENT");material.renderQueue=3100;shade.sharedMaterial=material;shade.shadowCastingMode=ShadowCastingMode.Off;shade.receiveShadows=false;}
 void LateUpdate(){if(!shade)return;var s=GameSession.Instance;float power=Mathf.Clamp01(Mathf.Abs(player.TurnInput)+Mathf.InverseLerp(player.Tuning.cruiseSpeed,player.Tuning.maxSpeed,player.Speed));shade.enabled=player.ComfortVignette&&s.IsPlaying&&!s.IsPaused&&power>.05f;material.SetColor("_BaseColor",new Color(.035f,.075f,.095f,power*player.Tuning.comfortStrength));}
 void OnDestroy(){if(material)Destroy(material);if(mesh)Destroy(mesh);}
}
}
