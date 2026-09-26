import type { CalendarEvent, Person, RecognitionLog } from "@/lib/types";
import { UNKNOWN_PERSON } from "@/lib/types";
import { addDays, format, startOfDay, startOfWeek } from "./date";

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

function logMatchesPerson(log: RecognitionLog, person: Person): boolean {
  const identified = normalized(log.identifiedPerson);
  if (!identified || identified === normalized(UNKNOWN_PERSON)) return false;
  return identified === normalized(person.name) || firstName(identified) === firstName(person.name);
}

function windowFor(weekCount: number, now: Date) {
  const currentWeek = startOfWeek(now);
  return {
    start: addDays(currentWeek, -(weekCount - 1) * 7),
    end: addDays(startOfDay(now), 1),
  };
}

export function weeklySeries(
  logs: RecognitionLog[],
  events: CalendarEvent[],
  people: Person[],
  weekCount: number,
  now = new Date(),
): WeekPoint[] {
  const { start, end } = windowFor(weekCount, now);
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
    const hour = new Date(event.start).getHours();
    if (hour >= 6 && hour < 23) points[hour - 6].visitors += peopleNamedInEvent(event, people).length;
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
    const moment = new Date(log.timestamp);
    const scheduledPeople = events
      .filter((event) => eventOverlapsMoment(event, moment))
      .flatMap((event) => peopleNamedInEvent(event, people));
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
  weekCount: number,
  now = new Date(),
): DashboardAnalytics {
  const { start, end } = windowFor(weekCount, now);
  return {
    weeks: weeklySeries(logs, events, people, weekCount, now),
    hours: hourlySeries(logs, events, people, start, end),
    health: healthMetric(logs, events, people, start, end),
    tenure: tenureSeries(logs, people, start, end, now),
    windowStart: start,
    windowEnd: end,
  };
}
