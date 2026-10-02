using System.IO;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
namespace Soaring.Editor {
public static class SoaringBuild {
 public static void Setup(){QuestProjectSetup.Configure();Directory.CreateDirectory("Assets/Soaring/Scenes");Directory.CreateDirectory("Assets/Soaring/Resources");AssetDatabase.Refresh();if(!File.Exists("Assets/Soaring/Resources/FlightShader.mat"))AssetDatabase.CreateAsset(new Material(Shader.Find("Universal Render Pipeline/Simple Lit")),"Assets/Soaring/Resources/FlightShader.mat");if(!File.Exists("Assets/Soaring/Resources/UIShader.mat"))AssetDatabase.CreateAsset(new Material(Shader.Find("Universal Render Pipeline/Unlit")),"Assets/Soaring/Resources/UIShader.mat");var scene=EditorSceneManager.NewScene(NewSceneSetup.EmptyScene,NewSceneMode.Single);var root=new GameObject("SOARING").AddComponent<SoaringBootstrap>();root.SliceMode=true;EditorSceneManager.SaveScene(scene,QuestProjectSetup.ScenePath);EditorBuildSettings.scenes=new[]{new EditorBuildSettingsScene(QuestProjectSetup.ScenePath,true)};AssetDatabase.SaveAssets();QuestProjectSetup.Validate();Debug.Log("SOARING_SETUP_OK");}
 public static void FullWorld(){var scene=EditorSceneManager.OpenScene(QuestProjectSetup.ScenePath);Object.FindAnyObjectByType<SoaringBootstrap>().SliceMode=false;EditorSceneManager.SaveScene(scene);AssetDatabase.SaveAssets();Debug.Log("SOARING_FULL_WORLD_OK");}
 public static void BuildMac(){QuestProjectSetup.BuildMac();}
 public static void BuildAndroid(){QuestProjectSetup.BuildAndroid();}
 public static void Validate(){QuestProjectSetup.Validate();}
 public static void Play(){QuestProjectSetup.PlaySimulator();}
}
}
