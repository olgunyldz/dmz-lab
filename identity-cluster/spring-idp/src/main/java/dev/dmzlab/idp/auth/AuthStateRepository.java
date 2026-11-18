package dev.dmzlab.idp.auth;

import org.springframework.jdbc.core.JdbcOperations;
import org.springframework.stereotype.Component;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.sql.Timestamp;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/**
 * Kimlik durumu kalıcılığı (PostgreSQL): OTP, yeni cihaz bekleyen kullanıcılar, aktivasyon token'ları, throttling.
 * Eşzamanlılık: lab için yeterli (sayaçlar satır bazında basit güncellenir); prod'da atomik upsert gerekir.
 */
@Component
public class AuthStateRepository {

    public enum OtpResult { OK, WRONG, LOCKED, NOT_FOUND, EXPIRED }

    static final long OTP_TTL_SECONDS = 300;
    static final int OTP_MAX_TRIES = 5;

    private static final SecureRandom RANDOM = new SecureRandom();
    private final JdbcOperations jdbc;

    public AuthStateRepository(JdbcOperations jdbc) {
        this.jdbc = jdbc;
    }

    // --- OTP ---

    /** Yeni OTP üretir ve yalnız özetini saklar. Düz kod yalnız dönüş değeridir (demo: yanıtta gösterilir). */
    public String newOtp(String flowId, String username) {
        String code = String.format("%06d", RANDOM.nextInt(1_000_000));
        jdbc.update("DELETE FROM auth_otp WHERE flow_id = ?", flowId);
        jdbc.update("INSERT INTO auth_otp (flow_id, username, code_hash, expires_at, tries) VALUES (?, ?, ?, ?, 0)",
                flowId, username, hash(flowId, code), Timestamp.from(Instant.now().plusSeconds(OTP_TTL_SECONDS)));
        return code;
    }

    public OtpResult verifyOtp(String flowId, String username, String code) {
        List<Map<String, Object>> rows = jdbc.queryForList(
                "SELECT username, code_hash, expires_at, tries FROM auth_otp WHERE flow_id = ?", flowId);
        if (rows.isEmpty() || !username.equals(rows.get(0).get("username"))) {
            return OtpResult.NOT_FOUND;
        }
        Map<String, Object> r = rows.get(0);
        if (Instant.now().isAfter(((Timestamp) r.get("expires_at")).toInstant())) {
            jdbc.update("DELETE FROM auth_otp WHERE flow_id = ?", flowId);
            return OtpResult.EXPIRED;
        }
        int tries = ((Number) r.get("tries")).intValue();
        if (tries >= OTP_MAX_TRIES) {
            return OtpResult.LOCKED;
        }
        byte[] expected = ((String) r.get("code_hash")).getBytes(StandardCharsets.UTF_8);
        if (MessageDigest.isEqual(expected, hash(flowId, code).getBytes(StandardCharsets.UTF_8))) {
            jdbc.update("DELETE FROM auth_otp WHERE flow_id = ?", flowId);
            return OtpResult.OK;
        }
        jdbc.update("UPDATE auth_otp SET tries = tries + 1 WHERE flow_id = ?", flowId);
        return OtpResult.WRONG;
    }

    // --- Yeni cihaz / aktivasyon bekleyen kullanıcılar ---

    public void markPending(String username) {
        jdbc.update("DELETE FROM pending_activation WHERE username = ?", username);
        jdbc.update("INSERT INTO pending_activation (username, since) VALUES (?, ?)", username, Timestamp.from(Instant.now()));
    }

    public boolean isPending(String username) {
        Integer n = jdbc.queryForObject("SELECT COUNT(*) FROM pending_activation WHERE username = ?", Integer.class, username);
        return n != null && n > 0;
    }

    public void clearPending(String username) {
        jdbc.update("DELETE FROM pending_activation WHERE username = ?", username);
    }

    // --- Aktivasyon token'ları ---

    public void createActivation(String activationToken, String username) {
        jdbc.update("INSERT INTO device_activation (activation_token, username) VALUES (?, ?)", activationToken, username);
    }

    public void setActivationStatus(String activationToken, String status) {
        jdbc.update("UPDATE device_activation SET status = ? WHERE activation_token = ?", status, activationToken);
    }

    public Optional<String> activationStatus(String activationToken) {
        List<String> rows = jdbc.queryForList(
                "SELECT status FROM device_activation WHERE activation_token = ?", String.class, activationToken);
        return rows.stream().findFirst();
    }

    public Optional<String> activationOwner(String activationToken) {
        List<String> owners = jdbc.queryForList(
                "SELECT username FROM device_activation WHERE activation_token = ?", String.class, activationToken);
        return owners.stream().findFirst();
    }

    // --- Login akış durumu (Seal Mobile bildirir) ---

