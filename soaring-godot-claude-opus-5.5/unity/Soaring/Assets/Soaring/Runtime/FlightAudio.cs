using System;
using UnityEngine;
namespace Soaring
{
    public sealed class FlightAudio : MonoBehaviour
    {
        public GameSession game; public PlayerFlight player; public VRInput input;
        AudioSource wind, music, ambient, water, meadow; float nextBell, nextHeartbeat; AudioSource[] voices; AudioClip whoosh, catchTone, growTone, collisionTone; int nextVoice; float nextBuffet;
        public void Initialize()
        {
            voices = new AudioSource[16];
            for (int i = 0; i < voices.Length; i++)
            {
                voices[i] = new GameObject("Audio voice " + i).AddComponent<AudioSource>();
                voices[i].transform.SetParent(transform);
                voices[i].playOnAwake = false;
                voices[i].rolloffMode = AudioRolloffMode.Linear;
                voices[i].minDistance = .5f;
                voices[i].maxDistance = 120;
                voices[i].dopplerLevel = .15f;
            }
            wind = Loop("Flight wind", Noise("wind", 2, .18f));
            music = Loop("Menu music", Resources.Load<AudioClip>("Audio/music/menu_heavenly_loop"));
            ambient = Loop("Forest ambience", Resources.Load<AudioClip>("Audio/ambience/amb_forest_birds"));
            water = Loop("Water ambience", Noise("water", 3, .18f));
            meadow = Loop("Meadow ambience", Noise("meadow", 4, .08f));
            whoosh = Noise("wing", .18f, .45f);
            catchTone = Tone("catch", 660, .16f);
            growTone = Tone("grow", 880, .5f);
            collisionTone = Noise("collision", .22f, .5f);
        }
        AudioSource Loop(string name, AudioClip clip)
        {
            var source = new GameObject(name).AddComponent<AudioSource>();
            source.transform.SetParent(transform);
            source.clip = clip;
            source.loop = true;
            source.playOnAwake = false;
            source.spatialBlend = 0;
            source.volume = 0;
            if (clip)
                source.Play();
            return source;
        }
        void Update()
        {
            if (!wind)
                return;
            var p = input.preferences;
            AudioListener.volume = p.master;
            bool flying = game.phase == GamePhase.Flying && !player.perched;
            float speed = player.model.airspeed / SizeRules.Cruise(player.model.mass);
            wind.volume = Mathf.Lerp(wind.volume, flying ? Mathf.Clamp01(speed * .18f) * p.effects : 0, Time.unscaledDeltaTime * 5);
            wind.pitch = Mathf.Lerp(.65f, 1.6f, Mathf.Clamp01(speed / 2.6f));
            music.volume = Mathf.Lerp(music.volume, game.phase != GamePhase.Flying ? p.music * .55f : 0, Time.unscaledDeltaTime * 2);
            float forest = 1 - SizeRules.Smooth(100, 250, Vector3.Distance(player.model.position, new Vector3(-262, 15, 258)));
            ambient.volume = forest * .13f * p.effects;
            float lake = 1 - SizeRules.Smooth(120, 260, Vector3.Distance(player.model.position, new Vector3(228, 0, -228)));
            water.volume = lake * .11f * p.effects;
            water.pitch = .6f;
            meadow.volume = (1 - forest) * (1 - lake) * .055f * p.effects;
            meadow.pitch = 2.3f;
            if (Time.unscaledTime > nextBell && Vector3.Distance(player.model.position, new Vector3(-90, 20, -4)) < 170)
            {
                nextBell = Time.unscaledTime + 55;
                Play(growTone, new Vector3(-90, 20, -4), .15f, .35f, true);
            }
            if (flying && game.ecosystem.threatLevel > .45f && Time.unscaledTime > nextHeartbeat)
            {
                nextHeartbeat = Time.unscaledTime + Mathf.Lerp(1.5f, .45f, game.ecosystem.threatLevel);
                Play(collisionTone, player.model.position, .06f, .45f, false);
            }

            if (flying && player.model.stallWarning > .7f && Time.unscaledTime > nextBuffet)
            {
                nextBuffet = Time.unscaledTime + .32f;
                Play(whoosh, player.model.position, .12f, 1.8f, false);
                input.Haptic(.08f, .04f);
            }
        }
        public void Wingbeat() => Play(whoosh, player.model.position, .15f, .7f + UnityEngine.Random.value * .15f, false);
        public void Cue(string name)
        {
            AudioClip clip = name switch
            {
                "catch" => catchTone,
                "grow" or "victory" => growTone,
                "collision" or "caught" => collisionTone,
                "click" => Resources.Load<AudioClip>("Audio/ui/ui_click"),
                "hover" => Resources.Load<AudioClip>("Audio/ui/ui_hover"),
                _ => ToneCached
            };
            Play(clip, player.model.position, name == "hover" ? .12f : .35f, 1, false);
        }
        AudioClip ToneCached => catchTone;
        public void BirdCall(BirdAgent bird, bool danger)
        {
            string id = SizeRules.Ladder[bird.tier].id;
            if (id == "moth" || id == "starling")
                id = "sparrow";
            var clip = Resources.Load<AudioClip>("Audio/calls/" + id + "_" + UnityEngine.Random.Range(1, 4));
            Play(clip, bird.position, danger ? .65f : .22f, 1, true);
        }
        void Play(AudioClip clip, Vector3 position, float volume, float pitch, bool spatial)
        {
            if (!clip || voices == null)
                return;
            var source = voices[nextVoice++ % voices.Length];
            source.Stop();
            source.transform.position = position;
            source.clip = clip;
            source.volume = volume * input.preferences.effects;
            source.pitch = pitch;
            source.spatialBlend = spatial ? 1 : 0;
            source.Play();
        }
        static AudioClip Noise(string name, float duration, float gain)
        {
            int count = (int)(22050 * duration);
            var samples = new float[count];
            var random = new System.Random(17);
            float smooth = 0;
            for (int i = 0; i < count; i++)
            {
                smooth = smooth * .92f + ((float)random.NextDouble() * 2 - 1) * .08f;
                float envelope = name == "wind" ? 1 : Mathf.Sin(Mathf.PI * i / count);
                samples[i] = smooth * gain * envelope;
            }
            var clip = AudioClip.Create(name, count, 1, 22050, false);
            clip.SetData(samples, 0);
            return clip;
        }
        static AudioClip Tone(string name, float frequency, float duration)
        {
            int count = (int)(22050 * duration);
            var data = new float[count];
            for (int i = 0; i < count; i++)
            {
                float t = i / 22050f;
                data[i] = Mathf.Sin(t * frequency * 2 * Mathf.PI) * Mathf.Sin(Mathf.PI * i / count) * .18f + Mathf.Sin(t * frequency * 3 * Mathf.PI) * .03f;
            }
            var clip = AudioClip.Create(name, count, 1, 22050, false);
            clip.SetData(data, 0);
            return clip;
        }
        void OnDestroy()
        {
            foreach (var clip in new[] { whoosh, catchTone, growTone, collisionTone, wind ? wind.clip : null })
                if (clip)
                    Destroy(clip);
        }
    }
}
