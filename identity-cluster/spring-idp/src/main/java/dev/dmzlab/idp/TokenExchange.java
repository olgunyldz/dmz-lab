package dev.dmzlab.idp;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.security.authentication.AbstractAuthenticationToken;
import org.springframework.security.authentication.AuthenticationProvider;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.AuthenticationException;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.oauth2.core.AuthorizationGrantType;
import org.springframework.security.oauth2.core.OAuth2AccessToken;
import org.springframework.security.oauth2.core.OAuth2AuthenticationException;
import org.springframework.security.oauth2.core.OAuth2Error;
import org.springframework.security.oauth2.core.OAuth2ErrorCodes;
import org.springframework.security.oauth2.jose.jws.SignatureAlgorithm;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.jwt.JwtClaimsSet;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtEncoder;
import org.springframework.security.oauth2.jwt.JwtEncoderParameters;
import org.springframework.security.oauth2.jwt.JwtException;
import org.springframework.security.oauth2.jwt.JwsHeader;
import org.springframework.security.oauth2.server.authorization.authentication.OAuth2AccessTokenAuthenticationToken;
import org.springframework.security.oauth2.server.authorization.authentication.OAuth2ClientAuthenticationToken;
import org.springframework.security.oauth2.server.authorization.client.RegisteredClient;
import org.springframework.security.web.authentication.AuthenticationConverter;
import org.springframework.security.web.authentication.DelegatingAuthenticationConverter;

import java.time.Instant;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;

/**
 * RFC 8693 token exchange (prototip).
 * İstek: grant_type=urn:ietf:params:oauth:grant-type:token-exchange, subject_token, [audience], [scope].
 * Yanıt: aud = istenen audience, azp = exchange yapan istemci. Subject token bu IdP'nin imzaladığı bir JWT olmalı.
 * Eksik (sonraki adım): audience için istemci yetki listesi, mTLS (client-x509), DPoP bağlama, token iptali.
 */
public final class TokenExchange {

    static final String SUBJECT_TOKEN_TYPE_ACCESS = "urn:ietf:params:oauth:token-type:access_token";
    private static final long TTL_SECONDS = 300;

    private TokenExchange() {
    }

    /** Dış tokenEndpoint'e eklenen converter: diğer grant'lere dokunmaz (null döner). */
    public static AuthenticationConverter converter() {
        return new Converter();
    }

    /** Varsayılan grant converter'larını (auth code, refresh, client credentials) bu grant ile birleştirir. */
    public static AuthenticationConverter delegating(AuthenticationConverter tokenExchangeConverter) {
        return new DelegatingAuthenticationConverter(List.of(
                tokenExchangeConverter,
                new org.springframework.security.oauth2.server.authorization.web.authentication.OAuth2AuthorizationCodeAuthenticationConverter(),
                new org.springframework.security.oauth2.server.authorization.web.authentication.OAuth2RefreshTokenAuthenticationConverter(),
                new org.springframework.security.oauth2.server.authorization.web.authentication.OAuth2ClientCredentialsAuthenticationConverter()));
    }

    public static AuthenticationProvider provider(JwtDecoder subjectDecoder, JwtEncoder encoder, String issuer) {
        return new Provider(subjectDecoder, encoder, issuer);
    }

    static final class Request extends AbstractAuthenticationToken {
        private final Authentication clientPrincipal;
        private final String subjectToken;
        private final String audience;
        private final Set<String> scopes;

        Request(Authentication clientPrincipal, String subjectToken, String audience, Set<String> scopes) {
            super(Collections.emptyList());
            this.clientPrincipal = clientPrincipal;
            this.subjectToken = subjectToken;
            this.audience = audience;
            this.scopes = scopes;
            setAuthenticated(false);
        }

        @Override
        public Object getCredentials() {
            return "";
        }

        /** İstemci kimliği (OAuth2ClientAuthenticationToken). details'e YAZILMAZ: Spring filtresi onu ezer. */
        @Override
        public Object getPrincipal() {
            return clientPrincipal;
        }
    }

