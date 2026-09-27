"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import type { ProviderNote, SyncResponse } from "@/lib/types";
import { readStored, writeStored } from "./storage";

const CACHE_KEY = "provider-notes-mongo-v1";
const LEGACY_KEY = "provider-notes-v1";
const SYNC_INTERVAL = 60_000;

type Cache = { notes: ProviderNote[]; cursor: string | null };
const EMPTY: Cache = { notes: [], cursor: null };

async function request<T>(url: string, init?: RequestInit): Promise<T> {
  const response = await fetch(url, { cache: "no-store", ...init, headers: init?.body ? { "Content-Type": "application/json" } : undefined });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error((body as { error?: string }).error ?? `Request failed (${response.status}).`);
  return body as T;
}

// Notes written before Mongo storage lived only in this browser. Upload them once, keeping their dates.
// Module-level so React's development double-mount cannot start a second upload of the same notes.
let legacyMigration: Promise<void> | null = null;

function migrateLegacy(): Promise<void> {
  legacyMigration ??= (async () => {
    const legacy = await readStored<ProviderNote[]>(LEGACY_KEY, []);
    if (!legacy.length) return;
    // Clear first, so a reload mid-upload cannot upload the same notes again.
    await writeStored(LEGACY_KEY, []);
    const remaining: ProviderNote[] = [];
    for (const item of legacy) {
      try {
        await request("/api/notes", { method: "POST", body: JSON.stringify({ title: item.title, body: item.body, createdAt: item.createdAt }) });
      } catch {
        remaining.push(item);
      }
    }
    if (remaining.length) await writeStored(LEGACY_KEY, remaining);
  })();
  return legacyMigration;
}

function merge(existing: ProviderNote[], incoming: ProviderNote[]): ProviderNote[] {
  const byId = new Map(existing.map((note) => [note.id, note]));
  for (const note of incoming) {
    if (note.deleted) byId.delete(note.id);
    else byId.set(note.id, note);
  }
  return [...byId.values()].sort((a, b) => b.createdAt.localeCompare(a.createdAt));
}

export function useProviderNotes() {
  const [cache, setCache] = useState(EMPTY);
  const [hydrated, setHydrated] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const ref = useRef(EMPTY);
  const inFlight = useRef(false);

  const commit = useCallback((next: Cache) => {
    ref.current = next;
    setCache(next);
    void writeStored(CACHE_KEY, next);
  }, []);

  const sync = useCallback(async () => {
    if (inFlight.current) return;
    inFlight.current = true;
    try {
      const cursor = ref.current.cursor;
      let result = await request<SyncResponse<ProviderNote>>(`/api/notes${cursor ? `?updatedAfter=${encodeURIComponent(cursor)}` : ""}`);
      let notes = cursor ? merge(ref.current.notes, result.items) : merge([], result.items);
      // Backdated notes never arrive as changes, so reload them all when the counts disagree.
      if (result.total !== undefined && notes.length !== result.total) {
        result = await request<SyncResponse<ProviderNote>>("/api/notes");
        notes = merge([], result.items);
      }
      commit({ notes, cursor: result.serverTime });
      setError(null);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Could not sync notes.");
    } finally {
      inFlight.current = false;
    }
  }, [commit]);

  useEffect(() => {
    let cancelled = false;
    void readStored(CACHE_KEY, EMPTY).then(async (stored) => {
      if (cancelled) return;
      ref.current = stored;
      setCache(stored);
      setHydrated(true);
      await migrateLegacy();
      if (!cancelled) await sync();
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

  const add = useCallback(async (title: string, body: string) => {
    const { item } = await request<{ item: ProviderNote }>("/api/notes", { method: "POST", body: JSON.stringify({ title, body }) });
    commit({ ...ref.current, notes: merge(ref.current.notes, [item]) });
  }, [commit]);

  const update = useCallback(async (id: string, title: string, body: string) => {
    const { item } = await request<{ item: ProviderNote }>("/api/notes", { method: "PATCH", body: JSON.stringify({ id, title, body }) });
    commit({ ...ref.current, notes: merge(ref.current.notes, [item]) });
  }, [commit]);

  const remove = useCallback(async (id: string) => {
    await request(`/api/notes?id=${encodeURIComponent(id)}`, { method: "DELETE" });
    commit({ ...ref.current, notes: ref.current.notes.filter((note) => note.id !== id) });
  }, [commit]);

  return { notes: cache.notes, hydrated, error, add, update, remove };
}
