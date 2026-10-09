"""Soaring LLM Lab: patch for the scratch copy of 2026-08-11-unity-prime-muse-1.2, applied by
tools/capture_unity.sh after the import check and before the player build.

  python3 -I 2026-08-11-unity-prime-muse-1.2.patch.py <copy of the Unity project>

Why: the build's MonoBehaviour `Soaring.World.Perch` is declared inside WorldBuilder.cs instead of a
Perch.cs of its own. The edit-time world generator added 590 Perch components to SampleScene, and
the editor saved them against a MonoScript embedded in the scene (`--- !u!115`, m_ClassName: Perch).
A macOS player built from the scene (Unity 6000.6.4f1) crashes while loading it: "level0 is
corrupted! [Position out of bounds]". Bisecting the scene's root objects isolates World/BirdManager/HUD,
and the embedded Perch script is the only one in the scene.

Patch (smallest change that loads, no behaviour change): move the Perch class, unchanged, into
Assets/Soaring/Scripts/World/Perch.cs with a fixed GUID, and point the scene's Perch components at
that script asset instead of the embedded one. Their serialized values are untouched.
"""
import hashlib
import os
import re
import sys

copy = sys.argv[1]
world = os.path.join(copy, "Assets/Soaring/Scripts/World")
builder_path = os.path.join(world, "WorldBuilder.cs")
guid = hashlib.md5(b"soaring-lab Soaring.World.Perch").hexdigest()

source = open(builder_path).read()
match = re.search(r"\n    public class Perch : MonoBehaviour\n    \{.*?\n    \}\n", source, re.S)
if match:
    perch = match.group(0)
    open(builder_path, "w").write(source.replace(perch, "\n"))
    with open(os.path.join(world, "Perch.cs"), "w") as f:
        f.write("// Moved out of WorldBuilder.cs by the Soaring LLM Lab capture patch (scratch copy only).\n"
                "using UnityEngine;\n\nnamespace Soaring.World\n{" + perch + "}\n")
    with open(os.path.join(world, "Perch.cs.meta"), "w") as f:
        f.write(f"fileFormatVersion: 2\nguid: {guid}\nMonoImporter:\n  externalObjects: {{}}\n  serializedVersion: 2\n"
                "  defaultReferences: []\n  executionOrder: 0\n  icon: {instanceID: 0}\n  userData: \n"
                "  assetBundleName: \n  assetBundleVariant: \n")
    print("[patch] moved Soaring.World.Perch to Perch.cs")

for root, _, files in os.walk(os.path.join(copy, "Assets")):
    for name in files:
        if not name.endswith(".unity"):
            continue
        path = os.path.join(root, name)
        text = open(path).read()
        ids = [m.group(1) for m in re.finditer(r"--- !u!115 &(\d+)\nMonoScript:\n(?:  .*\n)*?  m_ClassName: Perch\n", text)]
        if not ids:
            continue
        count = 0
        for file_id in ids:
            text, n = re.subn(r"m_Script: \{fileID: " + file_id + r"\}", f"m_Script: {{fileID: 11500000, guid: {guid}, type: 3}}", text)
            count += n
            text = re.sub(r"--- !u!115 &" + file_id + r"\n(?:(?!--- ).*\n)*", "", text)
        open(path, "w").write(text)
        print(f"[patch] {os.path.relpath(path, copy)}: {count} Perch components now use Perch.cs")
