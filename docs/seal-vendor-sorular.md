# Seal vendor'a sorular (cihaz kaydı, PIN, aktivasyon)

Amaç: Lab'da Seal Intranet ve Seal Mobile'ın davranışını (mock) gerçek ürünle karşılaştırmak ve prod sözleşmesini netleştirmek. Bu doküman yalnızca soru listesidir; lab'a ait sır veya kişisel veri içermez.

## Mevcut lab tasarımı (karşılaştırma için)

- Cihaz kaydı ve durumu (`PENDING`, `ACTIVE`, `LOCKED`, `REVOKED`) Seal'de tutulur. Sahip (`ownerId`), cihaz (`deviceId`) ve durum alanları vardır.
- `update-device`: sahip, cihaz ve durumu yazar. Durum verilmezse korunur.
- `get-device`: cihaz durumunu okur (lab'da eklendi; vendor sözleşmesinde yoksa karşılığı sorulur).
- PIN doğrulaması Fortuna monolitindedir: `pin/set` ve `pin/verify`. Kilit 5 yanlış denemede, geçerlilik 90 gündür.
- Yeni cihaz akışı: `NEW_DEVICE` → cihaz imzası ile `PIN_AUTHORIZED` → OTP ve müşteri doğrulaması → `activation-api/create-activation-token` → `get-activation-status` `ACTIVATED` → cihaz `ACTIVE`.
- Seal Intranet lab'da kayıtları bellekte tutar; yeniden başlatmada kayıtlar kaybolur.

## Sorular

### 1. Cihaz kaydı ve durumu
1. Cihaz kaydı ve durumunun tek kaynağı Seal midir? Dış bir sistemden gelen durumu kabul ediyor musunuz?
2. `updateDevice` üründe hangi alanları kabul eder ve saklar? Zorunlu alanlar nelerdir?
3. Cihaz durumu okuma (`get-device` veya eşdeğeri) ürünün sözleşmesinde var mı? Yoksa sorgulama nasıl yapılır?
4. Cihaz durum geçişleri (`PENDING` → `ACTIVE` → `LOCKED` / `REVOKED`) ürün tarafından mı zorlanır, yoksa çağıran sorumlu mu?

### 2. PIN
5. PIN'i Seal kendi içinde mi doğrular, yoksa dış bir doğrulayıcıya (bizde Fortuna monolitinde) çağrı yapmasını mı bekler?
6. Kilit eşiği (yanlış deneme sayısı), kilit süresi ve kilit açma yetkisi ürünün politikası mıdır, yoksa yapılandırılabilir mi?
7. PIN geçerlilik süresi ve süre dolumunda beklenen durum (`PIN_EXPIRED` benzeri) nedir?
8. PIN'in taşıma hash'i (lab: `sha256(pin)`) ürünün beklediği format mı?

### 3. Aktivasyon ve akış durumları
9. `NEW_DEVICE`, `PIN_OK`, `PIN_AUTHORIZED`, `SEAL_AUTHORIZED` ve `PIN_LOCKED` durumlarının anlamları ve geçiş kuralları nelerdir?
10. Aktivasyonu tamamlayan koşul nedir? Lab'da: cihaz imzası ile yetkilendirme ve müşteri OTP'si. Ürün bu koşulu nasıl tanımlar?
11. `create-activation-token` ve `get-activation-status` uçlarının istek/yanıt sözleşmesi nedir? Token geçerlilik süresi nedir?

### 4. Kalıcılık, güvenlik ve entegrasyon
12. Seal'in kayıtları (cihaz, PIN, durum) ürün tarafından kalıcı mı tutulur? Yedekleme ve yeniden başlatma davranışı nedir?
13. Seal'e erişim için beklenen kimlik doğrulama nedir (mTLS, bearer, IdP entegrasyonu)? Cihaz sertifikası (device CA) ürünün sözleşmesinde bir gereklilik mi?
14. Seal Mobile ↔ IdP introspection ve Seal Intranet ↔ IdP JWKS için ürünün beklentisi nedir?
15. Ürünün denetim kaydı (audit) ve olay bildirimi (SIEM) özellikleri nelerdir?

## Yanıt sonrası

Yanıtlar geldiğinde `docs/servisler.md` ve `design.md`'deki D-13 kararı ile lab mock'ları karşılaştırılır; farklılıklar listelenir. Vendor'ın `get-device` gibi lab'a özgü uçları sözleşmede yoksa, Janus ve monolitin cihaz kontrolü bu sözleşmeye göre yeniden tasarlanır.
