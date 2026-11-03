#include <metal_stdlib>
using namespace metal;

// The ordered dither uses one device pixel per dot, or half a point at 2x scale.
constant int BayerThresholds[16] = {0,8,2,10,12,4,14,6,3,11,1,9,15,7,13,5};
// Canonical hash(bin, 4.1) for the thirty angular download streams, including the seam.
// Storing these scalar seeds avoids GPU contraction changing their trajectories.
constant float DownloadStreamSeeds[31] = {0.0830078125f, 0.421875f, 0.89453125f, 0.72265625f, 0.29296875f, 0.6875f, 0.046875f, 0.900390625f, 0.75390625f, 0.29248046875f, 0.54296875f, 0.6396484375f, 0.7578125f, 0.8203125f, 0.51953125f, 0.396484375f, 0.375f, 0.06640625f, 0.044921875f, 0.0703125f, 0.80859375f, 0.9453125f, 0.9871826171875f, 0.26171875f, 0.7998046875f, 0.4140625f, 0.755859375f, 0.1015625f, 0.0234375f, 0.345703125f, 0.8046875f};
#define RELIEF .075
#define ALBEDO_LOW .22
#define ALBEDO_HIGH .7
#define SUN normalize(float3(-.5,.75,.55))
float mod(float value, float divisor) { return value - divisor * floor(value / divisor); }
float2 mod(float2 value, float divisor) { return value - divisor * floor(value / divisor); }
float smoothing(float lower, float upper, float value) {
    float fraction = clamp((value-lower)/(upper-lower), 0., 1.);
    return fraction*fraction*(3.-2.*fraction);
}
#define uRes float2(values[0], values[1])
#define uTime values[2]
#define uLevel values[3]
#define uShake values[4]
#define uWarn values[5]
#define uForm values[6]
#define uMix values[7]
#define uRate values[8]
#define uLoading values[9]
#define uPhase values[10]
#define uMode int(values[11])
#define uA int(values[12])
#define uB int(values[13])
#define uInk float3(values[14], values[15], values[16])

