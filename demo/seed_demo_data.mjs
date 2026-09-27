#!/usr/bin/env node
// Seeds the Violet demo with a history from January 1 to today in which the familiar people, the calendar, the
// Violet logs, the provider notes and the patient details tell one story: his recall declines through the year
// and he sundowns, so he needs Violet far more in the late afternoon and evening.
//
//   node demo/seed_demo_data.mjs                                     dry run: writes demo/synthetic_data/ only
//   node demo/seed_demo_data.mjs --apply                             write everything below
//   node demo/seed_demo_data.mjs --apply --replace-template --clear-test-data   first run on the team's data
//
// relationships    the seven familiar people in PEOPLE. Missing ones are added with placeholder photos to replace
//                  in the app; people who already exist are never changed, so photo edits survive reruns.
// Google Calendar  their visits, varied week to week, from January 1 to December 31.
// logs             Violet recognitions during in-person visits. 95% name the person on the calendar; the rest are
//                  "Unknown" or the wrong person. Lookups per person seen rise through the year, climbing every week
//                  of the portal's default six weeks as of the day the script runs, and cluster after 4 pm.
// provider_notes   a clinician note every two weeks or so; the figures in them come from the generated logs.
// patient details  the portal keeps these in the browser, so they are written through the portal tab.
//
// --replace-template  one-time: deletes the recurring weekly events the calendar started with, turns "bob" (a test
//                     entry saved as a son) into the nurse from those events, and removes people outside PEOPLE.
// --clear-test-data   removes logs and notes this script did not write.
// --only <steps>      runs some of the steps, comma separated: calendar, people, logs, patient.
//
// The calendar is reached with the Google token of a Chrome tab at http://localhost:3000 that is connected to
// Google Calendar, read through AppleScript, so Chrome needs View > Developer > Allow JavaScript from Apple Events.
// The same tab draws the placeholder photos, gets the patient details and has its cached logs and notes cleared:
// the portal only syncs changes, so it would otherwise keep showing deleted rows.
//
// Everything written is tagged (Mongo: synthetic: "seed_demo_data", Calendar: private property violetSeed=1), so a
// rerun replaces only its own calendar events, logs and notes. Anything deleted is saved to
// demo/synthetic_data/backup/ first.

import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const DEMO = dirname(fileURLToPath(import.meta.url));
const ROOT = dirname(DEMO);
const OUT = join(DEMO, "synthetic_data");
const { MongoClient } = createRequire(join(ROOT, "webapp/package.json"))("mongodb");

const args = process.argv.slice(2);
const APPLY = args.includes("--apply");
const REPLACE_TEMPLATE = args.includes("--replace-template");
const CLEAR_TEST_DATA = args.includes("--clear-test-data");
const SEED = args.includes("--seed") ? Number(args[args.indexOf("--seed") + 1]) : 7;
const STEPS = args.includes("--only") ? args[args.indexOf("--only") + 1].split(",") : ["calendar", "people", "logs", "patient"];

const TAG = "seed_demo_data";
const UNKNOWN = "Unknown";
const MATCH_RATE = 0.95;
const MINUTE = 60_000;
const DAY = 86_400_000;
const NOW = new Date();
const YEAR = NOW.getFullYear();
const START = new Date(YEAR, 0, 1);
const LAST_DAY = new Date(YEAR, 11, 31);

const PATIENT = {
  name: "Arthur Bennett",
  gender: "Male",
  dateOfBirth: "1949-04-12",
  caregiverName: "Josh Bennett",
  caregiverPhone: "(404) 555-0148",
};

// The familiar people, keyed by first name. Details are only used to add someone who is missing.
const PEOPLE = {
  josh: { name: "Josh", relation: "Daughter", yearMet: 1976, color: "3", bio: "Josh is your daughter.", notes: "" },
  conrad: { name: "Conrad", relation: "Gardening instructor", yearMet: 2002, color: "10", bio: "This is Conrad, your gardening instructor.", notes: "" },
  monica: { name: "Monica", relation: "Granddaughter", yearMet: 2004, color: "4", bio: "Monica is your granddaughter, David's oldest.", notes: "She studies computer science at Georgia Tech." },
  andrew: { name: "Andrew", relation: "Music teacher", yearMet: 2023, color: "7", bio: "Andrew is your music teacher. He runs your piano class.", notes: "" },
  bob: { name: "Bob", relation: "Home health nurse", yearMet: 2020, color: "9", bio: "Bob is your nurse. He checks your blood pressure and medicines every week.", notes: "" },
  david: { name: "David", relation: "Son", yearMet: 1978, color: "5", bio: "David is your older son. He visits on Sundays with his kids.", notes: "" },
  michael: { name: "Michael", relation: "Son", yearMet: 1982, color: "6", bio: "Michael is your younger son. He takes you to the library on Saturdays.", notes: "" },
};

// ---------------------------------------------------------------- dates and randomness

function addDays(date, days) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate() + days);
}

function day(month, date) {
  return new Date(YEAR, month - 1, date);
}

function at(date, hour) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate(), Math.floor(hour), Math.round((hour % 1) * 60));
}

const hourOf = (date) => date.getHours() + date.getMinutes() / 60;
const clamp = (value, low, high) => Math.min(high, Math.max(low, value));
const firstName = (name) => name.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim().replace(/^(dr|mr|mrs|ms)\s+/, "").split(" ")[0];
const between = (date, [from, to]) => date >= from && date <= to;

