using System.IO;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;
namespace Soaring.Editor {
public static class SoaringBuild {
 static void Resources(){Directory.CreateDirectory("Assets/Soaring/Resources");AssetDatabase.Refresh();EnsureMaterial("FlightShader","Universal Render Pipeline/Simple Lit",false);EnsureMaterial("UIShader","Universal Render Pipeline/Unlit",false);EnsureMaterial("ComfortShader","Universal Render Pipeline/Unlit",true);AssetDatabase.SaveAssets();}
 static void EnsureMaterial(string name,string shader,bool transparent){string path="Assets/Soaring/Resources/"+name+".mat";if(File.Exists(path))return;var mat=new Material(Shader.Find(shader)){enableInstancing=true};if(transparent){mat.SetFloat("_Surface",1);mat.SetFloat("_SrcBlend",(float)BlendMode.SrcAlpha);mat.SetFloat("_DstBlend",(float)BlendMode.OneMinusSrcAlpha);mat.SetFloat("_ZWrite",0);mat.SetFloat("_Cull",0);mat.EnableKeyword("_SURFACE_TYPE_TRANSPARENT");mat.SetOverrideTag("RenderType","Transparent");mat.renderQueue=3100;}AssetDatabase.CreateAsset(mat,path);}
 [MenuItem("Soaring/Recreate flight slice")]
 public static void Setup(){QuestProjectSetup.Configure();Resources();Directory.CreateDirectory("Assets/Soaring/Scenes");AssetDatabase.Refresh();var scene=EditorSceneManager.NewScene(NewSceneSetup.EmptyScene,NewSceneMode.Single);var root=new GameObject("SOARING").AddComponent<SoaringBootstrap>();root.SliceMode=true;EditorSceneManager.SaveScene(scene,QuestProjectSetup.ScenePath);EditorBuildSettings.scenes=new[]{new EditorBuildSettingsScene(QuestProjectSetup.ScenePath,true)};AssetDatabase.SaveAssets();QuestProjectSetup.Validate();Debug.Log("SOARING_SETUP_OK");}
 [MenuItem("Soaring/Enable full ecosystem")]
 public static void FullWorld(){var scene=EditorSceneManager.OpenScene(QuestProjectSetup.ScenePath);Object.FindAnyObjectByType<SoaringBootstrap>().SliceMode=false;EditorSceneManager.SaveScene(scene);AssetDatabase.SaveAssets();Debug.Log("SOARING_FULL_WORLD_OK");}
 public static void BuildMac(){Resources();QuestProjectSetup.BuildMac();}
 public static void BuildAndroid(){Resources();QuestProjectSetup.BuildAndroid();}
 public static void Validate(){QuestProjectSetup.Validate();}
 public static void Play(){QuestProjectSetup.PlaySimulator();}
}
}
