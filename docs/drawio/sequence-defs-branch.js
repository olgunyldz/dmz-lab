// Şube (branch) sequence tanımı. sequence-defs.js ile birlikte gen-sequence.js tarafından okunur.
// Şube trafiği HAProxy'den geçmez: cihaz mTLS ile doğrudan gw-branch (F10), token exchange ext-authz'de.
const EXT = "#FFFFFF", DMZ = "#FFEDD5", INT = "#DBEAFE", ID = "#EDE9FE", BR = "#CCFBF1";

module.exports = [
  {
    name: "7 Şube (doğrudan gw-branch, exchange)",
    title: "7) Şube: cihaz mTLS ile doğrudan gw-branch (HAProxy yok) → ext-authz token exchange → iç BFF",
    participants: [
      { id: "u", label: "Şube UI pod (veznedar)\n[şube cluster]", color: BR },
      { id: "gw", label: "kgateway gw-branch\n[DMZ]", color: DMZ },
      { id: "ea", label: "ext-authz (branch)\n[DMZ auth]", color: DMZ },
      { id: "gi", label: "kgateway internal\n[iç]", color: INT },
      { id: "kc", label: "Keycloak\n[identity]", color: ID },
      { id: "bff", label: "BFF app-bff\n[iç]", color: INT },
    ],
    messages: [
      { from: "u", to: "gw", label: "1. WAN üzerinden HTTPS 30449 (F10, HAProxy yok), TLS: cihaz sertifikası branch-device" },
      { from: "gw", to: "gw", self: true, label: "2. Frontend mTLS: cihaz zinciri branch-ca ile doğrulanır" },
      { from: "gw", to: "ea", label: "3. ext-authz: X-Dmz-Channel=branch, Authorization: Bearer <dış token>" },
      { from: "ea", to: "ea", self: true, label: "4. Dış token: RS256 (JWKS), aud=channel-branch, exp" },
      { from: "ea", to: "gi", label: "5. token exchange (mTLS: CN=dmz-exchange-branch)" },
      { from: "gi", to: "kc", label: "6. /realms/bank/.../token grant=token-exchange (XFCC: dmz-exchange-branch)" },
      { from: "kc", to: "kc", self: true, label: "7. client-x509 doğrula; channel=branch, auth_method=branch_cert; iç JWT üret" },
      { from: "kc", to: "gi", ret: true, internalToken: true, label: "8. iç JWT (aud=kgateway-internal, channel=branch)" },
      { from: "gi", to: "ea", ret: true, internalToken: true, label: "9. iç JWT" },
      { from: "ea", to: "gw", ret: true, internalToken: true, label: "10. 200 + iç JWT (dış token iç ağa gitmez)" },
      { from: "gw", to: "gi", internalToken: true, label: "11. GET /bff/accounts + iç JWT (mTLS: DMZ kimliği)" },
      { from: "gi", to: "gi", self: true, label: "12. RBAC: x-channel == branch; /partner ve /public bu kanalda 404" },
      { from: "gi", to: "bff", internalToken: true, label: "13. forwardToken: iç JWT" },
      { from: "bff", to: "bff", self: true, label: "14. iç JWT'yi kendisi doğrular; teller görünümü" },
      { from: "bff", to: "gi", ret: true, label: "15. 200 service=bff channel=branch user=<sub> (token YOK)" },
      { from: "gi", to: "gw", ret: true, label: "16. 200" },
      { from: "gw", to: "u", ret: true, label: "17. 200 (şube ekranı)" },
    ],
    footer: [
      "KONTROLLER: K1 cihaz sertifikası olmayan istek TLS aşamasında reddedilir. K2 dış token iç ağa gitmez; iç token istemciye dönmez.",
      "K3 şube CA'sı (branch-ca) yalnız gw-branch'te; iç ağa güven vermez. K4 iç RBAC: şube token'ı yalnız /bff ve x-channel=branch.",
      "LAB → PROD: branch-ca HSM/KMS, cihaz sertifikası kısa ömürlü (Vault PKI), çalışan kimliği AD/LDAP, F10 şube edge'inde.",
      "LAB: şube UI branch cluster pod'u; teller.lab.local HAProxy'den çıkarıldı. Bağlantı kind ağı üzerinden gw-branch:30449 (WAN benzeri, F10).",
    ],
  },
];
