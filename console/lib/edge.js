// Edge (HAProxy) üzerinden TLS çağrısı. Sunucu tarafında çalışır (tarayıcı bu dosyayı görmez).
// Konsol yalnızca DMZ hostlarına gider: web.lab.local, mobile-api.lab.local, seal.lab.local (SNI ve Host başlığı).
// opts.ca: sunucu sertifikası CA'sı (varsayılan: public CA). opts.cert/key: cihaz istemci sertifikası (PEM, mTLS).
import https from "node:https";
import fs from "node:fs";
import path from "node:path";

const EDGE_PORT = 8443;
const CA_FILES = {
  public: path.resolve(process.cwd(), "..", "edge", "certs", "public-ca.crt"),
  internal: path.resolve(process.cwd(), "..", "edge", "certs", "internal-ca.crt"),
};
const cache = {};
function caPem(kind) {
  if (!cache[kind]) cache[kind] = fs.readFileSync(CA_FILES[kind]);
  return cache[kind];
}

export function edgeCall(host, method, urlPath, headers = {}, obj, opts = {}) {
  const body = obj === undefined ? undefined : Buffer.from(JSON.stringify(obj));
  return new Promise((resolve, reject) => {
    const req = https.request(
      {
        host: "127.0.0.1",
        port: EDGE_PORT,
        method,
        path: urlPath,
        servername: host,
        ca: caPem(opts.ca || "public"),
        cert: opts.cert,
        key: opts.key,
        rejectUnauthorized: true,
        headers: {
          Host: host,
          Connection: "close",
          ...(body ? { "Content-Type": "application/json", "Content-Length": body.length } : {}),
          ...headers,
        },
      },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          let data = {};
          try { data = JSON.parse(Buffer.concat(chunks).toString() || "{}"); } catch { data = {}; }
          resolve({ status: res.statusCode, data });
        });
      },
    );
    req.on("error", reject);
    if (body) req.write(body);
    req.end();
  });
}
