Shader "Soaring/Water"
{
 Properties { _BaseColor("Tint",Color)=(1,1,1,1) }
 SubShader {
 Tags {"RenderPipeline"="UniversalPipeline" "RenderType"="Opaque"}
 Pass { Tags {"LightMode"="UniversalForward"}
 HLSLPROGRAM
 #pragma vertex Vert
 #pragma fragment Frag
 #pragma multi_compile_instancing
 #pragma multi_compile_fog
 #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE
 #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
 #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
 CBUFFER_START(UnityPerMaterial)
 float4 _BaseColor;
 CBUFFER_END
 struct A {float4 p:POSITION;float4 c:COLOR;UNITY_VERTEX_INPUT_INSTANCE_ID};struct V{float4 p:SV_POSITION;float3 world:TEXCOORD0;float3 color:COLOR;float fog:TEXCOORD1;UNITY_VERTEX_OUTPUT_STEREO};
 V Vert(A i){V o;UNITY_SETUP_INSTANCE_ID(i);UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);o.world=TransformObjectToWorld(i.p.xyz);o.p=TransformWorldToHClip(o.world);o.color=i.c.rgb*_BaseColor.rgb;o.fog=ComputeFogFactor(o.p.z);return o;}
 half4 Frag(V i):SV_Target{UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);float3 view=normalize(GetCameraPositionWS()-i.world);float3 n=normalize(float3(sin(i.world.x*.33+_Time.y*.8)*.024,1,cos(i.world.z*.28-_Time.y*.6)*.024));float fresnel=pow(1-saturate(dot(n,view)),4);Light sun=GetMainLight(TransformWorldToShadowCoord(i.world));sun.shadowAttenuation=lerp(sun.shadowAttenuation,1,GetMainLightShadowFade(i.world));float shine=pow(saturate(dot(n,normalize(view+sun.direction))),96)*.25;half3 color=lerp(i.color*.82,float3(.4,.6,.68),fresnel*.62)*lerp(.55,1,sun.shadowAttenuation)+sun.color*shine*sun.shadowAttenuation;return half4(MixFog(color,i.fog),1);}
 ENDHLSL
 }
 }
}
