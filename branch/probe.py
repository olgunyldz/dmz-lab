#!/usr/bin/env python3
"""Şube probe'u (test): şube pod'undan gw-branch'e tek bir HTTPS isteği. YALNIZ LAB.

Kullanım: python3 /app/probe.py <path> [bearer-token|-] [cert:yes|no]
Çıktı: ilk satır "HTTP/1.1 <kod>" (yanıt geldiyse) ya da "TLS-ERROR: <hata>" (el sıkışma reddi).
Ortam: BRANCH_GW_HOST, BRANCH_GW_PORT (30449), BRANCH_CERT_DIR (/certs).
"""
import os
import socket
import ssl
import sys
from pathlib import Path

CERTS = Path(os.environ.get("BRANCH_CERT_DIR", "/certs"))
GW = (os.environ["BRANCH_GW_HOST"], int(os.environ.get("BRANCH_GW_PORT", "30449")))
HOST = "teller.lab.local"


def main():
    path = sys.argv[1]
    token = sys.argv[2] if len(sys.argv) > 2 else "-"
    cert = (sys.argv[3] if len(sys.argv) > 3 else "yes") == "yes"

    ctx = ssl.create_default_context(cafile=str(CERTS / "internal-ca.crt"))
    if cert:
        ctx.load_cert_chain(str(CERTS / "branch-device.crt"), str(CERTS / "branch-device.key"))
    headers = f"GET {path} HTTP/1.1\r\nHost: {HOST}\r\nConnection: close\r\n"
    if token != "-":
        headers += f"Authorization: Bearer {token}\r\n"
    try:
        raw = socket.create_connection(GW, timeout=20)
        tls = ctx.wrap_socket(raw, server_hostname=HOST)
        tls.sendall((headers + "\r\n").encode())
        data = b""
        while True:
            chunk = tls.recv(65536)
            if not chunk:
                break
            data += chunk
        text = data.decode("utf-8", "replace")
        print(text.replace("\r\n", "\n")[:2000])
    except ssl.SSLError as e:
        print(f"TLS-ERROR: {e}")
    except OSError as e:
        print(f"TLS-ERROR: {e}")


if __name__ == "__main__":
    main()
