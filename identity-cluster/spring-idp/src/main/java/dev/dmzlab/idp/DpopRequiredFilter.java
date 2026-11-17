package dev.dmzlab.idp;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;

/**
 * mobile-app token isteğinde DPoP başlığı zorunlu (önceki IdP'deki dpop.bound.access.tokens=true karşılığı).
 * Token endpoint'ten ÖNCE çalışır: istemci kimliği form parametresinden okunur, böylece public istemcide de geçerli.
 * Başka istemcilere dokunmaz. Yetkilendirme sunucusu converter zinciri bu isteği görmediği için converter yerine filtre.
 */
final class DpopRequiredFilter extends OncePerRequestFilter {

    private final String tokenPath;

    DpopRequiredFilter(String tokenPath) {
        this.tokenPath = tokenPath;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        boolean tokenRequest = "POST".equalsIgnoreCase(request.getMethod())
                && tokenPath.equals(request.getRequestURI());
        if (tokenRequest
                && "mobile-app".equals(request.getParameter("client_id"))
                && request.getHeader("DPoP") == null) {
            response.setStatus(HttpServletResponse.SC_BAD_REQUEST);
            response.setContentType("application/json");
            response.getWriter().write(
                    "{\"error\":\"invalid_dpop_proof\",\"error_description\":\"mobile-app için DPoP proof gerekli\"}");
            return;
        }
        chain.doFilter(request, response);
    }
}
