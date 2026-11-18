package dev.dmzlab.idp.auth;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.ObjectMapper;
import tools.jackson.databind.node.ObjectNode;

import javax.naming.InvalidNameException;
import javax.naming.ldap.LdapName;
import javax.naming.ldap.Rdn;
import java.security.cert.X509Certificate;
import java.time.Duration;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * Mobil kimlik süreçleri için iç API (core mobile işlevi, identity cluster içinde).
 * Çağıran: seal-mobile (DMZ, gw-internal üzerinden mTLS). Yetkilendirme: istemci sertifikasının CN'i allowlist'te olmalı.
 * Düz HTTP yoktur: uç yalnız HTTPS portunda (8443) tanımlıdır ve sertifika olmadan 401 döner.
 */
@RestController
@RequestMapping("/internal/auth")
class InternalAuthController {

    static final String CERT_ATTR = "jakarta.servlet.request.X509Certificate";
    private static final Pattern USERNAME = Pattern.compile("^[a-z][a-z0-9_]{2,31}$");

    private final AuthStateRepository state;
    private final SealIntranetClient seal;
    private final Set<String> allowedCallers;
    private final boolean demoOtp;
    private final ObjectMapper mapper = new ObjectMapper();

    InternalAuthController(AuthStateRepository state, SealIntranetClient seal,
                           @Value("${idp.internal.allowed-clients}") String allowedCallers,
                           @Value("${idp.auth.demo-otp:true}") boolean demoOtp) {
        this.state = state;
        this.seal = seal;
        this.allowedCallers = Set.of(allowedCallers.split(","));
        this.demoOtp = demoOtp;
    }

    /** Yeni cihaz: PIN doğrulandı ama cihaz kayıtlı değil. OTP üretilir (SMS yok; demo'da yanıtta döner). */
    @PostMapping("/device/new")
    ResponseEntity<Map<String, Object>> newDevice(@RequestBody Map<String, String> body, HttpServletRequest req) {
        if (!callerAllowed(req)) return unauthorized();
        String user = body.getOrDefault("username", "");
        String flow = body.getOrDefault("flowId", "");
        if (!USERNAME.matcher(user).matches() || flow.isBlank()) return bad("username ve flowId gerekli");
        if (!state.allow("otp:" + user, 20, Duration.ofMinutes(10))) {  // kullanıcı başına yeni cihaz/OTP talebi
            return error(HttpStatus.TOO_MANY_REQUESTS, "çok fazla OTP isteği");
        }
        String code = state.newOtp(flow, user);
        Map<String, Object> out = new HashMap<>();
        out.put("status", "OTP_REQUIRED");
        if (demoOtp) out.put("demoOtp", code);
        return ResponseEntity.ok(out);
    }

    @PostMapping("/otp/verify")
    ResponseEntity<Map<String, Object>> verifyOtp(@RequestBody Map<String, String> body, HttpServletRequest req) {
        if (!callerAllowed(req)) return unauthorized();
        String user = body.getOrDefault("username", "");
        String flow = body.getOrDefault("flowId", "");
        if (!state.allow("otpverify:" + user, 30, Duration.ofMinutes(10))) {  // kullanıcı başına OTP doğrulama denemesi
            return error(HttpStatus.TOO_MANY_REQUESTS, "çok fazla doğrulama denemesi");
        }
        switch (state.verifyOtp(flow, user, body.getOrDefault("code", ""))) {
            case OK -> {
                state.markPending(user); // yeni cihaz: aktivasyon tamamlanana kadar token'lar kısıtlı
                return ResponseEntity.ok(Map.of("status", "OTP_OK", "activationRequired", true));
            }
            case WRONG -> {
                return error(HttpStatus.UNAUTHORIZED, "OTP yanlış");
            }
            case LOCKED -> {
                return error(HttpStatus.LOCKED, "OTP kilitlendi");
            }
            default -> {
                return error(HttpStatus.NOT_FOUND, "OTP isteği yok veya süresi doldu");
            }
        }
    }

