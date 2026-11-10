package dev.dmzlab.kc;

import jakarta.ws.rs.core.Response;
import org.keycloak.TokenVerifier;
import org.keycloak.crypto.KeyUse;
import org.keycloak.crypto.KeyWrapper;
import org.keycloak.jose.jws.JWSBuilder;
import org.keycloak.models.ClientModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.protocol.oidc.TokenExchangeContext;
import org.keycloak.protocol.oidc.TokenExchangeProvider;
import org.keycloak.representations.AccessToken;
import org.jboss.logging.Logger;

import java.security.PrivateKey;
import java.security.PublicKey;

/**
 * DMZ mobil exchange'i için sarmalayıcı provider.
 *
 * Akış (design.md 5.0b, D-11):
 *  1. DMZ ext-authz, cihazın DPoP proof'unu doğrular (htm, htu, iat, jti, ath, cnf.jkt).
 *  2. DMZ, mTLS ile kimliği doğrulanmış dmz-exchange-mobile client'ı ile bu provider'a istek yapar.
 *  3. Provider subject token'ı Keycloak'un kendi anahtarıyla doğrular, cnf'sini kaldırıp yeniden imzalar.
 *  4. Standart token exchange akışı, bağlamasız token ile çalışır.
 *
 * Güven sınırı: DMZ proof doğrulamasına ve dmz-exchange-mobile mTLS kimliğine dayanır.
 * Bu provider yalnızca dmz-exchange-mobile client'ı ve kanal=mobile, azp=mobile-app olan token'lar için devreye girer.
 */
public class DpopMobileTokenExchangeProvider implements TokenExchangeProvider {

    private static final Logger LOG = Logger.getLogger(DpopMobileTokenExchangeProvider.class);
    static final String DMZ_MOBILE_CLIENT = "dmz-exchange-mobile";
    static final String MOBILE_TOKEN_AZP = "mobile-app";
    static final String MOBILE_CHANNEL = "mobile";

    private final TokenExchangeProvider delegate;

    public DpopMobileTokenExchangeProvider(TokenExchangeProvider delegate) {
        this.delegate = delegate;
    }

    @Override
    public boolean supports(TokenExchangeContext context) {
        // Yalnızca DMZ mobil client'ı; asıl exchange delegate (standart) tarafından yapılır.
        return isDmzMobileRequest(context);
    }

    @Override
    public Response exchange(TokenExchangeContext context) {
        String subject = context.getFormParams().getFirst("subject_token");
        if (subject != null) {
            try {
                String unbound = unbind(context.getSession(), context.getRealm(), subject);
                context.getFormParams().putSingle("subject_token", unbound);
            } catch (Exception e) {
                // Token içeriği loglanmaz; yalnızca reddetme nedeni
                LOG.warnf("dmz-mobile subject token rejected: %s", e.getMessage());
                return Response.status(Response.Status.BAD_REQUEST)
                        .entity("{\"error\":\"invalid_request\",\"error_description\":\"subject token rejected\"}")
                        .type("application/json")
                        .build();
            }
        }
        return delegate.exchange(context);
    }

    @Override
    public int getVersion() {
        return delegate.getVersion();
    }

    @Override
    public void close() {
        delegate.close();
    }

    private static boolean isDmzMobileRequest(TokenExchangeContext context) {
        ClientModel client = context.getClient();
        return client != null && DMZ_MOBILE_CLIENT.equals(client.getClientId());
    }

    /**
     * Subject token'ı realm anahtarıyla doğrular; cnf'li ise cnf'siz olarak yeniden imzalar.
     * Yalnızca azp=mobile-app ve channel=mobile olan token'lar kabul edilir.
     */
    static String unbind(KeycloakSession session, RealmModel realm, String token) throws Exception {
        KeyWrapper key = session.keys().getActiveKey(realm, KeyUse.SIG, "RS256");
        if (key == null || key.getPublicKey() == null || key.getPrivateKey() == null) {
            throw new IllegalStateException("active RS256 signing key not found");
        }
        PublicKey publicKey = (PublicKey) key.getPublicKey();
        AccessToken at = TokenVerifier.create(token, AccessToken.class)
                .publicKey(publicKey)
                .verify()
                .getToken();

        if (!MOBILE_TOKEN_AZP.equals(at.getIssuedFor())) {
            throw new IllegalArgumentException("subject token azp is not mobile-app");
        }
        Object channel = at.getOtherClaims().get("channel");
        if (!MOBILE_CHANNEL.equals(channel)) {
            throw new IllegalArgumentException("subject token channel is not mobile");
        }
        if (at.getConfirmation() == null) {
            return token; // zaten bağlamasız
        }

        at.setConfirmation(null);
        return new JWSBuilder()
                .type("JWT")
                .kid(key.getKid())
                .jsonContent(at)
                .rsa256((PrivateKey) key.getPrivateKey());
    }
}
