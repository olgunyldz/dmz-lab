# DMZ lab test konsolu

Web, mobil, partner ve public senaryolarını tarayıcıdan çalıştırıp beklenen ve gerçek HTTP kodlarını karşılaştırmak için yerel bir test arayüzü. **Yalnız lab.**

## Çalıştırma

Ön koşullar: edge ayakta (`cd edge && docker compose up -d`), DMZ / iç / identity / mgmt cluster'ları kurulu, `kubectl` erişimi var, `openssl` PATH'te.

```
python console/server.py     # PYTHONIOENCODING=utf-8 önerilir (Windows konsolu)
```

Sonra tarayıcıda: http://127.0.0.1:9000

Sunucu başlarken iki şey yapar:
1. `kubectl` ile `keycloak-client-secrets` secret'ını okur (client secret'ları ve lab test parolası yalnız bellekte).
2. Identity Keycloak'a `kubectl port-forward` açar (127.0.0.1:18080), kapanışta sonlandırır.

## Senaryolar

| Kanal | Akış | Beklenen |
|---|---|---|
| Web | Giriş (PKCE, Bearer) → `/bff/accounts` | 200 |
| Web | Web token'ı `/partner/payments` üzerinde | 403 (audience) |
| Web | Çıkış | Keycloak 204 |
| Mobil | Giriş (PKCE + ES256 DPoP) → `/bff/accounts` + DPoP | 200 |
| Mobil | Aynı çağrı, DPoP yok | 401 (`missing dpop proof`) |
| Partner | Token (client credentials, mTLS) → `/partner/payments` | 200 |
| Partner | Token yok | 401 |
| Public | `GET /public/*` (web, mobil) | 200 |
| Public | `POST /public/*` | 404 |
| Public | `/bff/*` token yok | 401 |

Her düğme bir satır log yazar: istek, kullanılan auth, beklenen kod, gerçek kod, PASS/FAIL ve yanıtın kısa hali.

## Bilinçli sınırlar (lab)

- **Mobil login identity port-forward üzerinden:** Keycloak DPoP `htu` değerini kendi gördüğü URL ile karşılaştırır. Edge üzerinden `id.bank.lab.local` hostname'i henüz yönlendirilmiyor; bu yüzden login adımı identity'ye gider. Servis çağrıları (`/bff`, `/partner`, `/public`) yine edge üzerinden geçer.
- **Web login edge üzerinden** (DMZ `/realms` route'u).
- **Parola:** Parola alanı boşsa lab test kullanıcısının (`alice`) parolası kullanılır. Hiçbir parola diske yazılmaz.
- **Token gösterimi:** Ham token tarayıcıya gönderilmez; yalnız claim özeti (iss, aud, azp, channel, cnf varlığı, exp) gösterilir. İmza bu konsolda doğrulanmaz.
- **Geçici DPoP anahtarları:** Mobil oturum anahtarları sistem geçici dizininde tutulur; çıkışta silinmez (lab).
- **Logout ve eski access token (ölçüldü):** Çıkıştan sonra eski access token ile `/bff/accounts` çağrısı **403** döner. ext-authz her istekte token exchange yaptığı için Keycloak, kapanmış kullanıcı oturumuna ait token'ı exchange'de reddeder. Yani dış token çıkışla fiilen geçersiz olur. İç token (exchange ile üretilmiş) ise kendi `exp`'ine kadar geçerlidir; bu süre design.md'deki iç token TTL'iyle sınırlıdır.
- **Mobil çıkış:** DPoP'a bağlı refresh token için `/logout` ucu DPoP'u kabul etmediği için (`invalid_grant`), konsol refresh token'ı `/revoke` ucu ile iptal eder (DPoP proof'uyla, 200).

## Güvenlik notu

Sunucu yalnız `127.0.0.1:9000`'e bağlanır. Cookie `HttpOnly; SameSite=Strict`. Bu konsol prod'da kullanılmaz; test kullanıcısı ve client secret'ları yalnız lab içindir.
