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
using Unity.XR.CoreUtils;
using UnityEngine.XR.Interaction.Toolkit;
using UnityEngine.XR.Interaction.Toolkit.Interactables;
using UnityEngine.XR.Interaction.Toolkit.Locomotion.Teleportation;

namespace Soaring.Editor
{
    public static class ProjectSetup
    {
        public const string ScenePath = "Assets/Soaring/Scenes/Soaring.unity";
        [MenuItem("Soaring/Apply project settings")]
        public static void Configure()
        {
            // CLI platform switches can retain the previous custom profile.
            // Apply the baseline to the global settings, not its overrides.
            BuildProfile.SetActiveBuildProfile(null);
            PlayerSettings.companyName = "Soaring";
            PlayerSettings.productName = "Soaring";
            PlayerSettings.colorSpace = ColorSpace.Linear;
            PlayerSettings.SetApplicationIdentifier(NamedBuildTarget.Android, "com.soaring.unity");
            PlayerSettings.SetApplicationIdentifier(NamedBuildTarget.Standalone, "com.soaring.unity");
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
            var player = ProjectSettingsObject("ProjectSettings/ProjectSettings.asset", "PlayerSettings");
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
                if (!targets.HasSettingsForBuildTarget(group))
                    targets.CreateDefaultSettingsForBuildTarget(group);
                if (!targets.HasManagerSettingsForBuildTarget(group))
                    targets.CreateDefaultManagerSettingsForBuildTarget(group);
                var general = targets.SettingsForBuildTarget(group);
                general.InitManagerOnStart = false;
                general.Manager.automaticLoading = false;
                general.Manager.automaticRunning = false;
                if (!XRPackageMetadataStore.AssignLoader(general.Manager, typeof(OpenXRLoader).FullName, group))
                    throw new InvalidOperationException("Cannot assign OpenXR loader for " + group);
                FeatureHelpers.RefreshFeatures(group);
                var settings = OpenXRSettings.GetSettingsForBuildTargetGroup(group);
                settings.renderMode = OpenXRSettings.RenderMode.SinglePassInstanced;
                settings.foveatedRenderingApi = OpenXRSettings.BackendFovationApi.SRPFoveation;
                settings.depthSubmissionMode = OpenXRSettings.DepthSubmissionMode.None;
                if (group == BuildTargetGroup.Android)
                    settings.latencyOptimization = OpenXRSettings.LatencyOptimization.PrioritizeInputPolling;
                foreach (var feature in settings.GetFeatures())
                {
                    // Intentionally keep advanced MR/eye/face features opt-in.
                    feature.enabled = feature is OculusTouchControllerProfile ||
                        feature is MetaQuestTouchProControllerProfile ||
                        feature is MetaQuestTouchPlusControllerProfile ||
                        (group == BuildTargetGroup.Android && (feature is MetaQuestFeature || feature is FoveatedRenderingFeature));
                    EditorUtility.SetDirty(feature);
                }
                if (group == BuildTargetGroup.Android)
                {
                    var foveation = settings.GetFeature<FoveatedRenderingFeature>();
                    var foveationData = new SerializedObject(foveation);
                    foveationData.FindProperty("useEyeTracking").boolValue = false;
                    foveationData.ApplyModifiedPropertiesWithoutUndo();
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
            // Match the original's restrained near-field sun shadows.
            var pipeline = AssetDatabase.LoadAssetAtPath<UniversalRenderPipelineAsset>("Assets/Settings/Mobile_RPAsset.asset");
            pipeline.supportsHDR = false;
            pipeline.msaaSampleCount = 4;
            pipeline.renderScale = 1f;
            pipeline.supportsCameraDepthTexture = false;
            pipeline.supportsCameraOpaqueTexture = false;
            var urp = new SerializedObject(pipeline);
            urp.FindProperty("m_MainLightRenderingMode").intValue = (int)LightRenderingMode.PerPixel;
            urp.FindProperty("m_MainLightShadowsSupported").boolValue = true;
            var anyShadows = urp.FindProperty("m_AnyShadowsSupported");
            if (anyShadows != null) anyShadows.boolValue = true;
            urp.FindProperty("m_AdditionalLightsRenderingMode").intValue = (int)LightRenderingMode.Disabled;
            urp.FindProperty("m_SoftShadowsSupported").boolValue = false;
            urp.ApplyModifiedPropertiesWithoutUndo();
            pipeline.mainLightShadowmapResolution = 2048;
            pipeline.shadowDistance = 90;
            pipeline.shadowCascadeCount = 1;
            var renderer = AssetDatabase.LoadAssetAtPath<UniversalRendererData>("Assets/Settings/Mobile_Renderer.asset");
            var rendererSettings = new SerializedObject(renderer);
            rendererSettings.FindProperty("postProcessData").objectReferenceValue = null;
            rendererSettings.ApplyModifiedPropertiesWithoutUndo();
            EditorUtility.SetDirty(renderer);
            GraphicsSettings.defaultRenderPipeline = pipeline;
            var graphics = ProjectSettingsObject("ProjectSettings/GraphicsSettings.asset", "GraphicsSettings");
            graphics.FindProperty("m_InstancingStripping").intValue = 2;
            graphics.ApplyModifiedPropertiesWithoutUndo();
            for (int i = 0; i < QualitySettings.names.Length; i++)
            {
                QualitySettings.SetQualityLevel(i, false);
                QualitySettings.renderPipeline = pipeline;
                QualitySettings.vSyncCount = 0;
            }
            QualitySettings.SetQualityLevel(0, false);
            EditorUtility.SetDirty(pipeline);
            AssetDatabase.SaveAssets();
            Debug.Log("SOARING_SETTINGS_OK");
        }

        static SerializedObject ProjectSettingsObject(string path, string singleton)
        {
            // A native platform profile switch can temporarily remove project
            // settings from the AssetDatabase. The editor singleton remains valid.
            var assets = AssetDatabase.LoadAllAssetsAtPath(path);
            var target = assets.Length > 0 ? assets[0] : Unsupported.GetSerializedAssetInterfaceSingleton(singleton);
            if (target == null)
                throw new InvalidOperationException("Cannot load " + singleton);
            return new SerializedObject(target);
        }


        public static void RefreshScene()
        {
            Configure();
            CreateScene();
            Validate();
        }
        public static void Setup()
        {
            Configure();
            SourceImporter.Import();
            CreateScene();
            Validate();
        }
        public static void CreateScene()
        {
            var scene = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            Directory.CreateDirectory("Assets/Soaring/Scenes");
            var content = AssetDatabase.LoadAssetAtPath<SoaringContent>("Assets/Soaring/Resources/SoaringContent.asset");
            var valley = (GameObject)PrefabUtility.InstantiatePrefab(content.valleyPrefab);
            var world = valley.AddComponent<ValleyWorld>();
            world.content = content;
            var rig = new GameObject("XR Origin");
            var origin = rig.AddComponent<XROrigin>();
            origin.enabled = false; // Bootstrap enables it after XR has a valid session.
            origin.RequestedTrackingOriginMode = XROrigin.TrackingOriginMode.Floor;
            var floor = new GameObject("Tracking space");
            floor.transform.SetParent(rig.transform, false);
            origin.CameraFloorOffsetObject = floor;
            var cameraObject = new GameObject("Main Camera");
            cameraObject.tag = "MainCamera";
            cameraObject.transform.SetParent(floor.transform, false);
            var camera = cameraObject.AddComponent<Camera>();
            camera.clearFlags = CameraClearFlags.Skybox;
            camera.nearClipPlane = .003f;
            camera.farClipPlane = 1800;
            camera.allowHDR = false;
            camera.fieldOfView = 90;
            camera.GetUniversalAdditionalCameraData().renderPostProcessing = false;
            cameraObject.AddComponent<AudioListener>();
            origin.Camera = camera;
            var left = new GameObject("Left Wing Controller");
            left.transform.SetParent(floor.transform, false);
            var right = new GameObject("Right Wing Controller");
            right.transform.SetParent(floor.transform, false);
            var leftAim = new GameObject("Left Controller Aim");
            leftAim.transform.SetParent(floor.transform, false);
            var rightAim = new GameObject("Right Controller Aim");
            rightAim.transform.SetParent(floor.transform, false);
            var input = rig.AddComponent<VRInput>();
            input.origin = origin;
            input.eye = camera;
            input.leftHand = left.transform;
            input.rightHand = right.transform;
            input.leftAim = leftAim.transform;
            input.rightAim = rightAim.transform;
            new GameObject("XR Interaction Manager").AddComponent<XRInteractionManager>();
            var systems = new GameObject("Soaring Systems");
            var game = systems.AddComponent<GameSession>();
            var player = systems.AddComponent<PlayerFlight>();
            var ecosystem = systems.AddComponent<Ecosystem>();
            var ui = systems.AddComponent<SoaringUI>();
            var audio = systems.AddComponent<FlightAudio>();
            var effects = systems.AddComponent<FlightEffects>();
            player.input = input;
            player.world = world;
            player.game = game;
            ecosystem.world = world;
            ecosystem.player = player;
            ecosystem.game = game;
            ui.game = game;
            ui.input = input;
            ui.player = player;
            audio.game = game;
            audio.input = input;
            audio.player = player;
            effects.game = game;
            effects.player = player;
            effects.input = input;
            effects.ecosystem = ecosystem;
            effects.content = content;
            game.player = player;
            game.ecosystem = ecosystem;
            game.world = world;
            game.input = input;
            game.ui = ui;
            game.audio = audio;
            game.effects = effects;
            systems.AddComponent<SoaringBootstrap>().game = game;
            systems.AddComponent<PerformanceGovernor>().game = game;
            systems.AddComponent<RuntimeVerification>().game = game;
            var sun = new GameObject("Late morning sun").AddComponent<Light>();
            sun.type = LightType.Directional;
            sun.intensity = 1.25f;
            sun.color = new Color(1, .95f, .84f);
            sun.shadows = LightShadows.Hard;
            sun.shadowBias = .15f;
            sun.shadowNormalBias = .3f;
            float elevation = 47 * Mathf.Deg2Rad, azimuth = -38 * Mathf.Deg2Rad;
            var towardsSun = new Vector3(Mathf.Cos(elevation) * Mathf.Sin(azimuth), Mathf.Sin(elevation), -Mathf.Cos(elevation) * Mathf.Cos(azimuth));
            sun.transform.rotation = Quaternion.LookRotation(-towardsSun, Vector3.up);
            RenderSettings.sun = sun;
            var sky = new Material(Shader.Find("Skybox/Procedural")) { name = "Sky" };
            sky.SetFloat("_SunSize", .045f);
            sky.SetFloat("_AtmosphereThickness", .75f);
            sky.SetColor("_SkyTint", new Color(.48f, .68f, .8f));
            sky.SetColor("_GroundColor", new Color(.48f, .55f, .39f));
            sky.SetFloat("_Exposure", 1.15f);
            string skyPath = "Assets/Soaring/Generated/Materials/Sky.mat";
            var old = AssetDatabase.LoadAssetAtPath<Material>(skyPath);
            if (old)
            {
                EditorUtility.CopySerialized(sky, old);
                UnityEngine.Object.DestroyImmediate(sky);
                sky = old;
            }
            else
                AssetDatabase.CreateAsset(sky, skyPath);
            RenderSettings.skybox = sky;
            RenderSettings.ambientMode = AmbientMode.Trilight;
            RenderSettings.ambientSkyColor = new Color(.52f, .64f, .7f);
            RenderSettings.ambientEquatorColor = new Color(.42f, .48f, .42f);
            RenderSettings.ambientGroundColor = new Color(.27f, .31f, .21f);
            RenderSettings.fog = true;
            RenderSettings.fogMode = FogMode.Linear;
            RenderSettings.fogColor = new Color(.63f, .75f, .77f);
            RenderSettings.fogStartDistance = 270;
            RenderSettings.fogEndDistance = 1450;
            var tags = ProjectSettingsObject("ProjectSettings/TagManager.asset", "TagManager");
            tags.FindProperty("layers").GetArrayElementAtIndex(8).stringValue = "World";
            tags.ApplyModifiedPropertiesWithoutUndo();
            EditorSceneManager.SaveScene(scene, ScenePath);
            EditorBuildSettings.scenes = new[] { new EditorBuildSettingsScene(ScenePath, true) };
            AssetDatabase.SaveAssets();
            Debug.Log("SOARING_SCENE_OK");
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
                    if (general == null || !general.Manager.activeLoaders.Any(l => l is OpenXRLoader))
                        errors++;
                    var issues = new List<OpenXRFeature.ValidationRule>();
                    OpenXRProjectValidation.GetCurrentValidationIssues(issues, group);
                    foreach (var issue in issues)
                    {
                        lines.Add(group + ": " + (issue.error ? "ERROR " : "WARN ") + issue.message);
                        if (issue.error)
                            errors++;
                    }
                    var settings = OpenXRSettings.GetSettingsForBuildTargetGroup(group);
                    lines.Add(group + " enabled: " + string.Join(", ", settings.GetFeatures().Where(f => f.enabled).Select(f => f.GetType().Name)));
                }
            }
            finally { EditorUserBuildSettings.selectedBuildTargetGroup = previousGroup; }
            if (PlayerSettings.Android.targetArchitectures != AndroidArchitecture.ARM64 || PlayerSettings.GetScriptingBackend(NamedBuildTarget.Android) != ScriptingImplementation.IL2CPP)
                errors++;
            if (!File.Exists(ScenePath))
                errors++;
            lines.Add("Errors: " + errors);
            Directory.CreateDirectory("../Logs");
            File.WriteAllLines("../Logs/validation.txt", lines);
            foreach (var line in lines)
                Debug.Log(line);
            if (errors > 0)
                throw new InvalidOperationException("Quest setup validation failed; see Logs/validation.txt");
            Debug.Log("SOARING_VALIDATION_OK");
        }

