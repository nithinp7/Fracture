#ifndef _HDDA_GLSL_
#define _HDDA_GLSL_

struct DDA {
  // input
  vec3 o; // ray origin
  vec3 d; // ray dir
  
  // precomputed
  ivec3 sn;
  vec3 invD;

  // state
  vec3 t; // time till next closest collision on each axis
  ivec3 coord; // current grid coord
  float globalT; // total time marched along ray
  uint level;
};


vec3 getCurrentPos(DDA dda) {
  return dda.o + dda.globalT * dda.d;
}

int computeSubdivs(uint level) {
  return 1 << (BR_FACTOR_LOG2 * level);
}

void switchLevelsDDA(inout DDA dda, uint level) {
  dda.level = level;
  uint subdivs = computeSubdivs(dda.level);
  vec3 p = dda.o + dda.globalT * dda.d;
  vec3 fr = fract(p/subdivs);
  vec3 rm = subdivs * mix(fr, max(1.0.xxx - fr, 0.0.xxx), greaterThan(dda.sn, ivec3(0)));
  dda.t = rm * dda.invD;
}

DDA createDDA(vec3 o, vec3 d, uint initLevel) {
  DDA dda;
  dda.o = o;
  dda.d = d;
  
  dda.coord = ivec3(floor(o));
  dda.sn = ivec3(sign(d));
  dda.invD = abs(1.0/d);
  dda.globalT = 0.0;
  switchLevelsDDA(dda, initLevel);

  return dda;
}

float stepDDA(inout DDA dda, inout uint stepAxis) {
  int subdivs = computeSubdivs(dda.level);
  bvec3 stepMask = lessThan(dda.t.xyz, min(dda.t.zxy, dda.t.yzx));
  stepAxis = stepMask[0] ? 0 : (stepMask[1] ? 1 : 2);
  // these steps are not accurate in the lower levels, but this is
  // rectified during the level-switch
  // would be nice to not have to retrace the last step...
  dda.coord[stepAxis] += subdivs * dda.sn[stepAxis];
  float dt = dda.t[stepAxis];
  dda.globalT += dt;
  dda.t -= dt.xxx;
  dda.t[stepAxis] = subdivs * dda.invD[stepAxis];
  return dt;
}
#endif // _HDDA_GLSL_