package dev.dmzlab.idp.auth;

import jakarta.servlet.http.HttpSession;
import java.util.Map;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/** Web tarafı onay durumu: giriş yapmış oturum sorgular; APPROVED olunca oturum kapıdan geçer. */
@RestController
public class ApprovalStatusController {

    private final AuthStateRepository state;

    public ApprovalStatusController(AuthStateRepository state) {
        this.state = state;
    }

    @GetMapping("/realms/bank/approval/status")
    ResponseEntity<Map<String, Object>> status(HttpSession session) {
        Object id = session.getAttribute(ApprovalGateFilter.ID_KEY);
        if (id == null) {
            return ResponseEntity.ok(Map.of("state", "NONE"));
        }
        String st = state.approvalState(id.toString());
        if ("APPROVED".equals(st)) {
            session.setAttribute(ApprovalGateFilter.OK_KEY, id.toString());
        }
        return ResponseEntity.ok(Map.of("state", st == null ? "NONE" : st, "approvalId", id.toString()));
    }
}
