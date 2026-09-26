import { MongoClient, ObjectId, type Document, type Filter } from "mongodb";
import type { Person, PersonDraft, RecognitionLog, RecognitionLogDraft } from "@/lib/types";
import { serverEnv } from "./env";

declare global {
  var __violetMongoClient: Promise<MongoClient> | undefined;
}

function client(): Promise<MongoClient> {
  if (serverEnv.mongoError) throw new Error(serverEnv.mongoError);
  if (!global.__violetMongoClient) {
    global.__violetMongoClient = new MongoClient(serverEnv.mongoUri).connect();
  }
  return global.__violetMongoClient;
}

async function database() {
  return (await client()).db(serverEnv.mongoDatabase);
}

function text(value: unknown, fallback = ""): string {
  return typeof value === "string" ? value : value == null ? fallback : String(value);
}

function dateValue(value: unknown, fallback: Date): Date {
  if (value instanceof Date) return value;
  const parsed = typeof value === "string" || typeof value === "number" ? new Date(value) : fallback;
  return Number.isNaN(parsed.getTime()) ? fallback : parsed;
}

function person(document: Document): Person {
  return {
    id: document._id?.toString() ?? crypto.randomUUID(),
    name: text(document.name),
    frontPhoto: text(document.front_photo ?? document.frontPhoto),
    leftPhoto: text(document.left_photo ?? document.leftPhoto),
    rightPhoto: text(document.right_photo ?? document.rightPhoto),
    relation: text(document.relation),
    bio: text(document.bio),
    yearMet: Number(document.year_met ?? document.yearMet) || new Date().getFullYear(),
    updatedAt: dateValue(document.updated_at ?? document.updatedAt, new Date(0)).toISOString(),
  };
}

function log(document: Document): RecognitionLog {
  const timestamp = dateValue(document.timestamp, new Date(0)).toISOString();
  const identifiedPerson = text(document.identified_person ?? document.identifiedPerson, "Unknown") || "Unknown";
  return {
    id: document._id?.toString() ?? `${timestamp}:${identifiedPerson}`,
    timestamp,
    identifiedPerson,
  };
}

function changeFilter(cursor?: string): Filter<Document> {
  if (!cursor) return {};
  const after = new Date(cursor);
  if (Number.isNaN(after.getTime())) return {};
  const objectId = ObjectId.createFromTime(Math.floor(after.getTime() / 1000));
  return {
    $or: [
      { updated_at: { $gt: after } },
      { updatedAt: { $gt: after } },
      { created_at: { $gt: after } },
      { _id: { $gt: objectId } },
    ],
  };
}

export async function fetchRelationships(updatedAfter?: string): Promise<Person[]> {
  const db = await database();
  const documents = await db.collection(serverEnv.relationshipsPath).find(changeFilter(updatedAfter)).toArray();
  return documents.map(person);
}

export async function fetchLogs(after?: string): Promise<RecognitionLog[]> {
  const db = await database();
  const documents = await db.collection(serverEnv.logsPath).find(changeFilter(after)).toArray();
  return documents.map(log);
}

export async function createRecognitionLog(draft: RecognitionLogDraft): Promise<RecognitionLog> {
  const db = await database();
  const timestamp = new Date(draft.timestamp);
  const document = {
    timestamp,
    identifiedPerson: draft.identifiedPerson,
  };
  const result = await db.collection(serverEnv.logsPath).insertOne(document);
  return {
    id: result.insertedId.toString(),
    timestamp: timestamp.toISOString(),
    identifiedPerson: draft.identifiedPerson,
  };
}

export async function createRelationship(draft: PersonDraft): Promise<Person> {
  const db = await database();
  const now = new Date();
  const document = {
    name: draft.name,
    frontPhoto: draft.frontPhoto,
    leftPhoto: draft.leftPhoto,
    rightPhoto: draft.rightPhoto,
    relation: draft.relation,
    bio: draft.bio,
    yearMet: draft.yearMet,
    createdAt: now,
    updatedAt: now,
  };
  const result = await db.collection(serverEnv.relationshipsPath).insertOne(document);
  return { ...draft, id: result.insertedId.toString(), updatedAt: now.toISOString() };
}

export async function updateRelationship(id: string, draft: PersonDraft): Promise<Person> {
  if (!ObjectId.isValid(id)) throw new Error("Invalid familiar person ID.");
  const db = await database();
  const now = new Date();
  const result = await db.collection(serverEnv.relationshipsPath).updateOne(
    { _id: new ObjectId(id) },
    {
      $set: {
        name: draft.name,
        frontPhoto: draft.frontPhoto,
        leftPhoto: draft.leftPhoto,
        rightPhoto: draft.rightPhoto,
        relation: draft.relation,
        bio: draft.bio,
        yearMet: draft.yearMet,
        updatedAt: now,
      },
      $unset: {
        front_photo: "",
        left_photo: "",
        right_photo: "",
        year_met: "",
        updated_at: "",
      },
    },
  );
  if (!result.matchedCount) throw new Error("Familiar person not found.");
  return { ...draft, id, updatedAt: now.toISOString() };
}
