package dev.dmzlab.idp;

import org.springframework.security.oauth2.jwt.JwtClaimsSet;

import java.util.List;
import java.util.Optional;

/**
 * İstemci başına sabit claim'ler (eski IdP mapper'larının karşılığı).
 * channel: kanal; auth_method: exchange istemcisinin kimlik doğrulama yöntemi; partner_id: partner istemcisi.
 * audience: kanal istemcilerinin token'ının hedef kitlesi (channel-web, channel-mobile, ...).
 */
final class ChannelClaims {

    private final String channel;
    private final String audience;
    private final String authMethod;
    private final String partnerId;

    private ChannelClaims(String channel, String audience, String authMethod, String partnerId) {
        this.channel = channel;
        this.audience = audience;
        this.authMethod = authMethod;
        this.partnerId = partnerId;
    }

    static Optional<ChannelClaims> forClient(String clientId) {
        return Optional.ofNullable(switch (clientId) {
            case "web-app" -> new ChannelClaims("web", "channel-web", null, null);
            case "mobile-app" -> new ChannelClaims("mobile", "channel-mobile", null, null);
            case "branch-app" -> new ChannelClaims("branch", "channel-branch", null, null);
            case "partner-acme" -> new ChannelClaims("partner", "channel-partner", null, "acme-001");
            case "dmz-exchange-web" -> new ChannelClaims("web", null, "pwd_otp", null);
            case "dmz-exchange-mobile" -> new ChannelClaims("mobile", null, "dpop_device", null);
            case "dmz-exchange-partner" -> new ChannelClaims("partner", null, "mtls_partner", null);
            case "dmz-exchange-branch" -> new ChannelClaims("branch", null, "branch_cert", null);
            default -> null;
        });
    }

    /**
     * @param setAudience true ise kanal audience'ı yazılır; exchange'de istenen audience korunduğu için false.
     */
    void apply(JwtClaimsSet.Builder claims, boolean setAudience) {
        claims.claim("channel", channel);
        if (setAudience && audience != null) {
            claims.audience(List.of(audience));
        }
        if (authMethod != null) {
            claims.claim("auth_method", authMethod);
        }
        if (partnerId != null) {
            claims.claim("partner_id", partnerId);
        }
    }
}
