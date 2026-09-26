"use client";

import type { PatientProfile } from "@/lib/types";

type Props = {
  profile: PatientProfile;
  connected: boolean;
  connecting: boolean;
  error: string | null;
  onConnect: () => void;
  onEdit: () => void;
};

function dateOfBirth(value: string): string {
  if (!value) return "—";
  const [year, month, day] = value.split("-").map(Number);
  if (!year || !month || !day) return value;
  return new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", year: "numeric" }).format(new Date(year, month - 1, day));
}

export function PatientPanel({ profile, connected, connecting, error, onConnect, onEdit }: Props) {
  return (
    <section className="clinical-section patient-section" aria-labelledby="patient-title">
      <div className="section-header">
        <div className="patient-title">
          <h2 id="patient-title">Patient details</h2>
          {connected ? (
            <span className="calendar-status connected">Connected to Google Calendar</span>
          ) : (
            <button type="button" className="calendar-status" onClick={onConnect} disabled={connecting}>{connecting ? "Connecting…" : "Not connected, click to connect"}</button>
          )}
        </div>
        <button className="text-button" onClick={onEdit}>Edit</button>
      </div>
      <dl className="patient-details">
        <div><dt>Name</dt><dd>{profile.name || "—"}</dd></div>
        <div><dt>Date of birth</dt><dd>{dateOfBirth(profile.dateOfBirth)}</dd></div>
        <div className="notes-detail"><dt>Provider notes</dt><dd>{profile.providerNotes || "—"}</dd></div>
      </dl>
      {error && <p className="inline-error" role="status">{error}</p>}
    </section>
  );
}
