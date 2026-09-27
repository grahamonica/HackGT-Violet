"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { CalendarEvent, CalendarEventDraft } from "@/lib/types";
import { addDays, startOfDay } from "@/lib/date";
import { readStored, writeStored } from "./storage";

const CACHE_KEY = "google-calendar-v1";
const TOKEN_KEY = "violet-google-token";
const SYNC_INTERVAL = 60_000;
const GOOGLE_SCOPE = "openid profile email https://www.googleapis.com/auth/calendar.events";

type Cache = { events: CalendarEvent[]; profileName: string; lastSyncedAt: string | null };
type SessionToken = { accessToken: string; expiresAt: number; scope: string };
type TokenResponse = { access_token?: string; expires_in?: number; error?: string };
type TokenClient = { requestAccessToken: (options?: { prompt?: string }) => void };

declare global {
  interface Window {
    google?: {
      accounts: {
        oauth2: {
          initTokenClient: (config: {
            client_id: string;
            scope: string;
            callback: (response: TokenResponse) => void;
            error_callback?: (error: unknown) => void;
          }) => TokenClient;
        };
      };
    };
  }
}

const EMPTY: Cache = { events: [], profileName: "", lastSyncedAt: null };
let scriptPromise: Promise<void> | null = null;

function loadGoogleScript(): Promise<void> {
  if (window.google?.accounts.oauth2) return Promise.resolve();
  if (scriptPromise) return scriptPromise;
  scriptPromise = new Promise((resolve, reject) => {
    const existing = document.querySelector<HTMLScriptElement>('script[src="https://accounts.google.com/gsi/client"]');
    const script = existing ?? document.createElement("script");
    script.src = "https://accounts.google.com/gsi/client";
    script.async = true;
    script.defer = true;
    script.onload = () => resolve();
    script.onerror = () => reject(new Error("Could not load Google sign-in."));
    if (!existing) document.head.appendChild(script);
  });
  return scriptPromise;
}

function readToken(): SessionToken | null {
  try {
    const raw = window.sessionStorage.getItem(TOKEN_KEY);
    if (!raw) return null;
    const token = JSON.parse(raw) as SessionToken;
    return token.expiresAt > Date.now() + 30_000 && token.scope === GOOGLE_SCOPE ? token : null;
  } catch {
    return null;
  }
}

function storeToken(response: TokenResponse): SessionToken {
  if (!response.access_token) throw new Error(response.error || "Google did not return an access token.");
  const token = { accessToken: response.access_token, expiresAt: Date.now() + (response.expires_in ?? 3600) * 1000, scope: GOOGLE_SCOPE };
  window.sessionStorage.setItem(TOKEN_KEY, JSON.stringify(token));
  return token;
}

async function googleJSON<T>(url: string, accessToken: string): Promise<T> {
  const response = await fetch(url, { headers: { Authorization: `Bearer ${accessToken}` }, cache: "no-store" });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error((body as { error?: { message?: string } }).error?.message ?? `Google request failed (${response.status}).`);
  return body as T;
}

