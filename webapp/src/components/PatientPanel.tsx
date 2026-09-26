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
      <div className="section-header">
        <div className="patient-title">
          <h2 id="patient-title">{profile.name || "Patient"}</h2>
          {!connected && (
            <button type="button" className="calendar-status" onClick={onConnect} disabled={connecting}>{connecting ? "Connecting" : "Calendar not connected, click to connect"}</button>
          )}
        </div>
        <button className="text-button" onClick={onEdit}>Edit</button>
      </div>
      {details && <p className="patient-subtitle">{details}</p>}
      {error && <p className="inline-error" role="status">{error}</p>}

      <div className="panel-body">
        <ProviderNotes notes={notes} syncError={notesError} onAdd={onAddNote} onUpdate={onUpdateNote} onRemove={onRemoveNote} />
      </div>
    </section>
  );
}
