import type { CalendarEvent, Person, RecognitionLog } from "@/lib/types";
import { UNKNOWN_PERSON } from "@/lib/types";
import { addDays, format, startOfDay } from "./date";

export type WeekPoint = {
  start: Date;
  label: string;
  violetUses: number;
  peopleSeen: number;
  usesPerVisit: number | null;
};

export type HourPoint = { hour: number; violetUses: number; visitors: number };

export type HealthMetric = {
  mismatches: number;
  comparableUses: number;
  rate: number | null;
  status: "healthy" | "watch" | "high" | "unavailable";
};

export type TenurePoint = {
  id: string;
  name: string;
  yearsKnown: number;
  violetUses: number;
};

export type DashboardAnalytics = {
  weeks: WeekPoint[];
  hours: HourPoint[];
  health: HealthMetric;
  tenure: TenurePoint[];
  windowStart: Date;
  windowEnd: Date;
};

function normalized(value: string): string {
  return value.trim().toLocaleLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim();
}

export function firstName(value: string): string {
  return normalized(value).replace(/^(dr|mr|mrs|ms)\s+/, "").split(/\s+/)[0] ?? "";
}

function titleHasName(title: string, name: string): boolean {
  const words = new Set(normalized(title).split(/\s+/));
  return words.has(firstName(name));
}

export function peopleNamedInEvent(event: CalendarEvent, people: Person[]): Person[] {
  return people.filter((person) => titleHasName(event.title, person.name));
}

function within(timestamp: string, start: Date, end: Date): boolean {
  const value = new Date(timestamp).getTime();
  return value >= start.getTime() && value < end.getTime();
}

function eventOverlapsMoment(event: CalendarEvent, moment: Date): boolean {
  if (event.allDay) {
    const eventStart = startOfDay(new Date(event.start));
    const eventEnd = startOfDay(new Date(event.end));
    return moment >= eventStart && moment < eventEnd;
  }
  return moment >= new Date(event.start) && moment < new Date(event.end);
}

export function logMatchesPerson(log: RecognitionLog, person: Person): boolean {
  const identified = normalized(log.identifiedPerson);
  if (!identified || identified === normalized(UNKNOWN_PERSON)) return false;
  return identified === normalized(person.name) || firstName(identified) === firstName(person.name);
}

export function scheduledPeopleAt(events: CalendarEvent[], people: Person[], moment: Date): Person[] {
  return events
    .filter((event) => eventOverlapsMoment(event, moment))
    .flatMap((event) => peopleNamedInEvent(event, people));
}

// Both dates are calendar days; the end day is included in the window.
export type DateRange = { start: Date; end: Date };

function windowFor(range: DateRange) {
  return { start: startOfDay(range.start), end: addDays(startOfDay(range.end), 1) };
}

export function weeklySeries(
  logs: RecognitionLog[],
  events: CalendarEvent[],
  people: Person[],
  range: DateRange,
): WeekPoint[] {
  const { start, end } = windowFor(range);
  const weekCount = Math.max(1, Math.ceil(Math.round((end.getTime() - start.getTime()) / 86_400_000) / 7));
  return Array.from({ length: weekCount }, (_, index) => {
    const weekStart = addDays(start, index * 7);
    const weekEnd = index === weekCount - 1 ? end : addDays(weekStart, 7);
    const violetUses = logs.filter((log) => within(log.timestamp, weekStart, weekEnd)).length;
    const peopleSeen = events
      .filter((event) => within(event.start, weekStart, weekEnd))
      .reduce((sum, event) => sum + peopleNamedInEvent(event, people).length, 0);
    return {
      start: weekStart,
      label: format.shortDate(weekStart),
      violetUses,
      peopleSeen,
      usesPerVisit: peopleSeen ? violetUses / peopleSeen : null,
    };
  });
}

export function hourlySeries(
  logs: RecognitionLog[],
  events: CalendarEvent[],
  people: Person[],
  start: Date,
  end: Date,
): HourPoint[] {
  const points = Array.from({ length: 17 }, (_, index) => ({ hour: index + 6, violetUses: 0, visitors: 0 }));
  for (const log of logs) {
    if (!within(log.timestamp, start, end)) continue;
    const hour = new Date(log.timestamp).getHours();
    if (hour >= 6 && hour < 23) points[hour - 6].violetUses += 1;
  }
  for (const event of events) {
    if (event.allDay || !within(event.start, start, end)) continue;
    const count = peopleNamedInEvent(event, people).length;
    if (!count) continue;
    // Count visitors in every hour the visit covers, like a popular-times chart.
    const from = new Date(event.start);
    const to = new Date(event.end);
    const lastHour = to > from && to.getMinutes() === 0 && to.getSeconds() === 0 ? to.getHours() - 1 : to.getHours();
    const sameDay = to.toDateString() === from.toDateString();
    for (let hour = from.getHours(); hour <= (sameDay ? Math.max(from.getHours(), lastHour) : 22); hour += 1) {
      if (hour >= 6 && hour < 23) points[hour - 6].visitors += count;
    }
  }
  return points;
}

export function healthMetric(
  logs: RecognitionLog[],
  events: CalendarEvent[],
  people: Person[],
  start: Date,
  end: Date,
): HealthMetric {
  let comparableUses = 0;
  let mismatches = 0;
  for (const log of logs) {
    if (!within(log.timestamp, start, end)) continue;
    const scheduledPeople = scheduledPeopleAt(events, people, new Date(log.timestamp));
    if (!scheduledPeople.length) continue;
    comparableUses += 1;
    if (!scheduledPeople.some((person) => logMatchesPerson(log, person))) mismatches += 1;
  }
  if (!comparableUses) return { mismatches, comparableUses, rate: null, status: "unavailable" };
  const rate = mismatches / comparableUses;
  return {
    mismatches,
    comparableUses,
    rate,
    status: rate < 0.3 ? "healthy" : rate < 0.7 ? "watch" : "high",
  };
}

export function tenureSeries(logs: RecognitionLog[], people: Person[], start: Date, end: Date, now = new Date()): TenurePoint[] {
  const currentLogs = logs.filter((log) => within(log.timestamp, start, end));
  return people
    .map((person) => ({
      id: person.id,
      name: person.name,
      yearsKnown: Math.max(0, now.getFullYear() - person.yearMet),
      violetUses: currentLogs.filter((log) => logMatchesPerson(log, person)).length,
    }))
    .sort((a, b) => b.violetUses - a.violetUses || a.yearsKnown - b.yearsKnown || a.name.localeCompare(b.name));
}

export function dashboardAnalytics(
  logs: RecognitionLog[],
  events: CalendarEvent[],
  people: Person[],
  range: DateRange,
  now = new Date(),
): DashboardAnalytics {
  const { start, end } = windowFor(range);
  return {
    weeks: weeklySeries(logs, events, people, range),
    hours: hourlySeries(logs, events, people, start, end),
    health: healthMetric(logs, events, people, start, end),
    tenure: tenureSeries(logs, people, start, end, now),
    windowStart: start,
    windowEnd: end,
  };
}
