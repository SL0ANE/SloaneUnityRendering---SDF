Shader "Sloane/SDFLit"
{
    Properties
    {
        _MainTex ("Texture", 3D) = "white" {}
        _SurfaceColor("Surface Color", Color) = (0.5, 0.5, 0.5, 0.5)
        _SurfaceSmoothness("Smoothness", Range(0, 1)) = 0.5
        _SurfaceOffset("Surface Offset", float) = 0.001
        _MaxSurfaceOffset("Max Surface Offset", float) = 0.05
        _NormalSmoothness("Normal Smoothness", Range(0.0001, 0.1)) = 0.0001
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
            float _Scaler;
        CBUFFER_END

        half4 SDFfrag(Varyings input) : SV_Target {
            float2 screenCoord = input.positionSS / input.positionSS.w / 2 + 0.5;

            float3 rayDirOS = normalize(input.surfaceRayOS);
            float3 rayOriOS = CalculateRayBoxIntersection(input.positionOS, -rayDirOS, _Scaler);

            float insideDetect = length(rayOriOS - input.positionOS) - length(input.surfaceRayOS);
            if(insideDetect > 0) {
                float depth = Linear01Depth(0, _ZBufferParams);
                float4 nearPlanePos = mul(UNITY_MATRIX_I_V, mul(UNITY_MATRIX_I_P, float4(screenCoord.x * 2 - 1, screenCoord.y * 2 - 1, depth, 1)));
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

            GetSDFSurface(_MainTex, rayOriOS, rayDirOS, _SurfaceOffset, _MaxSurfaceOffset, _Scaler, _NormalSmoothness, maxRayLength, input.stepFactor, cos_theta, outDepth, alpha, surPosOS, normalOS);

            outDepth *= cos_theta;

            clip(alpha);

            float3 normal = normalize(TransformObjectToWorldDir(normalOS));
            float3 viewDir = normalize(-input.surfaceRayWS);
            float smoothness = exp2(10 * _SurfaceSmoothness + 1);

            float4 output = float4(0.0, 0.0, 0.0, 1.0);
            uint lightsCount = GetAdditionalLightsCount();
            LIGHT_LOOP_BEGIN(lightsCount)
            Light light = GetAdditionalLight(lightIndex, input.positionWS);
            output.xyz += ApplyLighting(light, normal, viewDir, _SurfaceColor, smoothness, _SurfaceSmoothness);
            LIGHT_LOOP_END

            Light mainLight = GetMainLight();
            output.xyz += ApplyLighting(mainLight, normal, viewDir, _SurfaceColor, smoothness, _SurfaceSmoothness);

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