    /** Seal Mobile akış güncellemesi: PIN sonucu (PIN_OK, NEW_DEVICE, PIN_EXPIRED, PIN_LOCKED, PIN_AUTHORIZED, ...). */
    @PostMapping("/flow/update")
    ResponseEntity<Map<String, Object>> flowUpdate(@RequestBody Map<String, Object> body, HttpServletRequest req) {
        if (!callerAllowed(req)) return unauthorized();
        String user = String.valueOf(body.getOrDefault("username", ""));
        String flow = String.valueOf(body.getOrDefault("flowId", ""));
        String status = String.valueOf(body.getOrDefault("status", ""));
        if (!USERNAME.matcher(user).matches() || flow.isBlank() || status.isBlank()) return bad("username, flowId, status gerekli");
        state.putFlow(flow, user, status, Boolean.TRUE.equals(body.get("newDevice")));
        return ResponseEntity.ok(Map.of("status", "ok"));
    }

    /** Login durumu: IdP'deki akış kaydı; PIN_AUTHORIZED ise oturum zamanı (Seal create-timestamp). */
    @PostMapping("/login/status")
    ResponseEntity<Map<String, Object>> loginStatus(@RequestBody Map<String, String> body, HttpServletRequest req) {
        if (!callerAllowed(req)) return unauthorized();
        String user = body.getOrDefault("username", "");
        String flow = body.getOrDefault("flowId", "");
        var rec = state.flow(flow);
        if (rec.isEmpty()) return error(HttpStatus.NOT_FOUND, "flow bulunamadı");
        if (!user.equals(rec.get().get("username"))) return error(HttpStatus.FORBIDDEN, "flow bu kullanıcıya ait değil");
        String status = String.valueOf(rec.get().get("status"));
        Map<String, Object> out = new HashMap<>();
        out.put("status", status);
        out.put("newDevice", Boolean.TRUE.equals(rec.get().get("new_device")));
        out.put("restricted", state.isPending(user));
        if ("PIN_AUTHORIZED".equals(status)) {
            try {
                SealIntranetClient.SealResponse ts = seal.call("timestamp-api/create-timestamp",
                        mapper.createObjectNode().put("flowId", flow));
                out.put("timestamp", ts.body().path("timestamp").asLong(0));
            } catch (java.io.IOException | InterruptedException e) {
                return error(HttpStatus.BAD_GATEWAY, "Seal Intranet erişilemedi");
            }
        }
        return ResponseEntity.ok(out);
    }

    @PostMapping("/activation/token")
    ResponseEntity<Map<String, Object>> activationToken(@RequestBody Map<String, String> body, HttpServletRequest req) {
        if (!callerAllowed(req)) return unauthorized();
        String user = body.getOrDefault("username", "");
        if (!USERNAME.matcher(user).matches()) return bad("username gerekli");
        try {
            ObjectNode payload = mapper.createObjectNode();
            payload.put("ownerId", user);
            payload.putObject("userIdentifiers");
            payload.put("pinRequestType", "NEW");
            SealIntranetClient.SealResponse st = seal.call("activation-api/create-activation-token", payload);
            if (st.status() != 200) return error(HttpStatus.valueOf(st.status()), "aktivasyon token'ı üretilemedi");
            String token = text(st.body(), "activationToken");
            state.createActivation(token, user);
            return ResponseEntity.ok(Map.of("activationToken", token));
        } catch (java.io.IOException | InterruptedException e) {
            return error(HttpStatus.BAD_GATEWAY, "Seal Intranet erişilemedi");
        }
    }

    /** Seal Mobile aktivasyonu tamamladı (cihaz PIN kaydı + SDK aktivasyonu): kullanıcının kısıtı kalkar. */
    @PostMapping("/activation/complete")
    ResponseEntity<Map<String, Object>> activationComplete(@RequestBody Map<String, String> body, HttpServletRequest req) {
        if (!callerAllowed(req)) return unauthorized();
        String token = body.getOrDefault("activationToken", "");
        var owner = state.activationOwner(token);
        if (owner.isEmpty()) return error(HttpStatus.NOT_FOUND, "aktivasyon token'ı yok");
        state.setActivationStatus(token, "ACTIVATED");
        state.clearPending(owner.get());
        return ResponseEntity.ok(Map.of("status", "ACTIVATED", "restricted", false));
    }

    /** Aktivasyon durumu (IdP kaydı). */
    @PostMapping("/activation/status")
    ResponseEntity<Map<String, Object>> activationStatus(@RequestBody Map<String, String> body, HttpServletRequest req) {
        if (!callerAllowed(req)) return unauthorized();
        String token = body.getOrDefault("activationToken", "");
        var owner = state.activationOwner(token);
        if (owner.isEmpty()) return error(HttpStatus.NOT_FOUND, "aktivasyon token'ı yok");
        String status = state.activationStatus(token).orElse("PENDING");
        return ResponseEntity.ok(Map.of("status", status, "restricted", state.isPending(owner.get())));
    }