    static final class Converter implements AuthenticationConverter {
        @Override
        public Authentication convert(HttpServletRequest request) {
            if (!IdpConfig.TOKEN_EXCHANGE.getValue().equals(request.getParameter("grant_type"))) {
                return null;
            }
            Authentication clientPrincipal = SecurityContextHolder.getContext().getAuthentication();
            if (clientPrincipal == null || !clientPrincipal.isAuthenticated()) {
                throw error(OAuth2ErrorCodes.INVALID_CLIENT, "istemci doğrulanmadı");
            }
            String subjectToken = request.getParameter("subject_token");
            if (subjectToken == null || subjectToken.isBlank()) {
                throw error(OAuth2ErrorCodes.INVALID_REQUEST, "subject_token gerekli");
            }
            String subjectType = request.getParameter("subject_token_type");
            if (subjectType != null && !SUBJECT_TOKEN_TYPE_ACCESS.equals(subjectType)) {
                throw error(OAuth2ErrorCodes.INVALID_REQUEST, "subject_token_type desteklenmiyor");
            }
            String audience = request.getParameter("audience");
            String scope = request.getParameter("scope");
            Set<String> scopes = scope == null || scope.isBlank()
                    ? Collections.emptySet()
                    : Arrays.stream(scope.trim().split("\\s+")).collect(Collectors.toSet());
            return new Request(clientPrincipal, subjectToken, audience, scopes);
        }
    }

    static final class Provider implements AuthenticationProvider {
        private final JwtDecoder subjectDecoder;
        private final JwtEncoder encoder;
        private final String issuer;

        Provider(JwtDecoder subjectDecoder, JwtEncoder encoder, String issuer) {
            this.subjectDecoder = subjectDecoder;
            this.encoder = encoder;
            this.issuer = issuer;
        }

        @Override
        public Authentication authenticate(Authentication authentication) {
            Request request = (Request) authentication;
            OAuth2ClientAuthenticationToken client = (OAuth2ClientAuthenticationToken) request.getPrincipal();
            RegisteredClient registeredClient = client.getRegisteredClient();
            if (registeredClient == null
                    || !registeredClient.getAuthorizationGrantTypes().contains(IdpConfig.TOKEN_EXCHANGE)) {
                throw error(OAuth2ErrorCodes.UNAUTHORIZED_CLIENT, "istemci token exchange yetkili değil");
            }

            Jwt subject;
            try {
                subject = subjectDecoder.decode(request.subjectToken);
            } catch (JwtException e) {
                throw error(OAuth2ErrorCodes.INVALID_GRANT, "subject_token geçersiz");
            }

            String audience = request.audience != null && !request.audience.isBlank()
                    ? request.audience
                    : registeredClient.getClientId();
            Instant now = Instant.now();
            Instant exp = now.plusSeconds(TTL_SECONDS);
            JwsHeader header = JwsHeader.with(SignatureAlgorithm.RS256).type("JWT").build();
            JwtClaimsSet.Builder claims = JwtClaimsSet.builder()
                    .issuer(issuer)
                    .subject(subject.getSubject())
                    .audience(List.of(audience))
                    .issuedAt(now)
                    .expiresAt(exp)
                    .claim("azp", registeredClient.getClientId())
                    .claim("scope", String.join(" ", request.scopes));
            // Exchange istemcisinin kanal ve auth_method claim'leri; audience istenen değerde kalır (setAudience=false)
            ChannelClaims.forClient(registeredClient.getClientId()).ifPresent(p -> p.apply(claims, false));
            Jwt token = encoder.encode(JwtEncoderParameters.from(header, claims.build()));

            OAuth2AccessToken accessToken = new OAuth2AccessToken(
                    OAuth2AccessToken.TokenType.BEARER, token.getTokenValue(), now, exp, request.scopes);
            return new OAuth2AccessTokenAuthenticationToken(registeredClient, client, accessToken);
        }

        @Override
        public boolean supports(Class<?> authentication) {
            return Request.class.isAssignableFrom(authentication);
        }
    }

    private static OAuth2AuthenticationException error(String code, String description) {
        return new OAuth2AuthenticationException(new OAuth2Error(code, description, null));
    }
}
