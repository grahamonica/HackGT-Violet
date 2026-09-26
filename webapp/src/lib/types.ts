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
  diagnosis: string;
  assessmentTool: string;
  assessmentScore: string;
  assessmentDate: string;
  providerNotes: string;
};

export const ASSESSMENT_TOOLS: Array<{ name: string; max: number | null }> = [
  { name: "MoCA", max: 30 },
  { name: "MMSE", max: 30 },
  { name: "CDR", max: 3 },
  { name: "Other", max: null },
];

// AD8 informant interview items (Galvin et al., Neurology 2005). Two or more "yes" answers is the validated cutoff.
export const AD8_ITEMS = [
  "Problems with judgment, such as bad financial decisions or trouble thinking through a problem",
  "Less interest in hobbies or activities",
  "Repeats the same questions, stories, or statements",
  "Trouble learning how to use a tool, appliance, or gadget",
  "Forgets the correct month or year",
  "Trouble handling complicated financial affairs, such as paying bills or balancing accounts",
  "Trouble remembering appointments",
  "Daily problems with thinking or memory",
];

export type CheckIn = {
  id: string;
  date: string;
  answers: boolean[];
};

export const UNKNOWN_PERSON = "Unknown";
