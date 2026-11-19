// Oturum deposu (sunucu belleği). Her tarayıcı bir "sid" çerezi taşır.
import { randomBytes, randomUUID } from "node:crypto";
import { cookies } from "next/headers";

const store = globalThis.__consoleSessions ?? (globalThis.__consoleSessions = new Map());

function fresh() {
  return {
    web: { device: "web-" + randomBytes(4).toString("hex"), flow: randomBytes(12).toString("hex") },
    mobile: {},
  };
}

// Çerezden oturumu al; yoksa oluştur.
export async function session() {
  const jar = await cookies();
  let sid = jar.get("sid")?.value;
  if (!sid || !store.has(sid)) {
    sid = randomUUID();
    store.set(sid, fresh());
    jar.set("sid", sid, { httpOnly: true, sameSite: "lax", path: "/" });
  }
  return store.get(sid);
}

export function summary(sess) {
  const out = {};
  for (const ch of ["web", "mobile"]) {
    const c = sess[ch] || {};
    out[ch] = { loggedIn: Boolean(c.token), customerId: c.customerId ?? null, fullName: c.fullName ?? null };
  }
  return out;
}
