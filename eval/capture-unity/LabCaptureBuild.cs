// Soaring LLM Lab: builds a desktop macOS player of a scratch copy for capture.
//
// tools/capture_unity.sh copies this file to raw/_work/<run>/Soaring/Assets/LabCapture/Editor/
// and runs it with
//   Unity -batchmode -nographics -projectPath <copy> -executeMethod LabCaptureBuild.BuildMac
//         -labBuild <path/Player.app> -labCompany <name>
//
// Changes it makes, to the scratch copy only:
//   - XR Plug-in Management "Initialize XR on Startup" off for Standalone, so the player shows a
//     plain desktop window (no headset, no XR runtime);
//   - company name set to -labCompany, so the player saves to its own fresh data folder instead of
//     reusing calibration or settings left by the agent's runs;
//   - Mono scripting backend, Apple silicon, windowed 1280x720 without Retina scaling, keeps
//     running in the background;
//   - builds the enabled scenes of the project's build settings, without the Development flag
//     (no watermark).
using System;
using System.Linq;
using System.Reflection;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
using UnityEngine;

public static class LabCaptureBuild
{
    static string Arg(string name, string fallback = null)
    {
        var args = Environment.GetCommandLineArgs();
        for (int i = 0; i < args.Length - 1; i++)
            if (args[i] == name) return args[i + 1];
        return fallback;
    }

    public static void BuildMac()
    {
        int code = 1;
        try
        {
            string output = Arg("-labBuild") ?? throw new ArgumentException("-labBuild <path.app> is required");
            DisableXRInit();
            PlayerSettings.companyName = Arg("-labCompany", "SoaringLab");
            PlayerSettings.SetScriptingBackend(NamedBuildTarget.Standalone, ScriptingImplementation.Mono2x);
            PlayerSettings.SetArchitecture(NamedBuildTarget.Standalone, 1); // Apple silicon
            PlayerSettings.fullScreenMode = FullScreenMode.Windowed;
            PlayerSettings.defaultScreenWidth = 1280;
            PlayerSettings.defaultScreenHeight = 720;
            PlayerSettings.resizableWindow = false;
            PlayerSettings.macRetinaSupport = false;
            PlayerSettings.runInBackground = true;
            AssetDatabase.SaveAssets();

            var scenes = EditorBuildSettings.scenes.Where(s => s.enabled).Select(s => s.path).ToArray();
            Debug.Log("LAB_BUILD scenes=" + string.Join(",", scenes) + " product=" + PlayerSettings.productName);
            var report = BuildPipeline.BuildPlayer(new BuildPlayerOptions
            {
                scenes = scenes,
                target = BuildTarget.StandaloneOSX,
                targetGroup = BuildTargetGroup.Standalone,
                locationPathName = output,
                // -labDevelopment 1: a development player, which names the script when a scene fails to load
                options = Arg("-labDevelopment") == "1" ? BuildOptions.Development : BuildOptions.None,
            });
            var s = report.summary;
            Debug.Log($"LAB_BUILD_RESULT {s.result} errors={s.totalErrors} warnings={s.totalWarnings} seconds={s.totalTime.TotalSeconds:F0} size={s.totalSize}");
            code = s.result == BuildResult.Succeeded ? 0 : 2;
        }
        catch (Exception e)
        {
            Debug.LogException(e);
        }
        EditorApplication.Exit(code);
    }

    // -executeMethod LabCaptureBuild.BuildAndroid -labBuild <path.apk> (start the editor with -buildTarget Android):
    // an APK with the project's own Android settings (package ID, XR, signing); nothing is changed first.
    public static void BuildAndroid()
    {
        int code = 1;
        try
        {
            string output = Arg("-labBuild") ?? throw new ArgumentException("-labBuild <path.apk> is required");
            EditorUserBuildSettings.buildAppBundle = false;
            var scenes = EditorBuildSettings.scenes.Where(s => s.enabled).Select(s => s.path).ToArray();
            Debug.Log("LAB_BUILD android scenes=" + string.Join(",", scenes) + " id=" + PlayerSettings.GetApplicationIdentifier(NamedBuildTarget.Android));
            var report = BuildPipeline.BuildPlayer(new BuildPlayerOptions
            {
                scenes = scenes,
                target = BuildTarget.Android,
                targetGroup = BuildTargetGroup.Android,
                locationPathName = output,
                options = BuildOptions.None,
            });
            var s = report.summary;
            Debug.Log($"LAB_BUILD_RESULT {s.result} errors={s.totalErrors} warnings={s.totalWarnings} seconds={s.totalTime.TotalSeconds:F0} size={s.totalSize}");
            code = s.result == BuildResult.Succeeded ? 0 : 2;
        }
        catch (Exception e)
        {
            Debug.LogException(e);
        }
        EditorApplication.Exit(code);
    }

    // Through reflection, so the script also compiles in a project without XR Plug-in Management.
    static void DisableXRInit()
    {
        var type = Type.GetType("UnityEditor.XR.Management.XRGeneralSettingsPerBuildTarget, Unity.XR.Management.Editor");
        if (type == null) { Debug.Log("LAB_XR no XR Plug-in Management in this project"); return; }
        var method = type.GetMethod("XRGeneralSettingsForBuildTarget", BindingFlags.Public | BindingFlags.Static);
        var settings = method?.Invoke(null, new object[] { BuildTargetGroup.Standalone }) as UnityEngine.Object;
        if (settings == null) { Debug.Log("LAB_XR no XR settings for Standalone"); return; }
        var property = settings.GetType().GetProperty("InitManagerOnStart");
        Debug.Log("LAB_XR Standalone InitManagerOnStart was " + property.GetValue(settings) + ", now False");
        property.SetValue(settings, false);
        EditorUtility.SetDirty(settings);
    }
}
