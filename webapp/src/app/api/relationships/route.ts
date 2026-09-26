import { NextResponse } from "next/server";
import type { PersonDraft, SyncResponse, Person } from "@/lib/types";
import { serverEnv } from "@/lib/server/env";
import { createRelationship, fetchRelationships, updateRelationship } from "@/lib/server/mongo";

export const dynamic = "force-dynamic";

function failure(error: unknown) {
  const message = error instanceof Error ? error.message : "Unexpected database error.";
  return NextResponse.json({ error: message }, { status: 500 });
}

export async function GET(request: Request) {
  if (serverEnv.mongoError) return NextResponse.json({ error: serverEnv.mongoError }, { status: 503 });
  const updatedAfter = new URL(request.url).searchParams.get("updatedAfter") ?? undefined;
  try {
    const body: SyncResponse<Person> = {
      items: await fetchRelationships(updatedAfter),
      serverTime: new Date().toISOString(),
    };
    return NextResponse.json(body);
  } catch (error) {
    return failure(error);
  }
}

function validate(input: unknown): PersonDraft | string {
  if (!input || typeof input !== "object") return "Body must be a JSON object.";
  const record = input as Record<string, unknown>;
  const value = (key: string) => (typeof record[key] === "string" ? record[key].trim() : "");
  const yearMet = Number(record.yearMet);
  const currentYear = new Date().getFullYear();
  const draft = {
    name: value("name"),
    relation: value("relation"),
    bio: value("bio"),
    frontPhoto: value("frontPhoto"),
    leftPhoto: value("leftPhoto"),
    rightPhoto: value("rightPhoto"),
    yearMet,
  };
  if (!draft.name) return "A name is required.";
  if (!draft.relation) return "A relationship is required.";
  if (!draft.frontPhoto || !draft.leftPhoto || !draft.rightPhoto) return "All three photos are required.";
  if (!Number.isInteger(yearMet) || yearMet < 1900 || yearMet > currentYear) {
    return `Year met must be between 1900 and ${currentYear}.`;
  }
  return draft;
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
    return NextResponse.json({ item: await createRelationship(draft) }, { status: 201 });
  } catch (error) {
    return failure(error);
  }
}

export async function PATCH(request: Request) {
  if (serverEnv.mongoError) return NextResponse.json({ error: serverEnv.mongoError }, { status: 503 });
  let input: unknown;
  try {
    input = await request.json();
  } catch {
    return NextResponse.json({ error: "Invalid JSON." }, { status: 400 });
  }
  if (!input || typeof input !== "object") return NextResponse.json({ error: "Body must be a JSON object." }, { status: 400 });
  const { id, ...personInput } = input as Record<string, unknown>;
  if (typeof id !== "string" || !id) return NextResponse.json({ error: "A familiar person ID is required." }, { status: 400 });
  const draft = validate(personInput);
  if (typeof draft === "string") return NextResponse.json({ error: draft }, { status: 400 });
  try {
    return NextResponse.json({ item: await updateRelationship(id, draft) });
  } catch (error) {
    return failure(error);
  }
}
