"use client";

import type { PatientProfile, ProviderNote } from "@/lib/types";
import { MOCA_MAX } from "@/lib/types";
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

const NOT_SET = "Not set";

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

function latestMoca(profile: PatientProfile): string {
  if (!profile.mocaScore) return NOT_SET;
  const date = parseDateOnly(profile.mocaDate);
  return `${profile.mocaScore} of ${MOCA_MAX}${date ? `, ${format.monthDayYear(date)}` : ""}`;
}

// Formats US numbers as (205) 555-0123, with a leading 1 as +1. Anything else is shown as typed.
function formatPhone(value: string): string {
  const digits = value.replace(/\D/g, "");
  const local = digits.length === 11 && digits.startsWith("1") ? digits.slice(1) : digits;
  if (local.length !== 10) return value.trim();
  const formatted = `(${local.slice(0, 3)}) ${local.slice(3, 6)}-${local.slice(6)}`;
  return local === digits ? formatted : `+1 ${formatted}`;
}

function caregiver(profile: PatientProfile): string {
  const parts = [profile.caregiverName, formatPhone(profile.caregiverPhone)].filter(Boolean);
  return parts.length ? parts.join(", ") : NOT_SET;
}

export function PatientPanel({ profile, connected, connecting, error, now, notes, notesError, onConnect, onEdit, onAddNote, onUpdateNote, onRemoveNote }: Props) {
  const details = subtitle(profile, now);
  return (
    <section className="clinical-section patient-section" aria-labelledby="patient-title">
      <div className="section-header">
        <div className="patient-title">
          <h2 id="patient-title">{profile.name || "Patient"}</h2>
          {connected ? (
            <span className="calendar-status connected">Connected to Google Calendar</span>
          ) : (
            <button type="button" className="calendar-status" onClick={onConnect} disabled={connecting}>{connecting ? "Connecting" : "Calendar not connected, click to connect"}</button>
          )}
        </div>
        <button className="text-button" onClick={onEdit}>Edit</button>
      </div>
      {details && <p className="patient-subtitle">{details}</p>}
      {error && <p className="inline-error" role="status">{error}</p>}

      <div className="panel-body">
        <dl className="patient-details">
          <div><dt>Primary caregiver</dt><dd>{caregiver(profile)}</dd></div>
          <div><dt>Latest MoCA</dt><dd>{latestMoca(profile)}</dd></div>
        </dl>
        <ProviderNotes notes={notes} syncError={notesError} onAdd={onAddNote} onUpdate={onUpdateNote} onRemove={onRemoveNote} />
      </div>
    </section>
  );
}
