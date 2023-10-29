Shader "Sloane/SDFLit"
{
    Properties
    {
        _MainTex ("Texture", 3D) = "white" {}
        _SurfaceOffset("Surface Offset", float) = 0.001
        _NormalSmoothness("Normal Smoothness", Range(0.0001, 0.1)) = 0.0001
        _Scaler("Scaler", float) = 1
    }
    SubShader
    {
        Tags { "RenderType"="Opaque" "Queue" = "Geometry+1"}
        LOD 100
        Cull Front

        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/Shaders/LitInput.hlsl"

        #define BIAS 0.001
        #define MAX_STEP 128
        
        struct Attributes {
            float3 positionOS : POSITION;
        };

        struct Varyings {
            float4 positionCS : SV_POSITION;
            float3 positionWS : TEXCOORD0;
            float3 positionOS : TEXCOORD1;
            float3 surfaceRayOS : TEXCOORD2;
            float3 surfaceRayWS : TEXCOORD3;
        };

        CBUFFER_START(UnityPerMaterial)
            sampler3D _MainTex;
            float _SurfaceOffset;
            float _NormalSmoothness;
            float _Scaler;
        CBUFFER_END

        float4 NormalizeColor(float3 pos) {
            float4 output = float4(pos, 1.0);
            output.xyz = output.xyz / 2.0 + 0.5;
            return output;
        }

        float GetSDF(float3 positionOS) {
            return tex3D(_MainTex, positionOS + float3(0.5, 0.5, 0.5)).r;
        }

        float3 GetNormal(float3 surfacePos) {
            float2 dt = float2(_NormalSmoothness, 0.0f);
            return normalize(float3(
            GetSDF(surfacePos + dt.xyy) - GetSDF(surfacePos - dt.xyy),
            GetSDF(surfacePos + dt.yxy) - GetSDF(surfacePos - dt.xyy),
            GetSDF(surfacePos + dt.yyx) - GetSDF(surfacePos - dt.xyy)
            ));
        }

        void GetSDFSurface(float3 rayOriOS, float3 rayDirOS, out int cull, out float3 positionOS, out float3 normalOS) {
            
            float3 curPos = rayOriOS;
            cull = -1;
            positionOS = float3(0.0, 0.0, 0.0);
            normalOS = float3(0.0, 0.0, 0.0);


            for(int i = 0; i < MAX_STEP; i++) {
                float curDis = GetSDF(curPos);
                
                if(curDis < _SurfaceOffset) {
                    cull = 1;
                    positionOS = curPos;
                    normalOS = GetNormal(curPos);
                    return;
                }
                
                curPos += curDis * rayDirOS;

                if(max(abs(curPos.x), max(abs(curPos.y), abs(curPos.z))) > 0.5f + 0.5) return;
            }

            return;
        }


        Varyings SDFvert(Attributes input) {
            Varyings output;
            output.positionOS = input.positionOS;
            output.positionCS = TransformObjectToHClip(input.positionOS);
            output.positionWS = TransformObjectToWorld(input.positionOS);

            
            output.surfaceRayWS = output.positionWS - _WorldSpaceCameraPos;
            output.surfaceRayOS = input.positionOS - TransformWorldToObject(_WorldSpaceCameraPos);

            return output;
        }

        half4 SDFfrag(Varyings input) : SV_Target {
            float3 rayDirOS = normalize(input.surfaceRayOS);
            float3 rayOriOS = input.positionOS;

            int cull;
            float3 surPosOS;
            float3 normalOS;
            GetSDFSurface(rayOriOS, rayDirOS, cull, surPosOS, normalOS);

            //clip(cull);

            return NormalizeColor(normalOS);
        }
        ENDHLSL

        Pass
        {
            HLSLPROGRAM
            #pragma vertex SDFvert
            #pragma fragment SDFfrag
            ENDHLSL
        }
    }
}
