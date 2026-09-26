"use client";

import { useEffect, useState, type FormEvent } from "react";
import { AD8_ITEMS } from "@/lib/types";
import { dayKey } from "@/lib/date";

type Props = { onSave: (date: string, answers: boolean[]) => void; onClose: () => void };

export function CheckInModal({ onSave, onClose }: Props) {
  const [date, setDate] = useState(() => dayKey(new Date()));
  const [answers, setAnswers] = useState<boolean[]>(() => AD8_ITEMS.map(() => false));

  useEffect(() => {
    const keydown = (event: KeyboardEvent) => event.key === "Escape" && onClose();
    document.addEventListener("keydown", keydown);
    return () => document.removeEventListener("keydown", keydown);
  }, [onClose]);

  function submit(event: FormEvent) {
    event.preventDefault();
    if (!date) return;
    onSave(date, answers);
    onClose();
  }

  const score = answers.filter(Boolean).length;

  return (
    <div className="modal-backdrop" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
      <div className="modal" role="dialog" aria-modal="true" aria-labelledby="checkin-modal-title">
        <div className="modal-heading"><h2 id="checkin-modal-title">AD8 caregiver check-in</h2><button className="close-button" onClick={onClose} aria-label="Close">×</button></div>
        <form className="patient-form" onSubmit={submit}>
          <p className="form-intro">Check each item where you have noticed a change over the last several years caused by thinking or memory problems, not by a physical problem.</p>
          <label className="checkin-date"><span>Date</span><input type="date" value={date} onChange={(event) => setDate(event.target.value)} required /></label>
          <ol className="checkin-list">
            {AD8_ITEMS.map((item, index) => (
              <li key={item}>
                <label className="checkin-item">
                  <input type="checkbox" checked={answers[index]} onChange={(event) => setAnswers(answers.map((value, position) => (position === index ? event.target.checked : value)))} />
                  <span>{item}</span>
                </label>
              </li>
            ))}
          </ol>
          <p className="checkin-score">Score {score} of 8. Two or more suggests cognitive impairment.</p>
          <div className="form-actions"><button className="secondary-button" type="button" onClick={onClose}>Cancel</button><button className="primary-button" type="submit">Save check-in</button></div>
        </form>
      </div>
    </div>
  );
}