    public void putFlow(String flowId, String username, String status, boolean newDevice) {
        jdbc.update("DELETE FROM auth_flow WHERE flow_id = ?", flowId);
        jdbc.update("INSERT INTO auth_flow (flow_id, username, status, new_device, updated_at) VALUES (?, ?, ?, ?, ?)",
                flowId, username, status, newDevice, Timestamp.from(Instant.now()));
    }

    /** Akış: (kullanıcı, durum, yeni cihaz). Yoksa boş. */
    public Optional<Map<String, Object>> flow(String flowId) {
        List<Map<String, Object>> rows = jdbc.queryForList(
                "SELECT username, status, new_device FROM auth_flow WHERE flow_id = ?", flowId);
        return rows.stream().findFirst();
    }

    // --- Throttling ---

    /** Pencere içinde en fazla {@code max} istek. Pencere dolunca sayaç sıfırlanır. */
    public boolean allow(String key, int max, Duration window) {
        List<Map<String, Object>> rows = jdbc.queryForList(
                "SELECT hits, window_start FROM throttle WHERE key_name = ?", key);
        Instant now = Instant.now();
        if (rows.isEmpty() || now.isAfter(((Timestamp) rows.get(0).get("window_start")).toInstant().plus(window))) {
            jdbc.update("DELETE FROM throttle WHERE key_name = ?", key);
            jdbc.update("INSERT INTO throttle (key_name, hits, window_start) VALUES (?, 1, ?)",
                    key, Timestamp.from(now));
            return true;
        }
        int hits = ((Number) rows.get(0).get("hits")).intValue();
        if (hits >= max) {
            return false;
        }
        jdbc.update("UPDATE throttle SET hits = hits + 1 WHERE key_name = ?", key);
        return true;
    }

    static String hash(String flowId, String code) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] d = md.digest((flowId + ":" + code).getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder();
            for (byte b : d) {
                sb.append(String.format("%02x", b));
            }
            return sb.toString();
        } catch (java.security.NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    // --- Cihaz kaydı ve web girişi onayı ---

    static final long APPROVAL_TTL_SECONDS = 60;

    /** Seal'de cihaz kaydı tamamlanınca çağrılır (idempotent). */
    public void registerDevice(String user, String device) {
        jdbc.update("INSERT INTO device_registry (username, device_id) VALUES (?, ?) ON CONFLICT DO NOTHING", user, device);
    }

    public List<String> devicesFor(String user) {
        return jdbc.queryForList("SELECT device_id FROM device_registry WHERE username = ?", String.class, user);
    }

    /** Onay isteği: kullanıcının her kayıtlı cihazına bir satır. Dönüş: onay kimliği. */
    public String createApproval(String user, List<String> devices) {
        String id = java.util.UUID.randomUUID().toString();
        Timestamp exp = Timestamp.from(Instant.now().plusSeconds(APPROVAL_TTL_SECONDS));
        for (String device : devices) {
            jdbc.update("INSERT INTO device_approval (approval_id, device_id, username, state, expires_at) "
                    + "VALUES (?, ?, ?, 'PENDING', ?)", id, device, user, exp);
        }
        return id;
    }

    /** Onay durumu: APPROVED (herhangi bir cihaz onayladı) > DENIED > PENDING (süresi dolmamış) > EXPIRED; bilinmiyorsa null. */
    public String approvalState(String id) {
        List<Map<String, Object>> rows = jdbc.queryForList(
                "SELECT state, expires_at FROM device_approval WHERE approval_id = ?", id);
        if (rows.isEmpty()) return null;
        boolean approved = false, denied = false, pending = false;
        for (Map<String, Object> r : rows) {
            String st = (String) r.get("state");
            if ("APPROVED".equals(st)) approved = true;
            else if ("DENIED".equals(st)) denied = true;
            else if ("PENDING".equals(st)
                    && Instant.now().isBefore(((Timestamp) r.get("expires_at")).toInstant())) pending = true;
        }
        if (approved) return "APPROVED";
        if (denied) return "DENIED";
        return pending ? "PENDING" : "EXPIRED";
    }

    /** Cihaza gelen bekleyen onaylar (süresi dolmamış, PENDING). */
    public List<Map<String, Object>> pendingApprovals(String user, String device) {
        return jdbc.queryForList("SELECT approval_id, expires_at FROM device_approval "
                + "WHERE username = ? AND device_id = ? AND state = 'PENDING' AND expires_at > now() "
                + "ORDER BY expires_at", user, device);
    }

    /** Karar yalnız bu cihaza gelmiş, PENDING ve süresi dolmamış onaya uygulanır. */
    public boolean decideApproval(String id, String user, String device, String approve) {
        String state = approve.equals("APPROVE") ? "APPROVED" : "DENIED";
        return jdbc.update("UPDATE device_approval SET state = ?, decided_at = now() "
                + "WHERE approval_id = ? AND username = ? AND device_id = ? AND state = 'PENDING' AND expires_at > now()",
                state, id, user, device) == 1;
    }
}
