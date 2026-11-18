package dev.dmzlab.idp;

import org.apache.tomcat.util.net.SSLHostConfig;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.tomcat.servlet.TomcatServletWebServerFactory;
import org.springframework.boot.web.server.WebServerFactoryCustomizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.jdbc.core.JdbcOperations;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.oauth2.core.AuthorizationGrantType;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtEncoder;
import org.springframework.security.oauth2.jwt.JwtValidators;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;
import org.springframework.security.oauth2.jwt.NimbusJwtEncoder;
import org.springframework.security.oauth2.server.authorization.JdbcOAuth2AuthorizationConsentService;
import org.springframework.security.oauth2.server.authorization.JdbcOAuth2AuthorizationService;
import org.springframework.security.oauth2.server.authorization.OAuth2AuthorizationConsentService;
import org.springframework.security.oauth2.server.authorization.OAuth2AuthorizationService;
import org.springframework.security.oauth2.server.authorization.OAuth2TokenType;
import org.springframework.security.oauth2.server.authorization.client.JdbcRegisteredClientRepository;
import org.springframework.security.oauth2.server.authorization.client.RegisteredClientRepository;
import org.springframework.security.oauth2.server.authorization.settings.AuthorizationServerSettings;
import org.springframework.security.oauth2.server.authorization.token.JwtEncodingContext;
import org.springframework.security.oauth2.server.authorization.token.OAuth2TokenCustomizer;
import org.springframework.security.provisioning.JdbcUserDetailsManager;
import org.springframework.security.provisioning.UserDetailsManager;

import io.micrometer.tracing.Tracer;
import javax.sql.DataSource;
import java.security.PrivateKey;
import java.security.KeyStore;
import java.security.cert.X509Certificate;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyStore;
import java.security.cert.X509Certificate;
import java.util.Collections;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.interfaces.RSAPublicKey;
import java.util.UUID;

import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jose.jwk.source.ImmutableJWKSet;
import com.nimbusds.jose.jwk.source.JWKSource;
import com.nimbusds.jose.proc.SecurityContext;

/**
 * Altyapı bean'leri: anahtarlar, JDBC kalıcılığı, token claim'leri.
 * Yolları IdP ile aynı tuttum (/realms/bank/...): ext-authz, BFF, konsol ve testler değişmesin diye.
 * İstemci ve kullanıcı tohumlaması: {@link Seeder}. Sırlar ortam değişkeninden okunur; repo'da sır yok.
 */
@Configuration
public class IdpConfig {

    static final String REALM_PATH = "/realms/bank";
    public static final AuthorizationGrantType TOKEN_EXCHANGE =
            new AuthorizationGrantType("urn:ietf:params:oauth:grant-type:token-exchange");

    @Bean
    AuthorizationServerSettings authorizationServerSettings(@Value("${idp.issuer}") String issuer) {
        return AuthorizationServerSettings.builder()
                .issuer(issuer)
                .authorizationEndpoint(REALM_PATH + "/protocol/openid-connect/auth")
                .tokenEndpoint(REALM_PATH + "/protocol/openid-connect/token")
                .jwkSetEndpoint(REALM_PATH + "/protocol/openid-connect/certs")
                .tokenRevocationEndpoint(REALM_PATH + "/protocol/openid-connect/revoke")
                // Introspection: diğer servisler (seal-mobile) token'ın hâlâ aktif olup olmadığını buradan öğrenir
                .tokenIntrospectionEndpoint(REALM_PATH + "/protocol/openid-connect/token/introspect")
                .build();
    }

