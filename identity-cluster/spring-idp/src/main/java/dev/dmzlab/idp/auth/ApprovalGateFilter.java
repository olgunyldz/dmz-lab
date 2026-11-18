package dev.dmzlab.idp.auth;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.servlet.http.HttpSession;
import java.io.IOException;
import java.util.List;
import org.springframework.security.authentication.AnonymousAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.web.filter.OncePerRequestFilter;

/**
 * Web girişi (client web-app) kapısı: kullanıcının kayıtlı bir mobil cihazı varsa, mobilde onay verilmeden
 * yetkilendirme kodu verilmez. Onay isteği kullanıcının tüm cihazlarına gider; ilk onay yeterlidir.
 * Kayıtlı cihazı olmayan kullanıcı için davranış değişmez.
 */
public final class ApprovalGateFilter extends OncePerRequestFilter {

    public static final String AUTH_PATH = "/realms/bank/protocol/openid-connect/auth";
    public static final String CLIENT = "web-app";
    /** Oturumdaki bekleyen onay kimliği. */
    public static final String ID_KEY = "approval.id";
    /** Oturumda onay tamamlandı (kod verilebilir). */
    public static final String OK_KEY = "approval.ok";

    private final AuthStateRepository state;

    public ApprovalGateFilter(AuthStateRepository state) {
        this.state = state;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res, FilterChain chain)
            throws ServletException, IOException {
        if (!AUTH_PATH.equals(req.getRequestURI()) || !CLIENT.equals(req.getParameter("client_id"))) {
            chain.doFilter(req, res);
            return;
        }
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        if (auth == null || !auth.isAuthenticated() || auth instanceof AnonymousAuthenticationToken) {
            chain.doFilter(req, res); // henüz giriş yok: giriş akışı devam eder
            return;
        }
        String user = auth.getName();
        List<String> devices = state.devicesFor(user);
        if (devices.isEmpty()) {
            chain.doFilter(req, res);
            return;
        }
        HttpSession session = req.getSession();
        if (session.getAttribute(OK_KEY) != null) {
            chain.doFilter(req, res);
            return;
        }
        Object pending = session.getAttribute(ID_KEY);
        String id = pending == null ? null : pending.toString();
        if (id == null || !"PENDING".equals(state.approvalState(id))) {
            id = state.createApproval(user, devices);
            session.setAttribute(ID_KEY, id);
        }
        res.setStatus(HttpServletResponse.SC_FORBIDDEN);
        res.setContentType("application/json");
        res.getWriter().write("{\"error\":\"approval_required\",\"approval_id\":\"" + id + "\",\"state\":\"PENDING\"}");
    }
}
