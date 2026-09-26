import type { CalendarEvent, CheckIn, Person, RecognitionLog } from "./types";
import { UNKNOWN_PERSON } from "./types";
import { addDays, dayKey, startOfDay } from "./date";
import { logMatchesPerson, peopleNamedInEvent, scheduledPeopleAt } from "./analytics";

const WEEK_MS = 7 * 86_400_000;
const BASELINE_WEEKS = 4;

export type BaselineMetric = { key: string; label: string; current: number; baseline: number; percent: boolean };
export type BaselineSummary = {
  status: "no-data" | "no-baseline" | "usual" | "flagged";
  metrics: BaselineMetric[];
  verdict: string;
};

export type MissedRecognition = { id: string; timestamp: string; scheduled: Person[]; said: string };
export type MissedSummary = { items: MissedRecognition[]; total: number; comparable: number };

export type Visit = { start: Date; names: string[] };
export type SocialSummary = { lastVisit: Visit | null; visitsLast7: number; nextVisit: Visit | null };

export type CoverageSummary = { lastUse: Date | null; activeDays: number };

export type LeftPanelSummary = {
  baseline: BaselineSummary;
  missed: MissedSummary;
  social: SocialSummary;
  coverage: CoverageSummary;
};

function isUnknown(log: RecognitionLog): boolean {
  const value = log.identifiedPerson.trim().toLocaleLowerCase();
  return !value || value === UNKNOWN_PERSON.toLocaleLowerCase();
}

function isNight(log: RecognitionLog): boolean {
  const hour = new Date(log.timestamp).getHours();
  return hour >= 23 || hour < 6;
}

function between(log: RecognitionLog, start: Date, end: Date): boolean {
  const value = new Date(log.timestamp).getTime();
  return value >= start.getTime() && value < end.getTime();
}

// Compares the last 7 days against the average of the 4 weeks before it.
// Abrupt change from baseline is the discriminator between delirium and dementia progression (CAM criteria),
// so the verdict only flags large deviations backed by enough events to mean something.
export function baselineSummary(logs: RecognitionLog[], now: Date): BaselineSummary {
  const currentStart = new Date(now.getTime() - WEEK_MS);
  const baselineStart = new Date(currentStart.getTime() - BASELINE_WEEKS * WEEK_MS);
  const current = logs.filter((log) => between(log, currentStart, now));
  const prior = logs.filter((log) => between(log, baselineStart, currentStart));
  if (!current.length && !prior.length) return { status: "no-data", metrics: [], verdict: "No Violet uses in the last 5 weeks." };
  if (!prior.length) return { status: "no-baseline", metrics: [], verdict: "No baseline yet. Comparison starts after a week of use." };

  const uses = { current: current.length, baseline: prior.length / BASELINE_WEEKS };
  const unknown = {
    current: current.length ? current.filter(isUnknown).length / current.length : 0,
    baseline: prior.filter(isUnknown).length / prior.length,
  };
  const night = { current: current.filter(isNight).length, baseline: prior.filter(isNight).length / BASELINE_WEEKS };

  const flags: string[] = [];
  if (uses.current >= 5 && uses.current >= 2 * uses.baseline) flags.push("Violet use is at least double the prior average.");
  if (uses.baseline >= 5 && uses.current <= uses.baseline / 2) flags.push("Violet use has dropped by half or more. Check coverage before reading this as improvement.");
  if (current.length >= 4 && unknown.current - unknown.baseline >= 0.25) flags.push("More faces went unrecognized than usual.");
  if (night.current >= 3 && night.current >= 2 * night.baseline) flags.push("More night-time use than usual.");

  return {
    status: flags.length ? "flagged" : "usual",
    metrics: [
      { key: "uses", label: "Violet uses", current: uses.current, baseline: uses.baseline, percent: false },
      { key: "unknown", label: "Unrecognized", current: unknown.current, baseline: unknown.baseline, percent: true },
      { key: "night", label: "Night-time uses", current: night.current, baseline: night.baseline, percent: false },
    ],
    verdict: flags.length ? flags.join(" ") : "Within the usual range for this patient.",
  };
}

// Every Violet use that overlapped a scheduled visit from a known person, where Violet did not name that person.
// These are the observed instances behind IQCODE items 1 and 2 (recognizing faces and names of family and friends).
export function missedSummary(logs: RecognitionLog[], events: CalendarEvent[], people: Person[], limit = 5): MissedSummary {
  const items: MissedRecognition[] = [];
  let total = 0;
  let comparable = 0;
  for (let index = logs.length - 1; index >= 0; index -= 1) {
    const log = logs[index];
    const scheduled = scheduledPeopleAt(events, people, new Date(log.timestamp));
    if (!scheduled.length) continue;
    comparable += 1;
    if (scheduled.some((person) => logMatchesPerson(log, person))) continue;
    total += 1;
    if (items.length < limit) {
      items.push({ id: log.id, timestamp: log.timestamp, scheduled, said: isUnknown(log) ? UNKNOWN_PERSON : log.identifiedPerson.trim() });
    }
  }
  return { items, total, comparable };
}

function visitsFrom(events: CalendarEvent[], people: Person[]): Visit[] {
  return events
    .map((event) => ({ start: new Date(event.start), names: peopleNamedInEvent(event, people).map((person) => person.name) }))
    .filter((visit) => visit.names.length > 0 && !Number.isNaN(visit.start.getTime()))
    .sort((a, b) => a.start.getTime() - b.start.getTime());
}

// Visits are calendar events that name a known person. Contact frequency is a care-plan item (NICE NG97)
// and the denominator for the recognition data: a quiet week often means nobody came.
export function socialSummary(events: CalendarEvent[], people: Person[], now: Date): SocialSummary {
  const visits = visitsFrom(events, people);
  const past = visits.filter((visit) => visit.start.getTime() < now.getTime());
  const weekAgo = new Date(now.getTime() - WEEK_MS);
  return {
    lastVisit: past.length ? past[past.length - 1] : null,
    visitsLast7: past.filter((visit) => visit.start.getTime() >= weekAgo.getTime()).length,
    nextVisit: visits.find((visit) => visit.start.getTime() >= now.getTime()) ?? null,
  };
}

// Absence of events is ambiguous without knowing whether the glasses were in use.
export function coverageSummary(logs: RecognitionLog[], now: Date): CoverageSummary {
  const weekStart = addDays(startOfDay(now), -6);
  const days = new Set<string>();
  let lastUse: Date | null = null;
  for (const log of logs) {
    const moment = new Date(log.timestamp);
    if (Number.isNaN(moment.getTime())) continue;
    if (!lastUse || moment > lastUse) lastUse = moment;
    if (moment >= weekStart && moment <= now) days.add(dayKey(moment));
  }
  return { lastUse, activeDays: days.size };
}

export function checkInScore(checkIn: CheckIn): number {
  return checkIn.answers.filter(Boolean).length;
}

export function leftPanelSummary(logs: RecognitionLog[], events: CalendarEvent[], people: Person[], now: Date): LeftPanelSummary {
  return {
    baseline: baselineSummary(logs, now),
    missed: missedSummary(logs, events, people),
    social: socialSummary(events, people, now),
    coverage: coverageSummary(logs, now),
  };
}