    // --- yardımcılar ---

    /** İstemci sertifikasının CN'i allowlist'te mi? (Tomcat mTLS: certificateVerification=optional; yoksa reddet.) */
    /** Seal: cihaz kaydı tamamlandı (enroll). IdP cihazı kullanıcıya bağlı tutar. */
    @PostMapping("/device/register")
    ResponseEntity<Map<String, Object>> deviceRegister(@RequestBody Map<String, Object> body, HttpServletRequest req) {
        if (!callerAllowed(req)) return unauthorized();
        String user = String.valueOf(body.getOrDefault("username", ""));
        String device = String.valueOf(body.getOrDefault("deviceId", ""));
        if (!USERNAME.matcher(user).matches() || device.isBlank()) return bad("username, deviceId gerekli");
        state.registerDevice(user, device);
        return ResponseEntity.ok(Map.of("status", "ok"));
    }

    /** Seal mobil ekranı: cihaza gelen bekleyen web girişi onayları. */
    @PostMapping("/approval/pending")
    ResponseEntity<Map<String, Object>> approvalPending(@RequestBody Map<String, Object> body, HttpServletRequest req) {
        if (!callerAllowed(req)) return unauthorized();
        String user = String.valueOf(body.getOrDefault("username", ""));
        String device = String.valueOf(body.getOrDefault("deviceId", ""));
        if (!USERNAME.matcher(user).matches() || device.isBlank()) return bad("username, deviceId gerekli");
        List<Map<String, Object>> items = new java.util.ArrayList<>();
        for (Map<String, Object> r : state.pendingApprovals(user, device)) {
            items.add(Map.of("approvalId", String.valueOf(r.get("approval_id")),
                    "expiresAt", ((java.sql.Timestamp) r.get("expires_at")).getTime()));
        }
        return ResponseEntity.ok(Map.of("approvals", items));
    }

    /** Seal mobil ekranı: onay kararı (cihaz imzası seal-mobile'da doğrulanmış olmalı). */
    @PostMapping("/approval/decide")
    ResponseEntity<Map<String, Object>> approvalDecide(@RequestBody Map<String, Object> body, HttpServletRequest req) {
        if (!callerAllowed(req)) return unauthorized();
        String user = String.valueOf(body.getOrDefault("username", ""));
        String device = String.valueOf(body.getOrDefault("deviceId", ""));
        String id = String.valueOf(body.getOrDefault("approvalId", ""));
        String decision = String.valueOf(body.getOrDefault("decision", ""));
        if (!USERNAME.matcher(user).matches() || device.isBlank() || id.isBlank()) {
            return bad("username, deviceId, approvalId gerekli");
        }
        if (!decision.equals("APPROVE") && !decision.equals("DENY")) return bad("decision APPROVE veya DENY olmalı");
        if (!state.decideApproval(id, user, device, decision)) {
            return error(HttpStatus.CONFLICT, "onay bulunamadı, süresi doldu veya karara bağlandı");
        }
        return ResponseEntity.ok(Map.of("status", "ok", "decision", decision));
    }

    boolean callerAllowed(HttpServletRequest req) {
        Object attr = req.getAttribute(CERT_ATTR);
        if (!(attr instanceof X509Certificate[] certs) || certs.length == 0) return false;
        String cn = commonName(certs[0].getSubjectX500Principal().getName());
        return cn != null && allowedCallers.contains(cn);
    }

    static String commonName(String dn) {
        try {
            for (Rdn rdn : new LdapName(dn).getRdns()) {
                if ("CN".equalsIgnoreCase(rdn.getType())) return String.valueOf(rdn.getValue());
            }
        } catch (InvalidNameException e) {
            return null;
        }
        return null;
    }

    private static String text(JsonNode node, String field) {
        return node.path(field).asString("");
    }

    private static ResponseEntity<Map<String, Object>> unauthorized() {
        return error(HttpStatus.UNAUTHORIZED, "istemci sertifikası yetkili değil");
    }

    private static ResponseEntity<Map<String, Object>> bad(String message) {
        return error(HttpStatus.BAD_REQUEST, message);
    }

    private static ResponseEntity<Map<String, Object>> error(HttpStatus status, String message) {
        return ResponseEntity.status(status).body(Map.of("error", message));
    }
}
