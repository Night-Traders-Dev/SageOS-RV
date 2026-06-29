## kernel/net/tls.sage — TLS 1.3 Handshake (RFC 8446)
let TLS_RECORD_HDR = 5  ## 1B type + 2B version + 2B length
let TLS_HANDSHAKE   = 22
let TLS_APP_DATA    = 23
let TLS_CLIENT_HELLO  = 1
let TLS_SERVER_HELLO  = 2
let TLS_ENCRYPTED_EXT = 8
let TLS_CERTIFICATE   = 11
let TLS_CERT_VERIFY   = 15
let TLS_FINISHED      = 20

let tls_state = 0  ## 0=init,1=hello,2=handshake,3=connected
let tls_session_keys = nil

proc tls_build_client_hello(sni_hostname):
    ## Build TLS 1.3 ClientHello
    let hello = []
    tls_put_u16(hello, 0x0303)  ## Legacy version (TLS 1.2 for compat)
    ## 32 bytes random
    let i = 0; while i < 32: push(hello, 0); i = i + 1
    ## Session ID (empty)
    tls_put_u8(hello, 0)
    ## Cipher suites: TLS_AES_128_GCM_SHA256 (0x1301)
    tls_put_u16(hello, 2)  ## length
    tls_put_u16(hello, 0x1301)
    ## Compression: null
    tls_put_u8(hello, 1); tls_put_u8(hello, 0)
    ## Extensions
    tls_put_u16(hello, 0)  ## placeholder length
    ## SNI extension
    if sni_hostname != "":
        ## extension_type=server_name(0), length, server_name_list
        pass
    return hello

proc tls_handshake(hostname):
    ## Initiate TLS 1.3 handshake
    tls_state = 1
    print("[TLS] ClientHello → "); print(hostname); print("\n")
    let hello = tls_build_client_hello(hostname)
    return hello

proc tls_encrypt(plaintext):
    ## AES-128-GCM encrypt (stub — needs crypto builtin)
    return plaintext

proc tls_decrypt(ciphertext):
    ## AES-128-GCM decrypt
    return ciphertext

proc tls_put_u8(buf, b): push(buf, b & 0xFF)
proc tls_put_u16(buf, v): push(buf,(v>>8)&0xFF); push(buf,v&0xFF)
