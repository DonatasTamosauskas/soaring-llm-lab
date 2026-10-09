Shader "Soaring/Bird"
{
 Properties { _Pose("Phase, amount, fold, perch",Vector)=(0,0,0,0) _Highlight("Highlight",Float)=0 }
 SubShader {
 Tags {"RenderPipeline"="UniversalPipeline" "RenderType"="Opaque"}
 HLSLINCLUDE
 #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
 #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
 CBUFFER_START(UnityPerMaterial)
 float4 _Pose; float _Highlight;
 CBUFFER_END
 UNITY_INSTANCING_BUFFER_START(Birds)
 UNITY_DEFINE_INSTANCED_PROP(float4,_BirdPose)
 UNITY_DEFINE_INSTANCED_PROP(float,_BirdHighlight)
 UNITY_INSTANCING_BUFFER_END(Birds)
 struct Attributes {float4 p:POSITION; float3 n:NORMAL; float4 col:COLOR;float2 uv:TEXCOORD0;float2 hug:TEXCOORD1;float4 c0:TEXCOORD2;float4 c1:TEXCOORD3;float4 c2:TEXCOORD4;float4 c3:TEXCOORD5;UNITY_VERTEX_INPUT_INSTANCE_ID};
 float3 rx(float3 v,float a){float s=sin(a),c=cos(a);return float3(v.x,v.y*c-v.z*s,v.y*s+v.z*c);}
 float3 ry(float3 v,float a){float s=sin(a),c=cos(a);return float3(v.x*c+v.z*s,v.y,-v.x*s+v.z*c);}
 float3 rz(float3 v,float a){float s=sin(a),c=cos(a);return float3(v.x*c-v.y*s,v.x*s+v.y*c,v.z);}
 float stroke(float p){return p<.42?cos(PI*p/.42):-cos(PI*(p-.42)/.58);}
 void Deform(Attributes i,out float3 q,out float3 m){
 float4 pose=UNITY_ACCESS_INSTANCED_PROP(Birds,_BirdPose);
 float phase=pose.x,amount=pose.y,fold=pose.z,perch=pose.w;float eff=amount*(1-fold)*(1-fold),s=stroke(phase),sl=stroke(frac(phase-.08));
 // Pose in the original right handed authoring space, then reflect Z once.
 q=i.p.xyz*float3(1,1,-1);m=i.n*float3(1,1,-1);int group=(int)round(i.c0.x);float amp=i.c3.x;
 if(group==1||group==2){
 float fx=phase<.42?0:sin(PI*(phase-.42)/.58),pw=phase<.42?sin(PI*phase/.42):0,retr=i.c3.z;
 float elev=eff*amp*(.1047198+.7679449*s)+fold*lerp(-.9599311,-1.2217305,perch)*i.c3.y;
 float sweep=-eff*fx*.2094395*retr-fold*1.4660766*i.c2.w;
 float twist=eff*(fx*.1745329-pw*.1047198)*retr,spanK=1-(eff*fx*.3+fold*.72)*retr;
 bool mirror=i.c0.y<0;if(mirror){q.x=-q.x;m.x=-m.x;}float3 sh=i.c1.xyz;
 q.z-=fold*(2-fold)*i.c0.w;float3 d;
 if(group==1){d=q-sh;d.x*=spanK;m=normalize(float3(m.x/spanK,m.y,m.z));}
 else{float3 wc=i.c2.xyz,dw=wc-sh;dw.x*=spanK;float hw=i.c0.z;
 float he=hw*(eff*amp*(.7679449*.3*(sl-s)-fx*.2792527)+eff*pw*.1745329)-fold*i.uv.x;
 float hs=-hw*eff*fx*.5235988,ht=hw*eff*fx*.3490659;
 d=dw+rz(ry(rx(q-wc,ht),hs),he);m=rz(ry(rx(m,ht),hs),he);}
 float droop=fold*lerp(.0698132,i.uv.y,perch)*retr,flat=-fold*i.c1.w;
 q=sh+rx(rz(ry(rx(rz(d,flat),twist),sweep),elev),droop);
 m=rx(rz(ry(rx(rz(m,flat),twist),sweep),elev),droop);
 q.x+=fold*.016*retr;q.x-=fold*fold*fold*i.hug.x;q.y+=fold*fold*fold*i.hug.y;
 if(mirror){q.x=-q.x;m.x=-m.x;}}
 else if(group==3){float3 t=i.c1.xyz;float tc=max(fold,perch),spread=1+eff*.12-i.c2.w*tc*(2-tc),tp=eff*amp*.1047198*sl+perch*i.c1.w;
 float3 d=q-t;d.x*=spread;q=t+rx(d,-tp);m=rx(normalize(float3(m.x/spread,m.y,m.z)),-tp);}
 else if(group==4){float3 hip=i.c1.xyz;float k=lerp(.3,1,perch),ang=lerp(i.c1.w,-i.c3.w,perch);q=hip+rx((q-hip)*k,ang);m=rx(m,ang);}
 else if(group==5){float3 neck=i.c1.xyz;float look=perch*.6632251*sin(_Time.y*.4)*.65;q=neck+rx(ry(q-neck,look),-perch*i.c3.w);m=rx(ry(m,look),-perch*i.c3.w);}
 q=rx(q,perch*i.c3.w);m=rx(m,perch*i.c3.w);q.y-=.014*eff*amp*sl;
 q*=float3(1,1,-1);m*=float3(1,1,-1);
 }
 ENDHLSL
 Pass { Tags {"LightMode"="UniversalForward"} Cull Back
 HLSLPROGRAM
 #pragma vertex Vert
 #pragma fragment Frag
 #pragma multi_compile_instancing
 #pragma multi_compile_fog
 #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE
 struct Varyings {float4 p:SV_POSITION;float3 n:TEXCOORD0;float4 col:COLOR;float fog:TEXCOORD1;float3 positionWS:TEXCOORD2;UNITY_VERTEX_OUTPUT_STEREO};
 Varyings Vert(Attributes i){Varyings o;UNITY_SETUP_INSTANCE_ID(i);UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
 float3 q,m;Deform(i,q,m);o.positionWS=TransformObjectToWorld(q);
 o.p=TransformWorldToHClip(o.positionWS);o.n=TransformObjectToWorldNormal(m);o.col=i.col;
 float highlight=UNITY_ACCESS_INSTANCED_PROP(Birds,_BirdHighlight);
 if(highlight>0)o.col.rgb=lerp(o.col.rgb,highlight<1.5?float3(.25,.18,1):float3(1,0,.6),.22);
 o.fog=ComputeFogFactor(o.p.z);return o;}
 half4 Frag(Varyings i):SV_Target{UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);Light sun=GetMainLight(TransformWorldToShadowCoord(i.positionWS));
    sun.shadowAttenuation=lerp(sun.shadowAttenuation,1,GetMainLightShadowFade(i.positionWS));half3 n=normalize(i.n);half3 c=i.col.rgb*(SampleSH(n)*.72+sun.color*(max(0,dot(n,sun.direction))*.8*sun.shadowAttenuation+.18));return half4(MixFog(c,i.fog),1);}
 ENDHLSL
 }
 Pass {
 Name "ShadowCaster" Tags {"LightMode"="ShadowCaster"}
 ZWrite On ZTest LEqual ColorMask 0 Cull Back
 HLSLPROGRAM
 #pragma vertex ShadowVert
 #pragma fragment ShadowFrag
 #pragma multi_compile_instancing
 float3 _LightDirection;
 struct ShadowVaryings {float4 p:SV_POSITION;};
 ShadowVaryings ShadowVert(Attributes i){UNITY_SETUP_INSTANCE_ID(i);ShadowVaryings o;float3 q,m;Deform(i,q,m);
 float3 p=TransformObjectToWorld(q),n=TransformObjectToWorldNormal(m);
 o.p=ApplyShadowClamping(TransformWorldToHClip(ApplyShadowBias(p,n,_LightDirection)));return o;}
 half4 ShadowFrag(ShadowVaryings i):SV_Target{return 0;}
 ENDHLSL
 }
 }
}
