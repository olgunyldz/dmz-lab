import { session, summary } from "../../../lib/sessions.js";
import { newTrace, withTrace } from "../../../lib/trace.js";

export const dynamic = "force-dynamic";

export async function GET() {
  const sess = await session();
  return withTrace(summary(sess), newTrace("GET /api/state"));
}
