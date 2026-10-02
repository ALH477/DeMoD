// SPDX-License-Identifier: LGPL-3.0-only
// Copyright (c) 2026 DeMoD LLC.
//
//! The linked gate is the gate, in this tree.
//!
//! The certification of `custos` is upstream's: Exsecutor's
//! `examples/custos/proba_c.sh` (anchors, double emission, five mutants) and
//! Punctim's `web/bridge/tests/certify_gate.rs` (the 360 golden, SuperPack and
//! medium vectors plus a 14,735-datagram differential against the Rust
//! reference codec). Neither can run here: this vendored copy carries no
//! Punctim `codec/` and no vectors.
//!
//! What this file checks is that the unit this crate actually links answers
//! the rule in `src/gate.rs` on anchors that need no vectors: a frame built
//! here from the published CRC, every single-bit corruption of it, every
//! version nibble, every length up to 40, and a SuperPack around the
//! zero-core anchor `0x5B75` from SUPERPACK_SPEC.md. A unit that admits
//! everything, refuses everything, or skips the version check fails here.

use dcf_ws_bridge::gate::{admit, Verdict};

/// CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF, no reflection, no final XOR.
fn crc16(b: &[u8]) -> u16 {
    let mut c: u16 = 0xFFFF;
    for &x in b {
        c ^= (x as u16) << 8;
        for _ in 0..8 {
            c = if c & 0x8000 != 0 { (c << 1) ^ 0x1021 } else { c << 1 };
        }
    }
    c
}

fn seal(mut f: Vec<u8>) -> Vec<u8> {
    let n = f.len();
    let c = crc16(&f[..n - 2]);
    f[n - 2] = (c >> 8) as u8;
    f[n - 1] = c as u8;
    f
}

/// A version-1 DeModFrame: sync, flags, seq, src, dst, payload, ts24, crc.
fn frame(ty: u8) -> Vec<u8> {
    seal(vec![
        0xD3, 0x10 | (ty & 0x0F), 0x12, 0x34, 0x00, 0x02, 0x00, 0x03, b'P', b'I', b'N', b'G', 0x01,
        0x02, 0x03, 0, 0,
    ])
}

#[test]
fn crc_anchors_hold() {
    // WIRE_QUANTUM_SPEC.md's two anchors, so a wrong CRC here cannot make
    // the frames below wrong in a way that still agrees with a wrong gate.
    assert_eq!(crc16(b"123456789"), 0x29B1);
    assert_eq!(crc16(&[0u8; 15]), 0x4EC3);
    // SUPERPACK_SPEC.md: two all-zero-core frames (`encode(0,0,0,0,0000,0)`,
    // so each core's flags byte is version 1, type 0) have joint CRC 0x5B75.
    let mut sp = vec![0u8; 30];
    sp[0] = 0xD3;
    sp[1] = 0x15;
    sp[2] = 0x10;
    sp[16] = 0x10;
    assert_eq!(crc16(&sp), 0x5B75);
}

#[test]
fn a_valid_frame_of_every_type_is_admitted() {
    for ty in 0..16 {
        assert_eq!(admit(&frame(ty)), Verdict::Admitted, "type {ty}");
    }
}

#[test]
fn every_single_bit_corruption_is_refused() {
    let f = frame(3);
    for bit in 0..(17 * 8) {
        let mut g = f.clone();
        g[bit / 8] ^= 1 << (bit % 8);
        assert!(!admit(&g).admitted(), "bit {bit} flipped was admitted");
    }
}

#[test]
fn only_version_one_passes_even_with_a_valid_crc() {
    for v in 0u8..16 {
        let mut f = frame(0);
        f[1] = (v << 4) | (f[1] & 0x0F);
        let f = seal(f);
        let want = if v == 1 { Verdict::Admitted } else { Verdict::BadVersion };
        assert_eq!(admit(&f), want, "version {v}");
    }
}

#[test]
fn no_other_length_is_admitted() {
    for n in 0..=40usize {
        if n == 17 || n == 32 {
            continue;
        }
        assert_eq!(admit(&vec![0xD3; n]), Verdict::BadLength, "length {n}");
    }
}

#[test]
fn a_superpack_is_admitted_and_its_cores_are_version_checked() {
    let mut sp = vec![0u8; 32];
    sp[0] = 0xD3;
    sp[1] = 0x15;
    sp[2] = 0x10; // core A: version 1, type 0
    sp[16] = 0x13; // core B: version 1, type 3
    assert_eq!(admit(&seal(sp.clone())), Verdict::Admitted);

    let mut bad_b = sp.clone();
    bad_b[16] = 0x23; // core B at version 2, joint CRC re-sealed
    assert_eq!(admit(&seal(bad_b)), Verdict::BadCoreVersion);

    let mut not_super = sp;
    not_super[1] = 0x14; // version 1, type 4: not SUPER
    assert_eq!(admit(&seal(not_super)), Verdict::NotSuperPack);
}

#[test]
fn a_frame_truncated_or_padded_is_refused() {
    let f = frame(0);
    assert_eq!(admit(&f[..16]), Verdict::BadLength);
    let mut g = f.clone();
    g.push(0);
    assert_eq!(admit(&g), Verdict::BadLength);
}