struct MoonShader {
constant float *values;
texture2d<float> legend;
texture2d<float> moon;
// Full-precision interpolation keeps the legend and lunar relief independent of hardware sampler precision.
float4 sampleLevel(texture2d<float> texture, float2 coordinates, uint mip, bool clampsVertical) {
    int2 extent = int2(texture.get_width(mip), texture.get_height(mip));
    float2 position = coordinates * float2(extent) - .5;
    int2 first = int2(floor(position)), second = first + 1;
    float2 weight = fract(position);
    first.x = (first.x % extent.x + extent.x) % extent.x;
    second.x = (second.x % extent.x + extent.x) % extent.x;
    first.y = clampsVertical ? clamp(first.y, 0, extent.y - 1) : (first.y % extent.y + extent.y) % extent.y;
    second.y = clampsVertical ? clamp(second.y, 0, extent.y - 1) : (second.y % extent.y + extent.y) % extent.y;
    float4 lower = mix(texture.read(uint2(first), mip), texture.read(uint2(second.x, first.y), mip), weight.x);
    float4 upper = mix(texture.read(uint2(first.x, second.y), mip), texture.read(uint2(second), mip), weight.x);
    return mix(lower, upper, weight.y);
}
float4 sampleImage(texture2d<float> texture, float2 coordinates, float detail, bool clampsVertical) {
    uint mip = uint(detail);
    return mix(sampleLevel(texture, coordinates, mip, clampsVertical),
               sampleLevel(texture, coordinates, min(mip + 1, texture.get_num_mip_levels() - 1), clampsVertical), fract(detail));
}
float4 sampleMoon(float2 coordinates, float detail) { return sampleImage(moon, coordinates, detail, true); }
float4 sampleLegend(float2 coordinates, float detail) { return sampleImage(legend, coordinates, detail, false); }
// A fixed fifth-order sine gives the grain hash the same range reduction on every GPU.
// It interpolates sin(2*pi*x) at 0, +/-1/12, +/-1/6 and +/-1/4.
float referenceSine(float angle) {
    float reduced = fma(angle, -0.15915493667125702f, 0.25f);
    float coordinate = 0.25f - abs(reduced - rint(reduced));
    float squared = coordinate * coordinate;
    return fma(fma(74.4388908503519f, squared, -41.16936742016338f), squared, 6.28230854637602f) * coordinate;
}
float referenceCosine(float angle) {
    float reduced = angle * 0.15915493667125702f;
    float coordinate = 0.25f - abs(reduced - rint(reduced));
    float squared = coordinate * coordinate;
    return fma(fma(74.4388908503519f, squared, -41.16936742016338f), squared, 6.28230854637602f) * coordinate;
}
float hash(float2 p){return fract(referenceSine(dot(p,float2(127.1,311.7)))*43758.5453);}
float2x2 rot(float a){float c=referenceCosine(a),s=referenceSine(a);return float2x2(float2(c,-s),float2(s,c));}
float circle(float2 p,float r){return length(p)-r;}
float box(float2 p,float2 b,float r){float2 d=abs(p)-b+r;return length(max(d,0.))+min(max(d.x,d.y),0.)-r;}
float seg(float2 p,float2 a,float2 b){float2 pa=p-a,ba=b-a;return length(pa-ba*clamp(dot(pa,ba)/dot(ba,ba),0.,1.));}
float microphone(float2 p){
  float d=seg(p,float2(0,.1),float2(0,.42))-.2;
  d=min(d,max(abs(length(p-float2(0,.16))-.36)-.05,p.y-.16));
  d=min(d,seg(p,float2(0,-.2),float2(0,-.5))-.05);
  return min(d,seg(p,float2(-.2,-.54),float2(.2,-.54))-.05);}
float shape(int id,float2 p){
  if(id==1)return microphone(p);
  if(id==2)return box(p,float2(.64,.62),.1);
  return circle(p,.6);}
float solid(int id,float3 p){
  if(id==0)return length(p)-.62;
  float2 q=float2(shape(id,p.xy)+.04,abs(p.z)-(id==2?.05:.16));return min(max(q.x,q.y),0.)+length(max(q,0.))-.04;}
float3x3 M;
float scene(float3 w){float3 p=M*w;return uMix<=.001?solid(uA,p):uMix>=.999?solid(uB,p):mix(solid(uA,p),solid(uB,p),uMix);}
float3 normal(float3 p){const float2 k=float2(1,-1);float e=.004;return normalize(k.xyy*scene(p+k.xyy*e)+k.yyx*scene(p+k.yyx*e)+k.yxy*scene(p+k.yxy*e)+k.xxx*scene(p+k.xxx*e));}
float lunar(float3 o,float3 Lo,float3 Vo){
  float2 uv=float2(atan2(o.x,o.z)/6.28318+.5,asin(clamp(o.y,-1.,1.))/3.14159+.5);
  float lod=max(0.,log2(615./uRes.y)+.25);float2 px=exp2(lod)*float2(1./1024.,1./512.);
  float alb=sampleMoon(uv,lod).r;
  float gE=(sampleMoon(uv+float2(px.x,0.),lod).g-sampleMoon(uv-float2(px.x,0.),lod).g)/(2.*px.x*6.28318);
  float gN=(sampleMoon(uv+float2(0.,px.y),lod).g-sampleMoon(uv-float2(0.,px.y),lod).g)/(2.*px.y*3.14159);
  float3 east=normalize(float3(o.z,0.,-o.x)+float3(1e-5,0.,0.)),north=cross(o,east);
  float3 nb=normalize(o-RELIEF*(gE/max(sqrt(1.-o.y*o.y),.2)*east+gN*north));
  float mu0=max(dot(nb,Lo),0.),mu=max(dot(o,Vo),.3),shade=mix(2.*mu0/(mu0+mu),mu0,.4);
  alb=clamp((alb-ALBEDO_LOW)/(ALBEDO_HIGH-ALBEDO_LOW),0.,1.);
  float earthshine=.075+.06*alb;
  return clamp(max((.12+.86*alb)*shade*1.04,earthshine),0.,1.);}
float solidTone(float2 uv){
  float keyWeight=uB==2?uMix:uA==2?1.-uMix:0.,moonWeight=uB==0?uMix:uA==0?1.-uMix:0.;
  float flip=uMix*uMix*(3.-2.*uMix);
  float yaw=uTime*1.15+6.28318*flip,pitch=mix(.3,.1,moonWeight)+.08*referenceSine(uTime*.7);
  float cy=referenceCosine(yaw),sy=referenceSine(yaw),cp=referenceCosine(pitch),sp=referenceSine(pitch);
  M=float3x3(float3(cy,0.,sy),float3(0.,1.,0.),float3(-sy,0.,cy))*float3x3(float3(1.,0.,0.),float3(0.,cp,-sp),float3(0.,sp,cp));
  float3 ro=float3(0.,.05,3.3),rd=normalize(float3(uv*.92,-2.6)),L=normalize(float3(-.55,.85,.5));
  float b=dot(ro,rd),c=dot(ro,ro)-1.69,h=b*b-c;
  if(h>0.){float t=max(-b-sqrt(h),0.),tm=-b+sqrt(h);
    for(int i=0;i<56;i++){float d=scene(ro+rd*t);
      if(d<.002){float3 at=ro+rd*t,pm=M*at,n=normal(at);
        float l=clamp(.14+.86*max(dot(n,L),0.)+.2*pow(1.-max(dot(n,-rd),0.),3.),0.,1.);
        float tone=.12+.82*(1.-l);
        if(keyWeight>.01){float face=smoothing(.9,.99,abs(dot(M*n,float3(0,0,1))));
          float legend=sampleLegend(float2((pm.z<0.?-pm.x:pm.x)/1.28+.5,pm.y/1.24+.5),2.).r;
          float key=mix(.1+.7*pow(l,1.4),.09+.05*l,face);
          tone=mix(tone,legend>.42&&keyWeight>.8&&face>.5?1.:key,smoothing(.2,.8,keyWeight));}
        if(moonWeight>.01){
          float settled=smoothing(1.,1.5,uPhase);
          float3 o=normalize(M*n);float icon=lunar(o,M*normalize(float3(-.42,.42,.8)),M*(-rd));
          /* the download assembles the moon: each grain of its surface locks in as its share of the bytes arrives */
          float prog=min(uPhase,1.);float3 oc=floor(o*44.);float3 cc=normalize(oc+.5);float bright=sampleMoon(float2(atan2(cc.x,cc.z)/6.28318+.5,asin(clamp(cc.y,-1.,1.))/3.14159+.5),4.).r;
          float due=clamp(.42*hash(oc.xy+oc.z*7.13)+.58*(1.-clamp((bright-.25)/.4,0.,1.)),0.,.97); /* bright highlands arrive first, the dark seas last, like a print developing */
          float placed=step(due,prog)*step(.001,prog),fresh=placed*smoothing(.06,0.,prog-due)*step(prog,.999);
          float scan=exp(-pow((n.y-(1.1-2.2*fract(uTime*.9)))/.1,2.))*smoothing(.88,.9,prog)*(1.-step(.97,prog));
          float ghost=.02+.3*pow(1.-max(dot(n,-rd),0.),2.5);
          float built=max(mix(ghost,icon,placed),fresh*.95)+scan*.55;
          tone=mix(tone,mix(built,icon,settled),smoothing(.45,1.,moonWeight));}
        return tone;}
      t+=d*.85;if(t>tm)break;}}
  /* while downloading, specks stream in from every side; at 100% a ring of light leaves the moon */
  float aura=0.;
  if(moonWeight>.5&&uPhase>0.&&uPhase<1.){float a=atan2(uv.y,uv.x),bin=floor(a/6.28318*30.),hb=DownloadStreamSeeds[clamp(int(bin)+15,0,30)],f=fract(uTime*(.45+.5*hb)+hb*3.);
    float ca=(bin+.5)/30.*6.28318,rad=1.02-f*.46;aura=smoothing(.028,.01,length(uv-float2(referenceCosine(ca),referenceSine(ca))*rad))*f;}
  if(moonWeight>.5&&uPhase>1.){float k=(uPhase-1.)/.5;aura=max(aura,smoothing(.03,0.,abs(length(uv)-(.54+k*.48)))*(1.-k));}
  if(rd.y<0.){float3 g=ro+rd*((-.82-ro.y)/rd.y);return max(aura,(1.-smoothing(.1,.75,length((g.xz-float2(.18,-.05))*float2(1,1.6))))*.22);}
  return aura;}

float maria(float3 n){float2 s=n.xy;
  return .1*smoothing(.21,0.,length(s-float2(-.22,.27)))+.08*smoothing(.17,0.,length(s-float2(.19,.13)))+.07*smoothing(.14,0.,length(s-float2(-.05,-.31)));}
float sunlit(float3 n){return clamp(.08+.92*max(dot(n,SUN),0.),0.,1.)*(1.-(uRate<0.?0.:maria(n)));}
float microphoneMark(float2 p){p/=1.18;
  float head=seg(p,float2(0,.09),float2(0,.24))-.125;
  float cradle=max(abs(length(p-float2(0,.12))-.25)-.044,p.y-.12);
  float stem=seg(p,float2(0,-.13),float2(0,-.27))-.044;
  float base=seg(p,float2(-.12,-.285),float2(.12,-.285))-.044;
  return min(min(head,cradle),min(stem,base))*1.18;}
float muted(float2 p,float w,float R){return mix(length(p)-R,microphoneMark(p),w);}
float loadingTone(float2 p,float R){
  float r=length(p),e=r/R,t=uTime;
  float3 n=float3(p/R,sqrt(max(1.-e*e,0.)));
  float inside=step(e,1.);
  float body=inside*(.06+.3*max(dot(n,SUN),0.))*(1.-2.*maria(n)),best=body;
  for(int i=0;i<9;i++){float ang=t*2.6-float(i)*.16,tilt=-.32,c=referenceCosine(tilt),s=referenceSine(tilt);
    float2 o=float2(referenceCosine(ang)*1.48,referenceSine(ang)*.4)*R;o=float2(c*o.x-s*o.y,s*o.x+c*o.y);
    bool back=referenceSine(ang)>0.;if(back&&length(o)<R*1.02)continue;if(back&&inside>.5)continue;
    float size=i==0?.16:.1*(1.-float(i)/12.),speck=smoothing(size*R,size*R*.55,length(p-o));
    best=max(best,speck*(i==0?1.:.85-.08*float(i)));}
  return best;}
float moonTone(float3 n,float edge){
  return sunlit(n);}
float orbTone(float2 c){
  float2 p=c/(uRes.y*.5);p.x-=uShake;
  float a=atan2(p.y,p.x),r=length(p),w=smoothing(0.,1.,uWarn),lv=uLevel;
  float ripple=uRate<0.?0.:1.;
  float R=uRate<0.?.7:((.42+.2*pow(lv,.7)+ripple*lv*(.02*referenceSine(a*5.+uTime*8.)+.015*referenceSine(a*3.-uTime*6.))));
  if(w>.001){
    if(w>.78){float2 sa=float2(-.34,.38),sb=mix(sa,float2(.34,-.38),smoothing(.78,1.,w));float sl=seg(p,sa,sb);
      if(sl<.028)return .96;if(sl<.066)return 0.;}
    float e=1./uRes.y,d=muted(p,w,R);if(d>0.)return 0.;
    float2 g=float2(muted(p+float2(e,0),w,R)-muted(p-float2(e,0),w,R),muted(p+float2(0,e),w,R)-muted(p-float2(0,e),w,R))/(2.*e);
    float3 nb=normalize(float3(g*(1.-clamp(-d/.07,0.,1.))*1.8,1.));
    float2 q=p/R;float3 ns=float3(q,sqrt(max(1.-dot(q,q),0.)));
    return mix(moonTone(ns,r/R),.62+.36*clamp(.2+.8*max(dot(nb,SUN),0.),0.,1.),w);}
  if(uLoading>.5)return loadingTone(p,R);
  if(r<R){float2 q=p/R;return moonTone(float3(q,sqrt(max(1.-dot(q,q),0.))),r/R);}
  return 0.;}
float4 shade(float4 position){
  float2 fc=float2(position.x, uRes.y-position.y),centered=fc-.5*uRes,cell=floor(fc),uv=centered/(uRes.y*.5);
  float k=1.-uForm;k*=k;
  float ang=atan2(uv.y,uv.x),edge=.8+.1*referenceSine(ang*3.+uTime*.6)+.07*referenceSine(ang*5.-uTime*.9);
  float fall=1.-smoothing(edge-.6,edge+.12,length(uv));
  float2 jit=float2(hash(cell),hash(cell+17.3))-.5;
  jit+=.18*float2(referenceSine(uTime*1.7+hash(cell+3.1)*6.283),referenceCosine(uTime*1.4+hash(cell+9.7)*6.283));
  float2 s=rot(k*(2.6+uTime*.35))*uv*(1.+k*1.4)+jit*k*2.6;
  float tone;
  if(uMode==1)tone=orbTone(s*uRes.y*.5);
  else tone=solidTone(s);
  tone*=mix(1.,fall,k);
  tone=max(tone,step(.972,hash(cell+3.1))*k*.95*step(hash(cell+7.7),fall));
  tone=clamp(tone,0.,1.);
#ifdef MOON_CAPTURE_TONE
  uint encoded = uint(round(tone * 16777215.));
  return float4(float(encoded & 255u), float((encoded >> 8) & 255u), float((encoded >> 16) & 255u), 255.) / 255.;
#endif
  float on;
  if(tone<1./17.)on=0.;else if(tone>16./17.)on=1.;
  else{float f=floor(uTime*uRate);float2 q=mod(floor(centered)+float2(f,f*3.),4.);on=step(float(BayerThresholds[int(q.y)*4+int(q.x)]+1)/17.,tone);}
  return on>.5?float4(uInk,1.):float4(0.);
}
};
vertex float4 moonVertex(uint identifier [[vertex_id]]) {
    const float2 positions[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
    return float4(positions[identifier],0,1);
}
fragment float4 moonFragment(float4 position [[position]], constant float *values [[buffer(0)]],
                             texture2d<float> legend [[texture(0)]], texture2d<float> moon [[texture(1)]]) {
    MoonShader shader{values,legend,moon};
    return shader.shade(position);
}
