"use client";

import type { PatientProfile, ProviderNote } from "@/lib/types";
import { format, parseDateOnly } from "@/lib/date";
import { ProviderNotes } from "./ProviderNotes";

type Props = {
  profile: PatientProfile;
  connected: boolean;
  connecting: boolean;
  error: string | null;
  now: Date;
  notes: ProviderNote[];
  onConnect: () => void;
  onEdit: () => void;
  notesError: string | null;
  onAddNote: (title: string, body: string) => Promise<void>;
  onUpdateNote: (id: string, title: string, body: string) => Promise<void>;
  onRemoveNote: (id: string) => Promise<void>;
};

function ageOf(born: Date, now: Date): number {
  let age = now.getFullYear() - born.getFullYear();
  const beforeBirthday = now.getMonth() < born.getMonth() || (now.getMonth() === born.getMonth() && now.getDate() < born.getDate());
  return beforeBirthday ? age - 1 : age;
}

function subtitle(profile: PatientProfile, now: Date): string {
  const parts: string[] = [];
  if (profile.gender) parts.push(profile.gender);
  const born = parseDateOnly(profile.dateOfBirth);
  if (born) parts.push(`${ageOf(born, now)} y.o.`, format.numericDate(born));
  return parts.join(", ");
}

export function PatientPanel({ profile, connected, connecting, error, now, notes, notesError, onConnect, onEdit, onAddNote, onUpdateNote, onRemoveNote }: Props) {
  const details = subtitle(profile, now);
  return (
    <section className="clinical-section patient-section" aria-labelledby="patient-title">
      <div className="patient-summary">
        <div className="section-header">
          <div className="patient-title">
            <h2 id="patient-title">{profile.name || "Patient"}</h2>
            {!connected && (
              <button type="button" className="calendar-status" onClick={onConnect} disabled={connecting}>{connecting ? "Connecting" : "Calendar not connected, click to connect"}</button>
            )}
          </div>
          <button className="text-button settings-button" onClick={onEdit}>
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
              <circle cx="12" cy="12" r="3" />
              <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" />
            </svg>
            Patient settings
          </button>
        </div>
        {details && <p className="patient-subtitle">{details}</p>}
        {error && <p className="inline-error" role="status">{error}</p>}
      </div>

      <div className="panel-body">
        <ProviderNotes notes={notes} syncError={notesError} onAdd={onAddNote} onUpdate={onUpdateNote} onRemove={onRemoveNote} />
      </div>
    </section>
  );
}
