package dev.dmzlab.idp.auth;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.security.oauth2.jose.jws.SignatureAlgorithm;
import org.springframework.security.oauth2.jwt.JwsHeader;
import org.springframework.security.oauth2.jwt.JwtClaimsSet;
import org.springframework.security.oauth2.jwt.JwtEncoder;
import org.springframework.security.oauth2.jwt.JwtEncoderParameters;
import org.springframework.stereotype.Component;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.ObjectMapper;
import tools.jackson.databind.node.ObjectNode;

import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManagerFactory;
import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.security.KeyStore;
import java.security.cert.X509Certificate;
import java.time.Duration;
import java.time.Instant;
import java.util.List;

/**
 * Seal Intranet (backend-to-backend API) istemcisi. IdP kendi imzalama anahtarıyla kısa ömürlü bir
 * "seal-b2b" token'ı üretir (aud=seal-intranet); bağlantı iç CA ile doğrulanan HTTPS'tir.
 * Seal Intranet identity cluster'da (küme içi); dış yol yok.
 */
@Component
public class SealIntranetClient {

    /** Seal Intranet yanıtı: HTTP durum kodu ve JSON gövde. */
    public record SealResponse(int status, JsonNode body) {
    }

    private static final String SERVICE_CLIENT = "seal-b2b";
    private static final String AUDIENCE = "seal-intranet";

    private final String baseUrl;
    private final String issuer;
    private final JwtEncoder encoder;
    private final HttpClient http;
    private final ObjectMapper mapper = new ObjectMapper();

    public SealIntranetClient(@Value("${idp.seal.url}") String baseUrl,
                              @Value("${idp.issuer}") String issuer,
                              JwtEncoder encoder,
                              X509Certificate labCa) throws Exception {
        this.baseUrl = baseUrl;
        this.issuer = issuer;
        this.encoder = encoder;
        KeyStore trust = KeyStore.getInstance("PKCS12");
        trust.load(null, null);
        trust.setCertificateEntry("lab-ca", labCa);
        TrustManagerFactory tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
        tmf.init(trust);
        SSLContext ctx = SSLContext.getInstance("TLSv1.2");
        ctx.init(null, tmf.getTrustManagers(), null);
        this.http = HttpClient.newBuilder().sslContext(ctx).connectTimeout(Duration.ofSeconds(5)).build();
    }

    /** Seal v3 entegrasyon uçlarından biri: op = login-api/get-login-status gibi. */
    public SealResponse call(String op, ObjectNode body) throws IOException, InterruptedException {
        HttpRequest req = HttpRequest.newBuilder(URI.create(baseUrl + "/seal-v3/server/integration/" + op))
                .timeout(Duration.ofSeconds(10))
                .header("Authorization", "Bearer " + serviceToken())
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(mapper.writeValueAsString(body)))
                .build();
        HttpResponse<String> resp = http.send(req, HttpResponse.BodyHandlers.ofString());
        JsonNode node = resp.body() == null || resp.body().isBlank()
                ? mapper.createObjectNode()
                : mapper.readTree(resp.body());
        return new SealResponse(resp.statusCode(), node);
    }

    private String serviceToken() {
        Instant now = Instant.now();
        JwtClaimsSet claims = JwtClaimsSet.builder()
                .issuer(issuer)
                .subject(SERVICE_CLIENT)
                .audience(List.of(AUDIENCE))
                .issuedAt(now)
                .expiresAt(now.plusSeconds(60))
                .build();
        JwsHeader header = JwsHeader.with(SignatureAlgorithm.RS256).type("JWT").build();
        return encoder.encode(JwtEncoderParameters.from(header, claims)).getTokenValue();
    }
}
