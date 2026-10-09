using System.Collections.Generic;
using UnityEngine;
using UnityEngine.UI;
namespace Soaring
{
    public sealed class SoaringUIArt : MonoBehaviour
    {
        public RawImage image;
        static readonly Dictionary<string, Texture2D> textures = new();
        string id; float epoch; int previous = -1;
        public void Set(string name)
        {
            if (name == id) return;
            id = name; previous = -1; epoch = Time.unscaledTime;
            if (!textures.TryGetValue(name, out var texture)) textures[name] = texture = Resources.Load<Texture2D>("UI/Art/" + name);
            image.texture = texture;
            image.uvRect = new Rect(0,0,1,1);
            enabled = name.StartsWith("gesture_");
            if (enabled) Update();
        }
        void Update()
        {
            float period = id == "gesture_flap" ? 1.3f : Mathf.PI * 2 / 1.4f;
            int frame = (int)((Time.unscaledTime - epoch) / period * 12) % 12;
            if (frame == previous) return;
            previous = frame;
            image.uvRect = new Rect((frame % 4) * .25f, 1 - (frame / 4 + 1) / 3f, .25f, 1 / 3f);
        }
    }
}