        [MenuItem("Soaring/Create Meta Quest build profile")]
        public static void CreateQuestProfile()
        {
            const string path = "Assets/Settings/Build Profiles/Meta Quest.asset";
            if (AssetDatabase.LoadAssetAtPath<BuildProfile>(path) != null)
                return;
            var installed = BuildProfile.GetInstalledPlatformModules();
            var quest = installed.FirstOrDefault(p => p.displayName == "Meta Quest");
            if (string.IsNullOrEmpty(quest.displayName))
                throw new InvalidOperationException("Enable Meta Quest in File > Build Profiles > Add Build Profile > Meta Quest > Enable Platform, then retry. The example includes a pre-created profile.");
            BuildProfile.CreateBuildProfile(quest.platformGuid, "Meta Quest", OnQuestProfileReady);
            AssetDatabase.SaveAssets();
        }
        static void OnQuestProfileReady(BuildProfile profile)
        {
            // Inherit the baseline while preserving Quest shader optimizations.
            SyncProfilePlayerSettings(profile);
            Debug.Log("SOARING_PROFILE_OK " + profile.name);
            AssetDatabase.SaveAssets();
        }

        static void SyncProfilePlayerSettings(BuildProfile profile)
        {
            foreach (var asset in AssetDatabase.LoadAllAssetsAtPath(AssetDatabase.GetAssetPath(profile)))
            {
                var data = new SerializedObject(asset);
                var instancing = data.FindProperty("m_InstancingStripping");
                if (instancing != null)
                {
                    instancing.intValue = 2;
                    data.ApplyModifiedPropertiesWithoutUndo();
                }
            }

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
            // The native platform profile carries shader optimizations. Player
            // settings inherit our global baseline, avoiding stale embedded YAML
            // overrides from the example when switching platforms in the CLI.
            // Imported pre-component profiles also keep a legacy YAML override;
            // RemoveComponent alone does not remove that serialized payload.
            var profileData = new SerializedObject(profile);
            var legacySettings = profileData.FindProperty("m_PlayerSettingsYaml.m_Settings");
            if (legacySettings != null)
            {
                legacySettings.ClearArray();
                profileData.ApplyModifiedPropertiesWithoutUndo();
            }
            profile.RemoveComponent<PlayerSettings>();
            EditorUtility.SetDirty(profile);
        }

