package dev.dmzlab.auth;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.core.annotation.Order;
import org.springframework.security.core.userdetails.User;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.oauth2.core.AuthorizationGrantType;
import org.springframework.security.oauth2.core.ClientAuthenticationMethod;
import org.springframework.security.oauth2.core.oidc.OidcScopes;
import org.springframework.security.oauth2.server.authorization.client.RegisteredClient;
import org.springframework.security.oauth2.server.authorization.client.RegisteredClientRepository;
import org.springframework.security.oauth2.server.authorization.settings.ClientSettings;
import org.springframework.security.provisioning.UserDetailsManager;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.UUID;

/**
 * Açılışta sistem istemcilerini ve kullanıcıyı veritabanına yazar.
 * İstemciler UPSERT: var olan kayıt aynı id ile güncellenir, böylece env'deki sır rotasyonu yeniden başlatmada uygulanır.
 * Kullanıcı yalnız yoksa eklenir (parola değişikliği bu betiğin işi değil).
 */
@Component
@Order(1)
class Seeder implements ApplicationRunner {

    private static final Logger log = LoggerFactory.getLogger(Seeder.class);

    private final RegisteredClientRepository clients;
    private final UserDetailsManager users;
    private final PasswordEncoder encoder;
    private final String alicePassword;
    private final String tellerPassword;
    private final String webAppSecret;
    private final String partnerSecret;
    private final String bffSecret;
    private final String coreSecret;
    private final String sealB2bSecret;
    private final String sealMobileSecret;

    Seeder(RegisteredClientRepository clients, UserDetailsManager users, PasswordEncoder encoder,
           @Value("${auth.users.alice.password}") String alicePassword,
           @Value("${auth.users.teller.password}") String tellerPassword,
           @Value("${auth.clients.web-app.secret}") String webAppSecret,
           @Value("${auth.clients.partner-acme.secret}") String partnerSecret,
           @Value("${auth.clients.bff.secret}") String bffSecret,
           @Value("${auth.clients.core-svc.secret}") String coreSecret,
           @Value("${auth.clients.seal-b2b.secret}") String sealB2bSecret,
           @Value("${auth.clients.seal-mobile.secret}") String sealMobileSecret) {
        this.clients = clients;
        this.users = users;
        this.encoder = encoder;
        this.alicePassword = alicePassword;
        this.tellerPassword = tellerPassword;
        this.webAppSecret = webAppSecret;
        this.partnerSecret = partnerSecret;
        this.bffSecret = bffSecret;
        this.coreSecret = coreSecret;
        this.sealB2bSecret = sealB2bSecret;
        this.sealMobileSecret = sealMobileSecret;
    }

    @Override
    public void run(ApplicationArguments args) {
        for (RegisteredClient definition : definitions()) {
            upsert(definition);
        }
        if (!users.userExists("alice")) {
            users.createUser(User.withUsername("alice")
                    .password(encoder.encode(alicePassword)).roles("USER").build());
            log.info("kullanıcı eklendi: alice");
        }
        if (!users.userExists("teller")) {
            users.createUser(User.withUsername("teller")
                    .password(encoder.encode(tellerPassword)).roles("USER").build());
            log.info("kullanıcı eklendi: teller");
        }
    }

    private void upsert(RegisteredClient definition) {
        RegisteredClient existing = clients.findByClientId(definition.getClientId());
        RegisteredClient toSave = existing == null
                ? definition
                : RegisteredClient.from(definition).id(existing.getId()).build();
        clients.save(toSave);
        log.info("istemci {}: {}", existing == null ? "eklendi" : "güncellendi", definition.getClientId());
    }

    private List<RegisteredClient> definitions() {
        RegisteredClient webApp = RegisteredClient.withId(UUID.randomUUID().toString())
                .clientId("web-app")
                .clientSecret(encoder.encode(webAppSecret))
                .clientAuthenticationMethod(ClientAuthenticationMethod.CLIENT_SECRET_BASIC)
                .authorizationGrantType(AuthorizationGrantType.AUTHORIZATION_CODE)
                .authorizationGrantType(AuthorizationGrantType.REFRESH_TOKEN)
                .redirectUri("https://web.lab.local:8443/callback")
                .scope(OidcScopes.OPENID)
                .scope(OidcScopes.PROFILE)
                .clientSettings(ClientSettings.builder().requireProofKey(true).build())
                .build();

        // Mobil: public istemci, PKCE zorunlu
        RegisteredClient mobileApp = RegisteredClient.withId(UUID.randomUUID().toString())
                .clientId("mobile-app")
                .clientAuthenticationMethod(ClientAuthenticationMethod.NONE)
                .authorizationGrantType(AuthorizationGrantType.AUTHORIZATION_CODE)
                .authorizationGrantType(AuthorizationGrantType.REFRESH_TOKEN)
                .redirectUri("com.bank.app:/callback")
                .scope(OidcScopes.OPENID)
                .scope(OidcScopes.PROFILE)
                .clientSettings(ClientSettings.builder().requireProofKey(true).build())
                .build();

        RegisteredClient branchApp = RegisteredClient.withId(UUID.randomUUID().toString())
                .clientId("branch-app")
                .clientSecret(encoder.encode(webAppSecret))
                .clientAuthenticationMethod(ClientAuthenticationMethod.CLIENT_SECRET_BASIC)
                .authorizationGrantType(AuthorizationGrantType.AUTHORIZATION_CODE)
                .authorizationGrantType(AuthorizationGrantType.REFRESH_TOKEN)
                .redirectUri("https://teller.lab.local/callback")
                .scope(OidcScopes.OPENID)
                .scope(OidcScopes.PROFILE)
                .clientSettings(ClientSettings.builder().requireProofKey(true).build())
                .build();

        return List.of(
                webApp,
                mobileApp,
                branchApp,
                serviceClient("partner-acme", partnerSecret),
                serviceClient("bff", bffSecret),
                serviceClient("core-svc", coreSecret),
                serviceClient("seal-b2b", sealB2bSecret),
                // Seal Mobile: yalnız introspection için (token'ın oturumu hâlâ aktif mi). Parola/giriş yetkisi yok.
                serviceClient("seal-mobile", sealMobileSecret),
                exchangeClient("web"),
                exchangeClient("mobile"),
                exchangeClient("partner"),
                exchangeClient("branch"));
    }

    private RegisteredClient serviceClient(String id, String secret) {
        return RegisteredClient.withId(UUID.randomUUID().toString())
                .clientId(id)
                .clientSecret(encoder.encode(secret))
                .clientAuthenticationMethod(ClientAuthenticationMethod.CLIENT_SECRET_BASIC)
                .authorizationGrantType(AuthorizationGrantType.CLIENT_CREDENTIALS)
                .build();
    }

    /**
     * Token exchange istemcisi: kimlik doğrulama mTLS ile (tls_client_auth).
     * Sertifika subject'i CN=dmz-exchange-<kanal> olmalı (edge/scripts/gen-internal-certs.sh ile üretilir).
     */
    private RegisteredClient exchangeClient(String channel) {
        String id = "dmz-exchange-" + channel;
        return RegisteredClient.withId(UUID.randomUUID().toString())
                .clientId(id)
                .clientAuthenticationMethod(ClientAuthenticationMethod.TLS_CLIENT_AUTH)
                .authorizationGrantType(AuthServerConfig.TOKEN_EXCHANGE)
                .clientSettings(ClientSettings.builder().x509CertificateSubjectDN("CN=" + id).build())
                .build();
    }
}
