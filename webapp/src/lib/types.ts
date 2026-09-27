export type Person = {
  id: string;
  name: string;
  frontPhoto: string;
  leftPhoto: string;
  rightPhoto: string;
  relation: string;
  bio: string;
  yearMet: number;
  updatedAt: string;
};

export type PersonDraft = Omit<Person, "id" | "updatedAt">;

export type RecognitionLog = {
  id: string;
  timestamp: string;
  identifiedPerson: string;
};

export type RecognitionLogDraft = Omit<RecognitionLog, "id">;

export type CalendarEvent = {
  id: string;
  title: string;
  start: string;
  end: string;
  allDay: boolean;
  location?: string;
};

export type CalendarEventDraft = Omit<CalendarEvent, "id">;

export type SyncResponse<T> = {
  items: T[];
  serverTime: string;
  // How many rows the server holds in all, so a client can tell when its cache has drifted.
  total?: number;
};

export type PeopleSyncResponse = SyncResponse<Person> & { ids: string[] };

export type PatientProfile = {
  name: string;
  gender: string;
  dateOfBirth: string;
  caregiverName: string;
  caregiverPhone: string;
};

export type ProviderNote = {
  id: string;
  title: string;
  body: string;
  createdAt: string;
  updatedAt: string;
  // Deletes are soft so the incremental sync can tell other open portals to drop the note.
  deleted?: boolean;
};

export type ProviderNoteDraft = { title: string; body: string };

export const GENDERS = ["Male", "Female", "Other"];

export const UNKNOWN_PERSON = "Unknown";
