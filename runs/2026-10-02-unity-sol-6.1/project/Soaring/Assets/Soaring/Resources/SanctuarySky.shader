Shader "Soaring/Sanctuary Sky"
{
 Properties { _SunDirection ("Sun direction", Vector) = (-0.4,0.65,-0.5,0) }
 SubShader {
  Tags { "Queue"="Background" "RenderType"="Background" "PreviewType"="Skybox" }
  Cull Off ZWrite Off
  Pass {
   HLSLPROGRAM
   #pragma vertex vert
   #pragma fragment frag
   #pragma multi_compile_instancing
   #include "UnityCG.cginc"
   float4 _SunDirection;
   struct appdata { float4 vertex:POSITION; UNITY_VERTEX_INPUT_INSTANCE_ID };
   struct v2f { float4 position:SV_POSITION; float3 direction:TEXCOORD0; UNITY_VERTEX_OUTPUT_STEREO };
   v2f vert(appdata v) { v2f o; UNITY_SETUP_INSTANCE_ID(v); UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o); o.position=UnityObjectToClipPos(v.vertex); o.direction=v.vertex.xyz; return o; }
   half4 frag(v2f i):SV_Target {
    float3 d=normalize(i.direction); float h=saturate(d.y);
    half3 horizon=half3(.91,.84,.68), zenith=half3(.19,.46,.65);
    half3 c=lerp(horizon,zenith,pow(h,.42));
    float sun=saturate(dot(d,normalize(_SunDirection.xyz)));
    c+=half3(.25,.16,.055)*pow(sun,12);
    c=lerp(c,half3(1,.95,.77),smoothstep(.9993,.9996,sun));
    // Broad painted wisps, stationary so the sky never implies camera motion.
    float w=sin(d.x*12+d.z*8+sin(d.z*7)*.7)*.5+.5;
    float band=smoothstep(.08,.16,h)*(1-smoothstep(.24,.36,h));
    c=lerp(c,half3(.93,.91,.80),smoothstep(.76,.96,w)*band*.22);
    return half4(GammaToLinearSpace(c),1);
   }
   ENDHLSL
  }
 }
}