    @Bean
    PasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder();
    }

    /** İmzalama anahtarı PKCS12 keystore'dan yüklenir (kalıcı). Yeniden başlatmada token'lar geçerli kalır. */
    @Bean
    KeyPair signingKeyPair(@Value("${idp.signing.keystore}") String keystore,
                           @Value("${idp.signing.keystore-password}") String password,
                           @Value("${idp.signing.alias}") String alias) throws Exception {
        KeyStore store = KeyStore.getInstance("PKCS12");
        try (InputStream in = Files.newInputStream(Path.of(keystore))) {
            store.load(in, password.toCharArray());
        }
        PrivateKey key = (PrivateKey) store.getKey(alias, password.toCharArray());
        X509Certificate cert = (X509Certificate) store.getCertificate(alias);
        return new KeyPair(cert.getPublicKey(), key);
    }

    @Bean
    JWKSource<SecurityContext> jwkSource(KeyPair signingKeyPair, @Value("${idp.signing.alias}") String alias) {
        RSAKey rsa = new RSAKey.Builder((RSAPublicKey) signingKeyPair.getPublic())
                .privateKey(signingKeyPair.getPrivate())
                .keyID(alias)
                .build();
        return new ImmutableJWKSet<>(new JWKSet(rsa));
    }

    @Bean
    JwtEncoder jwtEncoder(JWKSource<SecurityContext> jwkSource) {
        return new NimbusJwtEncoder(jwkSource);
    }

    /** Token exchange'de gelen subject token'ı doğrular: yalnız bu IdP'nin imzaladığı ve süresi dolmamış token'lar. */
    @Bean
    JwtDecoder subjectTokenDecoder(KeyPair signingKeyPair, @Value("${idp.issuer}") String issuer) {
        NimbusJwtDecoder decoder = NimbusJwtDecoder.withPublicKey((RSAPublicKey) signingKeyPair.getPublic()).build();
        decoder.setJwtValidator(JwtValidators.createDefaultWithIssuer(issuer));
        return decoder;
    }

    // --- Kalıcılık (PostgreSQL, şema: db/migration) ---

    @Bean
    RegisteredClientRepository registeredClientRepository(JdbcOperations jdbc) {
        return new JdbcRegisteredClientRepository(jdbc);
    }

    /** Kullanıcı başına tek aktif giriş (bkz. {@link SingleLoginAuthorizationService}). */
    @Bean
    OAuth2AuthorizationService authorizationService(JdbcOperations jdbc, RegisteredClientRepository clients) {
        return new SingleLoginAuthorizationService(new JdbcOAuth2AuthorizationService(jdbc, clients), jdbc);
    }

    @Bean
    OAuth2AuthorizationConsentService authorizationConsentService(JdbcOperations jdbc,
                                                                  RegisteredClientRepository clients) {
        return new JdbcOAuth2AuthorizationConsentService(jdbc, clients);
    }

    @Bean
    UserDetailsManager userDetailsManager(DataSource dataSource) {
        return new JdbcUserDetailsManager(dataSource);
    }

    /** X-Trace-Id yanıt başlığı: gözlemleme filtresinden sonra, güvenlik zincirinden önce. */
    @Bean
    org.springframework.boot.web.servlet.FilterRegistrationBean<TraceIdHeaderFilter> traceIdHeaderFilter(Tracer tracer) {
        var registration = new org.springframework.boot.web.servlet.FilterRegistrationBean<>(new TraceIdHeaderFilter(tracer));
        registration.setOrder(org.springframework.core.Ordered.HIGHEST_PRECEDENCE + 10);
        registration.addUrlPatterns("/*");
        return registration;
    }

    /** Realm discovery yolu (IdP uyumu): güvenlik zincirinden önce, en yüksek öncelikte çalışır. */
    @Bean
    org.springframework.boot.web.servlet.FilterRegistrationBean<RealmDiscoveryFilter> realmDiscoveryFilter() {
        var registration = new org.springframework.boot.web.servlet.FilterRegistrationBean<>(new RealmDiscoveryFilter());
        registration.setOrder(org.springframework.core.Ordered.HIGHEST_PRECEDENCE);
        registration.addUrlPatterns("/*");
        return registration;
    }

    /** Güven deposundaki lab CA sertifikası (ilk sertifika girdisi). XFCC zinciri bununla kurulur ve doğrulanır. */
    @Bean
    X509Certificate labCa(@Value("${idp.tls.truststore}") String truststore,
                          @Value("${idp.tls.truststore-password}") String truststorePassword) throws Exception {
        KeyStore store = KeyStore.getInstance("PKCS12");
        try (InputStream in = Files.newInputStream(Path.of(truststore))) {
            store.load(in, truststorePassword.toCharArray());
        }
        for (String alias : Collections.list(store.aliases())) {
            if (store.isCertificateEntry(alias)) {
                return (X509Certificate) store.getCertificate(alias);
            }
        }
        throw new IllegalStateException("güven deposunda CA sertifikası yok: " + truststore);
    }

    /**
     * İç yol için düz HTTP connector (idp.internal-port, varsayılan 8080). Yalnız iç gateway ve iç düğümlerden erişilir
     * (F8). İstemci sertifikası bu porttan XFCC ile gelir (XfccCertificateFilter). HTTPS portu (8443) değişmez.
     */
    @Bean
    WebServerFactoryCustomizer<TomcatServletWebServerFactory> internalHttpConnector(
            @Value("${idp.internal-port}") int internalPort) {
        return factory -> {
            org.apache.catalina.connector.Connector connector = new org.apache.catalina.connector.Connector();
            connector.setPort(internalPort);
            factory.addAdditionalConnectors(connector);
        };
    }

    /**
     * mTLS güven deposu (lab CA). Boot 4 server.ssl.trust-store değerini Tomcat'e aktarmadığı için (log: trust store [null])
     * Tomcat SSLHostConfig'ine doğrudan yazılır. İstemci sertifikası isteğe bağlıdır (certificateVerification=optional).
     */
    @Bean
    WebServerFactoryCustomizer<TomcatServletWebServerFactory> mtlsTruststore(
            @Value("${idp.tls.truststore}") String truststore,
            @Value("${idp.tls.truststore-password}") String truststorePassword) {
        return factory -> factory.addConnectorCustomizers(connector -> {
            for (SSLHostConfig host : connector.getProtocolHandler().findSslHostConfigs()) {
                host.setTruststoreFile(truststore);
                host.setTruststorePassword(truststorePassword);
                host.setTruststoreType("PKCS12");
                host.setCertificateVerification("optional");
            }
        });
    }

    // --- Token claim'leri ---

    /**
     * önceki IdP'deki protocol mapper'ların karşılığı: channel, aud, auth_method, partner_id.
     * Yalnız erişim token'ına uygulanır. Exchange token'ları kendi üretiminde aynı kuralı kullanır (TokenExchange).
     */
    @Bean
    OAuth2TokenCustomizer<JwtEncodingContext> channelClaimsCustomizer(
            dev.dmzlab.idp.auth.AuthStateRepository authState) {
        return context -> {
            if (!OAuth2TokenType.ACCESS_TOKEN.equals(context.getTokenType())) {
                return;
            }
            ChannelClaims.forClient(context.getRegisteredClient().getClientId())
                    .ifPresent(profile -> profile.apply(context.getClaims(), true));
            // Aktivasyon bekleyen kullanıcı (yeni cihaz + OTP geçildi): token yalnız aktivasyon kapsamında (kısıtlı)
            if (context.getAuthorizationGrantType() == AuthorizationGrantType.AUTHORIZATION_CODE
                    && context.getPrincipal() != null
                    && authState.isPending(context.getPrincipal().getName())) {
                context.getClaims().claim("restricted", true).claim("scope", "activation");
            }
        };
    }
}
