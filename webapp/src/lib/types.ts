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
};

export type PatientProfile = {
  name: string;
  dateOfBirth: string;
  providerNotes: string;
};

export const UNKNOWN_PERSON = "Unknown";
