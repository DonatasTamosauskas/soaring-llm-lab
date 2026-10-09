# Prompts

The brief each run started from, word for word, with where it came from. Edit nothing here; a
changed brief is a new file, so every run's starting point stays reproducible. What you said to
an agent after its first message is in that run's `human-messages.md`.

| Prompt | Used by | Lineage |
|---|---|---|
| [prime-muse-godot](prime-muse-godot.md) | Prime Muse 1.2 · Godot | summary only; the exact text was not kept |
| [unity-mcp](unity-mcp.md) | Prime Muse 1.2 · Unity | the same game in Unity, through Unity MCP |
| [v1](v1.md) | Opus 5 · Godot | the first full brief |
| [v1.1](v1.1.md) | Fable 5.1 · Godot | v1 plus angle of attack, opposite-tilt turns and the area-by-area ultracode workflow |
| [v1.2-combined](v1.2-combined.md) | Opus 5.5 · Godot | v1.1 plus aerodynamics detail, updrafts, an NPC food chain, growth that changes play, sub-agents and a definition of done |
| [v1.3-flight-ux](v1.3-flight-ux.md) | Sol 6.1 · Godot | v1.2 tuned for flight comfort (spread/tuck, strong flap lift, less arm fatigue), without ultracode mode |
| [v2-godot](v2-godot.md) | no run yet | rewritten by Opus 5.5 from what it learned building v1.2 |
| [v2-unity](v2-unity.md) | Sol 6.1 · Unity | v2 for Unity |
| [port-to-unity](port-to-unity.md) | Sol 6.1 · Unity port of Opus 5.5 | port the golden Godot build to Unity 6.6 |
| [quest-bootstrap](quest-bootstrap.md) | references/unity-quest-bootstrap | a reusable Unity Quest + simulator starter |

## Setup notes

These notes sat at the end of the former `prompt-claude.md`, next to the v1.x prompts:

```text
/addons
Setup meta xr simulator
/Applications/MetaXRSimulator.app/Contents/Resources/MetaXRSimulator/meta_openxr_simulator.json
```
