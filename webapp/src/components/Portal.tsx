"use client";

import { useEffect, useMemo, useState } from "react";
import { dashboardAnalytics, type DateRange } from "@/lib/analytics";
import { addDays, startOfDay } from "@/lib/date";
import { usePatientData } from "@/lib/client/usePatientData";
import { useGoogleCalendar } from "@/lib/client/useGoogleCalendar";
import { usePatientProfile } from "@/lib/client/usePatientProfile";
import { useProviderNotes } from "@/lib/client/useProviderNotes";
import { PortalHeader } from "./PortalHeader";
import { PatientPanel } from "./PatientPanel";
import { AnalyticsDashboard } from "./AnalyticsDashboard";
import { EditPatientModal } from "./EditPatientModal";
import { AddPersonModal } from "./AddPersonModal";
import type { Person } from "@/lib/types";

type Editor = { kind: "patient" } | { kind: "person"; person?: Person } | null;

export function Portal() {
  const [editor, setEditor] = useState<Editor>(null);
  const [now] = useState(() => new Date());
  // Default to the past six weeks, ending today.
  const [range, setRange] = useState<DateRange>(() => ({ start: addDays(startOfDay(now), -41), end: startOfDay(now) }));
  const patient = usePatientData();
  const profile = usePatientProfile();
  const providerNotes = useProviderNotes();
  const calendar = useGoogleCalendar(range.start, range.end);

  useEffect(() => {
    if (calendar.profileName) profile.applyGoogleName(calendar.profileName);
  }, [calendar.profileName, profile.applyGoogleName]);

  const analytics = useMemo(
    () => dashboardAnalytics(patient.logs, calendar.events, patient.people, range, now),
    [calendar.events, now, patient.logs, patient.people, range],
  );

  return (
    <main className="portal-page">
      <PortalHeader />
      {patient.error && <p className="database-error" role="status">Database: {patient.error}</p>}
      <div className="dashboard-layout">
        <div className="left-column">
          <PatientPanel profile={profile.profile} now={now} notes={providerNotes.notes} notesError={providerNotes.error} onAddNote={providerNotes.add} onUpdateNote={providerNotes.update} onRemoveNote={providerNotes.remove} connected={calendar.connected} connecting={calendar.connecting} error={calendar.error} onConnect={calendar.connect} onEdit={() => setEditor({ kind: "patient" })} />
        </div>
        <AnalyticsDashboard analytics={analytics} loading={!patient.hydrated || !calendar.hydrated} range={range} today={now} onRangeChange={setRange} />
      </div>
      {editor?.kind === "patient" && <EditPatientModal profile={profile.profile} people={patient.people} onSave={profile.save} onAddPerson={() => setEditor({ kind: "person" })} onEditPerson={(person) => setEditor({ kind: "person", person })} calendarEvents={calendar.events} calendarConnected={calendar.connected} calendarConnecting={calendar.connecting} onConnectCalendar={calendar.connect} onSaveCalendarEvent={calendar.saveEvent} onClose={() => setEditor(null)} />}
      {editor?.kind === "person" && <AddPersonModal person={editor.person} onClose={() => setEditor({ kind: "patient" })} onSubmit={(draft) => editor.person ? patient.updatePerson(editor.person.id, draft) : patient.addPerson(draft)} onDelete={patient.deletePerson} />}
    </main>
  );
}
