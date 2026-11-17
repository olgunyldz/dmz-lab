#!/usr/bin/env python3
"""DPoP proof (RFC 9449) üretir. RS256, başlıkta public JWK. Yalnız test içindir.

Kullanım: dpop_proof.py <özel-anahtar.pem> <htm> <htu>
Çıktı: JWT (stdout). İmza için openssl kullanılır (Python stdlib'de RSA imzası yok).
"""
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import uuid


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def public_jwk(key_path: str) -> dict:
    out = subprocess.run(["openssl", "rsa", "-in", key_path, "-noout", "-modulus"],
                         capture_output=True, text=True, check=True).stdout.strip()
    modulus = bytes.fromhex(out.split("=", 1)[1]).lstrip(b"\x00")
    return {"kty": "RSA", "n": b64url(modulus), "e": b64url(bytes([1, 0, 1]))}


def main() -> None:
    key_path, htm, htu = sys.argv[1], sys.argv[2], sys.argv[3]
    header = {"typ": "dpop+jwt", "alg": "RS256", "jwk": public_jwk(key_path)}
    payload = {"jti": str(uuid.uuid4()), "htm": htm, "htu": htu, "iat": int(time.time())}
    signing_input = f"{b64url(json.dumps(header, separators=(',', ':')).encode())}." \
                    f"{b64url(json.dumps(payload, separators=(',', ':')).encode())}"
    fd, data_path = tempfile.mkstemp()
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(signing_input.encode())
        sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path, data_path],
                             capture_output=True, check=True).stdout
    finally:
        os.remove(data_path)
    print(f"{signing_input}.{b64url(sig)}")


if __name__ == "__main__":
    main()
