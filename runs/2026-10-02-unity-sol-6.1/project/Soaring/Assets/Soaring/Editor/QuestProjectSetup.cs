using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Profile;
using UnityEditor.Build.Reporting;
using UnityEditor.SceneManagement;
using UnityEditor.XR.Management;
using UnityEditor.XR.Management.Metadata;
using UnityEditor.XR.OpenXR;
using UnityEditor.XR.OpenXR.Features;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.XR;
using UnityEngine.XR.Management;
using UnityEngine.XR.OpenXR;
using UnityEngine.XR.OpenXR.Features;
using UnityEngine.XR.OpenXR.Features.Interactions;
using UnityEngine.XR.OpenXR.Features.MetaQuestSupport;

public static class QuestProjectSetup
{
    public const string ScenePath = "Assets/Soaring/Scenes/Sanctuary.unity";

    [MenuItem("Soaring/Apply project settings")]
    public static void Configure()
    {
        PlayerSettings.companyName = "Soaring";
        PlayerSettings.productName = "Soaring Unity-Sol 6.1";
        PlayerSettings.colorSpace = ColorSpace.Linear;
        PlayerSettings.SetApplicationIdentifier(NamedBuildTarget.Android, "com.soaring.unitysol61");
        PlayerSettings.SetScriptingBackend(NamedBuildTarget.Android, ScriptingImplementation.IL2CPP);
        PlayerSettings.Android.targetArchitectures = AndroidArchitecture.ARM64;
        PlayerSettings.Android.minSdkVersion = AndroidSdkVersions.AndroidApiLevel32;
        PlayerSettings.Android.targetSdkVersion = AndroidSdkVersions.AndroidApiLevelAuto;
        PlayerSettings.SetUseDefaultGraphicsAPIs(BuildTarget.Android, false);
        PlayerSettings.SetGraphicsAPIs(BuildTarget.Android, new[] { GraphicsDeviceType.Vulkan });
        PlayerSettings.SetUseDefaultGraphicsAPIs(BuildTarget.StandaloneOSX, false);
        PlayerSettings.SetGraphicsAPIs(BuildTarget.StandaloneOSX, new[] { GraphicsDeviceType.Metal });
        PlayerSettings.defaultInterfaceOrientation = UIOrientation.LandscapeLeft;
        PlayerSettings.runInBackground = true;
        // Suppress the legacy Input Manager: OpenXR requires the Input System.
        var player = new SerializedObject(AssetDatabase.LoadAllAssetsAtPath("ProjectSettings/ProjectSettings.asset")[0]);
        player.FindProperty("activeInputHandler").intValue = 1;
        player.ApplyModifiedPropertiesWithoutUndo();

        Directory.CreateDirectory("Assets/XR/Settings");
        AssetDatabase.Refresh();
        if (!EditorBuildSettings.TryGetConfigObject(XRGeneralSettings.settingsKey, out XRGeneralSettingsPerBuildTarget targets))
        {
            targets = ScriptableObject.CreateInstance<XRGeneralSettingsPerBuildTarget>();
            AssetDatabase.CreateAsset(targets, "Assets/XR/Settings/XRGeneralSettingsPerBuildTarget.asset");
            EditorBuildSettings.AddConfigObject(XRGeneralSettings.settingsKey, targets, true);
        }
        foreach (var group in new[] { BuildTargetGroup.Standalone, BuildTargetGroup.Android })
        {
            if (!targets.HasSettingsForBuildTarget(group)) targets.CreateDefaultSettingsForBuildTarget(group);
            if (!targets.HasManagerSettingsForBuildTarget(group)) targets.CreateDefaultManagerSettingsForBuildTarget(group);
            var general = targets.SettingsForBuildTarget(group);
            general.InitManagerOnStart = true;
            general.Manager.automaticLoading = true;
            general.Manager.automaticRunning = true;
            if (!XRPackageMetadataStore.AssignLoader(general.Manager, typeof(OpenXRLoader).FullName, group))
                throw new InvalidOperationException("Cannot assign OpenXR loader for " + group);
            FeatureHelpers.RefreshFeatures(group);
            var settings = OpenXRSettings.GetSettingsForBuildTargetGroup(group);
            settings.renderMode = OpenXRSettings.RenderMode.SinglePassInstanced;
            settings.depthSubmissionMode = OpenXRSettings.DepthSubmissionMode.None;
            if (group == BuildTargetGroup.Android) settings.latencyOptimization = OpenXRSettings.LatencyOptimization.PrioritizeInputPolling;
            foreach (var feature in settings.GetFeatures())
            {
                // Intentionally keep advanced MR/eye/face features opt-in.
                feature.enabled = feature is OculusTouchControllerProfile ||
                    feature is MetaQuestTouchProControllerProfile ||
                    feature is MetaQuestTouchPlusControllerProfile ||
                    (group == BuildTargetGroup.Android && feature is MetaQuestFeature);
                EditorUtility.SetDirty(feature);
            }
            if (group == BuildTargetGroup.Android)
            {
                var quest = settings.GetFeature<MetaQuestFeature>();
                var serialized = new SerializedObject(quest);
                var devices = serialized.FindProperty("targetDevices");
                for (int i = 0; i < devices.arraySize; ++i)
                {
                    var device = devices.GetArrayElementAtIndex(i);
                    device.FindPropertyRelative("enabled").boolValue = device.FindPropertyRelative("manifestName").stringValue != "quest";
                }
                serialized.ApplyModifiedPropertiesWithoutUndo();
            }
            EditorUtility.SetDirty(settings);
            EditorUtility.SetDirty(general);
            EditorUtility.SetDirty(general.Manager);
        }
        EditorUtility.SetDirty(targets);
        // One conservative Forward URP asset for both simulator and device.
        var pipeline = AssetDatabase.LoadAssetAtPath<UniversalRenderPipelineAsset>("Assets/Settings/Mobile_RPAsset.asset");
        pipeline.supportsHDR = false;
        pipeline.msaaSampleCount = 4;
        pipeline.renderScale = 1f;
        pipeline.supportsCameraDepthTexture = false;
        pipeline.supportsCameraOpaqueTexture = false;
        var urp = new SerializedObject(pipeline);
        urp.FindProperty("m_MainLightRenderingMode").intValue = (int)LightRenderingMode.PerPixel;
        urp.FindProperty("m_MainLightShadowsSupported").boolValue = false;
        urp.FindProperty("m_AdditionalLightsRenderingMode").intValue = (int)LightRenderingMode.Disabled;
        urp.ApplyModifiedPropertiesWithoutUndo();
        var renderer = AssetDatabase.LoadAssetAtPath<UniversalRendererData>("Assets/Settings/Mobile_Renderer.asset");
        var rendererSettings = new SerializedObject(renderer);
        rendererSettings.FindProperty("postProcessData").objectReferenceValue = null;
        rendererSettings.ApplyModifiedPropertiesWithoutUndo();
        EditorUtility.SetDirty(renderer);
        GraphicsSettings.defaultRenderPipeline = pipeline;
        for (int i = 0; i < QualitySettings.names.Length; i++)
        {
            QualitySettings.SetQualityLevel(i, false);
            QualitySettings.renderPipeline = pipeline;
            QualitySettings.vSyncCount = 0;
        }
        QualitySettings.SetQualityLevel(0, false);
        EditorUtility.SetDirty(pipeline);
        AssetDatabase.SaveAssets();
        Debug.Log("QUEST_BOOTSTRAP_SETTINGS_OK");
    }

