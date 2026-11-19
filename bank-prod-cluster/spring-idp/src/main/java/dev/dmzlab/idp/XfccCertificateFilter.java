package dev.dmzlab.idp;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * İç gateway'den (kgateway/Envoy) gelen istemci sertifikasını XFCC başlığından okur.
 * önceki IdP'deki x509cert-lookup=envoy + trust-proxy-verification karşılığı.
 *
 * GÜVEN: İç portta (düz HTTP, trustedPort; yalnız iç gateway ve iç düğümler, F8) veya TLS eşi iç gateway (CN=gw-internal)
 * ise çalışır. Diğer HTTPS istemcileri XFCC gönderemez: başlık yok sayılır.
 * Gateway, dış istemciden gelen XFCC'yi silmeli (Envoy SanitizeSet); bu lab'da listener-client-cert.yaml ile yapılır.
 */
final class XfccCertificateFilter extends OncePerRequestFilter {

    static final String CERT_ATTRIBUTE = "jakarta.servlet.request.X509Certificate";
    private static final String HEADER = "X-Forwarded-Client-Cert";
    private static final Pattern CERT = Pattern.compile("Cert=\"([^\"]*)\"");

    private final int trustedPort;
    private final X509Certificate trustedCa;

    /**
     * @param trustedCa lab CA. Envoy XFCC yalnız yaprak sertifikayı taşır; IdP yaprağın bu CA tarafından imzalandığını
     *                  doğrular ve zinciri [yaprak, CA] olarak kurar (Spring PKI modu zincir uzunluğu > 1 bekler).
     */
    XfccCertificateFilter(int trustedPort, X509Certificate trustedCa) {
        this.trustedPort = trustedPort;
        this.trustedCa = trustedCa;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        Object peer = request.getAttribute(CERT_ATTRIBUTE);
        boolean fromInternalPort = request.getLocalPort() == trustedPort && peer == null;
        // HTTPS portu: yalnız TLS eşi iç gateway (CN=gw-internal) ise XFCC'ye güvenilir (gateway istemci sertifikasını iletir)
        boolean fromGateway = request.getLocalPort() != trustedPort && isGateway(peer);
        if (fromInternalPort || fromGateway) {
            X509Certificate leaf = parse(request.getHeader(HEADER));
            if (leaf != null && verifiedBy(leaf, trustedCa)) {
                request.setAttribute(CERT_ATTRIBUTE, new X509Certificate[] {leaf, trustedCa});
            }
        }
        chain.doFilter(request, response);
    }

    /** TLS eşi iç gateway mi? (sertifika CN=gw-internal) */
    static boolean isGateway(Object peer) {
        if (!(peer instanceof X509Certificate[] certs) || certs.length == 0) {
            return false;
        }
        return certs[0].getSubjectX500Principal().getName().matches("(?s).*(^|,\s*)CN=gw-internal(,.*)?");
    }

    /** Yaprak, CA tarafından imzalanmış ve geçerlilik süresi içinde mi? */
    static boolean verifiedBy(X509Certificate leaf, X509Certificate ca) {
        try {
            if (!leaf.getIssuerX500Principal().equals(ca.getSubjectX500Principal())) {
                return false;
            }
            leaf.verify(ca.getPublicKey());
            leaf.checkValidity();
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    /** XFCC: ilk öğenin Cert="<url-encoded PEM>" alanı (Envoy böyle yazar). */
    static X509Certificate parse(String xfcc) {
        if (xfcc == null) {
            return null;
        }
        Matcher m = CERT.matcher(xfcc);
        if (!m.find()) {
            return null;
        }
        String pem = URLDecoder.decode(m.group(1), StandardCharsets.UTF_8);
        try (ByteArrayInputStream in = new ByteArrayInputStream(pem.getBytes(StandardCharsets.UTF_8))) {
            return (X509Certificate) CertificateFactory.getInstance("X.509").generateCertificate(in);
        } catch (Exception e) {
            return null;
        }
    }
}
