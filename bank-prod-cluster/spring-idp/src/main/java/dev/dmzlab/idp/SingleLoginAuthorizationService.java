package dev.dmzlab.idp;

import org.springframework.jdbc.core.JdbcOperations;
import org.springframework.security.oauth2.core.AuthorizationGrantType;
import org.springframework.security.oauth2.server.authorization.OAuth2Authorization;
import org.springframework.security.oauth2.server.authorization.OAuth2AuthorizationService;
import org.springframework.security.oauth2.server.authorization.OAuth2TokenType;

/**
 * Kullanıcı başına TEK AKTİF GİRİŞ (web ve mobil birbirini düşürür; son giriş kazanır).
 *
 * Bir authorization_code oturumu token'ları ilk kez aldığında (access token önceden yoktu) aynı kullanıcının
 * diğer authorization_code oturumları silinir. Silinen oturumların token'ları ve refresh token'ları geçersiz olur:
 * token exchange ({@link TokenExchange}) ve introspection bu kayıtlara bakar.
 *
 * Client credentials (servis) oturumlarına dokunmaz: principal burada istemci kimliğidir, kullanıcı değildir.
 * Refresh ile güncellenen mevcut oturum (aynı id, zaten token'lı) yeni giriş sayılmaz; oturumu düşürmez.
 */
final class SingleLoginAuthorizationService implements OAuth2AuthorizationService {

    private final OAuth2AuthorizationService delegate;
    private final JdbcOperations jdbc;

    SingleLoginAuthorizationService(OAuth2AuthorizationService delegate, JdbcOperations jdbc) {
        this.delegate = delegate;
        this.jdbc = jdbc;
    }

    @Override
    public void save(OAuth2Authorization authorization) {
        OAuth2Authorization previous = delegate.findById(authorization.getId());
        boolean loginCompleted = AuthorizationGrantType.AUTHORIZATION_CODE.equals(authorization.getAuthorizationGrantType())
                && authorization.getAccessToken() != null
                && (previous == null || previous.getAccessToken() == null);
        if (loginCompleted && authorization.getPrincipalName() != null) {
            jdbc.update("DELETE FROM oauth2_authorization WHERE principal_name = ? "
                    + "AND authorization_grant_type = ? AND id <> ?",
                    authorization.getPrincipalName(), AuthorizationGrantType.AUTHORIZATION_CODE.getValue(),
                    authorization.getId());
        }
        delegate.save(authorization);
    }

    @Override
    public void remove(OAuth2Authorization authorization) {
        delegate.remove(authorization);
    }

    @Override
    public OAuth2Authorization findById(String id) {
        return delegate.findById(id);
    }

    @Override
    public OAuth2Authorization findByToken(String token, OAuth2TokenType tokenType) {
        return delegate.findByToken(token, tokenType);
    }
}
