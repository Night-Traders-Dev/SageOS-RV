## kernel/net/http.sage — HTTP/1.1 Client (RFC 7230-7235)
let HTTP_PORT = 80

proc http_request(method, host, path):
    ## Build HTTP request
    let req = method + " " + path + " HTTP/1.1\r\n"
    req = req + "Host: " + host + "\r\n"
    req = req + "User-Agent: SageOS-RV/0.3.0\r\n"
    req = req + "Accept: */*\r\n"
    req = req + "Connection: close\r\n"
    req = req + "\r\n"
    return req

proc http_parse_response(raw):
    ## Parse HTTP response, return {status, headers, body}
    let lines = http_split(raw, "\r\n")
    if len(lines) == 0: return nil
    let status_line = lines[0]  ## "HTTP/1.1 200 OK"
    let status = http_extract_status(status_line)
    let headers = {}
    let body_start = 0
    let i = 1
    while i < len(lines):
        if lines[i] == "": body_start = i + 1; break
        let colon = http_find(lines[i], ":")
        if colon > 0:
            let key = lines[i][:colon]
            let val = lines[i][colon+2:]
            headers[key] = val
        i = i + 1
    let body = ""
    i = body_start
    while i < len(lines): body = body + lines[i] + "\r\n"; i = i + 1
    return {status: status, headers: headers, body: body}

proc http_get(host, path):
    ## Perform HTTP GET request
    let req = http_request("GET", host, path)
    print("[HTTP] GET "); print(path); print(" HTTP/1.1\n")
    ## Would connect TCP to host:80, send req, receive response
    return nil

proc http_post(host, path, data, content_type):
    let body = data
    let req = http_request("POST", host, path)
    req = req + "Content-Type: " + content_type + "\r\n"
    req = req + "Content-Length: " + str(len(body)) + "\r\n"
    req = req + "\r\n" + body
    print("[HTTP] POST "); print(path); print("\n")
    return nil

proc http_extract_status(line):
    return 200  ## stub

proc http_split(s, delim): return [s]  ## stub
proc http_find(s, c): return 0  ## stub
