package dev.dmzlab.auth;

import jakarta.servlet.http.HttpServletRequest;
import java.security.cert.X509Certificate;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;
import javax.naming.InvalidNameException;
import javax.naming.ldap.LdapName;
import javax.naming.ldap.Rdn;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.userdetails.User;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.provisioning.UserDetailsManager;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;

/**
 * Kullanıcı oluşturma (lab müşteri ekleme). İki yol:
 * <ul>
 *   <li>İç HTTP portu (auth.internal-port): X-Internal-Key başlığı doğruysa.</li>
 *   <li>HTTPS portu (server.port): TLS istemci sertifikasının CN'i auth.internal.user-admins listesindeyse
 *       (Janus, CN=janus-web / janus-mobile). İstemci sertifikası TLS katmanında iç CA ile doğrulanır.</li>
 * </ul>
 * Parola yalnız IdP'de (PasswordEncoder ile hash) tutulur. Diğer istekler 404/401 döner.
 * LAB SINIRI: doğrulama (OTP/e-posta), hız sınırı ve denetim kaydı bu uç noktada yok.
 */
@RestController
class InternalUserController {

    private static final Pattern USERNAME = Pattern.compile("^[a-z][a-z0-9_]{2,31}$");
    static final String CERT_ATTRIBUTE = "jakarta.servlet.request.X509Certificate";

    private final UserDetailsManager users;
    private final PasswordEncoder encoder;
    private final String internalKey;
    private final int internalPort;
    private final int httpsPort;
    private final List<String> userAdmins;

    InternalUserController(UserDetailsManager users, PasswordEncoder encoder,
                           @Value("${auth.internal-api-key:}") String internalKey,
                           @Value("${auth.internal-port}") int internalPort,
                           @Value("${server.port:8443}") int httpsPort,
                           @Value("${auth.internal.user-admins:}") String userAdmins) {
        this.users = users;
        this.encoder = encoder;
        this.internalKey = internalKey;
        this.internalPort = internalPort;
        this.httpsPort = httpsPort;
        this.userAdmins = Arrays.stream(userAdmins.split(",")).map(String::trim).filter(s -> !s.isEmpty()).toList();
    }

    @PostMapping("/internal/users")
    ResponseEntity<Map<String, Object>> create(@RequestBody Map<String, String> body, HttpServletRequest request) {
        int port = request.getLocalPort();
        if (port == internalPort) {
            if (!keyMatches(request.getHeader("X-Internal-Key"))) {
                return ResponseEntity.status(HttpStatus.UNAUTHORIZED).body(Map.of("error", "iç anahtar geçersiz"));
            }
        } else if (port == httpsPort) {
            if (!trustedAdmin(request)) {
                return ResponseEntity.status(HttpStatus.UNAUTHORIZED).body(Map.of("error", "istemci sertifikası yetkisiz"));
            }
        } else {
            return ResponseEntity.notFound().build();
        }
        String username = body.getOrDefault("username", "");
        String password = body.getOrDefault("password", "");
        if (!USERNAME.matcher(username).matches()) {
            return ResponseEntity.badRequest().body(Map.of("error", "kullanıcı adı geçersiz"));
        }
        if (password.length() < 8 || password.length() > 128 || password.toLowerCase().contains(username)) {
            return ResponseEntity.badRequest().body(Map.of("error", "parola politikaya uymuyor"));
        }
        if (users.userExists(username)) {
            return ResponseEntity.status(HttpStatus.CONFLICT).body(Map.of("error", "kullanıcı zaten var"));
        }
        users.createUser(User.withUsername(username).password(encoder.encode(password)).roles("USER").build());
        return ResponseEntity.status(HttpStatus.CREATED).body(Map.of("username", username));
    }

    private boolean keyMatches(String sent) {
        return !internalKey.isBlank() && sent != null && MessageDigest.isEqual(
                internalKey.getBytes(StandardCharsets.UTF_8), sent.getBytes(StandardCharsets.UTF_8));
    }

    /** TLS eşinin istemci sertifikası CN'i yetkili listede mi? */
    private boolean trustedAdmin(HttpServletRequest request) {
        Object attr = request.getAttribute(CERT_ATTRIBUTE);
        if (!(attr instanceof X509Certificate[] certs) || certs.length == 0) {
            return false;
        }
        String cn = commonName(certs[0]);
        return cn != null && userAdmins.contains(cn);
    }

    static String commonName(X509Certificate cert) {
        try {
            for (Rdn rdn : new LdapName(cert.getSubjectX500Principal().getName()).getRdns()) {
                if ("CN".equalsIgnoreCase(rdn.getType())) {
                    return String.valueOf(rdn.getValue());
                }
            }
        } catch (InvalidNameException e) {
            return null;
        }
        return null;
    }
}
