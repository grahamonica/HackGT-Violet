"use client";

import { useEffect, useMemo, useState } from "react";
import { dashboardAnalytics } from "@/lib/analytics";
import { leftPanelSummary } from "@/lib/summary";
import { useCheckIns } from "@/lib/client/useCheckIns";
import { usePatientData } from "@/lib/client/usePatientData";
import { useGoogleCalendar } from "@/lib/client/useGoogleCalendar";
import { usePatientProfile } from "@/lib/client/usePatientProfile";
import { PortalHeader } from "./PortalHeader";
import { PatientPanel } from "./PatientPanel";
import { AnalyticsDashboard } from "./AnalyticsDashboard";
import { EditPatientModal } from "./EditPatientModal";
import { AddPersonModal } from "./AddPersonModal";
import { CheckInModal } from "./CheckInModal";
import type { Person } from "@/lib/types";

type Editor = { kind: "patient" } | { kind: "person"; person?: Person } | { kind: "checkin" } | null;

export function Portal() {
  const [weeks, setWeeks] = useState(8);
  const [editor, setEditor] = useState<Editor>(null);
  const [now] = useState(() => new Date());
  const patient = usePatientData();
  const profile = usePatientProfile();
  const calendar = useGoogleCalendar(weeks);
  const checkIns = useCheckIns();

  useEffect(() => {
    if (calendar.profileName) profile.applyGoogleName(calendar.profileName);
  }, [calendar.profileName, profile.applyGoogleName]);

  const analytics = useMemo(
    () => dashboardAnalytics(patient.logs, calendar.events, patient.people, weeks, now),
    [calendar.events, now, patient.logs, patient.people, weeks],
  );

  const summary = useMemo(
    () => leftPanelSummary(patient.logs, calendar.events, patient.people, now),
    [calendar.events, now, patient.logs, patient.people],
  );

  return (
    <main className="portal-page">
      <PortalHeader />
      {patient.error && <p className="database-error" role="status">Database: {patient.error}</p>}
      <div className="dashboard-layout">
        <div className="left-column">
          <PatientPanel profile={profile.profile} summary={summary} checkIns={checkIns.checkIns} loading={!patient.hydrated || !calendar.hydrated} now={now} connected={calendar.connected} connecting={calendar.connecting} error={calendar.error} onConnect={calendar.connect} onEdit={() => setEditor({ kind: "patient" })} onCheckIn={() => setEditor({ kind: "checkin" })} />
        </div>
        <AnalyticsDashboard analytics={analytics} loading={!patient.hydrated || !calendar.hydrated} weeks={weeks} onWeeksChange={setWeeks} />
      </div>
      {editor?.kind === "patient" && <EditPatientModal profile={profile.profile} people={patient.people} onSave={profile.save} onAddPerson={() => setEditor({ kind: "person" })} onEditPerson={(person) => setEditor({ kind: "person", person })} calendarEvents={calendar.events} calendarConnected={calendar.connected} calendarConnecting={calendar.connecting} onConnectCalendar={calendar.connect} onSaveCalendarEvent={calendar.saveEvent} onClose={() => setEditor(null)} />}
      {editor?.kind === "checkin" && <CheckInModal onSave={checkIns.add} onClose={() => setEditor(null)} />}
      {editor?.kind === "person" && <AddPersonModal person={editor.person} onClose={() => setEditor({ kind: "patient" })} onSubmit={(draft) => editor.person ? patient.updatePerson(editor.person.id, draft) : patient.addPerson(draft)} />}
    </main>
  );
}
