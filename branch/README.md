# Şube (branch) zone ve veznedar arayüzü

Banka şubelerindeki çalışan iş istasyonlarının merkez sistemlere erişimi. Tasarım: `design.md` 4.7. **Yalnız lab.**

## Kurulum (bir kez)

Repo kökünden, sırayla:

```
bash edge/scripts/gen-branch-certs.sh          # branch-ca, gw-branch, dmz-exchange-branch, branch-device
bash identity-cluster/scripts/setup-realm.sh   # branch-app client, dmz-exchange-branch, teller kullanıcısı
bash dmz-cluster/scripts/load-extauth.sh       # ext-authz: branch profili ve exchange sertifikası
bash dmz-cluster/scripts/load-branch.sh        # gw-branch gateway, secret'lar, ConfigMap'ler
bash dmz-cluster/scripts/host-firewall.sh      # F1: NodePort 30449 yalnız edge'den
```

Edge (`haproxy.cfg`) `teller.lab.local` için SNI passthrough içerir; edge'i yeniden başlatın: `cd edge && docker compose restart haproxy`.

Iç cluster tarafında `internal-cluster/manifests/internal-authz.yaml` ve `services.yaml` (`branch` kanalı) uygulanmış olmalı:
`kubectl --context kind-internal apply -f internal-cluster/manifests/{internal-authz,services}.yaml`.

## Çalıştırma

```
PYTHONIOENCODING=utf-8 python branch/server.py     # http://127.0.0.1:9100
```

Sunucu `kubectl` ile `keycloak-client-secrets` secret'ını okur (branch-app secret'ı ve teller parolası yalnız bellekte).

## Akış

```
tarayıcı -> branch/server.py -(cihaz sertifikası)-> teller.lab.local (edge, SNI passthrough)
         -> gw-branch (mTLS: branch-ca) -> /bff/* ext-authz (branch) -> token exchange (dmz-exchange-branch)
         -> iç gateway (mTLS: DMZ kimliği, RBAC x-channel=branch) -> BFF (channel=branch, auth_method=branch_cert)
```

## Arayüz

| Düğme | Beklenen | Anlamı |
|---|---|---|
| Giriş yap | token alındı | Keycloak PKCE (branch-app), kullanıcı `teller` |
| Hesapları listele | 200 | `/bff/accounts`, iç servis `channel=branch` görür |
| Cihaz sertifikasız bağlan | TLS red | Gateway istemci sertifikası ister |
| Token yok | 401 | ext-authz bearer ister |
| /partner'a yönlendirme | 404 | Şube gateway'inde `/partner` yok |
| public yol | 404 | Şube gateway'inde `/public` yok |
| Çıkış yap | 204 | Refresh token iptali |

## Test

- `bash dmz-cluster/tests/branch.sh` — 9 kontrol (TLS red, login route, 401, 200 + iç servis alanları, web token 403, 404'ler).
- `run-all.sh` içinde de çalışır.

## Lab sınırları

- Cihaz sertifikası tek bir iş istasyonu için (`branch-ws-01`). Şube başına cihaz kaydı ve sertifika yaşam döngüsü yok (prod: Vault PKI, kısa ömür).
- Çalışan kimliği Keycloak'taki yerel `teller` kullanıcısı. Prod: kurumsal dizin federasyonu.
- Şube CA'sının özel anahtarı `edge/certs/` içinde (git'e girmez). Prod: HSM/KMS.
- Şube arayüzü (`branch/server.py`) iş istasyonunun yerine geçer; gerçek bir istemci değildir.
