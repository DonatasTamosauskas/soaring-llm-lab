using UnityEngine;
using Unity.Profiling;
namespace Soaring
{
    public sealed class PerformanceGovernor : MonoBehaviour
    {
        public GameSession game; ProfilerRecorder drawCalls, triangles;
        void OnEnable()
        {
            drawCalls = ProfilerRecorder.StartNew(ProfilerCategory.Render, "Draw Calls Count");
            triangles = ProfilerRecorder.StartNew(ProfilerCategory.Render, "Triangles Count");
        }
        void OnDisable()
        {
            drawCalls.Dispose();
            triangles.Dispose();
        }
        float average = 1f / 72, overBudget, nextReport;
        void Update()
        {
            if (!game.ready)
                return;
            average = Mathf.Lerp(average, Time.unscaledDeltaTime, .03f);
            if (Time.unscaledTime >= nextReport)
            {
                nextReport = Time.unscaledTime + 10;
                Debug.Log($"SOARING_PERF fps={1 / average:F1} npc={game.ecosystem.population} draws={drawCalls.LastValue} triangles={triangles.LastValue} memoryMiB={UnityEngine.Profiling.Profiler.GetTotalAllocatedMemoryLong() / 1048576} mass={game.player.model.mass:F4}");
            }
            if (Application.platform != RuntimePlatform.Android || game.phase != GamePhase.Flying)
                return;
            overBudget = average > 1f / 60 ? overBudget + Time.unscaledDeltaTime : Mathf.Max(0, overBudget - Time.unscaledDeltaTime);
            if (overBudget > 5 && game.ecosystem.population > 20)
            {
                game.ecosystem.population -= 2;
                for (int i = game.ecosystem.population; i < 96; i++)
                    game.ecosystem.Remove(game.ecosystem.birds[i]);
                overBudget = 0;
                Debug.Log("SOARING_QUALITY population=" + game.ecosystem.population);
            }
        }
    }
}
