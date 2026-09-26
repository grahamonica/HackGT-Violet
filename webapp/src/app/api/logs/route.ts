import { NextResponse } from "next/server";
import type { RecognitionLog, SyncResponse } from "@/lib/types";
import { serverEnv } from "@/lib/server/env";
import { fetchLogs } from "@/lib/server/mongo";

export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  if (serverEnv.mongoError) return NextResponse.json({ error: serverEnv.mongoError }, { status: 503 });
  const after = new URL(request.url).searchParams.get("after") ?? undefined;
  try {
    const body: SyncResponse<RecognitionLog> = {
      items: await fetchLogs(after),
      serverTime: new Date().toISOString(),
    };
    return NextResponse.json(body);
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unexpected database error.";
    return NextResponse.json({ error: message }, { status: 500 });
  }
}
