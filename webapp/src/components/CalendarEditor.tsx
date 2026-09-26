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

const DAY_COUNT = 3;
const DAY_MS = 24 * 60 * 60 * 1000;

function localDateTime(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60_000);
  return local.toISOString().slice(0, 16);
}

function startOfDay(date: Date): Date {
  const day = new Date(date);
  day.setHours(0, 0, 0, 0);
  return day;
}

function addDays(date: Date, days: number): Date {
  const next = new Date(date);
  next.setDate(next.getDate() + days);
  return next;
}

function sameDay(a: Date, b: Date): boolean {
  return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
}

function eventTime(event: CalendarEvent, day: Date): string {
  if (event.allDay) return "All day";
  const start = new Date(event.start);
  const end = new Date(event.end);
  const time = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" });
  const from = sameDay(start, day) ? time.format(start) : "…";
  const to = sameDay(end, day) ? time.format(end) : "…";
  return `${from} – ${to}`;
}

function initialDraft(event?: CalendarEvent, day?: Date): CalendarEventDraft {
  let start: Date;
  if (event) start = new Date(event.start);
  else if (day && !sameDay(day, new Date())) start = new Date(day.getFullYear(), day.getMonth(), day.getDate(), 9);
  else start = new Date(Date.now() + 60 * 60 * 1000);
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
  const [offset, setOffset] = useState(0);
  const [editing, setEditing] = useState<CalendarEvent | "new" | null>(null);
  const [draft, setDraft] = useState<CalendarEventDraft>(() => initialDraft());
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const days = useMemo(() => {
    const today = startOfDay(new Date());
    return Array.from({ length: DAY_COUNT }, (_, index) => {
      const day = addDays(today, offset + index);
      const dayStart = day.getTime();
      const dayEnd = dayStart + DAY_MS;
      const items = events
        .filter((event) => {
          const start = new Date(event.start).getTime();
          const end = new Date(event.end).getTime();
          return start < dayEnd && end > dayStart;
        })
        .sort((a, b) => Number(b.allDay) - Number(a.allDay) || a.start.localeCompare(b.start));
      return { day, isToday: offset + index === 0, items };
    });
  }, [events, offset]);

  const rangeLabel = useMemo(() => {
    const format = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" });
    return `${format.format(days[0].day)} – ${format.format(days[days.length - 1].day)}`;
  }, [days]);

  function begin(event?: CalendarEvent, day?: Date) {
    setEditing(event ?? "new");
    setDraft(initialDraft(event, day));
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
        <div className="calendar-days">
          <div className="calendar-days-nav">
            <button type="button" className="text-button" onClick={() => setOffset(offset - DAY_COUNT)} aria-label="Previous days">‹</button>
            <span>{rangeLabel}</span>
            <button type="button" className="text-button" onClick={() => setOffset(offset + DAY_COUNT)} aria-label="Next days">›</button>
            {offset !== 0 && <button type="button" className="text-button calendar-today-button" onClick={() => setOffset(0)}>Back to today</button>}
          </div>
          <div className="calendar-day-columns">
            {days.map(({ day, isToday, items }) => (
              <div key={day.toISOString()} className={isToday ? "calendar-day today" : "calendar-day"}>
                <div className="calendar-day-header">
                  <div>
                    <span>{new Intl.DateTimeFormat(undefined, { weekday: "short" }).format(day)}</span>
                    <strong>{day.getDate()}</strong>
                  </div>
                  <button type="button" className="text-button" onClick={() => begin(undefined, day)} aria-label={`Add event on ${day.toDateString()}`}>+</button>
                </div>
                <div className="calendar-day-events">
                  {items.length === 0 ? <p className="calendar-day-empty">No events</p> : items.map((event) => (
                    <button key={event.id} type="button" className="calendar-day-event" onClick={() => begin(event)}>
                      <span>{eventTime(event, day)}</span>
                      <strong>{event.title}</strong>
                      {event.location && <small>{event.location}</small>}
                    </button>
                  ))}
                </div>
              </div>
            ))}
          </div>
        </div>
      )}
    </section>
  );
}
