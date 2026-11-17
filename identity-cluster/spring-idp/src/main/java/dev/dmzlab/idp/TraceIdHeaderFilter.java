package dev.dmzlab.idp;

import io.micrometer.tracing.Span;
import io.micrometer.tracing.Tracer;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;

/**
 * Yanıta X-Trace-Id ekler: UI/konsol bu değeri ekranda gösterir ve Tempo'da aramak için kullanır.
 * Gelen traceparent varsa Micrometer onu kullanır (zincir kopmaz); X-Trace-Id tek başına gelirse IdP yeni iz açar.
 */
final class TraceIdHeaderFilter extends OncePerRequestFilter {

    static final String HEADER = "X-Trace-Id";
    private final Tracer tracer;

    TraceIdHeaderFilter(Tracer tracer) {
        this.tracer = tracer;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        Span span = tracer.currentSpan();
        if (span != null && span.context().traceId() != null) {
            response.setHeader(HEADER, span.context().traceId());
        }
        chain.doFilter(request, response);
    }
}
