Shader "Soaring/Air Wisps"
{
 SubShader {
  Tags { "Queue"="Transparent" "RenderType"="Transparent" }
  Blend SrcAlpha OneMinusSrcAlpha
  ZWrite Off Cull Off
  Pass {
   HLSLPROGRAM
   #pragma vertex vert
   #pragma fragment frag
   #pragma multi_compile_instancing
   #include "UnityCG.cginc"
   struct appdata { float4 vertex:POSITION; float2 uv:TEXCOORD0; half4 color:COLOR; UNITY_VERTEX_INPUT_INSTANCE_ID };
   struct v2f { float4 position:SV_POSITION; float2 uv:TEXCOORD0; half4 color:COLOR; UNITY_VERTEX_OUTPUT_STEREO };
   v2f vert(appdata v) { v2f o; UNITY_SETUP_INSTANCE_ID(v); UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o); o.position=UnityObjectToClipPos(v.vertex); o.uv=v.uv; o.color=v.color; return o; }
   half4 frag(v2f i):SV_Target { float2 p=(i.uv-.5)*2; half edge=saturate((1-dot(p,p))*2); return half4(i.color.rgb,i.color.a*edge*edge); }
   ENDHLSL
  }
 }
}
