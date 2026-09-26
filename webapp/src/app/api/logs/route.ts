import { NextResponse } from "next/server";
import type { RecognitionLog, RecognitionLogDraft, SyncResponse } from "@/lib/types";
import { serverEnv } from "@/lib/server/env";
import { createRecognitionLog, fetchLogs } from "@/lib/server/mongo";

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

function validate(input: unknown): RecognitionLogDraft | string {
  if (!input || typeof input !== "object") return "Body must be a JSON object.";
  const record = input as Record<string, unknown>;
  const timestamp = typeof record.timestamp === "string" ? record.timestamp.trim() : "";
  const identifiedPerson =
    typeof record.identifiedPerson === "string"
      ? record.identifiedPerson.trim()
      : typeof record.identified_person === "string"
        ? record.identified_person.trim()
        : "";
  if (!timestamp || Number.isNaN(new Date(timestamp).getTime())) return "A valid timestamp is required.";
  if (!identifiedPerson) return "An identified person is required.";
  return { timestamp, identifiedPerson };
}

export async function POST(request: Request) {
  if (serverEnv.mongoError) return NextResponse.json({ error: serverEnv.mongoError }, { status: 503 });
  let input: unknown;
  try {
    input = await request.json();
  } catch {
    return NextResponse.json({ error: "Invalid JSON." }, { status: 400 });
  }
  const draft = validate(input);
  if (typeof draft === "string") return NextResponse.json({ error: draft }, { status: 400 });
  try {
    return NextResponse.json({ item: await createRecognitionLog(draft) }, { status: 201 });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unexpected database error.";
    return NextResponse.json({ error: message }, { status: 500 });
  }
}
