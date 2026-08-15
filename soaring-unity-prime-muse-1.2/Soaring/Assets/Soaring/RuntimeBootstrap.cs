
using UnityEngine;
namespace Soaring
{
    [DefaultExecutionOrder(-1000)]
    public class RuntimeBootstrap : MonoBehaviour
    {
        void Awake()
        {
#if UNITY_EDITOR
            if (FindFirstObjectByType<Flight.BirdFlightController>()==null)
            {
                Debug.Log("[Soaring] RuntimeBootstrap: no flight controller found -> invoking setup");
                var t = System.Type.GetType("Soaring.Editor.SoaringSceneSetup, Assembly-CSharp");
                var m = t?.GetMethod("Setup", System.Reflection.BindingFlags.Public|System.Reflection.BindingFlags.Static);
                m?.Invoke(null,null);
            }
#endif
        }
    }
}
