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
        <h2 id="patient-title">Patient details</h2>
        <button className="text-button" onClick={onEdit}>Edit</button>
      </div>
      <dl className="patient-details">
        <div><dt>Name</dt><dd>{profile.name || "—"}</dd></div>
        <div><dt>Date of birth</dt><dd>{dateOfBirth(profile.dateOfBirth)}</dd></div>
        <div className="calendar-detail">
          <dt>Google Calendar</dt>
          <dd>{connected ? "Connected" : <button className="connect-button" onClick={onConnect} disabled={connecting}>{connecting ? "Connecting…" : "Connect Google Calendar"}</button>}</dd>
        </div>
        <div className="notes-detail"><dt>Provider notes</dt><dd>{profile.providerNotes || "—"}</dd></div>
      </dl>
      {error && <p className="inline-error" role="status">{error}</p>}
    </section>
  );
}
