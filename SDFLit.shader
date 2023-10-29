Shader "Sloane/SDFLit"
{
    Properties
    {
        _MainTex ("Texture", 3D) = "white" {}
        _SurfaceColor("Surface Color", Color) = (0.5, 0.5, 0.5, 0.5)
        _SurfaceSmoothness("Smoothness", Range(0, 1)) = 0.5
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
            float4 positionSS : TEXCOORD0;
            float3 positionWS : TEXCOORD1;
            float3 positionOS : TEXCOORD2;
            float3 surfaceRayOS : TEXCOORD3;
            float3 surfaceRayWS : TEXCOORD4;
        };

        CBUFFER_START(UnityPerMaterial)
            sampler3D _MainTex;
            float4 _SurfaceColor;
            float _SurfaceSmoothness;
            sampler2D _CameraDepthTexture;
            float _SurfaceOffset;
            float _NormalSmoothness;
            float _Scaler;
        CBUFFER_END

        float3 ApplyLighting(Light light, float3 normal, float3 viewDir, float4 baseColor, float smoothness) {
            float3 output = LightingLambert(light.color * light.distanceAttenuation, light.direction, normal) * baseColor;
            output += LightingSpecular(light.color * light.distanceAttenuation, light.direction, normal, viewDir, baseColor, smoothness);

            return output;
        }

        float4 NormalizeColor(float3 pos) {
            float4 output = float4(pos, 1.0);
            output.xyz = output.xyz / 2.0 + 0.5;
            return output;
        }

        float3 CalculateRayBoxIntersection(float3 rayOrigin, float3 rayDirection)
        {
            // 定义正方体的最小和最大顶点
            float3 minBox = float3(-0.5, -0.5, -0.5);  // 正方体的中心在原点
            float3 maxBox = float3(0.5, 0.5, 0.5);

            // 计算每个正方体面的平面方程
            float4 planes[6];
            planes[0] = float4(0, 0, 1, -maxBox.z);  // 前面
            planes[1] = float4(0, 0, -1, minBox.z);  // 后面
            planes[2] = float4(1, 0, 0, -maxBox.x);  // 右边
            planes[3] = float4(-1, 0, 0, minBox.x);  // 左边
            planes[4] = float4(0, 1, 0, -maxBox.y);  // 顶部
            planes[5] = float4(0, -1, 0, minBox.y);  // 底部

            // 初始化交点
            float3 intersectionPoint = float3(0, 0, 0);
            float pointDis = 0.0001 / _Scaler;

            float applyBias = BIAS / _Scaler;

            // 遍历每个面来找到交点
            for (int i = 0; i < 6; i++)
            {
                float d = abs(dot(planes[i], float4(rayOrigin, 1.0)));
                float t = d / dot(planes[i].xyz, rayDirection);
                
                // 计算交点
                float3 candidatePoint = rayOrigin + t * rayDirection;
                
                // 检查交点是否在正方体内
                if (candidatePoint.x >= minBox.x - applyBias / _Scaler && candidatePoint.x <= maxBox.x + applyBias &&
                candidatePoint.y >= minBox.y - applyBias / _Scaler && candidatePoint.y <= maxBox.y + applyBias &&
                candidatePoint.z >= minBox.z - applyBias / _Scaler && candidatePoint.z <= maxBox.z + applyBias)
                {
                    if(t < pointDis) continue;
                    pointDis = t;
                    intersectionPoint = candidatePoint;
                    break;
                }
            }
            intersectionPoint = (0.5 - applyBias) / (max(abs(intersectionPoint.x), max(abs(intersectionPoint.y), abs(intersectionPoint.z))) + applyBias) * intersectionPoint;
            return intersectionPoint;
            //return float3(pointDis, pointDis, pointDis);
        }

        float GetSDF(float3 positionOS) {
            return tex3D(_MainTex, (positionOS + float3(0.5, 0.5, 0.5)) * _Scaler).r;
        }

        float3 GetNormal(float3 surfacePos) {
            float2 dt = float2(_NormalSmoothness / _Scaler, 0.0f);
            return normalize(float3(
            GetSDF(surfacePos + dt.xyy) - GetSDF(surfacePos - dt.xyy),
            GetSDF(surfacePos + dt.yxy) - GetSDF(surfacePos - dt.yxy),
            GetSDF(surfacePos + dt.yyx) - GetSDF(surfacePos - dt.yyx)
            ));
        }

        void GetSDFSurface(float3 rayOriOS, float3 rayDirOS, out int cull, out float3 positionOS, out float3 normalOS) {
            
            float3 curPos = rayOriOS;
            cull = -1;
            positionOS = float3(0.0, 0.0, 0.0);
            normalOS = float3(0.0, 0.0, 0.0);


            for(int i = 0; i < MAX_STEP; i++) {
                float curDis = GetSDF(curPos);
                
                if(curDis <= _SurfaceOffset) {
                    cull = 1;
                    positionOS = curPos;
                    normalOS = GetNormal(curPos);
                    return;
                }
                
                curPos += curDis * rayDirOS / _Scaler;

                if(max(abs(curPos.x), max(abs(curPos.y), abs(curPos.z))) > 0.5f + BIAS) return;
            }

            return;
        }

        Varyings SDFvert(Attributes input) {
            Varyings output;
            output.positionOS = input.positionOS;
            output.positionCS = TransformObjectToHClip(input.positionOS);
            output.positionWS = TransformObjectToWorld(input.positionOS);
            output.positionSS = output.positionCS;

            
            output.surfaceRayOS = input.positionOS - TransformWorldToObject(_WorldSpaceCameraPos);
            output.surfaceRayWS = output.positionWS - _WorldSpaceCameraPos;

            return output;
        }

        half4 SDFfrag(Varyings input) : SV_Target {
            float2 screenCoord = input.positionSS / input.positionSS.w / 2 + 0.5;

            float3 rayDirOS = normalize(input.surfaceRayOS);
            float3 rayOriOS = CalculateRayBoxIntersection(input.positionOS, -rayDirOS);

            float insideDetect = length(rayOriOS - input.positionOS) - length(input.surfaceRayOS);
            if(insideDetect > 0) {
                float depth = Linear01Depth(0, _ZBufferParams);
                float4 nearPlanePos = mul(UNITY_MATRIX_I_V, mul(UNITY_MATRIX_I_P, float4(screenCoord.x * 2 - 1, screenCoord.y * 2 - 1, depth, 1)));
                nearPlanePos = mul(unity_WorldToObject, nearPlanePos);
                nearPlanePos /= nearPlanePos.w;

                rayOriOS = nearPlanePos.xyz;
            }

            int cull;
            float3 surPosOS;
            float3 normalOS;

            GetSDFSurface(rayOriOS, rayDirOS, cull, surPosOS, normalOS);

            clip(cull);

            #if UNITY_UV_STARTS_AT_TOP
                screenCoord.y = 1 - screenCoord.y;
            #endif
            float rawDepth = tex2D(_CameraDepthTexture, screenCoord).r;

            float3 normal = normalize(TransformObjectToWorldDir(normalOS));
            float3 viewDir = normalize(-input.surfaceRayWS);
            float smoothness = exp2(10 * _SurfaceSmoothness + 1);

            float4 output = float4(0.0, 0.0, 0.0, 1.0);
            uint lightsCount = GetAdditionalLightsCount();
            LIGHT_LOOP_BEGIN(lightsCount)
            Light light = GetAdditionalLight(lightIndex, input.positionWS);
            output.xyz += ApplyLighting(light, normal, viewDir, _SurfaceColor, smoothness);
            LIGHT_LOOP_END

            Light mainLight = GetMainLight();
            output.xyz += ApplyLighting(mainLight, normal, viewDir, _SurfaceColor, smoothness);

            //return NormalizeColor(viewDir);
            return output;
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
