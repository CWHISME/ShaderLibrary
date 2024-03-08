#ifndef SIH_STARRAIL_DRAWCORE_PASS_INCLUDED
#define SIH_STARRAIL_DRAWCORE_PASS_INCLUDED

// -------------------------------------
// 方法
// 去饱和度
float3 desaturation(float3 color)
{
    float3 grayXfer = float3(0.3, 0.59, 0.11);
    float grayf = dot(color, grayXfer);
    return float3(grayf, grayf, grayf);
}

// -------------------------------------
// 基本结构体输入
struct Attributes
{
    float4 positionOS   : POSITION;
    float3 normalOS     : NORMAL;
    float4 tangentOS    : TANGENT;
    float2 texcoord     : TEXCOORD0;
};

// -------------------------------------
// 基本结构体输出
struct Varyings
{
    float2 uv                       : TEXCOORD0;
    float4 positionWSAndFogFactor   : TEXCOORD1;    // xyz: positionWS, w: vertex FogFactor
    float3 normalWS                 : TEXCOORD2;
    float3 viewDirectionWS          : TEXCOORD3;
    float3 SH                       : TEXCOORD4;    
    float4 positionCS               : SV_POSITION;
};

// -------------------------------------
// 基本顶点着色器
Varyings StarRailPassVertex(Attributes input)
{
    Varyings output = (Varyings)0;

    VertexPositionInputs positionInputs = GetVertexPositionInputs(input.positionOS.xyz);
    VertexNormalInputs normalInputs = GetVertexNormalInputs(input.normalOS, input.tangentOS);
    output.uv = TRANSFORM_TEX(input.texcoord, _BaseMap);
    output.positionWSAndFogFactor = float4(positionInputs.positionWS, ComputeFogFactor(positionInputs.positionCS.z));
    output.normalWS = normalInputs.normalWS;
    output.viewDirectionWS = unity_OrthoParams.w == 0 ? GetCameraPositionWS() - positionInputs.positionWS : GetWorldToViewMatrix()[2].xyz;
    output.SH = SampleSH(lerp(normalInputs.normalWS, float3(0,0,0), _IndirectLightFlattenNormal));
    output.positionCS = positionInputs.positionCS;
    
    return output;
}

