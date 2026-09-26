"use client";

import type { Person } from "@/lib/types";

type Props = { people: Person[] };

function initials(name: string) {
  return name.replace(/^(dr|mr|mrs|ms)\.?\s+/i, "").split(/\s+/).slice(0, 2).map((part) => part[0]?.toUpperCase() ?? "").join("");
}

function photo(value: string): string | null {
  if (!value) return null;
  if (/^https?:\/\//i.test(value) || value.startsWith("data:")) return value;
  return `data:image/jpeg;base64,${value}`;
}

export function PeoplePanel({ people }: Props) {
  return (
    <section className="clinical-section" aria-labelledby="people-title">
      <div className="section-header"><h2 id="people-title">Familiar people</h2><span>{people.length}/10</span></div>
      <div className="people-table">
        {people.length === 0 ? <p className="empty-state">No familiar people.</p> : people.map((person) => {
          const src = photo(person.frontPhoto);
          return (
            <div className="people-table-row" key={person.id}>
              <div className="person-photo">{src ? <img src={src} alt="" /> : <span>{initials(person.name)}</span>}</div>
              <strong>{person.name}</strong>
              <span>{person.relation}</span>
              <span>{person.yearMet}</span>
            </div>
          );
        })}
      </div>
    </section>
  );
}