function generator(seed) {
  let state = seed >>> 0;
  const next = () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = Math.imul(state ^ (state >>> 15), state | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  return {
    next,
    chance: (p) => next() < p,
    between: (low, high) => low + next() * (high - low),
    pick: (items) => items[Math.floor(next() * items.length)],
    weighted(pairs) {
      let roll = next() * pairs.reduce((sum, [, weight]) => sum + weight, 0);
      for (const [value, weight] of pairs) if ((roll -= weight) < 0) return value;
      return pairs.at(-1)[0];
    },
    shuffle(items) {
      const out = [...items];
      for (let i = out.length - 1; i > 0; i -= 1) {
        const j = Math.floor(next() * (i + 1));
        [out[i], out[j]] = [out[j], out[i]];
      }
      return out;
    },
  };
}

// ---------------------------------------------------------------- calendar

const BIRTHDAY = day(Number(PATIENT.dateOfBirth.slice(5, 7)), Number(PATIENT.dateOfBirth.slice(8, 10)));
const COLLEGE = day(9, 18); // Conrad starts college at Emory (his note in the relationships collection).
const ILLNESS = day(6, 9);
const SUMMER_BREAK = [day(5, 9), day(8, 16)]; // Monica is home from Georgia Tech.

const HOLIDAYS = [
  [day(4, 5), 12, 150, "Easter lunch with Josh and David", ["josh", "david"]],
  [BIRTHDAY, 17, 180, "Birthday dinner with Josh, David and Michael", ["josh", "david", "michael"]],
  [day(5, 25), 13, 180, "Memorial Day cookout with David and Michael", ["david", "michael"]],
  [day(6, 21), 12, 180, "Father's Day with David and Michael", ["david", "michael"]],
  [day(7, 4), 16, 240, "Fourth of July cookout with Josh, David and Michael", ["josh", "david", "michael"]],
  [day(9, 7), 15, 210, "Labor Day cookout with Josh and Michael", ["josh", "michael"]],
  [day(11, 26), 15, 240, "Thanksgiving with Josh, David, Michael and Monica", ["josh", "david", "michael", "monica"]],
  [day(12, 25), 14, 240, "Christmas with Josh, David, Michael and Monica", ["josh", "david", "michael", "monica"]],
];

// Appointments name nobody familiar, so the portal does not count them as visits.
const APPOINTMENTS = [
  [day(1, 13), 10, 60, "Memory clinic, Dr. Patel"],
  [day(4, 28), 10, 60, "Memory clinic, Dr. Patel"],
  [ILLNESS, 11, 120, "Urgent care"],
  [day(7, 14), 10, 60, "Memory clinic, Dr. Patel"],
  [day(9, 15), 10, 60, "Memory clinic, Dr. Patel"],
  [day(12, 15), 10, 60, "Memory clinic, Dr. Patel"],
];

const AWAY = {
  josh: [[day(7, 18), day(7, 26)]],
  conrad: [[day(3, 9), day(3, 15)], [day(6, 29), day(7, 5)]],
  monica: [],
  andrew: [[day(1, 1), day(1, 4)], [day(8, 1), day(8, 9)], [day(12, 21), day(12, 31)]],
  bob: [[day(5, 11), day(5, 17)], [day(8, 17), day(8, 23)]],
  david: [[day(3, 28), day(4, 3)], [day(8, 2), day(8, 9)]],
  michael: [[day(2, 16), day(2, 22)], [day(10, 12), day(10, 18)]],
};

const JOSH = {
  lunch: { perWeek: [[1, 35], [2, 45], [3, 20]], start: [11.5, 12.5], minutes: [75, 120], titles: ["Lunch with Josh", "Lunch out with Josh", "Josh bringing lunch"] },
  dinner: { perWeek: [[0, 45], [1, 40], [2, 15]], start: [17, 18.5], minutes: [90, 150], titles: ["Dinner with Josh", "Josh staying for dinner", "Movie night with Josh"] },
};
const ANDREW = { perWeek: [[1, 30], [2, 50], [3, 20]], start: [9.5, 11], minutes: [60, 60], titles: ["Music class with Andrew", "Music class with Andrew", "Piano lesson with Andrew"] };
const BOB = {
  visit: { start: [9, 14], minutes: [45, 60], titles: ["Nurse eval with Bob"] },
  evening: { start: [18, 19.5], minutes: [30, 45], titles: ["Evening check-in with Bob"] },
};
const DAVID = {
  sunday: { start: [12, 13], minutes: [150, 210], titles: ["Family time with David and the grandkids"] },
  dinner: { start: [17.5, 18.5], minutes: [90, 120], titles: ["Dinner with David"] },
};
const MICHAEL = {
  library: { start: [13.5, 15], minutes: [90, 120], titles: ["Library visit with Michael", "Visit the library with Michael"] },
  dinner: { start: [17.5, 19], minutes: [60, 120], titles: ["Dinner with Michael", "Michael stopping by after work"] },
};
const MONICA = {
  call: { start: [10.5, 19.5], minutes: [30, 45], titles: ["Phone call with Monica"], inPerson: false },
  afternoon: { start: [13, 16], minutes: [90, 150], titles: ["Coffee with Monica", "Walk with Monica", "Monica visiting"] },
  dinner: { start: [17, 18.5], minutes: [90, 120], titles: ["Dinner with Monica"] },
};
const CONRAD = {
  winter: { perWeek: [[0, 55], [1, 45]], start: [10, 11], minutes: [60, 90], titles: ["Seed starting with Conrad", "Planning the garden with Conrad"] },
  spring: { perWeek: [[1, 55], [2, 45]], start: [9, 10], minutes: [90, 120], titles: ["Gardening with Conrad", "Planting tomatoes with Conrad", "Garden bed prep with Conrad"] },
  summer: { perWeek: [[1, 40], [2, 50], [3, 10]], start: [8, 9], minutes: [60, 120], titles: ["Gardening with Conrad", "Watering and weeding with Conrad", "Harvest with Conrad"] },
  late: { perWeek: [[1, 50], [2, 50]], start: [8.5, 9.5], minutes: [60, 120], titles: ["Gardening with Conrad", "Harvest with Conrad"] },
  college: { perWeek: [[0, 35], [1, 65]], start: [9.5, 10.5], minutes: [60, 90], titles: ["Saturday gardening with Conrad", "Fall planting with Conrad"] },
};

function conradSeason(date) {
  if (date >= COLLEGE) return CONRAD.college;
  const month = date.getMonth() + 1;
  return month <= 2 ? CONRAD.winter : month <= 5 ? CONRAD.spring : month <= 8 ? CONRAD.summer : CONRAD.late;
}

function planCalendar(cast, rng) {
  const events = [];
  const add = (title, start, minutes, keys = [], color = "8", inPerson = true) => {
    const end = new Date(start.getTime() + minutes * MINUTE);
    if (events.some((event) => event.start < end && start < event.end)) return false;
    events.push({ title, start, end, who: keys.map((key) => cast[key].name), color, inPerson });
    return true;
  };
  const visit = (date, kind, key, color = PEOPLE[key].color) => {
    const start = at(date, Math.round(rng.between(...kind.start) * 4) / 4);
    return add(rng.pick(kind.titles), start, Math.round(rng.between(...kind.minutes) / 15) * 15, [key], color, kind.inPerson ?? true);
  };
  // Places up to `count` visits on different days.
  const spread = (count, days, place) => {
    let placed = 0;
    for (const date of rng.shuffle(days)) if (placed < count && place(date)) placed += 1;
  };

  for (const [date, hour, minutes, title, keys] of HOLIDAYS) add(title, at(date, hour), minutes, keys, "5");
  for (const [date, hour, minutes, title] of APPOINTMENTS) add(title, at(date, hour), minutes, [], "11");

  for (let monday = addDays(START, -((START.getDay() + 6) % 7)); monday <= LAST_DAY; monday = addDays(monday, 7)) {
    const week = [0, 1, 2, 3, 4, 5, 6].map((offset) => addDays(monday, offset)).filter((date) => date >= START && date <= LAST_DAY);
    const home = (key) => week.filter((date) => !AWAY[key].some((range) => between(date, range)));
    const weekdays = (key) => home(key).filter((date) => date.getDay() >= 1 && date.getDay() <= 5);
    const on = (key, weekday) => home(key).filter((date) => date.getDay() === weekday);
    // Weeks swing between quiet (he is unwell, or family is away) and busy (family in town), for everyone at once.
    const busy = rng.weighted([[-2, 12], [-1, 18], [0, 36], [1, 20], [2, 14]]);
    const vary = (count) => Math.max(0, count + (rng.chance(0.75) ? busy : 0));
    const likely = (chance) => rng.chance(clamp(chance + 0.15 * busy, 0.1, 0.95));
    const summer = between(addDays(monday, 3), SUMMER_BREAK);

    for (const sunday of week.filter((date) => date.getDay() === 0)) {
      if (rng.chance(0.85)) add("Church", at(sunday, rng.chance(0.2) ? 9.5 : 11), 60);
    }
    for (const sunday of on("david", 0)) if (likely(0.65)) visit(sunday, DAVID.sunday, "david");
    for (const saturday of on("michael", 6)) if (likely(0.5)) visit(saturday, MICHAEL.library, "michael");

    const season = conradSeason(addDays(monday, 3));
    const gardenDays = home("conrad").filter((date) => (date >= COLLEGE ? date.getDay() === 6 : date.getDay() >= 1));
    spread(vary(rng.weighted(season.perWeek)), gardenDays, (date) => visit(date, conradSeason(date), "conrad"));
    spread(vary(rng.weighted(ANDREW.perWeek)), weekdays("andrew"), (date) => visit(date, ANDREW, "andrew"));
    spread(rng.chance(0.9) ? 1 : 0, weekdays("bob"), (date) => visit(date, BOB.visit, "bob"));
    spread(vary(rng.weighted(JOSH.lunch.perWeek)), home("josh"), (date) => visit(date, JOSH.lunch, "josh"));
    spread(vary(rng.weighted(JOSH.dinner.perWeek)), home("josh"), (date) => visit(date, JOSH.dinner, "josh"));
    spread(vary(rng.chance(0.3) ? 1 : 0), weekdays("michael"), (date) => visit(date, MICHAEL.dinner, "michael"));
    spread(vary(rng.chance(0.1) ? 1 : 0), weekdays("david"), (date) => visit(date, DAVID.dinner, "david"));
    spread(rng.chance(0.35) ? 1 : 0, weekdays("bob"), (date) => visit(date, BOB.evening, "bob"));
    spread(summer ? rng.weighted([[0, 50], [1, 50]]) : rng.weighted([[1, 60], [2, 40]]), home("monica"), (date) => visit(date, MONICA.call, "monica"));
    spread(vary(summer ? rng.weighted([[1, 55], [2, 45]]) : rng.weighted([[0, 60], [1, 40]])), summer ? home("monica") : [...on("monica", 0), ...on("monica", 6)], (date) =>
      visit(date, rng.chance(0.3) ? MONICA.dinner : MONICA.afternoon, "monica"));
  }
  return events.sort((a, b) => a.start - b.start);
}

// ---------------------------------------------------------------- Violet logs

// How far his recall has slipped: about 0.2 in January to about 1 by late September, plus a spike of delirium
// after the June infection that fades over two weeks and leaves him a little worse than before.
function decline(moment) {
  const progress = clamp((moment - START) / (day(9, 30) - START), 0, 1.3);
  const sinceIllness = (moment - ILLNESS) / DAY;
  const illness = sinceIllness < 0 ? 0 : 0.08 + 0.9 * Math.exp(-sinceIllness / 6);
  return 0.2 + 0.8 * progress ** 1.3 + illness;
}

// Sundowning: 0 before 3 pm, rising to 1 by 6:30 pm.
function sundown(hour) {
  const t = clamp((hour - 15) / 3.5, 0, 1);
  return t * t * (3 - 2 * t);
}

// Expected lookups per hour of one visitor. Later in the year and later in the day both raise it, and so does
// how recently he met the person, since recent memories go first.
function lookupRate(moment, person) {
  const level = decline(moment);
  return (0.03 + 0.12 * level) * (1 + sundown(hourOf(moment)) * (1 + 7 * level)) * person.difficulty;
}

// Violet uses per person seen, the dashed line on the portal's weekly chart: about 0.1 in January and 0.3 by July,
// then climbing fast to 0.8 by late September, with a spike after the June infection. It stays below 1, so there
// are always more visits than uses.
function usesPerVisit(moment) {
  const slip = (decline(moment) - 0.2) / 0.88;
  return clamp(0.1 + 0.2 * slip + 0.55 * slip ** 5, 0, 0.9);
}

const bump = (map, key, count) => map.set(key, (map.get(key) ?? 0) + count);

// Lookups for each week, as whole numbers, that stay closest to the curve while the weekly line holds steady where
// the curve rises and, where it rises steeply as it does from August, climbs at least half as fast. Rounding each
// week on its own would let the line jump around, most of all in quiet weeks. Every week keeps its lookups under
// 90% of the people seen.
function weeklyQuotas(seen, curve) {
  let paths = [{ ratio: 0, curve: Infinity, cost: 0, quotas: [] }];
  seen.forEach((people, week) => {
    const nearest = Math.round(curve[week] * people);
    const high = Math.max(0, Math.min(Math.ceil(0.9 * people) - 1, nearest + 2));
    const low = Math.min(high, Math.max(0, nearest - 2));
    paths = Array.from({ length: high - low + 1 }, (_, index) => {
      const ratio = (low + index) / people;
      const { path, cost } = paths
        .map((path) => {
          const rise = curve[week] - path.curve;
          const falls = rise >= 0.03 ? ratio < path.ratio + rise / 2 - 1e-9 : rise >= 0.01 && ratio < path.ratio - 1e-9;
          return { path, cost: path.cost + (falls ? 1 + path.ratio - ratio : 0) };
        })
        .reduce((best, option) => (option.cost < best.cost ? option : best));
      return { ratio, curve: curve[week], cost: cost + (ratio - curve[week]) ** 2, quotas: [...path.quotas, low + index] };
    });
  });
  return paths.reduce((best, path) => (path.cost < best.cost ? path : best)).quotas;
}

function planLogs(events, cast, rng) {
  // Weeks end today, like the portal's default six weeks, which counts everyone named in the events that have
  // started as seen, calls included.
  const today = at(NOW, 0);
  const weekOf = (date) => Math.floor((Math.round((at(date, 0) - today) / DAY) - 1) / 7);
  const named = events.filter((event) => event.who.length && event.start < NOW);
  const weeks = new Map();
  const days = new Map();
  const present = new Map();
  for (const event of named) {
    const day = event.start.toDateString();
    const target = event.who.length * usesPerVisit(event.start);
    if (!weeks.has(weekOf(event.start))) weeks.set(weekOf(event.start), { seen: 0, target: 0, days: [] });
    const week = weeks.get(weekOf(event.start));
    if (!days.has(day)) week.days.push(days.set(day, { seen: 0, target: 0, candidates: [] }).get(day));
    week.seen += event.who.length;
    week.target += target;
    days.get(day).seen += event.who.length;
    days.get(day).target += target;
    const last = event.end.getMinutes() === 0 ? event.end.getHours() - 1 : event.end.getHours();
    for (let hour = event.start.getHours(); hour <= last; hour += 1) bump(present, `${day} ${hour}`, event.who.length);
  }

  // A few candidate lookups for each person at each visit so far. Each gets a random rank that favours the visits
  // he finds harder (late in the day, people he met recently), so those take most of the day's lookups.
  for (const visit of named) {
    if (!visit.inPerson) continue;
    const end = Math.min(visit.end.getTime(), NOW.getTime());
    for (const name of visit.who) {
      const person = Object.values(cast).find((member) => member.name === name);
      // Stretches of the visit and the lookups expected in each. The arrival is the likeliest moment of all.
      const windows = [];
      const arrival = visit.start.getTime() + 2 * MINUTE;
      const arrivalChance = (0.04 + 0.14 * decline(visit.start) + 0.4 * sundown(hourOf(visit.start))) * person.difficulty;
      if (arrival < end) windows.push([arrival, 8 * MINUTE, clamp(arrivalChance, 0, 0.95)]);
      for (let slot = visit.start.getTime(); slot < end; slot += 5 * MINUTE) {
        const length = Math.min(5 * MINUTE, end - slot);
        windows.push([slot, length, (lookupRate(new Date(slot + length / 2), person) * length) / (60 * MINUTE)]);
      }
      const expected = windows.reduce((sum, [, , weight]) => sum + weight, 0);
      for (let count = 0; count < 3; count += 1) {
        let roll = rng.next() * expected;
        const [from, length] = windows.find(([, , weight]) => (roll -= weight) < 0) ?? windows.at(-1);
        const timestamp = new Date(Math.floor(Math.min(from + rng.next() * length, end - 1000) / 1000) * 1000);
        days.get(visit.start.toDateString()).candidates.push({ timestamp, identifiedPerson: name, visit, rank: rng.next() ** (1 / expected ** 2) });
      }
    }
  }

  // Each week's quota is spread over its days in proportion to the curve, so a range starting mid-week reads about
  // the same, and a day that falls short passes the rest on. Each day takes its candidates in rank order, with no
  // hour having more lookups than visitors present and no day more than people seen.
  const order = [...weeks.keys()].sort((a, b) => a - b).map((key) => weeks.get(key));
  const quotas = weeklyQuotas(order.map((week) => week.seen), order.map((week) => week.target / week.seen));
  const logs = [];
  const usedInHour = new Map();
  order.forEach((week, index) => {
    const first = logs.length;
    let share = 0;
    for (const day of week.days) {
      share += day.target;
      const quota = Math.min(day.seen, Math.round((share / week.target) * quotas[index]) - (logs.length - first));
      let taken = 0;
      for (const log of day.candidates.sort((a, b) => b.rank - a.rank)) {
        if (taken >= quota) break;
        const hour = `${log.timestamp.toDateString()} ${log.timestamp.getHours()}`;
        if ((usedInHour.get(hour) ?? 0) >= (present.get(hour) ?? 0)) continue;
        bump(usedInHour, hour, 1);
        logs.push(log);
        taken += 1;
      }
    }
  });

  // One in every 20 consecutive lookups disagrees with the calendar, so any stretch of time shows 95%. Within each
  // run of 20 the mistake is likelier in the dim evening.
  logs.sort((a, b) => a.timestamp - b.timestamp);
  const names = Object.values(cast).map((member) => member.name);
  const block = Math.round(1 / (1 - MATCH_RATE));
  for (let first = 0; first + block <= logs.length; first += block) {
    const run = logs.slice(first, first + block).map((log) => ({ log, key: rng.next() ** (1 / (1 + 2 * sundown(hourOf(log.timestamp)))) }));
    const { log } = run.reduce((best, entry) => (entry.key > best.key ? entry : best));
    const others = names.filter((name) => !log.visit.who.includes(name));
    log.identifiedPerson = rng.chance(0.35) ? rng.pick(others) : UNKNOWN;
  }
  return logs;
}

// ---------------------------------------------------------------- provider notes

const percent = (part, whole) => (whole ? Math.round((100 * part) / whole) : 0);

// "up from 12", "down from 12" or "about the same as 12".
function change(current, previous) {
  if (Number(current) > Number(previous) * 1.1) return `up from ${previous}`;
  if (Number(current) < Number(previous) * 0.9) return `down from ${previous}`;
  return `about the same as ${previous}`;
}

function stats(logs, events, cast, from, to) {
  const window = logs.filter((log) => log.timestamp >= from && log.timestamp < to);
  const visits = events.filter((event) => event.who.length && event.inPerson && event.start >= from && event.start < to && event.start < NOW);
  const matches = (log, name) => firstName(log.identifiedPerson) === firstName(name);
  const late = (moment) => moment.getHours() >= 16;
  const evening = window.filter((log) => late(log.timestamp));
  const morning = window.filter((log) => log.timestamp.getHours() < 12);
  // Visitor-hours of visiting time: before noon, noon to 4 pm, after 4 pm.
  const hours = [0, 0, 0];
  for (const event of visits) {
    for (let t = event.start.getTime(); t < Math.min(event.end, NOW); t += 5 * MINUTE) {
      const hour = new Date(t).getHours();
      hours[hour < 12 ? 0 : hour < 16 ? 1 : 2] += (event.who.length * 5) / 60;
    }
  }
  const dayRate = (window.length - evening.length) / (hours[0] + hours[1]);
  // Lookups per visit for each person with at least two visits, most first.
  const perPerson = Object.values(cast)
    .map((member) => {
      const count = visits.filter((event) => event.who.includes(member.name)).length;
      return { name: member.name, rate: count ? window.filter((log) => matches(log, member.name)).length / count : 0, count };
    })
    .filter((entry) => entry.count >= 2)
    .sort((a, b) => b.rate - a.rate);
  const top = (list) => {
    const counts = new Map();
    for (const log of list) if (log.identifiedPerson !== UNKNOWN) counts.set(log.identifiedPerson, (counts.get(log.identifiedPerson) ?? 0) + 1);
    return [...counts].sort((a, b) => b[1] - a[1])[0]?.[0] ?? "";
  };
  return {
    uses: window.length,
    visits: visits.length,
    evening: evening.length,
    eveningShare: percent(evening.length, window.length),
    eveningTime: percent(hours[2], hours[0] + hours[1] + hours[2]),
    morningShare: percent(morning.length, window.length),
    morningTime: percent(hours[0], hours[0] + hours[1] + hours[2]),
    // How many times more often he needs Violet per visiting hour after 4 pm than before.
    ratio: dayRate && hours[2] ? (evening.length / hours[2] / dayRate).toFixed(1) : "1.0",
    perVisit: visits.length ? (window.length / visits.length).toFixed(1) : "0",
    helped: new Set(window.map((log) => log.visit)).size,
    matched: percent(window.filter((log) => log.visit.who.some((name) => matches(log, name))).length, window.length),
    hardest: perPerson[0]?.name ?? "",
    easiest: perPerson.at(-1)?.name ?? "",
    eveningMost: top(evening),
    during: (text) => window.filter((log) => log.visit.title.includes(text)).length,
  };
}

function noteTemplates(cast, jan) {
  const { josh, conrad, monica, andrew, bob, david, michael } = Object.fromEntries(Object.entries(cast).map(([key, member]) => [key, member.name]));
  const age = YEAR - Number(PATIENT.dateOfBirth.slice(0, 4));
  const known = (name) => Object.values(cast).find((member) => member.name === name)?.yearsKnown;
  // A sentence about sundowning, only when evenings really are worse in that stretch.
  const evenings = (s) => (Number(s.ratio) >= 1.3 ? `he needed Violet ${s.ratio} times as often per hour of visiting after 4 pm as earlier in the day` : "");
  const recentFirst = (s) => (known(s.hardest) < known(s.easiest) ? ` He has known ${s.hardest} for ${known(s.hardest)} years and ${s.easiest} for ${known(s.easiest)}: recent memories are fading first.` : "");
  return [
    [day(1, 8), "Violet onboarding", () => `<p>Started Violet on the Meta glasses today. Enrolled seven familiar people: ${josh}, ${david}, ${michael}, ${monica}, ${conrad}, ${andrew} and ${bob}. ${josh} will keep visits on the shared calendar.</p><ul><li>Oriented to person and place, unsure of the date</li><li>Mild word-finding pauses in conversation</li><li>MoCA 22/30 at the December visit</li></ul><p>Plan: wear the glasses for every visit and review usage in two weeks.</p>`],
    [day(1, 22), "Two-week check-in", (s) => `<p>He needed Violet during ${s.helped} of ${s.visits} visits, often in the first minutes, and most with ${s.hardest}. Most visits go by without it.</p><p>No concerns from the family.</p>`],
    [day(2, 5), "Late-day confusion", (s) => `<p>${josh} reports he was more confused after dinner on two evenings last week.</p><p>${s.all.eveningShare > s.all.eveningTime ? `Since January, ${s.all.eveningShare}% of Violet lookups came after 4 pm, although only ${s.all.eveningTime}% of visiting time was then. This looks like early sundowning.` : "This may be early sundowning."}</p><ul><li>Open the blinds and get outside in the early afternoon</li><li>No naps after 2 pm, no caffeine after noon</li><li>Lights on by 4 pm</li></ul>`],
    [day(2, 19), "Medication review", () => `<p>Continues donepezil 10 mg nightly with no side effects. Sleeping about 7 hours with one or two awakenings.</p><p>Discussed melatonin 3 mg at 9 pm for evening restlessness. ${josh} will try it for two weeks.</p>`],
    [day(3, 5), "Mornings", (s) => `<p>${conrad} has started spring garden sessions again, and ${andrew}'s music class continues most weeks. He enjoys both.</p>${s.six.morningShare < s.six.morningTime ? `<p>Mornings remain his best time: over the past six weeks, ${s.six.morningShare}% of Violet lookups were before noon, though ${s.six.morningTime}% of visiting time was.</p>` : ""}`],
    [day(3, 19), "Sundowning update", (s) => `<p>${evenings(s.six) ? `Over the past six weeks, ${evenings(s.six)}${Number(s.six.ratio) > Number(jan.ratio) ? `, up from ${jan.ratio} in January` : ""}.` : "Evenings are harder than mornings, though Violet use after 4 pm is still low."} Most evening lookups were for ${s.six.eveningMost || josh}.</p><ul><li>Ask ${s.six.eveningMost || josh} to visit earlier in the day when possible</li><li>Keep a fixed dinner time of 5:30 pm</li></ul>`],
    [day(4, 2), "Caregiver check-in", (s) => `<p>${josh} is coping well but reports moderate stress, mostly around evenings. Shared information on respite care and the local caregiver support group.</p><p>Violet use averaged ${s.perVisit} lookups per visit over the past two weeks, ${change(s.perVisit, s.prev.perVisit)}.</p>`],
    [addDays(BIRTHDAY, 3), "Birthday weekend", (s) => `<p>Celebrated his ${age}th birthday at dinner with ${josh}, ${david} and ${michael}. He used Violet ${s.during("Birthday") === 1 ? "once" : `${s.during("Birthday")} times`} during the dinner and settled well afterwards.</p>`],
    [day(4, 29), "Memory clinic follow-up", () => `<p>Seen by Dr. Patel yesterday. MoCA 20/30, down from 22 in December, with delayed recall 1/5.</p><p>Continue donepezil and the evening routine. Next review in July.</p>`],
    [day(5, 13), "Evening routine", (s) => `<p>The routine is in place: dinner at 5:30, lights on at 4, television off by 8. ${josh} reports less pacing.</p><p>${evenings(s.six) ? `Evenings are still the hardest time: over the past six weeks, ${evenings(s.six)}, so the family will keep evening visits short and calm.` : "Evening lookups have eased since the routine started."}</p>`],
    [day(5, 27), "Four-week summary", (s) => `<p>${s.month.visits} visits and ${s.month.uses} Violet lookups in the past four weeks, ${change(s.month.uses, s.prevMonth.uses)} the four weeks before. He needs Violet most with ${s.month.hardest} and least with ${s.month.easiest}.${recentFirst(s.month)}</p>`],
    [day(6, 10), "Urgent care: UTI", () => `<p>Seen at urgent care yesterday for a urinary tract infection and started a five-day course of antibiotics.</p><p>Acute increase in confusion, worst in the evenings. Expect more Violet lookups while it clears. Push fluids and recheck in one week.</p>`],
    [day(6, 24), "Post-infection follow-up", (s) => `<p>The infection has cleared. Confusion is better than last week but has not returned to the May baseline.</p><p>${s.uses} Violet lookups in the two weeks since the infection, ${change(s.uses, s.prev.uses)} in the two weeks before it.</p>`],
    [day(7, 8), "Summer", (s) => `<p>Garden sessions with ${conrad} moved to 8 am because of the heat. ${monica} is home from Georgia Tech for the summer and visits often, which he enjoys.</p>${s.six.morningShare < s.six.morningTime ? `<p>Mornings remain calm: over the past six weeks, ${s.six.morningShare}% of lookups were before noon, during ${s.six.morningTime}% of visiting time.</p>` : ""}`],
    [day(7, 22), "Family meeting", (s) => `<p>Met with ${josh}, ${david} and ${michael}. ${josh} is away this week, so ${michael} is covering evenings.</p><p>Agreed to look for an evening companion from 5 to 8 pm${evenings(s.six) ? `: over the past six weeks, ${evenings(s.six)}` : ", when he tires most"}.</p>`],
    [day(8, 5), "Medication review", () => `<p>Discussed adding memantine with neurology given the steady decline, and the family agreed.</p><ul><li>Start memantine 5 mg daily</li><li>Increase by 5 mg each week to 10 mg twice daily</li></ul>`],
    [day(8, 19), "Memantine titration", (s) => `<p>Tolerating memantine 10 mg twice daily with no dizziness. Evening agitation is slightly less.</p><p>${s.uses} Violet lookups in the past two weeks, ${change(s.uses, s.prev.uses)}, or ${s.perVisit} per visit. ${monica} is back at Georgia Tech, and ${bob} will watch for evening agitation at his check-ins.</p>`],
    [day(9, 2), "Monthly summary", (s) => `<p>He needed Violet during ${s.helped} of ${s.visits} visits in the past two weeks, against ${jan.helped} of ${jan.visits} in all of January. ${s.eveningShare}% of lookups came after 4 pm.</p><p>Since January, Violet's recognitions have matched the calendar ${s.all.matched}% of the time, so the increase reflects his memory rather than the glasses.</p>`],
    [day(9, 16), "Memory clinic follow-up", () => `<p>Seen by Dr. Patel yesterday. MoCA 18/30, consistent with moderate Alzheimer's disease. Continue donepezil and memantine.</p><p>${conrad} starts college at Emory this week, so garden sessions move to Saturdays. Suggest a day program two mornings a week to keep mornings active.</p>`],
    [day(9, 24), "Weekly check-in", (s) => `<p>Weekday mornings are quieter without ${conrad}'s garden sessions.${evenings(s.month) ? ` Evenings remain the hardest time: over the past four weeks, ${evenings(s.month)}.` : ""}</p><p>Plan: start the evening companion next week and review in two weeks.</p>`],
  ];
}

function planNotes(logs, events, cast, rng) {
  const jan = stats(logs, events, cast, START, day(2, 1));
  return noteTemplates(cast, jan)
    .map(([date, title, body]) => {
      const createdAt = at(date, Math.round(rng.between(9, 16.5) * 4) / 4);
      const since = (days) => new Date(createdAt - days * DAY);
      const window = (from, to) => stats(logs, events, cast, from, to);
      const s = { ...window(since(14), createdAt), prev: window(since(28), since(14)), month: window(since(28), createdAt), prevMonth: window(since(56), since(28)), six: window(since(42), createdAt), all: window(START, createdAt) };
      return { title, body: body(s), createdAt };
    })
    .filter((note) => note.createdAt <= NOW);
}

// ---------------------------------------------------------------- Mongo, Google Calendar and the portal tab

function loadEnv() {
  const env = {};
  for (const line of readFileSync(join(ROOT, ".env"), "utf8").split("\n")) {
    const match = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)$/);
    if (match) env[match[1]] = match[2].trim().replace(/^["']|["']$/g, "");
  }
  return env;
}

// The cast as the portal will see it: stored people keep their own year met.
function castFrom(people) {
  return Object.fromEntries(Object.entries(PEOPLE).map(([key, spec]) => {
    const stored = people.find((person) => firstName(String(person.name ?? "")) === key);
    const yearsKnown = Math.max(0, YEAR - Number(stored?.yearMet ?? stored?.year_met ?? spec.yearMet));
    return [key, { name: spec.name, yearsKnown, difficulty: 0.45 + 1.6 * Math.exp(-yearsKnown / 8) }];
  }));
}

const PORTAL_SCRIPT = [
  "on run argv",
  'tell application "Google Chrome"',
  "repeat with w in windows",
  "repeat with t in tabs of w",
  'if URL of t starts with "http://localhost:3000" then return execute t javascript (item 1 of argv)',
  "end repeat",
  "end repeat",
  "end tell",
  'return "no-portal-tab"',
  "end run",
];

// Runs JavaScript in the portal tab and returns the result as text.
function portal(code) {
  const result = execFileSync("osascript", [...PORTAL_SCRIPT.flatMap((line) => ["-e", line]), code], { encoding: "utf8", maxBuffer: 16 * 1024 * 1024 }).trim();
  if (result === "no-portal-tab") throw new Error("Open the portal at http://localhost:3000 in Chrome first.");
  return result;
}

function googleToken() {
  if (process.env.GOOGLE_ACCESS_TOKEN) return process.env.GOOGLE_ACCESS_TOKEN;
  const raw = portal('sessionStorage.getItem("violet-google-token") || ""');
  const token = raw && raw !== "missing value" ? JSON.parse(raw) : null;
  if (!token || token.expiresAt < Date.now() + 10 * MINUTE) throw new Error("Connect Google Calendar in the portal tab first (the token is missing or about to expire).");
  return token.accessToken;
}

// Front, left and right placeholder photos: a white silhouette with an initial on the person's color.
function placeholderPhotos(name, color) {
  const hex = { 3: "#8e24aa", 4: "#e67c73", 5: "#f6bf26", 6: "#f4511e", 7: "#039be5", 9: "#3f51b5", 10: "#0b8043" }[color] ?? "#9b82e8";
  return JSON.parse(portal(`(() => {
    const canvas = document.createElement("canvas");
    canvas.width = canvas.height = 480;
    const g = canvas.getContext("2d");
    return JSON.stringify([0, -50, 50].map((shift) => {
      g.fillStyle = ${JSON.stringify(hex)};
      g.fillRect(0, 0, 480, 480);
      g.fillStyle = "#ffffff";
      g.beginPath(); g.arc(240 + shift, 190, 100, 0, 2 * Math.PI); g.fill();
      g.beginPath(); g.ellipse(240 + shift, 480, 180, 150, 0, Math.PI, 2 * Math.PI); g.fill();
      g.fillStyle = ${JSON.stringify(hex)};
      g.font = "700 96px sans-serif"; g.textAlign = "center"; g.textBaseline = "middle";
      g.fillText(${JSON.stringify(name.charAt(0).toUpperCase())}, 240 + shift, 196);
      return canvas.toDataURL("image/jpeg", 0.85).split(",")[1];
    }));
  })()`));
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function google(token, method, path, body) {
  for (let attempt = 0; ; attempt += 1) {
    const response = await fetch(`https://www.googleapis.com/calendar/v3/calendars/primary/${path}`, {
      method,
      headers: { Authorization: `Bearer ${token}`, ...(body ? { "Content-Type": "application/json" } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (response.ok) return response.status === 204 ? null : response.json();
    if (method === "DELETE" && response.status === 410) return null;
    const text = await response.text();
    const limited = response.status === 429 || response.status >= 500 || /rateLimitExceeded/.test(text);
    if (!limited || attempt === 6) throw new Error(`Google ${method} ${path.split("?")[0]} failed (${response.status}): ${text.slice(0, 300)}`);
    await sleep(1000 * 2 ** attempt);
  }
}

async function pool(items, worker, size = 3) {
  let index = 0;
  await Promise.all(Array.from({ length: size }, async () => {
    while (index < items.length) await worker(items[index++]);
  }));
}

const eventKey = (title, start, end) => `${title}|${new Date(start).toISOString()}|${new Date(end).toISOString()}`;

async function applyCalendar(token, events, stamp) {
  const items = [];
  let pageToken;
  let timeZone;
  do {
    const params = new URLSearchParams({ timeMin: START.toISOString(), timeMax: addDays(LAST_DAY, 1).toISOString(), singleEvents: "true", maxResults: "2500" });
    if (pageToken) params.set("pageToken", pageToken);
    const page = await google(token, "GET", `events?${params}`);
    items.push(...(page.items ?? []));
    ({ nextPageToken: pageToken, timeZone } = page);
  } while (pageToken);

  const ours = items.filter((item) => item.extendedProperties?.private?.violetSeed === "1");
  // The weekly template: recurring series this script did not create. Deleting a series removes every instance.
  const series = REPLACE_TEMPLATE ? [...new Set(items.filter((item) => item.recurringEventId && !ours.includes(item)).map((item) => item.recurringEventId))] : [];
  if (series.length) {
    const masters = [];
    for (const id of series) masters.push(await google(token, "GET", `events/${encodeURIComponent(id)}`));
    writeFileSync(join(OUT, "backup", `calendar-${stamp}.json`), JSON.stringify(masters, null, 2));
  }

  const planned = new Map(events.map((event) => [eventKey(event.title, event.start, event.end), event]));
  const existing = new Set(ours.map((item) => eventKey(item.summary, item.start.dateTime, item.end.dateTime)));
  const stale = ours.filter((item) => !planned.has(eventKey(item.summary, item.start.dateTime, item.end.dateTime)));
  const fresh = [...planned].filter(([key]) => !existing.has(key)).map(([, event]) => event);

  await pool(series, (id) => google(token, "DELETE", `events/${encodeURIComponent(id)}?sendUpdates=none`));
  await pool(stale, (item) => google(token, "DELETE", `events/${encodeURIComponent(item.id)}?sendUpdates=none`));
  let added = 0;
  await pool(fresh, async (event) => {
    await google(token, "POST", "events?sendUpdates=none", {
      summary: event.title,
      start: { dateTime: event.start.toISOString(), timeZone },
      end: { dateTime: event.end.toISOString(), timeZone },
      colorId: event.color,
      reminders: { useDefault: false },
      extendedProperties: { private: { violetSeed: "1" } },
    });
    if (++added % 100 === 0) console.log(`  added ${added} of ${fresh.length} events`);
  });
  console.log(`Calendar (${timeZone}): deleted ${series.length} recurring template series, removed ${stale.length} outdated events, added ${fresh.length}, kept ${ours.length - stale.length}.`);
}

async function applyPeople(db, collection, stamp) {
  const relationships = db.collection(collection);
  const people = await relationships.find({}).toArray();
  const now = new Date();
  const backup = [];

  if (REPLACE_TEMPLATE) {
    // "bob" was saved as a son with no bio while testing; the calendar template has Bob as the nurse.
    const bob = people.find((person) => firstName(String(person.name ?? "")) === "bob");
    if (bob && /^son$/i.test(String(bob.relation ?? "").trim())) {
      backup.push(bob);
      const { name, relation, bio } = PEOPLE.bob;
      await relationships.updateOne({ _id: bob._id }, { $set: { name, relation, bio, updatedAt: now } });
      console.log(`People: ${bob.name} is now ${name}, ${relation.toLowerCase()}.`);
    }
    const extras = people.filter((person) => !(firstName(String(person.name ?? "")) in PEOPLE));
    if (extras.length) {
      backup.push(...extras);
      await relationships.deleteMany({ _id: { $in: extras.map((person) => person._id) } });
      console.log(`People: removed ${extras.map((person) => person.name).join(", ")}.`);
    }
  }
  if (backup.length) writeFileSync(join(OUT, "backup", `relationships-${stamp}.json`), JSON.stringify(backup, null, 2));

  const missing = Object.entries(PEOPLE).filter(([key]) => !people.some((person) => firstName(String(person.name ?? "")) === key));
  for (const [, spec] of missing) {
    const [frontPhoto, leftPhoto, rightPhoto] = placeholderPhotos(spec.name, spec.color);
    const { name, relation, bio, notes, yearMet } = spec;
    await relationships.insertOne({ name, frontPhoto, leftPhoto, rightPhoto, relation, bio, notes, yearMet, createdAt: now, updatedAt: now, synthetic: TAG });
  }
  if (missing.length) console.log(`People: added ${missing.map(([, spec]) => spec.name).join(", ")} with placeholder photos.`);
}

async function applyMongo(db, collections, logs, notes, stamp) {
  const logsCollection = db.collection(collections.logs);
  const notesCollection = db.collection(collections.notes);
  const now = new Date();
  // Notes are deleted the way the portal deletes them, so open portals drop them on their next sync.
  const softDelete = (filter) => notesCollection.updateMany({ ...filter, deletedAt: { $exists: false } }, { $set: { deletedAt: now, updatedAt: now, title: "", body: "" } });

  if (CLEAR_TEST_DATA) {
    const backup = {
      logs: await logsCollection.find({ synthetic: { $ne: TAG } }).toArray(),
      provider_notes: await notesCollection.find({ synthetic: { $ne: TAG }, deletedAt: { $exists: false } }).toArray(),
    };
    writeFileSync(join(OUT, "backup", `mongo-${stamp}.json`), JSON.stringify(backup, null, 2));
    const removedLogs = await logsCollection.deleteMany({ synthetic: { $ne: TAG } });
    const removedNotes = await softDelete({ synthetic: { $ne: TAG } });
    console.log(`Mongo: backed up and removed ${removedLogs.deletedCount} test logs and ${removedNotes.modifiedCount} test notes.`);
  }
  await logsCollection.deleteMany({ synthetic: TAG });
  await softDelete({ synthetic: TAG });
  await logsCollection.insertMany(logs.map((log) => ({ timestamp: log.timestamp, identifiedPerson: log.identifiedPerson, synthetic: TAG })));
  await notesCollection.insertMany(notes.map((note) => ({ title: note.title, body: note.body, createdAt: note.createdAt, updatedAt: note.createdAt, synthetic: TAG })));
  console.log(`Mongo: wrote ${logs.length} logs and ${notes.length} provider notes.`);
}

// Saves the patient details and, after logs and notes change, clears the tab's cached copies. Then reloads it.
async function applyPortal(clearCache) {
  const cached = clearCache ? ["patient-data-v1", "provider-notes-mongo-v1"] : [];
  portal(`(() => {
    window.__violetSeed = "pending";
    for (const key of ${JSON.stringify(cached)}) localStorage.removeItem(key);
    const request = indexedDB.open("violet-care-portal", 1);
    request.onupgradeneeded = () => request.result.createObjectStore("cache");
    request.onerror = () => { window.__violetSeed = "error: " + request.error; };
    request.onsuccess = () => {
      const db = request.result;
      const transaction = db.transaction("cache", "readwrite");
      const store = transaction.objectStore("cache");
      store.put(${JSON.stringify(PATIENT)}, "patient-profile-v1");
      for (const key of ${JSON.stringify(cached)}) store.delete(key);
      transaction.oncomplete = () => { db.close(); window.__violetSeed = "done"; };
      transaction.onerror = () => { window.__violetSeed = "error: " + transaction.error; };
    };
    return "started";
  })()`);
  for (let attempt = 0; attempt < 50; attempt += 1) {
    const state = portal("String(window.__violetSeed)");
    if (state === "done") break;
    if (state.startsWith("error")) throw new Error(`Could not update the portal tab: ${state}`);
    await sleep(200);
  }
  portal('setTimeout(() => location.reload(), 50), "reloading"');
  console.log(`Portal: saved patient details for ${PATIENT.name} and reloaded the tab.`);
}

// ---------------------------------------------------------------- summary

function summarize(events, logs, notes, cast) {
  const visits = events.filter((event) => event.who.length);
  const matched = logs.filter((log) => {
    const scheduled = visits.filter((event) => event.start <= log.timestamp && log.timestamp < event.end).flatMap((event) => event.who);
    return scheduled.some((name) => firstName(name) === firstName(log.identifiedPerson));
  }).length;
  const past = visits.filter((event) => event.start < NOW);
  console.log(`History ${START.toDateString()} to ${NOW.toDateString()}, calendar through ${LAST_DAY.toDateString()}`);
  console.log(`  calendar events  ${events.length} (${visits.length} naming familiar people, ${visits.length - past.length} of them upcoming)`);
  console.log(`  Violet logs      ${logs.length}, ${((100 * matched) / logs.length).toFixed(1)}% match the person on the calendar`);
  console.log(`  provider notes   ${notes.length}`);
  console.log(`  patient          ${PATIENT.name}, ${PATIENT.gender}, born ${PATIENT.dateOfBirth}, caregiver ${PATIENT.caregiverName} ${PATIENT.caregiverPhone}`);

  console.log("\n  month  visits  lookups  per visit  after 4 pm  evening x");
  for (let month = 0; month <= NOW.getMonth(); month += 1) {
    const from = new Date(YEAR, month, 1);
    const s = stats(logs, events, cast, from, new Date(YEAR, month + 1, 1));
    console.log(`  ${from.toLocaleString("en-US", { month: "short" }).padEnd(5)}  ${String(s.visits).padStart(6)}  ${String(s.uses).padStart(7)}  ${s.perVisit.padStart(9)}  ${String(s.eveningShare).padStart(9)}%  ${s.ratio.padStart(9)}`);
  }

  console.log("\n  person    known  visits  lookups");
  for (const member of Object.values(cast)) {
    const count = past.filter((event) => event.who.includes(member.name) && event.inPerson).length;
    const lookups = logs.filter((log) => log.identifiedPerson === member.name).length;
    console.log(`  ${member.name.padEnd(8)}  ${String(member.yearsKnown).padStart(4)}y  ${String(count).padStart(6)}  ${String(lookups).padStart(7)}`);
  }

  // The portal's weekly chart, in weeks ending today: people named in the week's events against Violet lookups.
  const weeks = new Map();
  const today = at(NOW, 0);
  const weekOf = (date) => Math.floor((Math.round((at(date, 0) - today) / DAY) - 1) / 7);
  for (const visit of visits.filter((event) => event.start <= NOW)) weeks.set(weekOf(visit.start), { seen: (weeks.get(weekOf(visit.start))?.seen ?? 0) + visit.who.length, uses: 0 });
  for (const log of logs) weeks.get(weekOf(log.timestamp)).uses += 1;
  const ordered = [...weeks].sort((a, b) => a[0] - b[0]).map(([, week]) => week);
  console.log(`\n  people seen per week  ${ordered.map((week) => week.seen).join(" ")}`);
  console.log(`  lookups per week      ${ordered.map((week) => week.uses).join(" ")}`);
  console.log(`  per person seen       ${ordered.map((week) => (week.uses / week.seen).toFixed(2).slice(1)).join(" ")}`);
  console.log(`  weeks with more lookups than people seen: ${ordered.filter((week) => week.uses >= week.seen).length}`);

  // The portal's time-of-day chart over its default six weeks: visitors in each hour a visit covers.
  const from = addDays(NOW, -41);
  const recent = past.filter((event) => event.start >= addDays(from, -1));
  const hours = Array.from({ length: 16 }, (_, index) => index + 7);
  const label = (hour) => `${hour % 12 || 12}${hour < 12 ? "a" : "p"}`.padStart(4);
  const visitors = (hour) => recent.reduce((sum, event) => {
    const last = event.end.getMinutes() === 0 ? event.end.getHours() - 1 : event.end.getHours();
    return sum + (event.start.getHours() <= hour && hour <= last ? event.who.length : 0);
  }, 0);
  const lookups = (hour) => logs.filter((log) => log.timestamp >= addDays(from, -1) && log.timestamp.getHours() === hour).length;
  console.log("\n  last six weeks  " + hours.map(label).join(""));
  console.log("  lookups         " + hours.map((hour) => String(lookups(hour)).padStart(4)).join(""));
  console.log("  visitors        " + hours.map((hour) => String(visitors(hour)).padStart(4)).join(""));
}

// ---------------------------------------------------------------- main

const env = loadEnv();
const collections = {
  relationships: env.MONGO_RELATIONSHIPS_PATH || "relationships",
  logs: env.MONGO_LOGS_PATH || "logs",
  notes: env.MONGO_NOTES_PATH || "provider_notes",
};
const client = await new MongoClient(env.MONGO_URI).connect();
try {
  const db = client.db(env.MONGO_DB_NAME || "violet");
  const people = await db.collection(collections.relationships).find({}, { projection: { name: 1, yearMet: 1, year_met: 1 } }).toArray();
  const cast = castFrom(people);
  const events = planCalendar(cast, generator(SEED));
  const logs = planLogs(events, cast, generator(SEED + 1));
  const notes = planNotes(logs, events, cast, generator(SEED + 2));

  mkdirSync(join(OUT, "backup"), { recursive: true });
  const write = (name, data) => writeFileSync(join(OUT, name), JSON.stringify(data, null, 2));
  write("calendar.json", events.map(({ title, start, end, who, inPerson }) => ({ title, start, end, who, inPerson })));
  write("logs.json", logs.map(({ timestamp, identifiedPerson }) => ({ timestamp, identifiedPerson })));
  write("provider_notes.json", notes);
  write("patient.json", PATIENT);
  summarize(events, logs, notes, cast);

  if (!APPLY) {
    console.log("\nDry run: wrote demo/synthetic_data/ and changed nothing. Rerun with --apply to write it.");
  } else {
    const stamp = NOW.toISOString().replace(/[:.]/g, "-");
    console.log("");
    if (STEPS.includes("calendar")) await applyCalendar(googleToken(), events, stamp);
    if (STEPS.includes("people")) await applyPeople(db, collections.relationships, stamp);
    if (STEPS.includes("logs")) await applyMongo(db, collections, logs, notes, stamp);
    if (STEPS.includes("patient")) await applyPortal(STEPS.includes("logs"));
  }
} finally {
  await client.close();
}