export function useGoogleCalendar(from: Date, to: Date) {
  const [cache, setCache] = useState<Cache>(EMPTY);
  const [hydrated, setHydrated] = useState(false);
  const [connecting, setConnecting] = useState(false);
  const [syncing, setSyncing] = useState(false);
  const [connected, setConnected] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const inFlight = useRef(false);

  const fromTime = startOfDay(from).getTime();
  const toTime = addDays(startOfDay(to), 1).getTime();
  const range = useMemo(() => {
    // Always reach two weeks ahead so upcoming visits stay available to the calendar editor.
    const ahead = addDays(new Date(), 15).getTime();
    return {
      start: new Date(fromTime).toISOString(),
      end: new Date(Math.max(toTime, ahead)).toISOString(),
    };
  }, [fromTime, toTime]);

  const syncWithToken = useCallback(async (token: SessionToken) => {
    if (inFlight.current) return;
    inFlight.current = true;
    setSyncing(true);
    try {
      const profile = await googleJSON<{ name?: string }>("https://openidconnect.googleapis.com/v1/userinfo", token.accessToken);
      const params = new URLSearchParams({
        timeMin: range.start,
        timeMax: range.end,
        singleEvents: "true",
        orderBy: "startTime",
        maxResults: "2500",
      });
      const result = await googleJSON<{
        items?: Array<{
          id: string;
          summary?: string;
          location?: string;
          start: { date?: string; dateTime?: string };
          end: { date?: string; dateTime?: string };
        }>;
      }>(`https://www.googleapis.com/calendar/v3/calendars/primary/events?${params}`, token.accessToken);
      const events: CalendarEvent[] = (result.items ?? []).map((item) => {
        const allDay = Boolean(item.start.date);
        return {
          id: item.id,
          title: item.summary ?? "Untitled",
          start: item.start.dateTime ?? `${item.start.date}T00:00:00`,
          end: item.end.dateTime ?? `${item.end.date}T00:00:00`,
          allDay,
          location: item.location,
        };
      });
      const next = { events, profileName: profile.name?.trim() ?? "", lastSyncedAt: new Date().toISOString() };
      setCache(next);
      void writeStored(CACHE_KEY, next);
      setConnected(true);
      setError(null);
    } catch (reason) {
      setConnected(false);
      setError(reason instanceof Error ? reason.message : "Google Calendar sync failed.");
    } finally {
      inFlight.current = false;
      setSyncing(false);
    }
  }, [range.end, range.start]);

  const connect = useCallback(async () => {
    setConnecting(true);
    setError(null);
    try {
      const configResponse = await fetch("/api/google/config", { cache: "no-store" });
      const config = (await configResponse.json().catch(() => ({}))) as { clientId?: string; error?: string };
      if (!configResponse.ok || !config.clientId) throw new Error(config.error ?? "Google OAuth is not configured.");
      const clientId = config.clientId;
      await loadGoogleScript();
      const response = await new Promise<TokenResponse>((resolve, reject) => {
        if (!window.google) return reject(new Error("Google sign-in did not load."));
        const client = window.google.accounts.oauth2.initTokenClient({
          client_id: clientId,
          scope: GOOGLE_SCOPE,
          callback: resolve,
          error_callback: reject,
        });
        client.requestAccessToken({ prompt: "consent" });
      });
      const token = storeToken(response);
      await syncWithToken(token);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Could not connect Google Calendar.");
    } finally {
      setConnecting(false);
    }
  }, [syncWithToken]);

  const saveEvent = useCallback(async (draft: CalendarEventDraft, id?: string) => {
    const token = readToken();
    if (!token) throw new Error("Connect Google Calendar to save events.");
    const endpoint = id
      ? `https://www.googleapis.com/calendar/v3/calendars/primary/events/${encodeURIComponent(id)}`
      : "https://www.googleapis.com/calendar/v3/calendars/primary/events";
    const start = draft.allDay ? { date: draft.start.slice(0, 10) } : { dateTime: new Date(draft.start).toISOString() };
    const end = draft.allDay ? { date: draft.end.slice(0, 10) } : { dateTime: new Date(draft.end).toISOString() };
    const response = await fetch(endpoint, {
      method: id ? "PATCH" : "POST",
      headers: { Authorization: `Bearer ${token.accessToken}`, "Content-Type": "application/json" },
      body: JSON.stringify({ summary: draft.title, location: draft.location || undefined, start, end }),
    });
    const body = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error((body as { error?: { message?: string } }).error?.message ?? `Google request failed (${response.status}).`);
    await syncWithToken(token);
  }, [syncWithToken]);

  useEffect(() => {
    let cancelled = false;
    void readStored(CACHE_KEY, EMPTY).then((stored) => {
      if (cancelled) return;
      setCache(stored);
      setHydrated(true);
      const token = readToken();
      if (token) void syncWithToken(token);
    });
    const refresh = () => {
      const token = readToken();
      if (document.visibilityState === "visible" && token) void syncWithToken(token);
    };
    const interval = window.setInterval(refresh, SYNC_INTERVAL);
    document.addEventListener("visibilitychange", refresh);
    return () => {
      cancelled = true;
      window.clearInterval(interval);
      document.removeEventListener("visibilitychange", refresh);
    };
  }, [syncWithToken]);

  return { ...cache, hydrated, connected, connecting, syncing, error, connect, saveEvent };
}
