import { NextResponse } from "next/server";
import type { ProviderNote, ProviderNoteDraft, SyncResponse } from "@/lib/types";
import { serverEnv } from "@/lib/server/env";
import { countNotes, createNote, deleteNote, fetchNotes, updateNote } from "@/lib/server/mongo";

export const dynamic = "force-dynamic";

const MAX_TITLE = 200;
const MAX_BODY = 20_000;
const ALLOWED_TAGS = new Set(["b", "strong", "i", "em", "u", "ul", "ol", "li", "br", "p", "div"]);

function failure(error: unknown) {
  const message = error instanceof Error ? error.message : "Unexpected database error.";
  return NextResponse.json({ error: message }, { status: 500 });
}

function unavailable() {
  return serverEnv.mongoError ? NextResponse.json({ error: serverEnv.mongoError }, { status: 503 }) : null;
}

// Server-side copy of the client allowlist: keep basic formatting tags, drop every attribute and every other tag.
function sanitize(html: string): string {
  return html
    .replace(/<(script|style|iframe|object|template)[\s\S]*?<\/\1\s*>/gi, "")
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/<\s*(\/?)\s*([a-z0-9]+)[^>]*>/gi, (_, slash: string, tag: string) => {
      const name = tag.toLowerCase();
      return ALLOWED_TAGS.has(name) ? `<${slash}${name}>` : "";
    })
    .replace(/<(?![/a-z])/gi, "&lt;");
}

function plain(html: string): string {
  return html.replace(/<[^>]*>/g, "").replace(/&nbsp;/g, " ").trim();
}

function validate(input: unknown): ProviderNoteDraft | string {
  if (!input || typeof input !== "object") return "Body must be a JSON object.";
  const record = input as Record<string, unknown>;
  const title = typeof record.title === "string" ? record.title.trim() : "";
  const body = typeof record.body === "string" ? sanitize(record.body) : "";
  if (!title) return "A header is required.";
  if (title.length > MAX_TITLE) return `Header must be ${MAX_TITLE} characters or fewer.`;
  if (!plain(body)) return "The note is empty.";
  if (body.length > MAX_BODY) return "The note is too long.";
  return { title, body };
}

async function readJson(request: Request): Promise<Record<string, unknown> | null> {
  try {
    const value = await request.json();
    return value && typeof value === "object" ? (value as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

export async function GET(request: Request) {
  const blocked = unavailable();
  if (blocked) return blocked;
  const updatedAfter = new URL(request.url).searchParams.get("updatedAfter") ?? undefined;
  try {
    const [items, total] = await Promise.all([fetchNotes(updatedAfter), countNotes()]);
    const body: SyncResponse<ProviderNote> = { items, total, serverTime: new Date().toISOString() };
    return NextResponse.json(body);
  } catch (error) {
    return failure(error);
  }
}

export async function POST(request: Request) {
  const blocked = unavailable();
  if (blocked) return blocked;
  const input = await readJson(request);
  if (!input) return NextResponse.json({ error: "Invalid JSON." }, { status: 400 });
  const draft = validate(input);
  if (typeof draft === "string") return NextResponse.json({ error: draft }, { status: 400 });
  // Lets notes written before Mongo storage keep their original post date when uploaded.
  const createdAt = typeof input.createdAt === "string" ? new Date(input.createdAt) : new Date();
  const valid = !Number.isNaN(createdAt.getTime()) && createdAt.getTime() <= Date.now() ? createdAt : new Date();
  try {
    return NextResponse.json({ item: await createNote(draft, valid) }, { status: 201 });
  } catch (error) {
    return failure(error);
  }
}

export async function PATCH(request: Request) {
  const blocked = unavailable();
  if (blocked) return blocked;
  const input = await readJson(request);
  if (!input) return NextResponse.json({ error: "Invalid JSON." }, { status: 400 });
  if (typeof input.id !== "string" || !input.id) return NextResponse.json({ error: "A note ID is required." }, { status: 400 });
  const draft = validate(input);
  if (typeof draft === "string") return NextResponse.json({ error: draft }, { status: 400 });
  try {
    return NextResponse.json({ item: await updateNote(input.id, draft) });
  } catch (error) {
    return failure(error);
  }
}

export async function DELETE(request: Request) {
  const blocked = unavailable();
  if (blocked) return blocked;
  const id = new URL(request.url).searchParams.get("id");
  if (!id) return NextResponse.json({ error: "A note ID is required." }, { status: 400 });
  try {
    await deleteNote(id);
    return NextResponse.json({ ok: true });
  } catch (error) {
    return failure(error);
  }
}
