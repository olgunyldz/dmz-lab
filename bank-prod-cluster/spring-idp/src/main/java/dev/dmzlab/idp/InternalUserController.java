package dev.dmzlab.idp;

import jakarta.servlet.http.HttpServletRequest;
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
import java.util.Map;
import java.util.regex.Pattern;

/**
 * İç kullanıcı oluşturma (demo kayıt akışı için). Yalnızca iç HTTP portunda (idp.internal-port) ve
 * X-Internal-Key başlığı doğruysa çalışır; diğer durumlarda 404/401 döner. HTTPS portunda uç nokta yoktur.
 * LAB SINIRI: gerçek kayıt, doğrulama (OTP/SMS/e-posta), hız sınırı ve denetim kaydı bu uç noktada yok.
 */
@RestController
class InternalUserController {

    private static final Pattern USERNAME = Pattern.compile("^[a-z][a-z0-9_]{2,31}$");

    private final UserDetailsManager users;
    private final PasswordEncoder encoder;
    private final String internalKey;
    private final int internalPort;

    InternalUserController(UserDetailsManager users, PasswordEncoder encoder,
                           @Value("${idp.internal-api-key:}") String internalKey,
                           @Value("${idp.internal-port}") int internalPort) {
        this.users = users;
        this.encoder = encoder;
        this.internalKey = internalKey;
        this.internalPort = internalPort;
    }

    @PostMapping("/internal/users")
    ResponseEntity<Map<String, Object>> create(@RequestBody Map<String, String> body, HttpServletRequest request) {
        if (request.getLocalPort() != internalPort) {
            return ResponseEntity.notFound().build();
        }
        String sent = request.getHeader("X-Internal-Key");
        if (internalKey.isBlank() || sent == null || !MessageDigest.isEqual(
                internalKey.getBytes(StandardCharsets.UTF_8), sent.getBytes(StandardCharsets.UTF_8))) {
            return ResponseEntity.status(HttpStatus.UNAUTHORIZED).body(Map.of("error", "iç anahtar geçersiz"));
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
}
