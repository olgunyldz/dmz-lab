// Mobil cihaz kimliği: cihaz sertifikası (device CA ile imzalı, CN=cihaz no) ve PIN/SMS adımlarında nonce imzası.
// Sertifika üretimi openssl ile geçici dizinde yapılır; özel anahtar yalnız sunucu belleğinde (oturumda) tutulur.
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { randomBytes, sign as cryptoSign } from "node:crypto";

const DEVICE_CA_CRT = path.resolve(process.cwd(), "..", "edge", "certs", "device", "device-ca.crt");
const DEVICE_CA_KEY = path.resolve(process.cwd(), "..", "edge", "certs", "device", "device-ca.key");

export function newDeviceId() {
  return "mob-" + randomBytes(3).toString("hex");
}

// Cihaz anahtarı + sertifikası (PEM). CN=deviceId, clientAuth.
export function createDeviceCert(deviceId) {
  if (!/^mob-[0-9a-f]{6}$/.test(deviceId)) throw new Error("cihaz kimliği geçersiz");
  const td = mkdtempSync(path.join(tmpdir(), "device-"));
  try {
    const key = path.join(td, "d.key"), csr = path.join(td, "d.csr"), crt = path.join(td, "d.crt");
    const cnf = path.join(td, "d.cnf"), ext = path.join(td, "d.ext");
    writeFileSync(cnf, `[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nCN=${deviceId}\n`);
    writeFileSync(ext, `subjectAltName=DNS:${deviceId}\nextendedKeyUsage=clientAuth\nbasicConstraints=CA:FALSE\n`);
    execFileSync("openssl", ["req", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", csr, "-config", cnf],
      { stdio: "ignore" });
    execFileSync("openssl", ["x509", "-req", "-in", csr, "-CA", DEVICE_CA_CRT, "-CAkey", DEVICE_CA_KEY,
      "-set_serial", "0x" + randomBytes(8).toString("hex"), "-out", crt, "-days", "1", "-extfile", ext],
      { stdio: "ignore" });
    return { cert: readFileSync(crt, "utf8"), key: readFileSync(key, "utf8") };
  } finally {
    rmSync(td, { recursive: true, force: true });
  }
}

// Seal nonce imzası (RSA PKCS#1 v1.5 / SHA-256, base64). Eski akışla aynı biçim.
export function signNonce(keyPem, nonce) {
  return cryptoSign("sha256", Buffer.from(nonce), keyPem).toString("base64");
}
