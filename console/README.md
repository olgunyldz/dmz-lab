# DMZ lab konsolu (Next.js)

Operatör ve demo konsolu. Arayüz React bileşeni (`components/Console.jsx`), sunucu tarafı ise Next.js route handler'ları (`app/api/*`). Tarayıcı DMZ servislerine doğrudan gitmez; yalnız konsol sunucusu, edge (HAProxy, `127.0.0.1:8443`) üzerinden DMZ servislerini çağırır (`lib/edge.js`). **Yalnız lab.**

## Çalıştırma
```
cd console
npm install
npm run dev        # geliştirme sunucusu (http://localhost:9000)
npm run build      # üretim derlemesi
npm run start      # derlenmiş sürümü 9000 portunda çalıştırır
```

Önkoşul: edge (HAProxy) `127.0.0.1:8443` üzerinde çalışıyor olmalı ve `edge/certs/public-ca.crt` mevcut olmalı.

## Yapı
| Yol | Görev |
|---|---|
| `app/[[...slug]]/page.jsx`, `components/Console.jsx` | Ekranlar |
| `app/api/state`, `app/api/sms` | Oturum durumu, lab SMS kutusu |
| `app/api/web/otp`, `app/api/web/login` | Web: tek seferlik kod, giriş (Janus `/janus/otp/request`, `/janus/login-user`) |
| `app/api/transaction` | BALANCE, HISTORY, TRANSFER; 401'de token yenileme ve tekrar deneme |
| `app/api/logout` | Oturumu temizler |
| `lib/edge.js` | Edge'e TLS çağrısı (SNI ve Host başlığı kanal hostu) |
| `lib/janus.js` | Kanal tanımları ve Janus çağrıları |
| `lib/sessions.js` | Sunucu tarafı oturum deposu (`sid` çerezi, httpOnly) |

## Ekranlar
| Adres | Ekran |
|---|---|
| `/` | Kanal kartları |
| `/web` | Web girişi (tek seferlik kod, giriş), sonra hesap işlemleri |
| `/mobil` | Mobil uygulama: cihaz ve PIN, SMS, alt menü, çıkış (**henüz Next.js'e bağlı değil**, aşağıya bakın) |
| `/islemler` | Hesap işlemleri (giriş yapılmış kanal) |
| `/sms` | Lab SMS kutusu (2 sn'de bir yenilenir) |

## Durum
- Web akışı (OTP, giriş, işlemler, çıkış) Next.js route handler'ları üzerinden edge'e bağlanır.
- Mobil akış henüz taşınmadı. Konsolun yalnız DMZ servislerine gitmesi kuralı nedeniyle mobil token, Janus'a eklenecek bir mobil token uç noktasıyla alınacak; o değişiklik onaylandıktan sonra Seal ve yeni cihaz akışı port edilecek.
- Eski Python konsolu (`app.py`) ve Vite demo uygulaması (`ui/`) kaldırılmak üzere; bu README yalnız Next.js sürümünü anlatır.

## Sınırlar
- Demo bankası (tarayıcı içi veri) kaldırıldı; veriler DMZ servislerinden gelir.
- Oturum bilgisi sunucu bellekte tutulur; konsol yeniden başlatılırsa oturumlar düşer.
