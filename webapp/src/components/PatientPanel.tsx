"use client";

import type { CheckIn, PatientProfile, Person } from "@/lib/types";
import { ASSESSMENT_TOOLS } from "@/lib/types";
import type { BaselineMetric, LeftPanelSummary, Visit } from "@/lib/summary";
import { checkInScore } from "@/lib/summary";
import { format, parseDateOnly, relativeDay } from "@/lib/date";

type Props = {
  profile: PatientProfile;
  summary: LeftPanelSummary;
  checkIns: CheckIn[];
  loading: boolean;
  connected: boolean;
  connecting: boolean;
  error: string | null;
  now: Date;
  onConnect: () => void;
  onEdit: () => void;
  onCheckIn: () => void;
};

const NOT_SET = "Not set";

function ageOf(dateOfBirth: string, now: Date): string {
  const born = parseDateOnly(dateOfBirth);
  if (!born) return NOT_SET;
  let age = now.getFullYear() - born.getFullYear();
  const beforeBirthday = now.getMonth() < born.getMonth() || (now.getMonth() === born.getMonth() && now.getDate() < born.getDate());
  if (beforeBirthday) age -= 1;
  return age >= 0 ? String(age) : NOT_SET;
}

function dateOnly(value: string): string {
  const date = parseDateOnly(value);
  return date ? format.monthDayYear(date) : value || NOT_SET;
}

function assessment(profile: PatientProfile): string {
  if (!profile.assessmentTool || !profile.assessmentScore) return NOT_SET;
  const tool = ASSESSMENT_TOOLS.find((item) => item.name === profile.assessmentTool);
  const score = tool?.max ? `${profile.assessmentScore} of ${tool.max}` : profile.assessmentScore;
  const when = profile.assessmentDate ? `, ${dateOnly(profile.assessmentDate)}` : "";
  return `${profile.assessmentTool} ${score}${when}`;
}

function metricValue(metric: BaselineMetric, value: number): string {
  if (metric.percent) return `${Math.round(value * 100)}%`;
  return Number.isInteger(value) ? String(value) : value.toFixed(1);
}

function visitLabel(visit: Visit, now: Date): string {
  return `${visit.names.join(", ")}, ${relativeDay(visit.start, now)}`;
}

function describePeople(people: Person[]): string {
  return people.map((person) => (person.relation ? `${person.name}, ${person.relation.toLocaleLowerCase()}` : person.name)).join("; ");
}

