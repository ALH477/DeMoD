/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
 * quanta-speech-render — QSP -> PCM (Harmonic+Noise Model), spec Appendix P.
 * Copyright (c) 2026 DeMoD LLC.
 *
 * Normative speech audio path: libm-free hot loop (sine table for harmonics, LCG ->
 * 24-band SVF for noise — the render.c primitives verbatim).
 *
 * Harmonics use McAulay-Quatieri (1986) continuous-phase track synthesis: each
 * harmonic k is a track across consecutive frames; over a frame pair its phase is a
 * cubic that matches BOTH endpoint phases and instantaneous frequencies, with the
 * integer cycle count chosen for maximum smoothness. Amplitude ramps linearly.
 * Births/deaths (a harmonic or a whole voiced segment present on one side only)
 * ramp amplitude from/to zero at constant frequency. This is the key to phase
 * coherence across the pitch track — window-normalised OLA of independently
 * LS-fit frames beats because each frame's fixed-f0 phase ramp is discontinuous at
 * the overlap; MQ makes frequency vary continuously so voiced segments don't buzz.
 *
 * The per-sample hot path is a cubic polynomial eval + one sine-table lookup +
 * (for noise) the LCG/SVF bank, so it is Faust-freezable (Phase 2, gate H2 style).
 */
#include "../include/qsc.h"
#include "../include/qsp.h"

int main(int argc, char **argv){
    const char *inp=NULL, *wavout=NULL, *rawout=NULL; double master=1.0; int nonoise=0;
    for (int i=1;i<argc;i++){
        if (!strcmp(argv[i],"--wav")&&i+1<argc) wavout=argv[++i];
        else if (!strcmp(argv[i],"--raw")&&i+1<argc) rawout=argv[++i];
        else if (!strcmp(argv[i],"--master")&&i+1<argc) master=atof(argv[++i]);
        else if (!strcmp(argv[i],"--no-noise")) nonoise=1;
        else inp=argv[i];
    }
    if (!inp){ fprintf(stderr,"usage: quanta-speech-render in.qsp [--wav o.wav] [--raw o.f64] [--no-noise]\n"); return 2; }

    Qsp q; int rc=qsp_read(inp,&q);
    if (rc){ fprintf(stderr,"speech-render: qsp_read failed (%d)\n",rc); return 1; }
    double wtab[QSC_TAB], stab[QSC_TAB]; qsc_build_tables(wtab, stab);

    uint64_t N=q.h.source_len; double sr=(double)q.h.sample_rate; uint32_t nf=q.h.frame_count;
    double *out=calloc(N,sizeof(double));

    /* ---- deterministic layer: MQ continuous cubic-phase track synthesis
       (shared with the analyzer's residual reconstruction — see qsp.h). SINES mode
       renders general nearest-frequency-matched partials; else strict k*f0. ---- */
    if (q.h.flags & QSP_FLAG_SINES)
        qsp_render_sines(out, N, q.h.sample_rate, nf, q.fr, stab, 100.0);
    else
        qsp_render_harmonics(out, N, q.h.sample_rate, nf, q.fr, stab);

    /* --- noise: LCG -> 24-band SVF, gains interpolated across pitch marks --- */
    QscSvf f[QSC_BANDS]; for (int b=0;b<QSC_BANDS;b++) qsc_svf_init(&f[b], qsc_band_fc(b), QSC_BAND_Q, sr);
    int32_t st=0; uint32_t fi=0;
    for (uint64_t n=0; !nonoise && n<N;n++){
        while (fi+1<nf && q.fr[fi+1].onset<=n) fi++;
        uint32_t i0=fi, i1=(fi+1<nf)?fi+1:fi;
        double o0=q.fr[i0].onset, o1=q.fr[i1].onset;
        double fr = (i1>i0 && o1>o0) ? (double)(n-o0)/(o1-o0) : 0.0; if(fr<0)fr=0; if(fr>1)fr=1;
        st=qsc_lcg_step(st,(int32_t)q.h.noise_seed); double nz=qsc_lcg_out(st);
        double acc=0;
        for (int b=0;b<QSC_BANDS;b++){
            double g0=qsc_gain_dq(q.fr[i0].gain[b]), g1=qsc_gain_dq(q.fr[i1].gain[b]);
            acc += qsc_svf_bp(&f[b], nz) * (g0 + fr*(g1-g0));
        }
        out[n]+=acc;
    }

    /* master + DC blocker (pole 0.995) */
    { double x1=0,y1=0; for (uint64_t n=0;n<N;n++){ double xx=out[n]*master, yy=xx-x1+0.995*y1; x1=xx; y1=yy; out[n]=yy; } }

    if (wavout) wav_write16(wavout, out, N, q.h.sample_rate);
    if (rawout) raw_write_f64(rawout, out, N);
    double pk=0; for (uint64_t n=0;n<N;n++){ double a=fabs(out[n]); if(a>pk)pk=a; }
    fprintf(stderr,"speech-render: %u frames | %llu samples | peak %.3f\n",
            nf,(unsigned long long)N,pk);
    qsp_free(&q); free(out);
    return 0;
}
