using System.IO;
using System.Diagnostics;
using System;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;

// OpenXR 1.18.0 places libopenxr_loader.dylib under Plugins/ARM64, but its
// Mac player asks for Plugins/openxr_loader.dylib. Add a copy at that location
// and locally sign the built app. Editor/Android and the package cache are unaffected.
public sealed class MacOpenXRLoaderFix : IPostprocessBuildWithReport
{
    public int callbackOrder => 100;
    public void OnPostprocessBuild(BuildReport report)
    {
        if (report.summary.platform != BuildTarget.StandaloneOSX) return;
        var plugins = Path.Combine(report.summary.outputPath, "Contents", "Plugins");
        var source = Path.Combine(plugins, "ARM64", "libopenxr_loader.dylib");
        if (File.Exists(source))
        {
            File.Copy(source, Path.Combine(plugins, "openxr_loader.dylib"), true);
            // Unity's packaged loader signatures failed verification on this host.
            // Re-sign the completed local development app after adding the loader.
            // Production distribution requires its own signing/notarization workflow.
            var path = report.summary.outputPath.Replace("\\", "\\\\").Replace("\"", "\\\"");
            var info = new ProcessStartInfo("/usr/bin/codesign", "--force --deep --sign - \"" + path + "\"")
            {
                UseShellExecute = false,
                RedirectStandardError = true
            };
            using (var process = Process.Start(info))
            {
                var error = process.StandardError.ReadToEnd();
                process.WaitForExit();
                if (process.ExitCode != 0) throw new InvalidOperationException("Local Mac signing failed: " + error);
            }
        }
    }
}
