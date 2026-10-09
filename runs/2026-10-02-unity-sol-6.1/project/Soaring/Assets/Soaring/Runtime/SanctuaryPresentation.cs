using UnityEngine;
using UnityEngine.Rendering;

namespace Soaring
{
    /// <summary>Lighting and bounded feedback; presentation never changes flight or camera pose.</summary>
    public sealed class SanctuaryPresentation : MonoBehaviour
    {
        GameSession session;
        ParticleSystem catchFeathers;
        Material sky, featherMaterial, airMaterial;
        int previousCatches;

        void Start()
        {
            session = GameSession.Instance;
            sky = new Material(Resources.Load<Shader>("SanctuarySky"));
            var sunlight = new GameObject("Sanctuary golden sun").AddComponent<Light>();
            sunlight.transform.SetParent(transform);
            sunlight.type = LightType.Directional;
            sunlight.transform.rotation = Quaternion.Euler(38, -38, 0);
            sunlight.color = new Color(1, .87f, .66f);
            sunlight.intensity = 1.25f;
            sunlight.shadows = LightShadows.None;
            sky.SetVector("_SunDirection", -sunlight.transform.forward);
            RenderSettings.skybox = sky;
            RenderSettings.ambientMode = AmbientMode.Trilight;
            RenderSettings.ambientSkyColor = new Color(.52f, .68f, .78f);
            RenderSettings.ambientEquatorColor = new Color(.59f, .55f, .43f);
            RenderSettings.ambientGroundColor = new Color(.23f, .32f, .32f);
            RenderSettings.ambientIntensity = .85f;
            RenderSettings.fog = true;
            RenderSettings.fogMode = FogMode.Linear;
            RenderSettings.fogColor = new Color(.80f, .81f, .70f);
            RenderSettings.fogStartDistance = 100;
            RenderSettings.fogEndDistance = 390;
            session.Player.Head.GetComponent<Camera>().clearFlags = CameraClearFlags.Skybox;
            BuildCatchFeedback();
            BuildThermalWisps();
            session.Changed += OnChanged;
        }

        void BuildCatchFeedback()
        {
            var go = new GameObject("Catch • golden feather burst");
            go.transform.SetParent(transform);
            catchFeathers = go.AddComponent<ParticleSystem>();
            catchFeathers.Stop(true, ParticleSystemStopBehavior.StopEmittingAndClear);
            var main = catchFeathers.main;
            main.loop = false; main.playOnAwake = false; main.duration = .7f;
            main.startLifetime = new ParticleSystem.MinMaxCurve(.3f, .65f);
            main.startSpeed = new ParticleSystem.MinMaxCurve(.6f, 2.8f);
            main.startSize = new ParticleSystem.MinMaxCurve(.025f, .06f);
            main.startColor = new Color(1, .80f, .28f);
            main.gravityModifier = .12f; main.maxParticles = 32;
            main.simulationSpace = ParticleSystemSimulationSpace.World;
            main.useUnscaledTime = false;
            var emission = catchFeathers.emission; emission.enabled = false;
            var shape = catchFeathers.shape; shape.shapeType = ParticleSystemShapeType.Sphere; shape.radius = .2f;
            var size = catchFeathers.sizeOverLifetime; size.enabled = true;
            size.size = new ParticleSystem.MinMaxCurve(1, AnimationCurve.EaseInOut(0, 1, 1, 0));
            var renderer = go.GetComponent<ParticleSystemRenderer>();
            featherMaterial = new Material(Resources.Load<Material>("UIShader"));
            featherMaterial.color = new Color(1, .80f, .28f);
            renderer.sharedMaterial = featherMaterial;
            renderer.renderMode = ParticleSystemRenderMode.Stretch;
            renderer.lengthScale = .8f; renderer.velocityScale = .04f;
        }

        void BuildThermalWisps()
        {
            airMaterial = new Material(Resources.Load<Shader>("AirWisps"));
            foreach (var center in session.World.UpdraftCenters)
            {
                var go = new GameObject("Thermal • rising air motes");
                go.transform.SetParent(transform);
                go.transform.SetPositionAndRotation(center + Vector3.up * 2, Quaternion.Euler(-90, 0, 0));
                var particles = go.AddComponent<ParticleSystem>();
                particles.Stop(true, ParticleSystemStopBehavior.StopEmittingAndClear);
                var main = particles.main;
                main.loop = true; main.prewarm = true; main.duration = 9;
                main.startLifetime = new ParticleSystem.MinMaxCurve(6, 9);
                main.startSize = new ParticleSystem.MinMaxCurve(.24f, .52f);
                main.startSpeed = 0; main.maxParticles = 32;
                main.startColor = new Color(.65f, .94f, .83f, .40f);
                main.simulationSpace = ParticleSystemSimulationSpace.World;
                var emission = particles.emission; emission.rateOverTime = 2.5f;
                var shape = particles.shape; shape.shapeType = ParticleSystemShapeType.Circle; shape.radius = 8;
                var velocity = particles.velocityOverLifetime;
                velocity.enabled = true; velocity.space = ParticleSystemSimulationSpace.World; velocity.y = 6;
                var color = particles.colorOverLifetime; color.enabled = true;
                var gradient = new Gradient();
                gradient.SetKeys(new[] { new GradientColorKey(Color.white, 0), new GradientColorKey(Color.white, 1) },
                    new[] { new GradientAlphaKey(0, 0), new GradientAlphaKey(1, .15f), new GradientAlphaKey(.7f, .8f), new GradientAlphaKey(0, 1) });
                color.color = gradient;
                var renderer = go.GetComponent<ParticleSystemRenderer>();
                renderer.sharedMaterial = airMaterial; renderer.renderMode = ParticleSystemRenderMode.Stretch;
                renderer.lengthScale = 2; renderer.velocityScale = .06f;
                particles.Play();
            }
        }

        void OnChanged()
        {
            if (session.Catches > previousCatches)
            {
                var player = session.Player;
                catchFeathers.transform.position = player.Position + player.Head.forward * (2 * player.Size);
                var main = catchFeathers.main;
                main.startSize = new ParticleSystem.MinMaxCurve(.025f * player.Size, .06f * player.Size);
                catchFeathers.Play();
                catchFeathers.Emit(12);
            }
            previousCatches = session.Catches;
        }

        void OnDestroy()
        {
            if (session) session.Changed -= OnChanged;
            if (sky) Destroy(sky);
            if (featherMaterial) Destroy(featherMaterial);
            if (airMaterial) Destroy(airMaterial);
        }
    }
}