        public static void BuildMac()
        {
            Configure();
            Validate();
            Directory.CreateDirectory("../Builds");
            PlayerSettings.SetArchitecture(NamedBuildTarget.Standalone, 1); // Apple Silicon
            Build(new BuildPlayerOptions
            {
                scenes = new[] { ScenePath },
                target = BuildTarget.StandaloneOSX,
                locationPathName = "../Builds/Soaring.app",
                options = BuildOptions.Development
            });
        }
        public static void BuildAndroid()
        {
            var profile = AssetDatabase.LoadAssetAtPath<BuildProfile>("Assets/Settings/Build Profiles/Meta Quest.asset");
            if (profile == null)
                throw new InvalidOperationException("Create the Meta Quest build profile first.");
            SyncProfilePlayerSettings(profile);
            Configure();
            AssetDatabase.SaveAssets();
            Validate();
            Directory.CreateDirectory("../Builds");
            EditorUserBuildSettings.buildAppBundle = false;
            var previousGroup = EditorUserBuildSettings.selectedBuildTargetGroup;
            try
            {
                EditorUserBuildSettings.selectedBuildTargetGroup = BuildTargetGroup.Android;
                var report = BuildPipeline.BuildPlayer(new BuildPlayerWithProfileOptions
                {
                    buildProfile = profile,
                    locationPathName = "../Builds/Soaring.apk",
                    options = BuildOptions.None
                });
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
            if (report.summary.result != BuildResult.Succeeded)
                throw new InvalidOperationException("Build failed: " + report.summary.result);
            Debug.Log("SOARING_BUILD_OK " + target);
        }

        [MenuItem("Soaring/Play in Meta XR Simulator")]
        public static void PlaySimulator()
        {
            if (EditorApplication.isPlaying)
                return;
            var manifest = Environment.GetEnvironmentVariable("META_XR_SIMULATOR_JSON") ?? "/Applications/MetaXRSimulator.app/Contents/Resources/MetaXRSimulator/meta_openxr_simulator.json";
            if (!File.Exists(manifest))
                throw new FileNotFoundException("Simulator runtime manifest missing", manifest);
            Environment.SetEnvironmentVariable("XR_RUNTIME_JSON", manifest);
            Environment.SetEnvironmentVariable("XR_SELECTED_RUNTIME_JSON", manifest);
            EditorSceneManager.OpenScene(ScenePath);
            EditorApplication.delayCall += () => EditorApplication.isPlaying = true;
        }
    }

}
