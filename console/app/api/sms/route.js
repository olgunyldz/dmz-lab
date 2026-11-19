import { smsBox } from "../../../lib/sms.js";
import { newTrace, withTrace } from "../../../lib/trace.js";

export const dynamic = "force-dynamic";

export async function GET() {
  return withTrace(smsBox(), newTrace("GET /api/sms"));
}
