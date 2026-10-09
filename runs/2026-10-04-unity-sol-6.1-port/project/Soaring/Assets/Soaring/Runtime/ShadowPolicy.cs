using System;
namespace Soaring
{
    public static class ShadowPolicy
    {
        // Buildings, close tree geometry, rocks and bridges cast. Tiny soft
        // decoration and distant billboards stay out of the shadow atlas.
        public static bool CastsScenery(string name)
        {
            string n = name.ToLowerInvariant();
            foreach (string prefix in new[] { "water", "cloud", "backdrop", "terrain", "trees_far", "grass", "flower", "mote", "crop", "reeds", "wheat" })
                if (n.StartsWith(prefix, StringComparison.Ordinal)) return false;
            return true;
        }
    }
}
