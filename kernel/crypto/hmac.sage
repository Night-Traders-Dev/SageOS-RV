## kernel/crypto/hmac.sage — HMAC-SHA256 Implementation
##
## RFC 2104 HMAC using SHA-256.
##
## Usage:
##   let mac = hmac_sha256(key, message)   → 32-byte array

let HMAC_BLOCK_SIZE = 64  ## SHA-256 block size
let HMAC_IPAD = 0x36
let HMAC_OPAD = 0x5C

proc hmac_sha256(key, message):
    ## Compute HMAC-SHA256(key, message)
    let key_len = len(key)

    ## If key is longer than block size, hash it
    let key_block = array(HMAC_BLOCK_SIZE)
    let i = 0
    if key_len > HMAC_BLOCK_SIZE:
        let hashed = sha256(key)
        while i < 32:
            key_block[i] = hashed[i]
            i = i + 1
        while i < HMAC_BLOCK_SIZE:
            key_block[i] = 0
            i = i + 1
    else:
        while i < key_len:
            key_block[i] = key[i]
            i = i + 1
        while i < HMAC_BLOCK_SIZE:
            key_block[i] = 0
            i = i + 1

    ## Inner hash: H(K XOR ipad || message)
    let inner = array(HMAC_BLOCK_SIZE + len(message))
    i = 0
    while i < HMAC_BLOCK_SIZE:
        inner[i] = key_block[i] ^ HMAC_IPAD
        i = i + 1
    while i < HMAC_BLOCK_SIZE + len(message):
        inner[i] = message[i - HMAC_BLOCK_SIZE]
        i = i + 1
    let inner_hash = sha256(inner)

    ## Outer hash: H(K XOR opad || inner_hash)
    let outer = array(HMAC_BLOCK_SIZE + 32)
    i = 0
    while i < HMAC_BLOCK_SIZE:
        outer[i] = key_block[i] ^ HMAC_OPAD
        i = i + 1
    while i < HMAC_BLOCK_SIZE + 32:
        outer[i] = inner_hash[i - HMAC_BLOCK_SIZE]
        i = i + 1
    return sha256(outer)