    [MenuItem("Soaring/Validate settings")]
    public static void Validate()
    {
        var lines = new List<string> { "Unity " + Application.unityVersion, "Validated " + DateTime.UtcNow.ToString("O") };
        int errors = 0;
        var previousGroup = EditorUserBuildSettings.selectedBuildTargetGroup;
        try
        {
        foreach (var group in new[] { BuildTargetGroup.Standalone, BuildTargetGroup.Android })
        {
            EditorUserBuildSettings.selectedBuildTargetGroup = group;
            var general = XRGeneralSettingsPerBuildTarget.XRGeneralSettingsForBuildTarget(group);
            if (general == null || !general.Manager.activeLoaders.Any(l => l is OpenXRLoader)) errors++;
            var issues = new List<OpenXRFeature.ValidationRule>();
            OpenXRProjectValidation.GetCurrentValidationIssues(issues, group);
            foreach (var issue in issues) { lines.Add(group + ": " + (issue.error ? "ERROR " : "WARN ") + issue.message); if (issue.error) errors++; }
            var settings = OpenXRSettings.GetSettingsForBuildTargetGroup(group);
            lines.Add(group + " enabled: " + string.Join(", ", settings.GetFeatures().Where(f => f.enabled).Select(f => f.GetType().Name)));
        }
        }
        finally { EditorUserBuildSettings.selectedBuildTargetGroup = previousGroup; }
        if (PlayerSettings.Android.targetArchitectures != AndroidArchitecture.ARM64 || PlayerSettings.GetScriptingBackend(NamedBuildTarget.Android) != ScriptingImplementation.IL2CPP) errors++;
        if (!File.Exists(ScenePath)) errors++;
        lines.Add("Errors: " + errors);
        Directory.CreateDirectory("../Logs");
        File.WriteAllLines("../Logs/validation.txt", lines);
        foreach (var line in lines) Debug.Log(line);
        if (errors > 0) throw new InvalidOperationException("Quest setup validation failed; see Logs/validation.txt");
        Debug.Log("QUEST_BOOTSTRAP_VALIDATION_OK");
    }

    [MenuItem("Soaring/Create Meta Quest build profile")]
    public static void CreateQuestProfile()
    {
        const string path = "Assets/Settings/Build Profiles/Meta Quest.asset";
        if (AssetDatabase.LoadAssetAtPath<BuildProfile>(path) != null) return;
        var installed = BuildProfile.GetInstalledPlatformModules();
        var quest = installed.FirstOrDefault(p => p.displayName == "Meta Quest");
        if (string.IsNullOrEmpty(quest.displayName))
            throw new InvalidOperationException("Enable Meta Quest in File > Build Profiles > Add Build Profile > Meta Quest > Enable Platform, then retry. The example includes a pre-created profile.");
        BuildProfile.CreateBuildProfile(quest.platformGuid, "Meta Quest", OnQuestProfileReady);
        AssetDatabase.SaveAssets();
    }
    static void OnQuestProfileReady(BuildProfile profile)
    {
        // Sync the baseline into Quest's profile overrides; preserve its shader optimizations.
        SyncProfilePlayerSettings(profile);
        Debug.Log("QUEST_BOOTSTRAP_PROFILE_OK " + profile.name);
        AssetDatabase.SaveAssets();
    }

