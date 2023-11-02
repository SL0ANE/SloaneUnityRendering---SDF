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
    float stepFactor : TEXCOORD5;
};

float3 ApplyLighting(Light light, float3 normal, float3 viewDir, float4 baseColor, float smoothness, float intensity) {
    float3 output = LightingLambert(light.color * light.distanceAttenuation, light.direction, normal) * baseColor;
    output += LightingSpecular(light.color * light.distanceAttenuation, light.direction, normal, viewDir, baseColor, smoothness) * intensity;

    return output;
}

float4 NormalizeColor(float3 pos) {
    float4 output = float4(pos, 1.0);
    output.xyz = output.xyz / 2.0 + 0.5;
    return output;
}

float3 CalculateRayBoxIntersection(float3 rayOrigin, float3 rayDirection, float scaler)
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
    float3 intersectionPoint = float3(-256, 0, 0);
    float pointDis = pow(BIAS, 4) / scaler;

    float applyBias = BIAS / scaler;

    // 遍历每个面来找到交点
    for (int i = 0; i < 6; i++)
    {
        float d = abs(dot(planes[i], float4(rayOrigin, 1.0)));
        float t = d / dot(planes[i].xyz, rayDirection);
        
        // 计算交点
        float3 candidatePoint = rayOrigin + t * rayDirection;

        float3 projectCoord = candidatePoint * (1.0 - abs(planes[i].xyz));
        
        // 检查交点是否在正方体内
        if (projectCoord.x >= minBox.x - applyBias && projectCoord.x <= maxBox.x + applyBias &&
        projectCoord.y >= minBox.y - applyBias && projectCoord.y <= maxBox.y + applyBias &&
        projectCoord.z >= minBox.z - applyBias && projectCoord.z <= maxBox.z + applyBias)
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

float GetSDF(sampler3D mainTex, float3 positionOS, float scaler) {
    return tex3D(mainTex, (positionOS + float3(0.5, 0.5, 0.5)) * scaler).r;
}

float3 GetNormal(sampler3D mainTex, float3 surfacePos, float scaler, float smoothness) {
    float2 dt = float2(smoothness / scaler, 0.0f);
    return normalize(float3(
    GetSDF(mainTex, surfacePos + dt.xyy, scaler) - GetSDF(mainTex, surfacePos - dt.xyy, scaler),
    GetSDF(mainTex, surfacePos + dt.yxy, scaler) - GetSDF(mainTex, surfacePos - dt.yxy, scaler),
    GetSDF(mainTex, surfacePos + dt.yyx, scaler) - GetSDF(mainTex, surfacePos - dt.yyx, scaler)
    ));
}

void GetSDFSurface(sampler3D mainTex, float3 rayOriOS, float3 rayDirOS, float surfaceOffset, float maxSurfaceOffset, float scaler, float smoothness, float maxRayLength, float stepFactor, float cos, inout float rayLength, out int alpha, out float3 positionOS, out float3 normalOS) {
    
    float3 curPos = rayOriOS;
    alpha = -1;
    positionOS = float3(0.0, 0.0, 0.0);
    normalOS = float3(0.0, 0.0, 0.0);


    for(int i = 0; i < MAX_STEP; i++) {
        float curDis = GetSDF(mainTex, curPos, scaler);
        float depth = rayLength * cos;

        float curOffset = lerp(surfaceOffset, maxSurfaceOffset, (depth - _ZBufferParams.x) / (_ZBufferParams.y - _ZBufferParams.x));
        
        if(curDis <= surfaceOffset) {
            alpha = 1.0;
            positionOS = curPos;
            normalOS = GetNormal(mainTex, curPos, scaler, smoothness);
            return;
        }
        
        curPos += curDis * rayDirOS / scaler;
        rayLength += curDis * stepFactor;

        if(max(abs(curPos.x), max(abs(curPos.y), abs(curPos.z))) > 0.5f + BIAS || rayLength > maxRayLength) return;
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
    output.stepFactor = length(output.surfaceRayWS) / length(output.surfaceRayOS);

    return output;
}