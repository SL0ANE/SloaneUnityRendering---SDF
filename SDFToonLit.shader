Shader "Sloane/SDFToonLit"
{
    Properties
    {
        _MainTex ("Texture", 3D) = "white" {}
        _SurfaceColor("Surface Color", Color) = (0.5, 0.5, 0.5, 0.5)
        _SurfaceSmoothness("Smoothness", Range(0, 1)) = 0.5
        _SurfaceOffset("Surface Offset", float) = 0.001
        _MaxSurfaceOffset("Max Surface Offset", float) = 0.05
        _NormalSmoothness("Normal Smoothness", Range(0.0001, 0.5)) = 0.0125
        _MaxNormalSmoothness("Max Normal Smoothness", Range(0.0001, 0.5)) = 0.05

        _Gradation("Gradation", float) = 3
        _SubLightGradation("SubLight Gradation", float) = 2
        _DiffuseDither("Diffuse Dither", Range(0.0, 0.5)) = 0.03125
        _MaxDiffuseDither("Max Diffuse Dither", Range(0.0, 0.5)) = 0.08
        _EdgeThresholds("Edge Thresholds", float) = 0.15
        _MaxEdgeThresholds("Max Edge Thresholds", float) = 0.3
        _LerpMaxDistance("Lerp Max Distance", float) = 64

        _Scaler("Scaler", float) = 1
    }
    SubShader
    {
        Tags { "RenderType"="Opaque" "Queue" = "Geometry+1"}
        LOD 100
        Blend SrcAlpha OneMinusSrcAlpha
        ZWrite Off
        ZTest Always
        Cull Front

        HLSLINCLUDE

        #include "SloaneSDFGeneric.hlsl"

        CBUFFER_START(UnityPerMaterial)
            sampler3D _MainTex;
            float4 _SurfaceColor;
            float _SurfaceSmoothness;
            sampler2D _CameraDepthTexture;
            float _SurfaceOffset;
            float _MaxSurfaceOffset;
            float _NormalSmoothness;
            float _MaxNormalSmoothness;
            float _Scaler;
            float _Gradation;
            float _SubLightGradation;
            float _DiffuseDither;
            float _MaxDiffuseDither;
            float _EdgeThresholds;
            float _MaxEdgeThresholds;
            float _LerpMaxDistance;
        CBUFFER_END

        float3 ApplyToonLighting(Light light, float3 normal, float3 viewDir, float4 baseColor, float smoothness, float edgeThresholds, float intensity, float gradation, float depth, float graRate) {
            float diffuseDither = lerp(_DiffuseDither, _MaxDiffuseDither, graRate);
            float level = saturate(dot(normal, light.direction)) * gradation;
            if(dot(normal, viewDir) <= edgeThresholds) level = level - 1;
            level = level > 0 ? level : 0;
            float ditherLevel = level - diffuseDither * gradation;
            ditherLevel = ditherLevel > 0 ? ditherLevel : 0;
            float diffuse = (floor(level) / gradation + floor(ditherLevel) / gradation) / 2;
            float upValue = lerp(0.25, 0.8, (gradation - 1) / gradation) * diffuse;
            diffuse += upValue / gradation;
            float3 output = diffuse * light.color * light.distanceAttenuation * baseColor;

            float3 halfVec = SafeNormalize(light.direction + viewDir);
            float NdotH = saturate(dot(normal, halfVec));
            half modifier = pow(NdotH, smoothness) > 0.5 ? 1 : 0;

            if(graRate < 0.5) output += baseColor * modifier * light.color * intensity;

            return output;
        }

        void GetToonSDFSurface(sampler3D mainTex, float3 rayOriOS, float3 rayDirOS, float surfaceOffset, float maxSurfaceOffset, float smoothness, float maxSmoothness, float lerpMax, float nearPlaneDepth, float maxRayLength, float stepFactor, float scaler, float cos, inout float rayLength, out int alpha, out float3 positionOS, out float3 normalOS) {
            
            float3 curPos = rayOriOS;
            alpha = -1;
            positionOS = float3(0.0, 0.0, 0.0);
            normalOS = float3(0.0, 0.0, 0.0);


            for(int i = 0; i < MAX_STEP; i++) {
                float curDis = GetSDF(mainTex, curPos, scaler);
                float depth = rayLength * cos;

                float lerpRate = saturate((depth - nearPlaneDepth) / (lerpMax - nearPlaneDepth));
                float curOffset = lerp(surfaceOffset, maxSurfaceOffset, lerpRate);
                
                if(curDis <= curOffset) {
                    alpha = 1.0;
                    positionOS = curPos;
                    normalOS = GetNormal(mainTex, curPos, scaler, lerp(smoothness, maxSmoothness, lerpRate));
                    return;
                }
                
                curPos += curDis * rayDirOS / scaler;
                rayLength += curDis * stepFactor;

                if(max(abs(curPos.x), max(abs(curPos.y), abs(curPos.z))) > 0.5f + BIAS || rayLength > maxRayLength) return;
            }

            return;
        }

        half4 SDFfrag(Varyings input) : SV_Target {
            float2 screenCoord = input.positionSS / input.positionSS.w / 2 + 0.5;

            float3 rayDirOS = normalize(input.surfaceRayOS);
            float3 rayOriOS = CalculateRayBoxIntersection(input.positionOS, -rayDirOS, _Scaler);

            float insideDetect = length(rayOriOS - input.positionOS) - length(input.surfaceRayOS);
            float nearPlaneDepth = Linear01Depth(0, _ZBufferParams);

            if(insideDetect > 0) {
                float4 nearPlanePos = mul(UNITY_MATRIX_I_V, mul(UNITY_MATRIX_I_P, float4(screenCoord.x * 2 - 1, screenCoord.y * 2 - 1, nearPlaneDepth, 1)));
                nearPlanePos = mul(unity_WorldToObject, nearPlanePos);
                nearPlanePos /= nearPlanePos.w;

                rayOriOS = nearPlanePos.xyz;
            }

            #if UNITY_UV_STARTS_AT_TOP
                screenCoord.y = 1 - screenCoord.y;
            #endif
            float3 rayDirWS = normalize(input.surfaceRayWS);

            float rawDepth = tex2D(_CameraDepthTexture, screenCoord).r;
            float linerDepth = LinearEyeDepth(rawDepth, _ZBufferParams);
            float cos_theta = dot(rayDirWS, -UNITY_MATRIX_V[2].xyz);
            float maxRayLength = linerDepth / cos_theta;

            int alpha;
            float3 surPosOS;
            float3 normalOS;
            float outDepth = length(TransformObjectToWorld(rayOriOS) - _WorldSpaceCameraPos);

            GetToonSDFSurface(_MainTex, rayOriOS, rayDirOS, _SurfaceOffset, _MaxSurfaceOffset, _NormalSmoothness, _MaxNormalSmoothness, _LerpMaxDistance, nearPlaneDepth, maxRayLength, input.stepFactor, _Scaler, cos_theta, outDepth, alpha, surPosOS, normalOS);

            outDepth *= cos_theta;

            clip(alpha);

            float3 normal = normalize(TransformObjectToWorldDir(normalOS));
            float3 viewDir = normalize(-input.surfaceRayWS);
            float smoothness = exp2(10 * _SurfaceSmoothness + 1);

            float lerpRate = saturate((outDepth - nearPlaneDepth) / (_LerpMaxDistance - nearPlaneDepth));
            float gradation = lerp(_Gradation, 1, lerpRate);
            float subGradation = lerp(_SubLightGradation, 1, lerpRate);
            float edgeThresholds = lerp(_EdgeThresholds, _MaxEdgeThresholds, lerpRate);

            float4 output = float4(unity_AmbientSky.xyz, 1.0);
            uint lightsCount = GetAdditionalLightsCount();
            LIGHT_LOOP_BEGIN(lightsCount)
            Light light = GetAdditionalLight(lightIndex, input.positionWS);
            output.xyz += ApplyToonLighting(light, normal, viewDir, _SurfaceColor, smoothness, edgeThresholds, _SurfaceSmoothness, subGradation, outDepth, lerpRate);
            LIGHT_LOOP_END

            Light mainLight = GetMainLight();
            output.xyz += ApplyToonLighting(mainLight, normal, viewDir, _SurfaceColor, smoothness, edgeThresholds, _SurfaceSmoothness, gradation, outDepth, lerpRate);

            // output.a = alpha;

            // return NormalizeColor(viewDir);
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
