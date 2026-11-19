package dev.dmzlab.idp;

import java.net.URI;
import java.security.cert.X509Certificate;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.annotation.Order;
import org.springframework.security.config.Customizer;
import org.springframework.security.web.context.SecurityContextHolderFilter;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.annotation.web.configurers.oauth2.server.authorization.OAuth2AuthorizationServerConfigurer;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtEncoder;
import org.springframework.security.oauth2.server.authorization.OAuth2AuthorizationService;
import org.springframework.security.oauth2.server.authorization.settings.AuthorizationServerSettings;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.authentication.LoginUrlAuthenticationEntryPoint;
import org.springframework.security.web.util.matcher.OrRequestMatcher;
import org.springframework.security.web.util.matcher.RequestHeaderRequestMatcher;
import org.springframework.beans.factory.annotation.Value;

@Configuration
@EnableWebSecurity
public class SecurityConfig {

    /** Yetkilendirme sunucusu uçları (discovery, auth, token, JWKS). */
    @Bean
    @Order(1)
    SecurityFilterChain authorizationServerChain(HttpSecurity http,
                                                 JwtDecoder subjectTokenDecoder,
                                                 OAuth2AuthorizationService authorizationService,
                                                 JwtEncoder jwtEncoder,
                                                 @Value("${idp.issuer}") String issuer,
                                                 @Value("${idp.internal-port}") int internalPort,
                                                 X509Certificate labCa) throws Exception {
        OAuth2AuthorizationServerConfigurer authorizationServer = new OAuth2AuthorizationServerConfigurer();
        // Discovery'de Spring issuer yolunu uç noktaların önüne bir kez daha ekliyor (/realms/bank/realms/bank/...).
        // Gerçek uçlar /realms/bank/... altında; discovery'yi bu gerçek yollara sabitliyoruz.
        String origin = origin(issuer);
        String realm = URI.create(issuer).getPath();
        http.securityMatcher(authorizationServer.getEndpointsMatcher())
                .addFilterBefore(new XfccCertificateFilter(internalPort, labCa), SecurityContextHolderFilter.class)
                .with(authorizationServer, as -> as
                        .oidc(oidc -> oidc.providerConfigurationEndpoint(p -> p.providerConfigurationCustomizer(b -> {
                            b.authorizationEndpoint(origin + realm + "/protocol/openid-connect/auth");
                            b.tokenEndpoint(origin + realm + "/protocol/openid-connect/token");
                            b.jwkSetUrl(origin + realm + "/protocol/openid-connect/certs");
                        })))
                        .tokenEndpoint(token -> token
                                .accessTokenRequestConverter(TokenExchange.delegating(TokenExchange.converter()))
                                .authenticationProvider(TokenExchange.provider(subjectTokenDecoder, jwtEncoder, issuer,
                                        authorizationService))))
                .authorizeHttpRequests(auth -> auth.requestMatchers("/actuator/prometheus").permitAll()
                        .anyRequest().authenticated())
                // Girişe yönlendirme: (a) yetkilendirme uç noktası (her istemci, Accept'ten bağımsız) veya
                // (b) açıkça text/html isteyen tarayıcılar. Token uç noktası kimliksiz istekte JSON hata (401/invalid_client).
                .exceptionHandling(ex -> ex.defaultAuthenticationEntryPointFor(
                        new LoginUrlAuthenticationEntryPoint("/login"),
                        new OrRequestMatcher(
                                req -> req.getRequestURI().equals(IdpConfig.REALM_PATH + "/protocol/openid-connect/auth"),
                                new RequestHeaderRequestMatcher("Accept", "text/html"))));
        return http.build();
    }

    /** https://host:port/realms/bank -> https://host:port */
    private static String origin(String issuer) {
        URI uri = URI.create(issuer);
        String port = uri.getPort() == -1 ? "" : ":" + uri.getPort();
        return uri.getScheme() + "://" + uri.getHost() + port;
    }

    /** Giriş formu (Authorization Code akışında kullanıcı girişi). */
    @Bean
    @Order(2)
    SecurityFilterChain defaultChain(HttpSecurity http) throws Exception {
        // /internal/users: kimlik doğrulama InternalUserController'da (iç port + X-Internal-Key); CSRF bu yol için kapalı
        http.csrf(csrf -> csrf.ignoringRequestMatchers("/internal/users"))
                .authorizeHttpRequests(auth -> auth.requestMatchers("/internal/users", "/actuator/prometheus").permitAll()
                        .anyRequest().authenticated())
                .formLogin(Customizer.withDefaults());
        return http.build();
    }
}
