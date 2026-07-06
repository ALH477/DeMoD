#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
# qspeech_cli.py — thin CLI over the experimental quanta speech vocoder (qvoc/qcodec)
# for the MCP server. Encodes+decodes a WAV through the VQ codec, writes the decoded
# WAV, and prints a one-line JSON report (sample rate, duration, bits, bitrate, MCD).
# Uses only numpy (no PESQ/Codec2), so it runs under a plain python3.
#   usage: qspeech_cli.py in.wav out.wav
import sys, os, json, subprocess, numpy as np
HERE=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,HERE)
import qvoc, qcodec

def main():
    inp, outp = sys.argv[1], sys.argv[2]
    x, sr = qvoc.read_wav(inp)
    cbf=os.path.join(HERE,'..','test','speech','vq_cepK24.npz')
    d=np.load(cbf); cbs=[d[k] for k in d.files]
    meta, bits, bps = qcodec.encode_vq(x, sr, cbs, fps=50, K=24)
    y = qcodec.decode_vq(meta); qvoc.write_wav(outp, y, sr)
    # MCD via the repo metric (phase-independent envelope distortion)
    n=min(len(x),len(y)); x[:n].astype('<f8').tofile('/tmp/_qr.f64'); y[:n].astype('<f8').tofile('/tmp/_qd.f64')
    o=subprocess.run(['python3',os.path.join(HERE,'mcd.py'),'/tmp/_qr.f64','/tmp/_qd.f64',str(sr)],
                     capture_output=True,text=True).stdout
    mcd=float(o.split('mcd:')[1].split('dB')[0]) if 'mcd:' in o else None
    print(json.dumps({"sample_rate":sr,"seconds":round(len(x)/sr,2),
                      "envelope_bits_per_frame":sum(int(round(np.log2(len(c)))) for c in cbs),
                      "total_bits":bits,"bitrate_bps":round(bps),
                      "mcd_db":round(mcd,3) if mcd is not None else None,
                      "output_wav":os.path.abspath(outp)}))
if __name__=='__main__':
    main()
