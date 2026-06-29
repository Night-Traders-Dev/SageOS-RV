## kernel/net/dns.sage — DNS Resolver (RFC 1035)
let DNS_PORT = 53
let dns_id_counter = 0

proc dns_build_query(domain):
    ## Build DNS query for A record
    dns_id_counter = dns_id_counter + 1
    let query = []
    dns_put16(query, dns_id_counter)  ## Transaction ID
    dns_put16(query, 0x0100)  ## Standard query, recursion desired
    dns_put16(query, 1)       ## 1 question
    dns_put16(query, 0)       ## 0 answers
    dns_put16(query, 0)       ## 0 authority
    dns_put16(query, 0)       ## 0 additional
    dns_encode_name(query, domain)  ## QNAME
    dns_put16(query, 1)       ## QTYPE = A
    dns_put16(query, 1)       ## QCLASS = IN
    return query

proc dns_parse_reply(reply):
    let id = (reply[0]<<8)|reply[1]
    let flags = (reply[2]<<8)|reply[3]
    let qdcount = (reply[4]<<8)|reply[5]
    let ancount = (reply[6]<<8)|reply[7]
    let answers = []; let pos = 12
    ## Skip question section
    while pos < len(reply) and reply[pos] != 0: pos = pos + 1 + reply[pos]
    pos = pos + 5  ## skip 0x00 + QTYPE + QCLASS
    ## Parse answer RRs
    let i = 0
    while i < ancount and pos < len(reply):
        pos = pos + 2  ## skip name pointer
        let rtype = (reply[pos]<<8)|reply[pos+1]; pos = pos + 2
        let rclass = (reply[pos]<<8)|reply[pos+1]; pos = pos + 2
        let ttl = (reply[pos]<<24)|(reply[pos+1]<<16)|(reply[pos+2]<<8)|reply[pos+3]; pos = pos + 4
        let rdlen = (reply[pos]<<8)|reply[pos+1]; pos = pos + 2
        if rtype == 1 and rdlen == 4:  ## A record
            let ip = dns_fmt_ip(reply[pos],reply[pos+1],reply[pos+2],reply[pos+3])
            push(answers, ip)
        pos = pos + rdlen; i = i + 1
    return answers

proc dns_resolve(domain, dns_server):
    ## Resolve domain to IP using DNS server
    let query = dns_build_query(domain)
    ## Send query via UDP to dns_server:53
    ## Would call udp_send(dns_server, 53, query) 
    return []

proc dns_encode_name(buf, name):
    let parts = dns_split(name, '.')
    let i = 0; while i < len(parts):
        push(buf, len(parts[i]))
        let j = 0; while j < len(parts[i]): push(buf, parts[i][j]); j = j + 1
        i = i + 1
    push(buf, 0)  ## terminating zero

proc dns_fmt_ip(a,b,c,d):
    return str(a) + "." + str(b) + "." + str(c) + "." + str(d)

proc dns_put16(buf, v): push(buf,(v>>8)&0xFF); push(buf,v&0xFF)

proc dns_split(s, delim):
    return [s]  ## stub
