Shader "Soaring/Valley"
{
 Properties { _BaseColor("Tint",Color)=(1,1,1,1) _Sway("Foliage motion",Float)=0 }
 SubShader
 {
  Tags {"RenderPipeline"="UniversalPipeline" "RenderType"="Opaque" "Queue"="Geometry"}
  HLSLINCLUDE
  #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
  #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
  CBUFFER_START(UnityPerMaterial)
  float4 _BaseColor; float _Sway;
  CBUFFER_END
  struct Attributes {float4 positionOS:POSITION; float3 normalOS:NORMAL; float4 color:COLOR; UNITY_VERTEX_INPUT_INSTANCE_ID};
  float3 Deform(Attributes i)
  {
   float3 p=i.positionOS.xyz;
   p.x+=sin(_Time.y*1.1+p.x*.07+p.z*.09)*i.color.a*_Sway;
   return p;
  }
  ENDHLSL
  Pass
  {
   Tags {"LightMode"="UniversalForward"}
   HLSLPROGRAM
   #pragma vertex Vert
   #pragma fragment Frag
   #pragma multi_compile_instancing
   #pragma multi_compile_fog
   #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE
   struct Varyings {float4 positionCS:SV_POSITION; float3 normalWS:TEXCOORD0; float4 color:COLOR; float fog:TEXCOORD1; float3 positionWS:TEXCOORD2; UNITY_VERTEX_OUTPUT_STEREO};
   Varyings Vert(Attributes i)
   {
    Varyings o; UNITY_SETUP_INSTANCE_ID(i); UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
    o.positionWS=TransformObjectToWorld(Deform(i)); o.positionCS=TransformWorldToHClip(o.positionWS);
    o.normalWS=TransformObjectToWorldNormal(i.normalOS); o.color=i.color*_BaseColor;
    o.fog=ComputeFogFactor(o.positionCS.z); return o;
   }
   half4 Frag(Varyings i):SV_Target
   {
    UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);
    Light sun=GetMainLight(TransformWorldToShadowCoord(i.positionWS));
    sun.shadowAttenuation=lerp(sun.shadowAttenuation,1,GetMainLightShadowFade(i.positionWS));
    half3 n=normalize(i.normalWS); half nd=max(0,dot(n,sun.direction));
    half3 c=i.color.rgb*(SampleSH(n)*.72+sun.color*(nd*.72*sun.shadowAttenuation+.14));
    return half4(MixFog(c,i.fog),1);
   }
   ENDHLSL
  }
  Pass
  {
   Name "ShadowCaster"
   Tags {"LightMode"="ShadowCaster"}
   ZWrite On ZTest LEqual ColorMask 0
   HLSLPROGRAM
   #pragma vertex ShadowVert
   #pragma fragment ShadowFrag
   #pragma multi_compile_instancing
   float3 _LightDirection;
   struct ShadowVaryings {float4 positionCS:SV_POSITION;};
   ShadowVaryings ShadowVert(Attributes i)
   {
    UNITY_SETUP_INSTANCE_ID(i); ShadowVaryings o;
    float3 p=TransformObjectToWorld(Deform(i));
    float3 n=TransformObjectToWorldNormal(i.normalOS);
    o.positionCS=ApplyShadowClamping(TransformWorldToHClip(ApplyShadowBias(p,n,_LightDirection)));
    return o;
   }
   half4 ShadowFrag(ShadowVaryings i):SV_Target { return 0; }
   ENDHLSL
  }
 }
}
