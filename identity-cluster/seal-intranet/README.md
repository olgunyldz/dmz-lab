# Seal Intranet

Backend-to-backend API servisi; ayrı bir servistir (namespace `seal-intranet`, internal cluster). Yalnızca iç gateway (`gw-internal`, `/seal/`) üzerinden erişilir.

## Uç noktalar

| Yol | Kimlik | Açıklama |
|---|---|---|
| `GET /seal/v1/health` | yok | Sağlık kontrolü |
| `GET /seal/v1/whoami` | Bearer | Çağıran istemci kimliği |
| `POST /seal/v1/signing/requests` | Bearer | İmza isteği kabulü (**stub**: kabul eder, imzalamaz) |

## Kimlik doğrulama

- Çağıran backend, IdP'den `seal-b2b` istemcisiyle `client_credentials` token alır.
- Token RS256 imzası IdP JWKS ile doğrulanır; `iss`, `exp`, `sub`, `aud` zorunlu.
- `aud` = `seal-intranet` (IdP'de `seal-b2b` istemcisi bu audience'ı basar).
- İstemci kimliği `azp` yoksa `sub`'dan alınır (client_credentials token'larında `azp` yok).
- Yanlış audience (`bff`, `partner-acme`) ve sahte token reddedilir.

## Test

Uçtan uca test kümede çalışır (gerçek IdP token'ları, gateway ve TLS dahil):

```bash
python3 internal-cluster/tests/seal_v3.py
```

Bu test seal-b2b token'ı ile `/seal-v3/` çağrısını (IdP JWKS, HTTPS) da kapsar. Yerel tek başına çalıştırma (`smoke.py`) kaldırıldı.

## Lab sınırları

- HTTPS (iç CA); IdP JWKS HTTPS ile alınır. Gateway -> servis TLS, `BackendTLSPolicy` ile sağlanır.
- İmza istekleri bellekte; gerçek imza işlemi Seal Mobile orkestrasyonuna aittir.
- JWKS için `identity-idp` Service/Endpoints (lab sapması, `identity-idp` deseni).
