# Cihaz güven servisi (örnek, Seçenek A)

Mobil SDK, jailbreak/root veya attestation sinyalini **cihaz sertifikasıyla (mTLS)** bu servise gönderir. Servis, istemci sertifikasını **kendisi** doğrular; DMZ TLS'i açmaz.

## Akış

```
Mobil SDK (cihaz anahtarı)
  │  mTLS (TLS passthrough, DMZ TLS'i açmaz)  device-api.lab.local
  ▼
HAProxy (L4, SNI passthrough)  ──► DMZ gateway (TLSRoute passthrough)  ──► internal gateway (TLSRoute)
                                                                              │
                                                                              ▼
                                              identity: device-trust (CERT_REQUIRED, cihaz CA)
                                                                              │
                                                                              ▼
                                              risk kararı → IdP/ext-authz (ileride: risk claim'i)
```

DMZ bu akışta yalnızca bayt taşır; sertifika, anahtar ve karar tutmaz.

## Bu örnekte olanlar (doğrulandı)

| Parça | Dosya | Durum |
|---|---|---|
| Cihaz CA + sunucu + cihaz sertifikaları | `edge/scripts/gen-device-certs.sh` | Çalışıyor |
| Servis (stdlib, mTLS doğrulaması) | `identity-cluster/device-trust/server.py` | Çalışıyor |
| Yerel mTLS testleri (8 senaryo) | `identity-cluster/device-trust/tests/mtls_test.py` | 8/8 geçti |
| Kümede dağıtım | `identity-cluster/manifests/device-trust.yaml`, `scripts/load-device-trust.sh` | Çalışıyor (`devtrust` ns) |
| Kümede mTLS isteği | port-forward üzerinden | Geçerli cihaz 200; sertifikasız ve sahte CA reddedildi |

## Henüz doğrulanmamış (kümede)

1. **DMZ passthrough:** Aşağıdaki gateway TLSRoute'un kullandığımız kgateway sürümünde desteklendiği doğrulanmalı (Gateway API `TLSRoute` deneysel kanalda olabilir). Partner yolu bugün DMZ'de **Terminate** ediyor (Seçenek B); bu örnek farklı.
2. **HAProxy passthrough:** Aşağıdaki stanza `edge/haproxy/haproxy.cfg.tpl`'e eklenmedi; eklenip `haproxy -c` ile doğrulanmalı.
3. **İç yol:** `devtrust` servisine internal gateway üzerinden erişim için identity-idp deseni (Service + Endpoints) gerekir; henüz yok.
4. **Attestation:** Apple App Attest / Google Play Integrity doğrulanmıyor; olay olarak kaydediliyor (lab sınırı).
5. **İptal:** `DT_REVOKED` dosyası elle yönetiliyor; otomatik CRL/OCSP yok.

## HAProxy örneği (eklenmedi)

```haproxy
# frontend fe_public içine (partner stanza'sının yanına)
use_backend be_device_pt if { req.ssl_sni -i device-api.lab.local }

backend be_device_pt
    mode tcp
    # DMZ gateway passthrough NodePort (örnek port; kümede tanımlanmalı)
    server dmz-worker __DMZ_NODE_IP__:30450 check
```

## DMZ / internal gateway örneği (uygulanmadı)

```yaml
# DMZ: TLS passthrough dinleyici + TLSRoute (örnek)
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: gw-device, namespace: gw-device}
spec:
  gatewayClassName: kgateway
  listeners:
    - name: tls-passthrough
      port: 443
      protocol: TLS
      tls:
        mode: Passthrough
      allowedRoutes: {namespaces: {from: Same}}
---
apiVersion: gateway.networking.k8s.io/v1alpha2   # kanal ve sürüme göre değişir
kind: TLSRoute
metadata: {name: device, namespace: gw-device}
spec:
  parentRefs: [{name: gw-device}]
  hostnames: [device-api.lab.local]
  rules:
    - backendRefs: [{name: internal-gw, port: 443}]
```

## Güvenlik notları

- Servis yalnızca `CERT_REQUIRED` ile çalışır; sertifikasız veya başka CA'dan istemci TLS aşamasında reddedilir.
- Cihaz sertifikası SDK'ya **gömülmemeli**; cihaz içinde üretilen anahtar (Secure Enclave / Keystore) ve kayıt (enrollment) ile verilmeli. Lab'daki sertifikalar bu yüzden test içindir.
- Kişisel veri (cihaz kimliği) log'a yazılmıyor; prod'da saklama süresi ve KVKK/GDPR uyumu ayrıca tasarlanmalı.
