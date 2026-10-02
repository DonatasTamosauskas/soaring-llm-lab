using UnityEngine;

namespace Soaring
{
    /// <summary>Small procedural feedback sounds; no imported audio or per-frame allocations.</summary>
    public sealed class BirdAudio : MonoBehaviour
    {
        AudioSource source;
        AudioClip click, caught, death, victory;
        void Awake()
        {
            source = gameObject.AddComponent<AudioSource>();
            source.spatialBlend = 0;
            source.volume = .22f;
            source.playOnAwake = false;
            click = Tone("Wing click", .055f, 620, 780);
            caught = Tone("Bird catch", .24f, 520, 1050);
            death = Tone("Flight ended", .6f, 350, 140);
            victory = Tone("Apex", 1.1f, 480, 960);
        }
        public void Click() => source.PlayOneShot(click, .5f);
        public void Catch() => source.PlayOneShot(caught);
        public void Death() => source.PlayOneShot(death, .8f);
        public void Victory() => source.PlayOneShot(victory, .9f);
        static AudioClip Tone(string name, float duration, float startFrequency, float endFrequency)
        {
            const int rate = 22050;
            var samples = new float[Mathf.CeilToInt(duration * rate)];
            float phase = 0;
            for (int i = 0; i < samples.Length; i++)
            {
                float t = i / (float)samples.Length;
                phase += Mathf.Lerp(startFrequency, endFrequency, t) * 2 * Mathf.PI / rate;
                float envelope = Mathf.Sin(Mathf.PI * t) * Mathf.Pow(1 - t, .6f);
                samples[i] = (Mathf.Sin(phase) + .18f * Mathf.Sin(phase * 2)) * envelope * .5f;
            }
            var clip = AudioClip.Create(name, samples.Length, 1, rate, false);
            clip.SetData(samples, 0);
            return clip;
        }
        void OnDestroy()
        {
            foreach (var clip in new[] { click, caught, death, victory }) if (clip) Destroy(clip);
        }
    }
}
