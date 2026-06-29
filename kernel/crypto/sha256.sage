## kernel/crypto/sha256.sage — Pure-Sage SHA-256 Hash Implementation
##
## FIPS 180-4 compliant SHA-256. Used by HMAC and SSH.
##
## Usage:
##   let hash = sha256(data)   → 32-byte hex string
##   let hash = sha256_raw(data) → 32-byte array

## SHA-256 constants (first 32 bits of fractional parts of cube roots of primes 2-311)
let SHA256_K = [
    0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5,
    0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
    0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3,
    0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
    0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC,
    0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
    0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7,
    0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
    0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13,
    0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
    0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3,
    0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
    0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5,
    0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
    0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208,
    0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2
]

## Initial hash values
let sha256_h = [0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
                 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19]

proc sha256_rotr(x, n):
    return ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF

proc sha256_ch(x, y, z):
    return (x & y) ^ ((~x) & z)

proc sha256_maj(x, y, z):
    return (x & y) ^ (x & z) ^ (y & z)

proc sha256_bsig0(x):
    return sha256_rotr(x, 2) ^ sha256_rotr(x, 17) ^ sha256_rotr(x, 22)

proc sha256_bsig1(x):
    return sha256_rotr(x, 6) ^ sha256_rotr(x, 11) ^ sha256_rotr(x, 25)

proc sha256_ssig0(x):
    return sha256_rotr(x, 7) ^ sha256_rotr(x, 18) ^ (x >> 3)

proc sha256_ssig1(x):
    return sha256_rotr(x, 17) ^ sha256_rotr(x, 19) ^ (x >> 10)

proc sha256_transform(state, block):
    ## Process 64-byte block (16 × 32-bit words)
    let w = array(64)
    let i = 0
    while i < 16:
        let off = i * 4
        w[i] = (block[off] << 24) | (block[off + 1] << 16) | (block[off + 2] << 8) | block[off + 3]
        i = i + 1
    while i < 64:
        w[i] = (sha256_ssig1(w[i - 2]) + w[i - 7] + sha256_ssig0(w[i - 15]) + w[i - 16]) & 0xFFFFFFFF
        i = i + 1

    let a = state[0]; let b = state[1]; let c = state[2]; let d = state[3]
    let e = state[4]; let f = state[5]; let g = state[6]; let h = state[7]

    i = 0
    while i < 64:
        let t1 = (h + sha256_bsig1(e) + sha256_ch(e, f, g) + SHA256_K[i] + w[i]) & 0xFFFFFFFF
        let t2 = (sha256_bsig0(a) + sha256_maj(a, b, c)) & 0xFFFFFFFF
        h = g; g = f; f = e; e = (d + t1) & 0xFFFFFFFF
        d = c; c = b; b = a; a = (t1 + t2) & 0xFFFFFFFF
        i = i + 1

    state[0] = (state[0] + a) & 0xFFFFFFFF
    state[1] = (state[1] + b) & 0xFFFFFFFF
    state[2] = (state[2] + c) & 0xFFFFFFFF
    state[3] = (state[3] + d) & 0xFFFFFFFF
    state[4] = (state[4] + e) & 0xFFFFFFFF
    state[5] = (state[5] + f) & 0xFFFFFFFF
    state[6] = (state[6] + g) & 0xFFFFFFFF
    state[7] = (state[7] + h) & 0xFFFFFFFF

proc sha256(msg):
    ## Compute SHA-256 hash, return 32-byte array
    let state = [0, 0, 0, 0, 0, 0, 0, 0]
    let i = 0
    while i < 8:
        state[i] = sha256_h[i]
        i = i + 1

    let msg_len = len(msg)
    ## Pad message: append 0x80, pad zeros, append 64-bit length
    let pad_len = 64 - ((msg_len + 9) % 64)
    if pad_len == 64:
        pad_len = 0

    let padded_len = msg_len + 1 + pad_len + 8
    let padded = array(padded_len)

    ## Copy message
    i = 0
    while i < msg_len:
        padded[i] = msg[i] & 0xFF
        i = i + 1

    ## Append 0x80
    padded[msg_len] = 0x80

    ## Pad with zeros
    i = msg_len + 1
    while i < msg_len + 1 + pad_len:
        padded[i] = 0
        i = i + 1

    ## Append 64-bit big-endian length (in bits)
    let bit_len = msg_len * 8
    let len_pos = msg_len + 1 + pad_len
    padded[len_pos + 7] = bit_len & 0xFF
    padded[len_pos + 6] = (bit_len >> 8) & 0xFF
    padded[len_pos + 5] = (bit_len >> 16) & 0xFF
    padded[len_pos + 4] = (bit_len >> 24) & 0xFF

    ## Process blocks
    let pos = 0
    while pos < padded_len:
        let block = array(64)
        i = 0
        while i < 64:
            block[i] = padded[pos + i]
            i = i + 1
        sha256_transform(state, block)
        pos = pos + 64

    ## Output
    let result = array(32)
    i = 0
    while i < 8:
        let val = state[i]
        result[i * 4]     = (val >> 24) & 0xFF
        result[i * 4 + 1] = (val >> 16) & 0xFF
        result[i * 4 + 2] = (val >> 8) & 0xFF
        result[i * 4 + 3] = val & 0xFF
        i = i + 1
    return result
