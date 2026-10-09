using UnityEngine;

namespace Soaring
{
    /// <summary>Warm bell feedback and quiet filtered wing/air sounds, generated once at startup.</summary>
    public sealed class BirdAudio : MonoBehaviour
    {
        AudioSource effects, air;
        AudioClip click, flap, wind, death, victory, growth;
        AudioClip[] catches;
        float lastFlap=-1;
        int growthStage=1;
        public float Volume { get; private set; } = .4f;
        void Awake()
        {
            Volume=PlayerPrefs.GetFloat("Soaring.Audio",.4f);
            effects=gameObject.AddComponent<AudioSource>();effects.spatialBlend=0;effects.playOnAwake=false;effects.volume=Volume;
            air=gameObject.AddComponent<AudioSource>();air.spatialBlend=0;air.playOnAwake=false;air.loop=true;air.volume=0;
            click=Chime("Soft menu tap",.12f,new[]{740f},.28f);
            catches=new AudioClip[5];float[] notes={523.25f,587.33f,659.25f,783.99f,880f};
            for(int i=0;i<5;i++)catches[i]=Chime("Catch note "+i,.42f,new[]{notes[i]},.5f);
            growth=Chime("Growing wings",.9f,new[]{523.25f,659.25f,783.99f},.45f);
            death=Chime("Last feather",.7f,new[]{392f,329.63f,261.63f},.3f);
            victory=Chime("Crown of the sky",1.7f,new[]{523.25f,659.25f,783.99f,1046.5f},.4f);
            flap=AirNoise("Feather stroke",.22f,true);
            wind=AirNoise("Valley breeze",2f,false);air.clip=wind;air.Play();
        }
        public void SetVolume(float value){Volume=Mathf.Clamp01(value);effects.volume=Volume;PlayerPrefs.SetFloat("Soaring.Audio",Volume);}
        public void Click()=>effects.PlayOneShot(click);
        public void Catch(int count,float size)
        {
            effects.PlayOneShot(catches[(count-1+catches.Length)%catches.Length]);
            int stage=Mathf.FloorToInt(size);
            if(stage>growthStage){effects.PlayOneShot(growth,.8f);growthStage=stage;}
            if(size<1.3f)growthStage=1;
        }
        public void Catch()=>Catch(1,1);
        public void Death()=>effects.PlayOneShot(death);
        public void Victory()=>effects.PlayOneShot(victory);
        public void Flight(float speed,bool flapped,bool flying)
        {
            float target=flying?Mathf.Clamp01(speed/45)*Volume*.12f:0;
            air.volume=Mathf.Lerp(air.volume,target,1-Mathf.Exp(-Time.unscaledDeltaTime*4));
            if(flying&&flapped&&Time.unscaledTime-lastFlap>.11f){lastFlap=Time.unscaledTime;effects.PlayOneShot(flap,.2f);}
        }
        static AudioClip Chime(string name,float duration,float[] notes,float gain)
        {
            const int rate=22050;var samples=new float[Mathf.CeilToInt(duration*rate)];
            for(int n=0;n<notes.Length;n++)
            {
                float delay=n*.14f;
                for(int i=Mathf.FloorToInt(delay*rate);i<samples.Length;i++)
                {
                    float t=i/(float)rate-delay;
                    float attack=Mathf.Clamp01(t/.012f);
                    float envelope=attack*Mathf.Exp(-t*7)*Mathf.Clamp01((duration-i/(float)rate)/.08f);
                    float phase=t*notes[n]*Mathf.PI*2;
                    float bell=Mathf.Sin(phase)+.28f*Mathf.Sin(phase*2)*Mathf.Exp(-t*4)+.12f*Mathf.Sin(phase*3.01f)*Mathf.Exp(-t*12);
                    samples[i]+=bell*envelope*gain/Mathf.Sqrt(notes.Length);
                }
            }
            return Clip(name,samples,rate);
        }
        static AudioClip AirNoise(string name,float duration,bool transient)
        {
            const int rate=22050;var samples=new float[Mathf.CeilToInt(duration*rate)];
            uint seed=41971;float filtered=0;
            for(int i=0;i<samples.Length;i++)
            {
                seed=seed*1664525+1013904223;
                float noise=(seed&65535)/32767.5f-1;
                filtered=Mathf.Lerp(filtered,noise,transient?.16f:.025f);
                float t=i/(float)samples.Length;
                float envelope=transient?Mathf.Sin(t*Mathf.PI)*Mathf.Pow(1-t,.45f):.75f+.12f*Mathf.Sin(t*Mathf.PI*4);
                samples[i]=filtered*envelope*(transient?.7f:.6f);
            }
            if(!transient)for(int i=0;i<128;i++){float t=i/128f;samples[i]*=t;samples[samples.Length-1-i]*=t;}
            return Clip(name,samples,rate);
        }
        static AudioClip Clip(string name,float[] data,int rate){var clip=AudioClip.Create(name,data.Length,1,rate,false);clip.SetData(data,0);return clip;}
        void OnDestroy()
        {
            foreach(var clip in new[]{click,flap,wind,death,victory,growth})if(clip)Destroy(clip);
            if(catches!=null)foreach(var clip in catches)if(clip)Destroy(clip);
        }
    }
}
