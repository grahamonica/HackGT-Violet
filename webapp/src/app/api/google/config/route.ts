import { NextResponse } from "next/server";
import { serverEnv } from "@/lib/server/env";

export const dynamic = "force-dynamic";

export function GET() {
  if (!serverEnv.googleClientId) {
    return NextResponse.json({ error: "GOOGLE_CLIENT_ID is not configured." }, { status: 503 });
  }
  return NextResponse.json({ clientId: serverEnv.googleClientId });
}
