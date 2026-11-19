# Seal Intranet

Backend-to-backend API servisi; ayrı bir servistir (namespace `seal-intranet`, internal cluster). Yalnızca iç gateway (`gw-internal`, `/seal/`) üzerinden erişilir.

## Uç noktalar

| Yol | Kimlik | Açıklama |
|---|---|---|
| `GET /seal/v1/health` | yok | Sağlık kontrolü |
| `GET /seal/v1/whoami` | Bearer | Çağıran istemci kimliği |
| `POST /seal/v1/signing/requests` | Bearer | İmza isteği kabulü (**stub**: kabul eder, imzalamaz) |

## Kimlik doğrulama

- Çağıran backend, auth-server'den `seal-b2b` istemcisiyle `client_credentials` token alır.
- Token RS256 imzası auth-server JWKS ile doğrulanır; `iss`, `exp`, `sub`, `aud` zorunlu.
- `aud` = `seal-intranet` (auth-server'de `seal-b2b` istemcisi bu audience'ı basar).
- İstemci kimliği `azp` yoksa `sub`'dan alınır (client_credentials token'larında `azp` yok).
- Yanlış audience (`bff`, `partner-acme`) ve sahte token reddedilir.

## Test

Uçtan uca test kümede çalışır (gerçek auth-server token'ları, gateway ve TLS dahil):

```bash
# Test betiği henüz bu klasörde değil (eski internal-cluster/tests kaldırıldı); tests/ altına taşınmalı.
```

Bu test seal-b2b token'ı ile `/seal-v3/` çağrısını (auth-server JWKS, HTTPS) da kapsar. Yerel tek başına çalıştırma (`smoke.py`) kaldırıldı.

## Lab sınırları

- HTTPS (iç CA); auth-server JWKS HTTPS ile alınır. Gateway -> servis TLS, `BackendTLSPolicy` ile sağlanır.
- İmza istekleri bellekte; gerçek imza işlemi Seal Mobile orkestrasyonuna aittir.
- JWKS için auth-server (bank-prod) HTTPS NodePort'u (lab sapması: IP ile erişim, SNI id.bank.lab.local).