    static void SyncProfilePlayerSettings(BuildProfile profile)
    {
        // Enabling the Meta Quest platform creates an additional global quality level.
        // Keep that level on the project's mobile renderer, including profile builds.
        var pipeline = AssetDatabase.LoadAssetAtPath<UniversalRenderPipelineAsset>("Assets/Settings/Mobile_RPAsset.asset");
        var previousQuality = QualitySettings.GetQualityLevel();
        for (int i = 0; i < QualitySettings.names.Length; ++i)
        {
            QualitySettings.SetQualityLevel(i, false);
            QualitySettings.renderPipeline = pipeline;
        }
        QualitySettings.SetQualityLevel(previousQuality, false);
        var global = new SerializedObject(AssetDatabase.LoadAllAssetsAtPath("ProjectSettings/ProjectSettings.asset")[0]);
        var player = new SerializedObject(profile.GetComponent<PlayerSettings>());
        foreach (var field in new[] { "companyName", "productName", "applicationIdentifier", "AndroidMinSdkVersion", "AndroidTargetSdkVersion",
            "AndroidTargetArchitectures", "scriptingBackend", "m_BuildTargetGraphicsAPIs", "m_ActiveColorSpace", "activeInputHandler" })
        {
            var source = global.FindProperty(field);
            if (source == null || player.FindProperty(field) == null) throw new InvalidOperationException("PlayerSettings field missing: " + field);
            player.CopyFromSerializedProperty(source);
        }
        player.ApplyModifiedPropertiesWithoutUndo();
        EditorUtility.SetDirty(profile);
    }

    public static void BuildMac()
    {
        Validate();
        Directory.CreateDirectory("../Builds");
        PlayerSettings.SetArchitecture(NamedBuildTarget.Standalone, 1); // Apple Silicon
        Build(new BuildPlayerOptions { scenes = new[] { ScenePath }, target = BuildTarget.StandaloneOSX,
            locationPathName = "../Builds/Soaring.app", options = BuildOptions.Development });
    }
    public static void BuildAndroid()
    {
        var profile = AssetDatabase.LoadAssetAtPath<BuildProfile>("Assets/Settings/Build Profiles/Meta Quest.asset");
        if (profile == null) throw new InvalidOperationException("Create the Meta Quest build profile first.");
        SyncProfilePlayerSettings(profile);
        AssetDatabase.SaveAssets();
        Validate();
        Directory.CreateDirectory("../Builds");
        EditorUserBuildSettings.buildAppBundle = false;
        var previousGroup = EditorUserBuildSettings.selectedBuildTargetGroup;
        try
        {
            EditorUserBuildSettings.selectedBuildTargetGroup = BuildTargetGroup.Android;
            var report = BuildPipeline.BuildPlayer(new BuildPlayerWithProfileOptions { buildProfile = profile,
                locationPathName = "../Builds/Soaring-unity-sol-6.1.apk", options = BuildOptions.Development });
            CheckBuild(report, "Android");
        }
        finally { EditorUserBuildSettings.selectedBuildTargetGroup = previousGroup; }
    }
    static void Build(BuildPlayerOptions options)
    {
        var report = BuildPipeline.BuildPlayer(options);
        CheckBuild(report, options.target.ToString());
    }
    static void CheckBuild(BuildReport report, string target)
    {
        File.WriteAllText("../Logs/build-" + target + ".txt", report.summary.result + "\nErrors: " + report.summary.totalErrors + "\nWarnings: " + report.summary.totalWarnings + "\n");
        if (report.summary.result != BuildResult.Succeeded) throw new InvalidOperationException("Build failed: " + report.summary.result);
        Debug.Log("QUEST_BOOTSTRAP_BUILD_OK " + target);
    }

    [MenuItem("Soaring/Play in Meta XR Simulator")]
    public static void PlaySimulator()
    {
        if (EditorApplication.isPlaying) return;
        var manifest = Environment.GetEnvironmentVariable("META_XR_SIMULATOR_JSON") ?? "/Applications/MetaXRSimulator.app/Contents/Resources/MetaXRSimulator/meta_openxr_simulator.json";
        if (!File.Exists(manifest)) throw new FileNotFoundException("Simulator runtime manifest missing", manifest);
        Environment.SetEnvironmentVariable("XR_RUNTIME_JSON", manifest);
        Environment.SetEnvironmentVariable("XR_SELECTED_RUNTIME_JSON", manifest);
        EditorSceneManager.OpenScene(ScenePath);
        EditorApplication.delayCall += () => EditorApplication.isPlaying = true;
    }
}
