using System;
using UnityEngine;
namespace Soaring
{
    [Serializable]
    public class Perch
    {
        public Vector3 position, facing; public int kind; public float maxSpan; public string district; [NonSerialized] public BirdAgent occupant;
    }
    [Serializable]
    public struct Landmark
    {
        public string name, kind; public Vector3 position; public float radius;
    }
    [Serializable]
    public struct Refuge
    {
        public Vector3 position; public float radius, maxSpan;
    }
    [Serializable]
    public struct Thermal
    {
        public string name; public Vector3 position, lean; public float radius, strength, top;
    }
    public sealed class SoaringContent : ScriptableObject
    {
        public GameObject valleyPrefab; public Species[] species; public Perch[] perches; public Landmark[] landmarks;
        public Refuge[] refuges; public Thermal[] thermals; public Vector3 spawn, spawnFacing;
        public Material birdMaterial, markerMaterial, comfortMaterial, particleMaterial;
        public int heightMapSize; public float[] heights; public float bounds = 680, ceiling = 300;
    }
}
