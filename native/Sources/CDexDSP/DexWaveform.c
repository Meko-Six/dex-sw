#include "DexWaveform.h"
#include <math.h>
#include <stdlib.h>
typedef struct { double b0,b1,b2,a1,a2,z1,z2; } Filter;
struct DexWaveformState {
    unsigned channels;
    int64_t step, frames;
    float peak;
    double energy[2][4];
    Filter filters[2][4];
};
static Filter filter(double rate, double hz, int high) {
    double w = 2 * 3.14159265358979323846 * fmin(hz, rate * .45) / rate;
    double c = cos(w), alpha = sin(w) / sqrt(2), a0 = 1 + alpha;
    double b0 = (high ? 1 + c : 1 - c) / 2 / a0;
    return (Filter){ b0, (high ? -(1+c) : 1-c)/a0, b0, -2*c/a0, (1-alpha)/a0, 0, 0 };
}
static double tick(Filter *f, double x) {
    double y = f->b0*x + f->z1;
    f->z1 = f->b1*x - f->a1*y + f->z2;
    f->z2 = f->b2*x - f->a2*y;
    return y;
}
DexWaveformState *dex_waveform_create(double rate, unsigned channels, int64_t step) {
    if (!isfinite(rate) || rate <= 0 || channels < 1 || channels > 2 || step < 1) return NULL;
    DexWaveformState *s = calloc(1,sizeof(*s));
    if (!s) return NULL;
    s->channels=channels; s->step=step;
    for (unsigned c=0;c<channels;c++) {
        s->filters[c][0]=filter(rate,220,0);
        s->filters[c][1]=filter(rate,220,1);
        s->filters[c][2]=filter(rate,3500,0);
        s->filters[c][3]=filter(rate,3500,1);
    }
    return s;
}
void dex_waveform_destroy(DexWaveformState *s) { free(s); }
static DexWaveBin emit(DexWaveformState *s) {
    double e[4]={0};
    for (unsigned c=0;c<s->channels;c++) for(unsigned b=0;b<4;b++) {
        e[b]=fmax(e[b],s->energy[c][b]); s->energy[c][b]=0;
    }
    double n=(double)s->frames;
    DexWaveBin bin={s->peak,sqrt(e[0]/n),sqrt(e[1]/n),sqrt(e[2]/n),sqrt(e[3]/n)};
    s->frames=0; s->peak=0;
    return bin;
}
unsigned dex_waveform_consume(DexWaveformState *s, const float *left, const float *right,
                             unsigned frames, DexWaveBin *bins, unsigned capacity) {
    unsigned count=0;
    // Caller budgets one output for each possible boundary plus the partial bin.
    if ((uint64_t)capacity < ((uint64_t)frames + (uint64_t)s->step - 1)/(uint64_t)s->step + 1) return 0;
    for(unsigned i=0;i<frames;i++) {
        for(unsigned c=0;c<s->channels;c++) {
            double x=c ? right[i] : left[i];
            if (!isfinite(x)) x=0;
            x=fmin(4,fmax(-4,x)); s->peak=fmax(s->peak,fabs(x));
            double low=tick(&s->filters[c][0],x);
            double mid=tick(&s->filters[c][2],tick(&s->filters[c][1],x));
            double high=tick(&s->filters[c][3],x);
            s->energy[c][0]+=x*x; s->energy[c][1]+=low*low;
            s->energy[c][2]+=mid*mid; s->energy[c][3]+=high*high;
        }
        s->frames++;
        if(s->frames==s->step) bins[count++]=emit(s);
    }
    return count;
}
unsigned dex_waveform_finish(DexWaveformState *s, DexWaveBin *bin) {
    if(!s->frames) return 0;
    *bin=emit(s); return 1;
}
