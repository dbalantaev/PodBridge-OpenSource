#include <metal_stdlib>
using namespace metal;

inline uint rol(uint value, uint bits) { return (value << bits) | (value >> (32 - bits)); }

inline void sha1_compress(thread uint h[5], thread uchar block[64]) {
    uint w[80];
    for (uint i = 0; i < 16; ++i) {
        uint p = i * 4;
        w[i] = (uint(block[p]) << 24) | (uint(block[p + 1]) << 16) | (uint(block[p + 2]) << 8) | uint(block[p + 3]);
    }
    for (uint i = 16; i < 80; ++i) w[i] = rol(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    uint a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
    for (uint i = 0; i < 80; ++i) {
        uint f, k;
        if (i < 20) { f = (b & c) | ((~b) & d); k = 0x5a827999; }
        else if (i < 40) { f = b ^ c ^ d; k = 0x6ed9eba1; }
        else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8f1bbcdc; }
        else { f = b ^ c ^ d; k = 0xca62c1d6; }
        uint temp = rol(a, 5) + f + e + k + w[i];
        e = d; d = c; c = rol(b, 30); b = a; a = temp;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e;
}

inline void sha1_init(thread uint h[5]) {
    h[0] = 0x67452301; h[1] = 0xefcdab89; h[2] = 0x98badcfe; h[3] = 0x10325476; h[4] = 0xc3d2e1f0;
}

inline void sha1_key(thread uchar input[34], thread uchar digest[20]) {
    uchar block[64] = {};
    for (uint i = 0; i < 34; ++i) block[i] = input[i];
    block[34] = 0x80;
    ulong bitLength = 34 * 8;
    for (uint i = 0; i < 8; ++i) block[63 - i] = uchar(bitLength >> (i * 8));
    uint h[5]; sha1_init(h); sha1_compress(h, block);
    for (uint i = 0; i < 5; ++i) {
        digest[i * 4] = uchar(h[i] >> 24); digest[i * 4 + 1] = uchar(h[i] >> 16);
        digest[i * 4 + 2] = uchar(h[i] >> 8); digest[i * 4 + 3] = uchar(h[i]);
    }
}

inline void hmac_sha1(
    thread uchar key[20], device const uchar *message, uint length, thread uchar digest[20]
) {
    uint inner[5]; sha1_init(inner);
    uchar block[64];
    for (uint i = 0; i < 64; ++i) block[i] = (i < 20 ? key[i] : 0) ^ 0x36;
    sha1_compress(inner, block);
    uint full = length / 64;
    for (uint n = 0; n < full; ++n) {
        for (uint i = 0; i < 64; ++i) block[i] = message[n * 64 + i];
        sha1_compress(inner, block);
    }
    uint remainder = length - full * 64;
    for (uint i = 0; i < 64; ++i) block[i] = 0;
    for (uint i = 0; i < remainder; ++i) block[i] = message[full * 64 + i];
    block[remainder] = 0x80;
    ulong bitLength = ulong(64 + length) * 8;
    if (remainder >= 56) {
        sha1_compress(inner, block);
        for (uint i = 0; i < 64; ++i) block[i] = 0;
    }
    for (uint i = 0; i < 8; ++i) block[63 - i] = uchar(bitLength >> (i * 8));
    sha1_compress(inner, block);

    uchar innerDigest[20];
    for (uint i = 0; i < 5; ++i) {
        innerDigest[i * 4] = uchar(inner[i] >> 24); innerDigest[i * 4 + 1] = uchar(inner[i] >> 16);
        innerDigest[i * 4 + 2] = uchar(inner[i] >> 8); innerDigest[i * 4 + 3] = uchar(inner[i]);
    }
    uint outer[5]; sha1_init(outer);
    for (uint i = 0; i < 64; ++i) block[i] = (i < 20 ? key[i] : 0) ^ 0x5c;
    sha1_compress(outer, block);
    for (uint i = 0; i < 64; ++i) block[i] = 0;
    for (uint i = 0; i < 20; ++i) block[i] = innerDigest[i];
    block[20] = 0x80;
    ulong outerBits = 84 * 8;
    for (uint i = 0; i < 8; ++i) block[63 - i] = uchar(outerBits >> (i * 8));
    sha1_compress(outer, block);
    for (uint i = 0; i < 5; ++i) {
        digest[i * 4] = uchar(outer[i] >> 24); digest[i * 4 + 1] = uchar(outer[i] >> 16);
        digest[i * 4 + 2] = uchar(outer[i] >> 8); digest[i * 4 + 3] = uchar(outer[i]);
    }
}

kernel void recover_signature_id(
    device const uchar *message [[buffer(0)]],
    constant uint &messageLength [[buffer(1)]],
    device const uchar *expected [[buffer(2)]],
    device const uint *pairTable [[buffer(3)]],
    constant ulong &start [[buffer(4)]],
    constant uint &candidateCount [[buffer(5)]],
    device atomic_uint &foundSuffix [[buffer(6)]],
    device atomic_uint &foundFlag [[buffer(7)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= candidateCount || atomic_load_explicit(&foundFlag, memory_order_relaxed) != 0) return;
    uint suffix = uint(start + gid);
    uint first = pairTable[(suffix >> 16) & 0xffff];
    uint second = pairTable[suffix & 0xffff];
    uchar fixed[18] = {0x67,0x23,0xfe,0x30,0x45,0x33,0xf8,0x90,0x99,0x21,0x07,0xc1,0xd0,0x12,0xb2,0xa1,0x07,0x81};
    // Precomputed pair encodings for 00 0a and 27 00.
    uint prefix0 = pairTable[0x000a], prefix1 = pairTable[0x2700];
    uchar keyInput[34];
    for (uint i = 0; i < 18; ++i) keyInput[i] = fixed[i];
    uint packed[4] = {prefix0, prefix1, first, second};
    for (uint p = 0; p < 4; ++p) for (uint i = 0; i < 4; ++i) keyInput[18 + p * 4 + i] = uchar(packed[p] >> (i * 8));
    uchar key[20], signature[20];
    sha1_key(keyInput, key);
    hmac_sha1(key, message, messageLength, signature);
    bool matches = true;
    for (uint i = 0; i < 20; ++i) matches = matches && signature[i] == expected[i];
    if (matches) {
        atomic_store_explicit(&foundSuffix, suffix, memory_order_relaxed);
        atomic_store_explicit(&foundFlag, 1, memory_order_relaxed);
    }
}
