# Şube (branch) cluster'ı ve veznedar arayüzü

Banka şubelerindeki çalışan iş istasyonlarının merkez sistemlere erişimi. Tasarım: `design.md` 4.7. **Yalnız lab.**

## Mimari

Şube trafiği HAProxy'den geçmez. Şube UI, kendi cluster'ı olan `kind-branch` içinde bir pod olarak çalışır ve gw-branch'e WAN benzeri bağlantıyla (DMZ NodePort 30449) cihaz sertifikasıyla mTLS bağlanır. Lab'da WAN, kind ağı ile simüle edilir. Bağlantı F10 güvenlik duvarı ile sınırlanır (yalnız şube cluster'ının node IP'leri).

```
tarayıcı (host, 127.0.0.1:9100)
  -> şube UI pod (kind-branch, ns branch)
  -> WAN -> gw-branch (DMZ, NodePort 30449, F10, mTLS: branch-ca)
  -> /bff/* ext-authz (branch) -> token exchange (dmz-exchange-branch)
  -> iç gateway (mTLS: DMZ kimliği, RBAC x-channel=branch) -> BFF (channel=branch, auth_method=branch_cert)
```

## Kurulum

Tam kurulumda (`bash up.sh`) adım 6 olarak otomatik çalışır. Tek başına:

```
bash edge/scripts/gen-branch-certs.sh          # branch-ca, gw-branch, dmz-exchange-branch, branch-device
bash identity-cluster/scripts/setup-realm.sh   # branch-app client, dmz-exchange-branch, teller kullanıcısı
bash dmz-cluster/scripts/load-extauth.sh       # ext-authz: branch profili ve exchange sertifikası
bash dmz-cluster/scripts/load-branch.sh        # gw-branch gateway, secret'lar, ConfigMap'ler
bash branch-cluster/scripts/up.sh              # kind-branch, şube UI pod'u, secret'lar, F10
```

`branch-cluster/scripts/up.sh`:
1. `kind-branch` cluster'ını oluşturur (host `127.0.0.1:9100` → pod 30900).
2. `python:3.12-alpine` imajını kind node'larına yükler.
3. Secret'ları oluşturur: `branch-device-tls` (cihaz sertifikası, internal-ca) ve `branch-app-secrets` (identity'den `branch-app` secret'ı ve `teller` parolası; repo'da tutulmaz).
4. ConfigMap `branch-code`: `server.py`, `probe.py`, `index.html`.
5. `BRANCH_GW_HOST` değerini bir DMZ node IP'sine ayarlar.
6. `dmz-cluster/scripts/host-firewall.sh` çalıştırarak F10 kuralını şube node IP'lerine açar.

## Çalıştırma

Şube UI'a tarayıcıdan: **http://127.0.0.1:9100**

Pod'un logları: `kubectl --context kind-branch -n branch logs deploy/branch-ui`

Host'ta (kind olmadan, geliştirme amaçlı) `branch/server.py` çalıştırılabilir. Bu durumda `BRANCH_GW_HOST` ve `BRANCH_GW_PORT` ayarlanmalıdır; secret'lar `kubectl` ile identity'den okunur.

## Ortam değişkenleri

| Değişken | Varsayılan | Açıklama |
|---|---|---|
| `BRANCH_GW_HOST` | `127.0.0.1` | gw-branch'in erişildiği DMZ node IP'si (pod'da `up.sh` ayarlar) |
| `BRANCH_GW_PORT` | `30449` | gw-branch NodePort |
| `BRANCH_CERT_DIR` | `edge/certs` | Cihaz sertifikası ve internal-ca (pod'da `/certs`) |
| `BRANCH_LISTEN` | `127.0.0.1` | Dinleme adresi (pod'da `0.0.0.0`) |
| `BRANCH_APP_SECRET`, `TELLER_PASSWORD` | yok | Pod'da `branch-app-secrets` secret'ından gelir; yoksa kubectl ile okunur |

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

- `bash dmz-cluster/tests/branch.sh`: 9 kontrol (TLS red, login route, 401, 200 + iç servis alanları, web token 403, 404'ler). Test istekleri şube pod'undan `kubectl exec` ile gider (`branch/probe.py`).
- `run-all.sh` içinde de çalışır.
- Tarayıcı testi (arayüz düğmeleri) ayrıca yapılmalı; bu README'deki beklenen sonuçlar henüz tarayıcıda doğrulanmadı.

## Lab sınırları

- Cihaz sertifikası tek bir iş istasyonu için (`branch-ws-01`). Şube başına cihaz kaydı ve sertifika yaşam döngüsü yok (prod: Vault PKI, kısa ömür).
- Çalışan kimliği Keycloak'taki yerel `teller` kullanıcısı. Prod: kurumsal dizin federasyonu (AD/LDAP).
- Şube CA'sının özel anahtarı `edge/certs/` içinde (git'e girmez). Prod: HSM/KMS.
- WAN lab'da kind ağı ile simüle edilir. Prod'da şube ile DMZ arasında gerçek WAN, şube edge'i ve ayrı firewall (F10) olur.
- Şube UI bir gerçek istemci değildir; iş istasyonunun yerine geçer.
