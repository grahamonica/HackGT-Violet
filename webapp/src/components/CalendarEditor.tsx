"use client";

import { useMemo, useState } from "react";
import type { CalendarEvent, CalendarEventDraft } from "@/lib/types";

type Props = {
  events: CalendarEvent[];
  connected: boolean;
  connecting: boolean;
  onConnect: () => void;
  onSave: (draft: CalendarEventDraft, id?: string) => Promise<void>;
};

function localDateTime(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60_000);
  return local.toISOString().slice(0, 16);
}

function eventDate(event: CalendarEvent): string {
  const date = new Date(event.start);
  if (event.allDay) return new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", year: "numeric" }).format(date);
  return new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }).format(date);
}

function initialDraft(event?: CalendarEvent): CalendarEventDraft {
  const start = event ? new Date(event.start) : new Date(Date.now() + 60 * 60 * 1000);
  start.setMinutes(0, 0, 0);
  const end = event ? new Date(event.end) : new Date(start.getTime() + 60 * 60 * 1000);
  return {
    title: event?.title ?? "",
    start: event?.allDay ? event.start.slice(0, 10) : localDateTime(start.toISOString()),
    end: event?.allDay ? event.end.slice(0, 10) : localDateTime(end.toISOString()),
    allDay: event?.allDay ?? false,
    location: event?.location ?? "",
  };
}

export function CalendarEditor({ events, connected, connecting, onConnect, onSave }: Props) {
  const upcoming = useMemo(() => events
    .filter((event) => new Date(event.end).getTime() >= Date.now())
    .sort((a, b) => a.start.localeCompare(b.start))
    .slice(0, 10), [events]);
  const [editing, setEditing] = useState<CalendarEvent | "new" | null>(null);
  const [draft, setDraft] = useState<CalendarEventDraft>(() => initialDraft());
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  function begin(event?: CalendarEvent) {
    setEditing(event ?? "new");
    setDraft(initialDraft(event));
    setError(null);
  }

  async function submit() {
    if (!draft.title.trim()) return setError("Event title is required.");
    if (!draft.start || !draft.end || new Date(draft.end).getTime() <= new Date(draft.start).getTime()) return setError("Event end must be after its start.");
    setBusy(true);
    setError(null);
    try {
      await onSave({ ...draft, title: draft.title.trim(), location: draft.location?.trim() }, editing === "new" ? undefined : editing?.id);
      setEditing(null);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Could not save the calendar event.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="calendar-editor" aria-labelledby="patient-calendar-title">
      <div className="edit-people-header">
        <h3 id="patient-calendar-title">Patient calendar</h3>
        {connected && !editing && <button type="button" className="text-button" onClick={() => begin()}>Add event</button>}
      </div>
      {!connected ? (
        <button type="button" className="connect-button" onClick={onConnect} disabled={connecting}>{connecting ? "Connecting…" : "Connect Google Calendar"}</button>
      ) : editing ? (
        <div className="calendar-event-form">
          <label><span>Event</span><input value={draft.title} onChange={(event) => setDraft({ ...draft, title: event.target.value })} /></label>
          <label className="checkbox-field"><input type="checkbox" checked={draft.allDay} onChange={(event) => setDraft({ ...draft, allDay: event.target.checked, start: event.target.checked ? draft.start.slice(0, 10) : localDateTime(new Date(draft.start).toISOString()), end: event.target.checked ? draft.end.slice(0, 10) : localDateTime(new Date(draft.end).toISOString()) })} /><span>All day</span></label>
          <div className="field-pair">
            <label><span>Start</span><input type={draft.allDay ? "date" : "datetime-local"} value={draft.start} onChange={(event) => setDraft({ ...draft, start: event.target.value })} /></label>
            <label><span>End</span><input type={draft.allDay ? "date" : "datetime-local"} value={draft.end} onChange={(event) => setDraft({ ...draft, end: event.target.value })} /></label>
          </div>
          <label><span>Location</span><input value={draft.location ?? ""} onChange={(event) => setDraft({ ...draft, location: event.target.value })} /></label>
          {error && <p className="form-error" role="alert">{error}</p>}
          <div className="inline-actions"><button type="button" className="secondary-button" onClick={() => setEditing(null)} disabled={busy}>Cancel</button><button type="button" className="primary-button" onClick={() => void submit()} disabled={busy}>{busy ? "Saving…" : "Save event"}</button></div>
        </div>
      ) : (
        <div className="calendar-event-list">
          {upcoming.length === 0 ? <p className="empty-state">No upcoming events.</p> : upcoming.map((event) => (
            <div key={event.id}><div><strong>{event.title}</strong><span>{eventDate(event)}{event.location ? ` · ${event.location}` : ""}</span></div><button type="button" className="text-button" onClick={() => begin(event)}>Edit</button></div>
          ))}
        </div>
      )}
    </section>
  );
}
