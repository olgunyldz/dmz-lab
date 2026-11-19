# DMZ lab konsolu (web ve mobil)

Web ve mobil kanal akışlarını tarayıcıdan çalıştırmak için yerel bir arayüz. **Yalnız lab.**

## Çalıştırma

Ön koşullar: edge ayakta (`cd edge && docker compose up -d`), bank-prod (auth-server, Fortuna, channel-gateway), bank-dmz-prod (Janus), codevo-dmz (Seal Mobile) kurulu, `kubectl` erişimi, `openssl` PATH'te.

Repo kökünden:

```
bash console/start.sh
```

Sonra tarayıcıda: http://127.0.0.1:9000

Sunucu başlarken iki şey yapar:
1. `kubectl` ile bank-prod `auth-secrets` secret'ından alice parolasını okur. Yalnız bellekte tutulur, tarayıcıya gönderilmez.
2. bank-prod `auth-server` için `kubectl port-forward` açar (127.0.0.1:18443). Kapanışta sonlandırılır.

Kanal uçları edge üzerinden (`127.0.0.1:8443`, SNI/Host): Janus `web.lab.local` ve `mobile-api.lab.local`, Seal `seal.lab.local`.

## Akışlar

| Kanal | Adımlar | Sonuç |
|---|---|---|
| Web | Müşteri no + parola → OTP iste (lab: kod ekranda) → SMS kodu → giriş → bakiye | Client token; `BALANCE` 200 |
| Mobil | PIN → IdP (`mobile-app`, PKCE) → Seal PIN ve cihaz imzası → secure-login → mobile-login → bakiye | Client token; `BALANCE` 200 |
| Mobil (yeni cihaz) | Yeni cihaz kimliği → Seal PIN + imza → OTP + parola (login-user) → aktivasyon (ACTIVE) → PIN kaydı → normal mobil giriş → bakiye | Client token; `BALANCE` 200 |

Web'de Seal yoktur. Mobilde cihaz sertifikası her girişte geçici dizinde device CA ile üretilir ve silinir. Cihaz kimliği tarayıcı oturumunda tutulur: yeni cihazla aktive edilen cihaz, çıkıştan sonra da aynı oturumda "Yeni cihaz" kutusu işaretlenmeden kullanılabilir. Oturumda cihaz yoksa (yeni tarayıcı) önce yeni cihazla aktive edilmelidir. "İlk kez kurulum" kutusu PIN'i cihaza yeniden tanımlar (lab).

İşlem (`BALANCE`) her zaman client token ile `/janus/transaction` üzerinden gider. Janus içeri giderken server token üretir ve channel-gateway'e iletir.

## Bilinen sınırlar (lab)

- Yeni cihaz her seferinde yeni bir cihaz kimliğiyle (`mob-…`) aktive edilir ve LegacyDB'de kalır (lab).
- Client token (15 dk) ve splash (15 dk) dolunca konsol yenileme token'ı ile (8 saat, tek kullanımlık, her yenilemede döner) otomatik yeniler. Yenileme token'ı da geçersizse "oturum süresi doldu" mesajıyla yeniden giriş gerekir.
- Mobil yenilemede cihaz durumu kontrol edilir: iptal edilmiş ya da kilitli cihaz yenileme yapamaz. Müşteri durumu yenilemede kontrol edilmez (lab sınırı).
- PIN durumları Türkçe mesajla gösterilir: hatalı, kilitli, süresi dolmuş (`PIN_MESSAGES`). Yalnız "hatalı" durumu canlı test edildi; kilit ve süre dolumu eşleme olarak tanımlı, uçtan uca denenmedi.
- OTP lab'da SMS ile gönderilmez; kod yanıtta döner (demo).
- Captcha değeri `lab-captcha` sabittir.
- Token'lar tarayıcıya gönderilmez. İşlem yanıtları Janus ve channel-gateway'den gelen JSON'dur.
- Her mobil girişte IdP'de yeni bir oturum açılır.

## Güvenlik notu

Sunucu yalnız `127.0.0.1:9000`'e bağlanır. Oturum çerezi `HttpOnly; SameSite=Strict`. Parola ve token'lar diske yazılmaz. Cihaz sertifikası yalnız geçici dizinde üretilir ve giriş bitince silinir. Bu konsol prod'da kullanılmaz.
