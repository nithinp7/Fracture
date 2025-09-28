#ifndef _LIGHTING_GLSL_
#define _LIGHTING_GLSL_

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

float phaseFunction(float cosTheta, float g) {
  float g2 = g * g;
  return  
      3.0 * (1.0 - g2) * (1.0 + cosTheta * cosTheta) / 
      (8 * PI * (2.0 + g2) * pow(1.0 + g2 - 2.0 * g * cosTheta, 1.5));
}

vec3 raymarchLight(vec3 pos, vec3 viewDir, bool jitter, uint numIters, float lightDt) {
  vec3 lightThroughput = 1.0.xxx;
  vec3 lightDir = normalize(2.0 * randVec3(seed) - 1.0.xxx);
  float phase = phaseFunction(abs(dot(lightDir, viewDir)), G);
  float dt = lightDt;
  pos += lightDir * lightDt * 2.0;
  for (int lightIter = 0; lightIter < numIters; lightIter++) {
    pos += lightDt * lightDir;
    if (getBit(0, ivec3(round(pos)))) {
      lightThroughput *= exp(-DENSITY * lightDt).xxx;
      if (dot(lightThroughput, lightThroughput) < 0.00001) {
        lightThroughput = 0.0.xxx;
        break;
      }
    }
    lightDt *= 1.9;
  }

  return phase * sampleEnv(lightDir) * lightThroughput;
}

vec3 raymarchLight_OLD(vec3 pos, vec3 viewDir, bool jitter, uint numIters, float lightDt) {
  vec3 lightThroughput = 1.0.xxx;
  vec3 lightDir = normalize(2.0 * randVec3(seed) - 1.0.xxx);
  float phase = phaseFunction(abs(dot(lightDir, viewDir)), G);
  pos += lightDir * lightDt * 2.0;
  for (int lightIter = 0; lightIter < numIters; lightIter++) {
    pos += lightDt * lightDir;
    if (getBit(0, ivec3(round(pos)))) {
      lightThroughput *= exp(-DENSITY * lightDt).xxx;
      if (dot(lightThroughput, lightThroughput) < 0.00001) {
        lightThroughput = 0.0.xxx;
        break;
      }
    }
  }

  return phase * sampleEnv(lightDir) * lightThroughput;
}

#if 0
// UNUSED DDA-based light ray impl 
vec3 raymarchLight(vec3 pos, bool jitter, uint numIters, float unused) {
  vec3 lightThroughput = 1.0.xxx;
  vec3 lightPos = getLightPos();
  vec3 lightDir = (lightPos - pos);
  float lightDist2 = dot(lightDir, lightDir);
  lightDir /= sqrt(lightDist2);
  float phase = phaseFunction(abs(dot(lightDir, dir)), G);
  // pos += SHADOW_SOFTNESS * (2.0 * randVec3(seed) - 1.0.xxx) * lightDt;
  // if (jitter)
    // pos += lightDir * lightDt * rng(seed);
  DDA dda = createDDA(pos, lightDir, 1);
  for (int lightIter = 0; lightIter < numIters; lightIter++) {
    uint stepAxis;
    float dt = stepDDA(dda, stepAxis);
    if (getBit(dda.level, dda.coord >> (BR_FACTOR_LOG2 * dda.level))) {
      lightThroughput *= exp(-DENSITY * dt).xxx;
      if (dot(lightThroughput, lightThroughput) < 0.001) {
        lightThroughput = 0.0.xxx;
        break;
      }
    }
  }

  vec3 LIGHT_COLOR = 1.0.xxx;
  return phase * 1000.0 * LIGHT_INTENSITY * LIGHT_COLOR * lightThroughput / lightDist2;
}
#endif

bool accumulateLight(vec3 pos, vec3 dir, float dt, inout vec3 color, inout vec3 throughput, int iter) {
  
  vec3 Li = raymarchLight(pos, dir, true, LIGHT_ITERS, LIGHT_DT);
  {
    float fakeAo = max(1.0 - FAKE_AO * float(iter) / ITERS, 0.4);
    Li *= fakeAo;
  }
  color += throughput * Li;
  throughput *= exp(-DENSITY * 1.0);
  if (dot(throughput, throughput) < 0.0001) 
  {
    throughput = 0.0.xxx;
    return false;
  }
  return true;
}

#endif // _LIGHTING_GLSL_