// -------------------------------------
// 基本片元着色器
float4 StarRailPassFragment(Varyings input, bool isFrontFace : SV_IsFrontFace) : SV_Target
{
    // Vector
    float3 positionWS = input.positionWSAndFogFactor.xyz;
    float4 shadowCoord = TransformWorldToShadowCoord(positionWS);
    Light mainLight = GetMainLight(shadowCoord);
    float3 lightDirectionWS = normalize(mainLight.direction);
    float3 normalWS = normalize(input.normalWS);
    float3 viewDirectionWS = normalize(input.viewDirectionWS);

    
    // BaseMap
    float3 baseColor = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, input.uv).rgb;
    float4 areaMap = 0;
    #if _AREA_FACE
        areaMap = SAMPLE_TEXTURE2D(_FaceColorMap, sampler_FaceColorMap, input.uv);
        baseColor = areaMap.rgb;
    #elif _AREA_HAIR 
        areaMap = SAMPLE_TEXTURE2D(_HairColorMap, sampler_HairColorMap, input.uv);
        baseColor = areaMap.rgb;
    #elif _AREA_UPPERBODY
        areaMap = SAMPLE_TEXTURE2D(_UpperBodyColorMap, sampler_UpperBodyColorMap, input.uv);
        baseColor = areaMap.rgb;
    #elif _AREA_LOWERBODY 
        areaMap = SAMPLE_TEXTURE2D(_LowerBodyColorMap, sampler_LowerBodyColorMap, input.uv);
        baseColor = areaMap.rgb;
    #endif
    baseColor.rgb *= lerp(_BackFaceTintColor, _FrontFaceTintColor, isFrontFace);    // 双面颜色相乘

    // LightMap
    float4 lightMap = 0;
    #if _AREA_HAIR || _AREA_UPPERBODY || _AREA_LOWERBODY
    {
        #if _AREA_HAIR
            lightMap = SAMPLE_TEXTURE2D(_HairLightMap, sampler_HairLightMap, input.uv);
        #elif _AREA_UPPERBODY
            lightMap = SAMPLE_TEXTURE2D(_UpperBodyLightMap, sampler_UpperBodyLightMap, input.uv);
        #elif _AREA_LOWERBODY
            lightMap = SAMPLE_TEXTURE2D(_LowerBodyLightMap, sampler_LowerBodyLightMap, input.uv);
        #endif
    }
    #endif

    // FaceMap
    float4 faceMap = 0;
    #if _AREA_FACE
        faceMap = SAMPLE_TEXTURE2D(_FaceMap, sampler_FaceMap, input.uv);
    #endif

    // IndirectLightColor
    float3 indirectLightColor = input.SH * _IndirectLightUsage;
    #if _AREA_HAIR || _AREA_UPPERBODY || _AREA_LOWERBODY
        indirectLightColor *= lerp(1, lightMap.r, _IndirectLightOcclusionUsage);    // 头发身体AO相乘
    #else
        float faceMask = lerp(faceMap.g, 1, step(faceMap.r, 0.5));
        indirectLightColor *= lerp(1, faceMask, _IndirectLightOcclusionUsage);    // 嘴巴内都是AO区域
    #endif
    indirectLightColor *= lerp(1, baseColor.rgb, _IndirectLightMixBaseColor);

    // MainLightShadow & Ramp
    float3 mianLightColor = lerp(desaturation(mainLight.color), mainLight.color, _MainLightColorUsage); // 插值去饱和减弱光颜色的影响
    float mainLightShadow = 1;
    int rampRowIndex = 0;
    int rampRowNum = 1; // 头发1行，身体8行
    #if _AREA_HAIR || _AREA_UPPERBODY || _AREA_LOWERBODY
        // Lambert
        float NoL = dot(normalWS, lightDirectionWS);
        float remappedNoL = NoL * 0.5 + 0.5;
        mainLightShadow = smoothstep(1 - lightMap.g + _ShadowThresholdCenter - _ShadowThresholdSoftness,
                                     1 - lightMap.g + _ShadowThresholdCenter + _ShadowThresholdSoftness,
                                     remappedNoL);
        mainLightShadow *= lightMap.r;

        // Ramp
        #if _AREA_HAIR
            rampRowIndex = 0;
            rampRowNum = 1;
        #elif _AREA_UPPERBODY || _AREA_LOWERBODY
            int rawIndex = (round((lightMap.a + 0.0425) / 0.0625) - 1) / 2;    // 将灰度值转换成没调整过的行序号
            rampRowIndex = lerp(rawIndex, rawIndex + 4 < 8 ? rawIndex + 4 : rawIndex + 4 - 8, fmod(rawIndex, 2));   // 判断行序号是奇数还是偶数，偶数不用调整，奇数偏移4行，一个周期是8，超过8就减8
        #endif
    #elif _AREA_FACE
        // SDF
        float3 headForward = normalize(_HeadForward);
        float3 headRight = normalize(_HeadRight);
        float3 headUp = normalize(cross(headForward, headRight));  // Unity 是左手坐标系，前向量和右向量得到向上向量
    
        float3 fixedLightDirectionWS = normalize(lightDirectionWS - dot(lightDirectionWS, headUp) * headUp);    // 把光向量投影倒头坐标系的水平面，不然人物颠倒过来阴影是反的
        float2 sdfUV = float2(sign(dot(fixedLightDirectionWS, headRight)), 1) * input.uv * float2(-1, 1);   // 判断光照在脸左还是右，正数是脸左，复数是脸右，图是左黑右白
        float sdfValue = SAMPLE_TEXTURE2D(_FaceMap, sampler_FaceMap, sdfUV).a;   //采样SDF图
        sdfValue += _FaceShadowOffset;  // 让正面不是全白，偏移一点点
    
        float sdfThreshold = 1 - (dot(fixedLightDirectionWS, headForward) * 0.5 + 0.5);   // 从-1~1映射到0~1，再反向一下，照正面是0，背面是1
        float sdf = smoothstep(sdfThreshold- _FaceShadowTransitionSoftness, sdfThreshold + _FaceShadowTransitionSoftness, sdfValue);   // 光在正前方阈值越低，越容易被点亮，像素的灰度值超过阈值时会被点亮
        mainLightShadow = lerp(faceMap.g, sdf, step(faceMap.r, 0.5));  // 把遮罩外的五官替换成AO

        // Ramp
        rampRowIndex = 0;
        rampRowNum = 8;
    #endif

    // RampMap
    float rampUVx = mainLightShadow * (1 - _ShadowRampOffset) + _ShadowRampOffset;  // 细节集中在3/4的地方，挤压一下
    float rampUVy = (2 * rampRowIndex + 1) * (1.0 / (rampRowNum * 2));    // 先将行序号改为半行序号，再乘以半行宽度
    float2 rampUV = float2(rampUVx, rampUVy);
    float3 coolRamp = 1;
    float3 warmRamp = 1;
    #if _AREA_HAIR
        coolRamp = SAMPLE_TEXTURE2D(_HairCoolRamp, sampler_HairCoolRamp, rampUV).rgb;
        warmRamp = SAMPLE_TEXTURE2D(_HairWarmRamp, sampler_HairWarmRamp, rampUV).rgb;
    #elif _AREA_FACE || _AREA_UPPERBODY || _AREA_LOWERBODY
        coolRamp = SAMPLE_TEXTURE2D(_BodyCoolRamp, sampler_BodyCoolRamp, rampUV).rgb;
        warmRamp = SAMPLE_TEXTURE2D(_BodyWarmRamp, sampler_BodyWarmRamp, rampUV).rgb;
    #endif
    float isDay = lightDirectionWS.y * 0.5 + 0.5;   // 光向量的数坐标插值冷Ramp 和 暖Ramp
    float3 rampColor = lerp(coolRamp, warmRamp, isDay);
    mianLightColor *= baseColor.rgb * rampColor;

    // Specular
    float3 specularColor = 0;
    #if _AREA_HAIR || _AREA_UPPERBODY || _AREA_LOWERBODY
        float3 halfVectorWS = normalize(viewDirectionWS + lightDirectionWS);
        float NoH = dot(normalWS, halfVectorWS);
        float blinnPhong = pow(saturate(NoH), _SpecularExpon);
    
        float nonMetalSpecular = step(1.04 - blinnPhong, lightMap.b) * _SpecularKsNonMetal;   // blinnPhong反向与阈值图比较，偏移一点避免漏光。再乘以反射率，非金属的反射率固定是0.04
        float metalSpecular = blinnPhong * lightMap.b * _SpecularKsMetal;

        float metallic = 0;
        #if _AREA_UPPERBODY || _AREA_LOWERBODY
            metallic = saturate((abs(lightMap.a - _SpecularMetalRange) - 0.1) / (0 - 0.1));   // 贴图的0.52正好是金属度,0.1作为插值范围
        #endif
    
        specularColor = lerp(nonMetalSpecular, metalSpecular * baseColor.rgb, metallic);
        specularColor *= mainLight.color;
        specularColor *= _SpecularBrightness;
    #endif
    
    // Albedo
    float3 albedo = 0;
    albedo += indirectLightColor;
    albedo += mianLightColor;
    albedo += specularColor;

    // Alpha
    float alpha = _Alpha;
    
    //Debug
    switch(_DebugColor) 
    {
        case 2:
            albedo = baseColor.rgb;
        break;
        case 3:
            albedo = indirectLightColor;
        break;
        case 4:
            albedo = mianLightColor;
        break;
        case 5:
            albedo = mainLightShadow.rrr;
        break;
        case 6:
            albedo = rampColor;
        break;
        case 7:
            albedo = specularColor;
        break;
        /*case 8:
        #if _AREA_UPPERBODY || _AREA_LOWERBODY
            albedo = metallic;
        #endif
        break;*/
        default:
            // albedo = albedo;
        break;
    }
    
    float4 color = float4(albedo, alpha);
    return color;
}
#endif