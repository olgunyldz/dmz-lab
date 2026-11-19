# DMZ cluster'ları NodePort'larını 127.0.0.1'e yayınlar (kind extraPortMappings); edge onlara host.docker.internal üzerinden gider.
# Edge kind ağına bağlı değildir. haproxy.cfg bu şablondan üretilir (edge/scripts/render-haproxy.sh).
# DMZ Edge — HAProxy (lab), yeni cluster yapısı:
#   seal.lab.local      -> codevo-dmz Seal Mobile (NodePort 30456), TLS passthrough (cihaz mTLS pod'da)
#   web.lab.local       -> bank-dmz-prod nginx ingress (NodePort 30802) -> janus-web, TLS edge'de sonlanır
#   mobile-api.lab.local-> bank-dmz-prod nginx ingress (NodePort 30802) -> janus-mobile, TLS edge'de sonlanır
# Bilinen sınır: Janus'a bağlantı düz HTTP (zone kuralındaki mTLS henüz uygulanmadı).

global
    log stdout format raw local0
    maxconn 20000
    ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets

defaults
    log global
    option dontlognull
    timeout connect 5s
    timeout client 30s
    timeout server 60s
    timeout http-request 10s
    timeout queue 10s
    retries 2
    option redispatch

frontend fe_public
    mode tcp
    bind *:443
    option tcplog

    stick-table type ip size 1m expire 60s store conn_rate(10s),conn_cur
    tcp-request connection track-sc0 src
    tcp-request connection reject if { sc_conn_rate(0) gt 200 }
    tcp-request connection reject if { sc_conn_cur(0) gt 100 }

    tcp-request inspect-delay 5s
    tcp-request content accept if { req.ssl_hello_type 1 }

    use_backend be_seal_pt if { req.ssl_sni -i seal.lab.local }
    default_backend be_edge_tls

backend be_edge_tls
    mode tcp
    server fe_https 127.0.0.1:8444 send-proxy-v2

backend be_seal_pt
    mode tcp
    server codevo-worker host.docker.internal:30456 check

frontend fe_https
    mode http
    bind 127.0.0.1:8444 accept-proxy ssl crt /certs/edge.pem
    option httplog
    option forwardfor
    unique-id-format %{+X}o\ %ci:%cp_%fi:%fp_%Ts_%rt:%pid
    unique-id-header X-Request-ID

    stick-table type ip size 1m expire 10m store http_req_rate(10s)
    http-request track-sc0 src
    http-request deny deny_status 429 if { sc_http_req_rate(0) gt 50 }

    acl host_web hdr(host) -i web.lab.local
    acl host_mobile hdr(host) -i mobile-api.lab.local
    http-request return status 404 content-type text/plain string "not found" unless host_web || host_mobile

    http-request set-header X-Edge-Zone dmz-edge
    http-request set-header X-Forwarded-Proto https

    http-response set-header Strict-Transport-Security "max-age=31536000"
    http-response set-header X-Content-Type-Options nosniff
    http-response del-header Server

    use_backend be_janus_web if host_web
    use_backend be_janus_mobile if host_mobile

backend be_janus_web
    mode http
    balance roundrobin
    http-request set-header Host web.lab.local
    option httpchk
    http-check send meth GET uri /janus/health ver HTTP/1.1 hdr host web.lab.local
    http-check expect status 200
    server janus-web host.docker.internal:30802 check inter 2s fall 2 rise 2

backend be_janus_mobile
    mode http
    balance roundrobin
    http-request set-header Host mobile-api.lab.local
    option httpchk
    http-check send meth GET uri /janus/health ver HTTP/1.1 hdr host mobile-api.lab.local
    http-check expect status 200
    server janus-mobile host.docker.internal:30802 check inter 2s fall 2 rise 2

frontend fe_stats
    mode http
    bind *:8404
    stats enable
    stats uri /stats
    stats refresh 5s
