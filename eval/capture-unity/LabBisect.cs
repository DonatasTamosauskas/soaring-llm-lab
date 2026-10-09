// Soaring LLM Lab: diagnostic for a player that crashes while loading its first scene
// ("level0 is corrupted [Position out of bounds]": a component whose serialized layout differs
// between editor and player). Copy to <copy>/Assets/LabCapture/Editor/ and run
//   Unity -batchmode -nographics -buildTarget OSXUniversal -projectPath <copy>
//         -executeMethod LabBisect.Run -labOut <dir> -labGroups "0,1,2;3,4;5-9"
// For each ';'-separated group of root-object indices (ranges allowed) it saves a copy of the first
// enabled scene with only those roots and builds a development player to <dir>/g<N>/LabCapture.app.
// Run each player for a few frames; the groups that crash contain the culprit. With -labGroups
// "list" it only logs the scene's root objects (LAB_ROOT index name) and their component types.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;

public static class LabBisect
{
    static string Arg(string name, string fallback = null)
    {
        var args = Environment.GetCommandLineArgs();
        for (int i = 0; i < args.Length - 1; i++)
            if (args[i] == name) return args[i + 1];
        return fallback;
    }

    static HashSet<int> Parse(string group)
    {
        var set = new HashSet<int>();
        foreach (var part in group.Split(',').Select(p => p.Trim()).Where(p => p.Length > 0))
        {
            var ends = part.Split('-');
            int a = int.Parse(ends[0]), b = ends.Length > 1 ? int.Parse(ends[1]) : a;
            for (int i = a; i <= b; i++) set.Add(i);
        }
        return set;
    }

    public static void Run()
    {
        int code = 0;
        try
        {
            string source = EditorBuildSettings.scenes.First(s => s.enabled).path;
            string groups = Arg("-labGroups", "list"), output = Arg("-labOut", "LabBisect");
            var scene = EditorSceneManager.OpenScene(source);
            var roots = scene.GetRootGameObjects();
            for (int i = 0; i < roots.Length; i++)
            {
                var types = roots[i].GetComponentsInChildren<MonoBehaviour>(true).Where(m => m != null)
                    .Select(m => m.GetType().FullName).Distinct().OrderBy(t => t);
                Debug.Log($"LAB_ROOT {i} {roots[i].name} :: {string.Join(", ", types)}");
            }
            if (groups == "list") { EditorApplication.Exit(0); return; }
            int g = 0;
            foreach (var group in groups.Split(';'))
            {
                var keep = Parse(group);
                scene = EditorSceneManager.OpenScene(source);
                roots = scene.GetRootGameObjects();
                for (int i = 0; i < roots.Length; i++)
                    if (!keep.Contains(i)) UnityEngine.Object.DestroyImmediate(roots[i]);
                string path = $"Assets/LabCapture/Bisect{g}.unity";
                EditorSceneManager.SaveScene(scene, path);
                var report = BuildPipeline.BuildPlayer(new[] { path }, Path.Combine(output, $"g{g}", "LabCapture.app"),
                    BuildTarget.StandaloneOSX, BuildOptions.Development);
                Debug.Log($"LAB_BISECT g{g} roots={group} build={report.summary.result}");
                g++;
            }
        }
        catch (Exception e) { Debug.LogException(e); code = 1; }
        EditorApplication.Exit(code);
    }
}
