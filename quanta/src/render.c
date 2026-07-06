/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
 * quanta-render — QSC reference renderer (spec §6 semantics, exploration player)
 * Copyright (c) 2026 DeMoD LLC.
 *
 * This is the normative audio path: table-based transcendentals only,
 * no libm per-sample, fixed summation order (voices 0..P-1, then bands
 * 0..23, then master). Frozen Faust output must null against this.
 * Mono renders one channel; mid/side stereo renders M and S with the same
 * per-channel path (S residual decorrelated by QSC_SIDE_SEED_XOR), then
 * L = M+S, R = M-S.
 */
#include "../include/qsc.h"
#include "../include/qrender.h"   /* render_channel + master_dcblock (shared with analyzer) */

int main(int argc, char **argv){
    const char *inpath=NULL, *wavout=NULL, *rawout=NULL, *bitspec="16";
    uint32_t K = 0xFFFFFFFF;
    double lg[3] = {1.0,1.0,1.0}, master = 1.0;
    int nocres = 0;   /* --no-cres: render the lossy atoms+noise tier from a coherent file */
    for (int i=1;i<argc;i++){
        if (!strcmp(argv[i],"--k")&&i+1<argc) K=(uint32_t)strtoul(argv[++i],0,0);
        else if (!strcmp(argv[i],"--no-cres")) nocres=1;
        else if (!strcmp(argv[i],"--wav")&&i+1<argc) wavout=argv[++i];
        else if (!strcmp(argv[i],"--raw")&&i+1<argc) rawout=argv[++i];
        else if (!strcmp(argv[i],"--bits")&&i+1<argc) bitspec=argv[++i]; /* 16|24|32f (hi-res) */
        else if (!strcmp(argv[i],"--master")&&i+1<argc) master=atof(argv[++i]);
        else if (!strcmp(argv[i],"--g0")&&i+1<argc) lg[0]=atof(argv[++i]);
        else if (!strcmp(argv[i],"--g1")&&i+1<argc) lg[1]=atof(argv[++i]);
        else if (!strcmp(argv[i],"--g2")&&i+1<argc) lg[2]=atof(argv[++i]);
        else inpath=argv[i];
    }
    if (!inpath){ fprintf(stderr,"usage: quanta-render in.qsc [--k N] [--wav o.wav] [--bits 16|24|32f] [--raw o.f64]\n"); return 2; }
    int wbits = !strcmp(bitspec,"24")?24 : (!strcmp(bitspec,"32f")||!strcmp(bitspec,"32"))?32 : 16;
    #define WAV_WRITE(p,x,n,s) (wbits==24?wav_write24(p,x,n,s):wbits==32?wav_write_f32(p,x,n,s):wav_write16(p,x,n,s))

    Qsc q;
    int rc = qsc_read(inpath, &q);
    if (rc){ fprintf(stderr,"render: qsc_read failed (%d)\n", rc); return 1; }

    double wtab[QSC_TAB], stab[QSC_TAB];
    qsc_build_tables(wtab, stab);
    uint64_t N = q.h.source_len;
    double sr = (double)q.h.sample_rate;
    int P = q.h.voice_count;
    uint32_t FR = q.h.residual_frames, HB = q.h.residual_hop;
    int cc = q.h.channel_count ? q.h.channel_count : 1;
    /* coherent (bit-transparent) tier: atoms-only mix (noise off) + stored true residual,
       added AFTER the DC blocker (§B). --no-cres falls back to the lossy atoms+noise tier. */
    int cres_on = (q.h.flags & QSC_FLAG_CRES) && q.cres && !nocres;
    uint32_t FRr = cres_on ? 0 : FR;

    if (cc <= 1){
        double *out = calloc(N, sizeof(double));
        render_channel(q.atoms, q.h.atom_count, P, K, q.res_gains, FRr, HB, q.h.noise_seed,
                       N, sr, lg, wtab, stab, out);
        master_dcblock(out, N, master);
        if (cres_on){ double s=q.cres_scale[0]; for (uint64_t t=0;t<N;t++) out[t]+=(double)q.cres[t]*s; }
        if (wavout) WAV_WRITE(wavout, out, N, q.h.sample_rate);
        if (rawout) raw_write_f64(rawout, out, N);
        double pk=0; for (uint64_t t=0;t<N;t++){ double a=fabs(out[t]); if(a>pk)pk=a; }
        fprintf(stderr,"render: %u atoms (K=%u) P=%d | %llu samples | peak %.3f (mono)\n",
                q.h.atom_count, K, P, (unsigned long long)N, pk);
        free(out);
    } else {
        /* atoms are stored [mid block][side block]; split at the first side atom (flag bit0). */
        uint32_t split=0; while (split < q.h.atom_count && !(q.atoms[split].flags & 1)) split++;
        uint32_t nM=split, nS=q.h.atom_count - split;
        size_t gblk = (size_t)FR*QSC_BANDS;
        double *oM = calloc(N,sizeof(double)), *oS = calloc(N,sizeof(double));
        render_channel(q.atoms,        nM, P, K, q.res_gains,        FRr, HB, q.h.noise_seed,
                       N, sr, lg, wtab, stab, oM);
        render_channel(q.atoms+split,  nS, P, K, q.res_gains+gblk,   FRr, HB, q.h.noise_seed ^ QSC_SIDE_SEED_XOR,
                       N, sr, lg, wtab, stab, oS);
        master_dcblock(oM, N, master); master_dcblock(oS, N, master);
        if (cres_on){ double s0=q.cres_scale[0], s1=q.cres_scale[1];
            for (uint64_t t=0;t<N;t++){ oM[t]+=(double)q.cres[t]*s0; oS[t]+=(double)q.cres[N+t]*s1; } }
        if (wavout){ if (wbits==24) wav_write24_ms(wavout, oM, oS, N, q.h.sample_rate);
                     else if (wbits==32) wav_write_f32_ms(wavout, oM, oS, N, q.h.sample_rate);
                     else wav_write16_ms(wavout, oM, oS, N, q.h.sample_rate); }
        if (rawout){                                       /* interleaved L,R f64 */
            double *il = malloc(sizeof(double)*2*N);
            for (uint64_t t=0;t<N;t++){ il[2*t]=oM[t]+oS[t]; il[2*t+1]=oM[t]-oS[t]; }
            raw_write_f64(rawout, il, 2*N); free(il);
        }
        double pk=0; for (uint64_t t=0;t<N;t++){ double l=fabs(oM[t]+oS[t]),r=fabs(oM[t]-oS[t]);
            if(l>pk)pk=l; if(r>pk)pk=r; }
        fprintf(stderr,"render: %u atoms (M=%u S=%u, K=%u) P=%d | %llu samples | peak %.3f (stereo M/S)\n",
                q.h.atom_count, nM, nS, K, P, (unsigned long long)N, pk);
        free(oM); free(oS);
    }
    qsc_free(&q);
    return 0;
}
