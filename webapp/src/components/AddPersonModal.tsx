"use client";

import { useEffect, useRef, useState, type FormEvent } from "react";
import type { Person, PersonDraft } from "@/lib/types";
import { fileToBase64Jpeg } from "@/lib/client/photos";

type Slot = "frontPhoto" | "leftPhoto" | "rightPhoto";
const SLOTS: Array<{ key: Slot; label: string; short: string }> = [
  { key: "frontPhoto", label: "Front-facing photo", short: "Front" },
  { key: "leftPhoto", label: "Left-facing photo", short: "Left" },
  { key: "rightPhoto", label: "Right-facing photo", short: "Right" },
];

type Props = { person?: Person; onClose: () => void; onSubmit: (draft: PersonDraft) => Promise<Person> };

export function AddPersonModal({ person, onClose, onSubmit }: Props) {
  const [name, setName] = useState(person?.name ?? "");
  const [relation, setRelation] = useState(person?.relation ?? "");
  const [yearMet, setYearMet] = useState(person ? String(person.yearMet) : "");
  const [bio, setBio] = useState(person?.bio ?? "");
  const [photos, setPhotos] = useState<Record<Slot, string>>({
    frontPhoto: person?.frontPhoto ?? "",
    leftPhoto: person?.leftPhoto ?? "",
    rightPhoto: person?.rightPhoto ?? "",
  });
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const firstInput = useRef<HTMLInputElement>(null);

  useEffect(() => {
    firstInput.current?.focus();
    const keydown = (event: KeyboardEvent) => event.key === "Escape" && onClose();
    document.addEventListener("keydown", keydown);
    const overflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.removeEventListener("keydown", keydown);
      document.body.style.overflow = overflow;
    };
  }, [onClose]);

  async function choose(slot: Slot, file?: File) {
    if (!file) return;
    try {
      const value = await fileToBase64Jpeg(file);
      setPhotos((current) => ({ ...current, [slot]: value }));
      setError(null);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Could not read that photo.");
    }
  }

  async function submit(event: FormEvent) {
    event.preventDefault();
    const year = Number(yearMet);
    if (!name.trim() || !relation.trim()) return setError("Name and relationship are required.");
    if (!Number.isInteger(year) || year < 1900 || year > new Date().getFullYear()) return setError("Enter a valid year met.");
    if (SLOTS.some((slot) => !photos[slot.key])) return setError("Add all three recognition photos.");
    setBusy(true);
    setError(null);
    try {
      await onSubmit({ name: name.trim(), relation: relation.trim(), bio: bio.trim(), yearMet: year, ...photos });
      onClose();
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Could not save this person.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="modal-backdrop" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
      <div className="modal" role="dialog" aria-modal="true" aria-labelledby="add-person-title">
        <div className="modal-heading">
          <div>
            <h2 id="add-person-title">{person ? "Edit familiar person" : "Add a familiar person"}</h2>
          </div>
          <button className="close-button" onClick={onClose} aria-label="Close">×</button>
        </div>
        <form onSubmit={submit} className="person-form">
          <label>
            <span>Name</span>
            <input ref={firstInput} value={name} onChange={(event) => setName(event.target.value)} autoComplete="off" />
          </label>
          <div className="field-pair">
            <label>
              <span>Relationship</span>
              <input value={relation} onChange={(event) => setRelation(event.target.value)} placeholder="Daughter, doctor, neighbor…" />
            </label>
            <label>
              <span>Year met</span>
              <input type="number" min="1900" max={new Date().getFullYear()} value={yearMet} onChange={(event) => setYearMet(event.target.value)} />
            </label>
          </div>
          <label>
            <span>Short bio</span>
            <textarea value={bio} onChange={(event) => setBio(event.target.value)} placeholder="What should Violet read aloud to the patient?" />
          </label>
          <fieldset>
            <legend>Recognition photos</legend>
            <div className="photo-grid">
              {SLOTS.map((slot) => (
                <label className="photo-input" key={slot.key}>
                  {photos[slot.key] ? <img src={photos[slot.key].startsWith("data:") || /^https?:\/\//i.test(photos[slot.key]) ? photos[slot.key] : `data:image/jpeg;base64,${photos[slot.key]}`} alt="" /> : <span>{slot.short}<small>{slot.label}</small></span>}
                  <input type="file" accept="image/*" capture="environment" onChange={(event) => void choose(slot.key, event.target.files?.[0])} aria-label={slot.label} />
                </label>
              ))}
            </div>
          </fieldset>
          {error && <p className="form-error" role="alert">{error}</p>}
          <div className="form-actions">
            <button className="secondary-button" type="button" onClick={onClose} disabled={busy}>Cancel</button>
            <button className="primary-button" type="submit" disabled={busy}>{busy ? "Saving…" : person ? "Save changes" : "Save person"}</button>
          </div>
        </form>
      </div>
    </div>
  );
}
