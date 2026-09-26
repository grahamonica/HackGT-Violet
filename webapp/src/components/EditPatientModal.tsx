"use client";

import { useEffect, useState, type FormEvent } from "react";
import type { CalendarEvent, CalendarEventDraft, PatientProfile, Person } from "@/lib/types";
import { CalendarEditor } from "./CalendarEditor";

type Props = {
  profile: PatientProfile;
  people: Person[];
  onSave: (profile: PatientProfile) => void;
  onAddPerson: () => void;
  onEditPerson: (person: Person) => void;
  calendarEvents: CalendarEvent[];
  calendarConnected: boolean;
  calendarConnecting: boolean;
  onConnectCalendar: () => void;
  onSaveCalendarEvent: (draft: CalendarEventDraft, id?: string) => Promise<void>;
  onClose: () => void;
};

export function EditPatientModal({ profile, people, onSave, onAddPerson, onEditPerson, calendarEvents, calendarConnected, calendarConnecting, onConnectCalendar, onSaveCalendarEvent, onClose }: Props) {
  const [draft, setDraft] = useState(profile);
  useEffect(() => {
    const keydown = (event: KeyboardEvent) => event.key === "Escape" && onClose();
    document.addEventListener("keydown", keydown);
    return () => document.removeEventListener("keydown", keydown);
  }, [onClose]);

  function submit(event: FormEvent) {
    event.preventDefault();
    onSave({ ...draft, name: draft.name.trim(), providerNotes: draft.providerNotes.trim() });
    onClose();
  }

  return (
    <div className="modal-backdrop" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
      <div className="modal" role="dialog" aria-modal="true" aria-labelledby="edit-patient-title">
        <div className="modal-heading"><h2 id="edit-patient-title">Edit patient details</h2><button className="close-button" onClick={onClose} aria-label="Close">×</button></div>
        <form className="patient-form" onSubmit={submit}>
          <label><span>Name</span><input value={draft.name} onChange={(event) => setDraft({ ...draft, name: event.target.value })} /></label>
          <label><span>Date of birth</span><input type="date" value={draft.dateOfBirth} onChange={(event) => setDraft({ ...draft, dateOfBirth: event.target.value })} /></label>
          <label><span>Provider notes</span><textarea value={draft.providerNotes} onChange={(event) => setDraft({ ...draft, providerNotes: event.target.value })} /></label>
          <div className="edit-people-header"><h3>Familiar people ({people.length}/10)</h3><button type="button" className="text-button" onClick={onAddPerson} disabled={people.length >= 10}>Add person</button></div>
          <div className="edit-people-list">{people.map((person) => <div key={person.id}><div><strong>{person.name}</strong><span>{person.relation} · met {person.yearMet}</span></div><button type="button" className="text-button" onClick={() => onEditPerson(person)}>Edit</button></div>)}</div>
          <CalendarEditor events={calendarEvents} connected={calendarConnected} connecting={calendarConnecting} onConnect={onConnectCalendar} onSave={onSaveCalendarEvent} />
          <div className="form-actions"><button className="secondary-button" type="button" onClick={onClose}>Cancel</button><button className="primary-button" type="submit">Save</button></div>
        </form>
      </div>
    </div>
  );
}
