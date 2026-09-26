"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import type { Person, PersonDraft, RecognitionLog, SyncResponse } from "@/lib/types";
import { readStored, writeStored } from "./storage";

const CACHE_KEY = "patient-data-v1";
const SYNC_INTERVAL = 60_000;

type Cache = {
  people: Person[];
  logs: RecognitionLog[];
  peopleCursor: string | null;
  logsCursor: string | null;
  lastSyncedAt: string | null;
};

const EMPTY: Cache = { people: [], logs: [], peopleCursor: null, logsCursor: null, lastSyncedAt: null };

async function getJSON<T>(url: string): Promise<T> {
  const response = await fetch(url, { cache: "no-store" });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error((body as { error?: string }).error ?? `Request failed (${response.status}).`);
  return body as T;
}

function mergeById<T extends { id: string }>(existing: T[], incoming: T[]): T[] {
  const byId = new Map(existing.map((item) => [item.id, item]));
  for (const item of incoming) byId.set(item.id, item);
  return [...byId.values()];
}

export function usePatientData() {
  const [cache, setCache] = useState<Cache>(EMPTY);
  const [hydrated, setHydrated] = useState(false);
  const [syncing, setSyncing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const cacheRef = useRef(EMPTY);
  const inFlight = useRef(false);

  const commit = useCallback((next: Cache) => {
    cacheRef.current = next;
    setCache(next);
    void writeStored(CACHE_KEY, next);
  }, []);

  const sync = useCallback(async () => {
    if (inFlight.current) return;
    inFlight.current = true;
    setSyncing(true);
    const current = cacheRef.current;
    const peopleQuery = current.peopleCursor ? `?updatedAfter=${encodeURIComponent(current.peopleCursor)}` : "";
    const logsQuery = current.logsCursor ? `?after=${encodeURIComponent(current.logsCursor)}` : "";
    const [peopleResult, logsResult] = await Promise.allSettled([
      getJSON<SyncResponse<Person>>(`/api/relationships${peopleQuery}`),
      getJSON<SyncResponse<RecognitionLog>>(`/api/logs${logsQuery}`),
    ]);

    let next = current;
    const errors: string[] = [];
    if (peopleResult.status === "fulfilled") {
      next = {
        ...next,
        people: mergeById(next.people, peopleResult.value.items).sort((a, b) => a.name.localeCompare(b.name)),
        peopleCursor: peopleResult.value.serverTime,
      };
    } else {
      errors.push(peopleResult.reason instanceof Error ? peopleResult.reason.message : "Could not sync familiar people.");
    }
    if (logsResult.status === "fulfilled") {
      next = {
        ...next,
        logs: mergeById(next.logs, logsResult.value.items).sort((a, b) => a.timestamp.localeCompare(b.timestamp)),
        logsCursor: logsResult.value.serverTime,
      };
    } else {
      errors.push(logsResult.reason instanceof Error ? logsResult.reason.message : "Could not sync recognition logs.");
    }
    if (peopleResult.status === "fulfilled" || logsResult.status === "fulfilled") {
      next = { ...next, lastSyncedAt: new Date().toISOString() };
      commit(next);
    }
    setError(errors.length ? [...new Set(errors)].join(" ") : null);
    setSyncing(false);
    inFlight.current = false;
  }, [commit]);

  useEffect(() => {
    let cancelled = false;
    void readStored(CACHE_KEY, EMPTY).then((stored) => {
      if (cancelled) return;
      cacheRef.current = stored;
      setCache(stored);
      setHydrated(true);
      void sync();
    });
    const refresh = () => {
      if (document.visibilityState === "visible") void sync();
    };
    const interval = window.setInterval(refresh, SYNC_INTERVAL);
    document.addEventListener("visibilitychange", refresh);
    return () => {
      cancelled = true;
      window.clearInterval(interval);
      document.removeEventListener("visibilitychange", refresh);
    };
  }, [sync]);

  const addPerson = useCallback(async (draft: PersonDraft) => {
    const response = await fetch("/api/relationships", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(draft),
    });
    const body = (await response.json().catch(() => ({}))) as { item?: Person; error?: string };
    if (!response.ok || !body.item) throw new Error(body.error ?? `Could not save (${response.status}).`);
    const current = cacheRef.current;
    commit({ ...current, people: mergeById(current.people, [body.item]).sort((a, b) => a.name.localeCompare(b.name)) });
    return body.item;
  }, [commit]);

  const updatePerson = useCallback(async (id: string, draft: PersonDraft) => {
    const response = await fetch("/api/relationships", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ id, ...draft }),
    });
    const body = (await response.json().catch(() => ({}))) as { item?: Person; error?: string };
    if (!response.ok || !body.item) throw new Error(body.error ?? `Could not save (${response.status}).`);
    const current = cacheRef.current;
    commit({ ...current, people: mergeById(current.people, [body.item]).sort((a, b) => a.name.localeCompare(b.name)) });
    return body.item;
  }, [commit]);

  return { ...cache, hydrated, syncing, error, sync, addPerson, updatePerson };
}
