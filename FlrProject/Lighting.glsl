#ifndef _LIGHTING_GLSL_
#define _LIGHTING_GLSL_

struct Material {
  vec3 diffuse;
  float roughness;
  vec3 specular;
  float metallic;
};
#include <FlrLib/PBR/BRDF.glsl>

#define DENSITY (DENSITY_PARAM * 10.0)

vec3 sampleEnv(vec3 dir) {
  if (BACKGROUND == 0) {
    float yaw = mod(atan(dir.z, dir.x) + LIGHT_THETA, 2.0 * PI) - PI;
    float pitch = -atan(dir.y, length(dir.xz));
    vec2 uv = vec2(0.5 * yaw, pitch) / PI + 0.5;

    return LIGHT_INTENSITY * textureLod(EnvironmentMap, uv, 0.0).rgb;
  } else if (BACKGROUND == 1) {
    float c = 5.0;
    vec3 n = 0.5 * normalize(dir) + 0.5.xxx;
    float cosphi = cos(LIGHT_PHI); float sinphi = sin(LIGHT_PHI);
    float costheta = cos(LIGHT_THETA); float sintheta = sin(LIGHT_THETA);
    float x = 0.5 + 0.5 * dot(dir, normalize(vec3(costheta * cosphi, sinphi, sintheta * cosphi)));
    // x = pow(x, 10.0) + 0.01;
    return LIGHT_INTENSITY * x * round(n * c) / c;
  } else {
    return LIGHT_INTENSITY.xxx;
  }
}

vec3 raymarchLight(vec3 pos, vec3 viewDir, bool jitter, uint numIters, float lightDt, vec3 extinction) {
  vec3 lightThroughput = 1.0.xxx;
  vec3 lightDir = normalize(2.0 * randVec3(seed) - 1.0.xxx);
  // vec3 phaseJitter = 0.1 * (randVec3(seed) - 0.5.xxx);
  // viewDir = normalize(viewDir + phaseJitter);
  float phase = phaseFunction((dot(lightDir , viewDir)), G);
  float dt = lightDt;
  pos += lightDir * lightDt * (1.0 + rng(seed));
  for (int lightIter = 0; lightIter < numIters; lightIter++) {
    pos += lightDt * lightDir;
    if (getBit(0, ivec3(round(pos)))) {
      lightThroughput *= exp(-extinction * lightDt).xxx;
      if (dot(lightThroughput, lightThroughput) < 0.00001) {
        lightThroughput = 0.0.xxx;
        break;
      }
    }
    lightDt *= 1.9;
  }

  return phase * sampleEnv(lightDir) * lightThroughput;
}

bool bCachedHit = false;
vec3 cachedLi = 0.0.xxx;

bool accumulateLight(vec3 pos, vec3 dir, float dt, inout vec3 color, inout vec3 throughput, int iter, uint level) {
  
  vec3 extinction = SCATTER_COL.rgb * DENSITY;
  // / pow(1.0 + 0.5 * level + float(iter) / ITERS, 1.0);
  vec3 Li;
  if (bCachedHit) {
    Li = cachedLi; // todo cache reuse limit...
  } else {
    Li = cachedLi = raymarchLight(pos, dir, true, LIGHT_ITERS, LIGHT_DT,extinction);
    bCachedHit = true;
  }

  {
    float fakeAo = max(1.0 - FAKE_AO * float(iter) / ITERS, 0.4);
    Li *= fakeAo;
    // throughput *= exp(- FAKE_AO * float(iter) / ITERS * DENSITY);
  }
  // throughput *= exp(-(1.0 + rng(seed)) *LIGHT_DT * extinction);
  color += (1.0 - ABSORB_PREPOST) * throughput * Li;
  throughput *= exp(-LIGHT_DT * extinction);
  color += ABSORB_PREPOST * throughput * Li;

  if (dot(throughput, throughput) < 0.0001) 
  {
    throughput = 0.0.xxx;
    return false;
  }
  return true;
}

#endif // _LIGHTING_GLSL_