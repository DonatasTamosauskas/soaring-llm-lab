Shader "Soaring/UI Always Visible"
{
 Properties { [PerRendererData] _MainTex ("Font / Sprite", 2D) = "white" {} _Color ("Tint", Color) = (1,1,1,1) }
 SubShader
 {
  Tags { "Queue"="Overlay" "RenderType"="Transparent" "IgnoreProjector"="True" "CanUseSpriteAtlas"="True" }
  Cull Off ZWrite Off ZTest Always Blend SrcAlpha OneMinusSrcAlpha
  Pass
  {
   CGPROGRAM
   #pragma vertex vert
   #pragma fragment frag
   #pragma multi_compile_instancing
   #include "UnityCG.cginc"
   struct appdata { float4 vertex:POSITION; float4 color:COLOR; float2 uv:TEXCOORD0; UNITY_VERTEX_INPUT_INSTANCE_ID };
   struct v2f { float4 vertex:SV_POSITION; float4 color:COLOR; float2 uv:TEXCOORD0; UNITY_VERTEX_OUTPUT_STEREO };
   sampler2D _MainTex; float4 _Color; float4 _TextureSampleAdd;
   v2f vert(appdata v) { v2f o; UNITY_SETUP_INSTANCE_ID(v); UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o); o.vertex=UnityObjectToClipPos(v.vertex); o.color=v.color*_Color; o.uv=v.uv; return o; }
   fixed4 frag(v2f i):SV_Target { return (tex2D(_MainTex,i.uv)+_TextureSampleAdd)*i.color; }
   ENDCG
  }
 }
}
