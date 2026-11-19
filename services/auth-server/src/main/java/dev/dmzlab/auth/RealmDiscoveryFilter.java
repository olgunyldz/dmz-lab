package dev.dmzlab.auth;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletRequestWrapper;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;

/**
 * auth-server uyumluluğu: /realms/bank/.well-known/openid-configuration yolu, Spring'in kökteki
 * /.well-known/openid-configuration discovery'sine çevrilir (Spring issuer yolu altında discovery sunmaz).
 *
 * Güvenlik zincirinden ÖNCE çalışmalı (bkz. AuthServerConfig): zincir isteği kökteki discovery olarak eşleyebilsin diye
 * isteğin URI'si değiştirilir. Bu yalnız discovery yolunu etkiler; diğer istekler dokunulmadan geçer.
 */
final class RealmDiscoveryFilter extends OncePerRequestFilter {

    static final String FROM = AuthServerConfig.REALM_PATH + "/.well-known/openid-configuration";
    static final String TO = "/.well-known/openid-configuration";

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        if (FROM.equals(request.getRequestURI())) {
            chain.doFilter(new RewrittenRequest(request, TO), response);
            return;
        }
        chain.doFilter(request, response);
    }

    /** Yalnız URI ve servlet yolunu değiştirir; diğer her şey orijinal istektir. */
    private static final class RewrittenRequest extends HttpServletRequestWrapper {
        private final String uri;

        RewrittenRequest(HttpServletRequest request, String uri) {
            super(request);
            this.uri = uri;
        }

        @Override
        public String getRequestURI() {
            return uri;
        }

        @Override
        public String getServletPath() {
            return uri;
        }

        @Override
        public StringBuffer getRequestURL() {
            String base = getScheme() + "://" + getServerName()
                    + (getServerPort() == 443 || getServerPort() == 80 ? "" : ":" + getServerPort());
            return new StringBuffer(base + uri);
        }
    }
}