export function PatientPanel({ profile, summary, checkIns, loading, connected, connecting, error, now, onConnect, onEdit, onCheckIn }: Props) {
  const latest = checkIns.length ? checkIns[checkIns.length - 1] : null;
  const previous = checkIns.length > 1 ? checkIns[checkIns.length - 2] : null;

  return (
    <section className="clinical-section patient-section" aria-labelledby="patient-title">
      <div className="section-header">
        <div className="patient-title">
          <h2 id="patient-title">Patient details</h2>
          {connected ? (
            <span className="calendar-status connected">Connected to Google Calendar</span>
          ) : (
            <button type="button" className="calendar-status" onClick={onConnect} disabled={connecting}>{connecting ? "Connecting" : "Not connected, click to connect"}</button>
          )}
        </div>
        <button className="text-button" onClick={onEdit}>Edit</button>
      </div>
      {error && <p className="inline-error" role="status">{error}</p>}

      <div className="panel-body">
        <dl className="patient-details">
          <div className="identity-row">
            <dt>Name</dt><dd>{profile.name || NOT_SET}</dd>
            <dt>Age</dt><dd>{ageOf(profile.dateOfBirth, now)}</dd>
            <dt>Born</dt><dd>{dateOnly(profile.dateOfBirth)}</dd>
          </div>
          <div><dt>Diagnosis</dt><dd>{profile.diagnosis || NOT_SET}</dd></div>
          <div><dt>Last assessment</dt><dd>{assessment(profile)}</dd></div>
          <div className="notes-detail"><dt>Provider notes</dt><dd>{profile.providerNotes || NOT_SET}</dd></div>
        </dl>

        <section className="panel-block" aria-labelledby="baseline-title">
          <h3 id="baseline-title">Change from baseline</h3>
          {loading ? <p className="block-note">Loading</p> : (
            <>
              {summary.baseline.metrics.length > 0 && (
                <dl className="block-rows baseline-rows">
                  <div className="baseline-head" aria-hidden="true"><dt /><dd>This week</dd><dd>Prior 4-week avg</dd></div>
                  {summary.baseline.metrics.map((metric) => (
                    <div key={metric.key}><dt>{metric.label}</dt><dd>{metricValue(metric, metric.current)}</dd><dd>{metricValue(metric, metric.baseline)}</dd></div>
                  ))}
                </dl>
              )}
              <p className={summary.baseline.status === "flagged" ? "block-verdict flagged" : "block-verdict"}>{summary.baseline.verdict}</p>
            </>
          )}
        </section>

        <section className="panel-block" aria-labelledby="missed-title">
          <h3 id="missed-title">Missed recognitions</h3>
          {loading ? <p className="block-note">Loading</p> : !connected && !summary.missed.comparable ? (
            <p className="block-note">Needs Google Calendar, so Violet uses can be matched against scheduled visitors.</p>
          ) : !summary.missed.items.length ? (
            <p className="block-note">{summary.missed.comparable ? "Every Violet use during a scheduled visit named the visitor." : "No Violet uses have overlapped a scheduled visit yet."}</p>
          ) : (
            <>
              <ul className="event-list">
                {summary.missed.items.map((item) => (
                  <li key={item.id}>
                    <strong>{format.dateTime(new Date(item.timestamp))}</strong>
                    <span>Scheduled: {describePeople(item.scheduled)}. Violet said: {item.said}.</span>
                  </li>
                ))}
              </ul>
              <p className="block-note">{summary.missed.total > summary.missed.items.length ? `Most recent ${summary.missed.items.length} of ${summary.missed.total} missed, out of ${summary.missed.comparable} uses during visits.` : `${summary.missed.total} missed out of ${summary.missed.comparable} uses during visits.`}</p>
            </>
          )}
        </section>

        <section className="panel-block" aria-labelledby="social-title">
          <h3 id="social-title">Social contact</h3>
          {loading ? <p className="block-note">Loading</p> : !connected ? (
            <p className="block-note">Connect Google Calendar to track visits from familiar people.</p>
          ) : (
            <dl className="block-rows">
              <div><dt>Last visit</dt><dd>{summary.social.lastVisit ? visitLabel(summary.social.lastVisit, now) : "None recorded"}</dd></div>
              <div><dt>Past 7 days</dt><dd>{summary.social.visitsLast7 === 1 ? "1 visit" : `${summary.social.visitsLast7} visits`}</dd></div>
              <div><dt>Next visit</dt><dd>{summary.social.nextVisit ? visitLabel(summary.social.nextVisit, now) : "None scheduled"}</dd></div>
            </dl>
          )}
        </section>

        <section className="panel-block" aria-labelledby="coverage-title">
          <h3 id="coverage-title">Coverage</h3>
          {loading ? <p className="block-note">Loading</p> : !summary.coverage.lastUse ? (
            <p className="block-note">No Violet uses recorded yet.</p>
          ) : (
            <p className="block-text">Active {summary.coverage.activeDays} of the last 7 days. Last Violet use {format.dateTime(summary.coverage.lastUse)}, {relativeDay(summary.coverage.lastUse, now)}.</p>
          )}
        </section>

        <section className="panel-block" aria-labelledby="checkin-title">
          <div className="block-header">
            <h3 id="checkin-title">Caregiver check-in</h3>
            <button type="button" className="text-button" onClick={onCheckIn}>Record AD8</button>
          </div>
          {!latest ? (
            <p className="block-note">No check-ins yet. The AD8 is eight yes-or-no questions for the caregiver, once a month.</p>
          ) : (
            <>
              <p className="block-text">AD8 score {checkInScore(latest)} of 8 on {dateOnly(latest.date)}.{previous ? ` Previous ${checkInScore(previous)} of 8 on ${dateOnly(previous.date)}.` : ""}</p>
              <p className="block-note">{checkInScore(latest) >= 2 ? "At or above the cutoff of 2, which suggests cognitive impairment." : "Below the cutoff of 2."}</p>
            </>
          )}
        </section>
      </div>
    </section>
  );
}
