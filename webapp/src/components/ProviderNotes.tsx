"use client";

import { useCallback, useEffect, useRef, useState, type ClipboardEvent, type DragEvent, type FormEvent, type KeyboardEvent, type ReactNode } from "react";
import type { ProviderNote } from "@/lib/types";
import { plainText, sanitizeHtml } from "@/lib/client/richText";
import { format } from "@/lib/date";

type Props = {
  notes: ProviderNote[];
  syncError: string | null;
  onAdd: (title: string, body: string) => Promise<void>;
  onUpdate: (id: string, title: string, body: string) => Promise<void>;
  onRemove: (id: string) => Promise<void>;
};

// Bulleted list glyph, drawn to match the stroke icons in the analytics tabs.
const BulletIcon = () => (
  <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden="true">
    <path d="M10 6h10M10 12h10M10 18h10" />
    <circle cx="4.5" cy="6" r="1.2" fill="currentColor" stroke="none" />
    <circle cx="4.5" cy="12" r="1.2" fill="currentColor" stroke="none" />
    <circle cx="4.5" cy="18" r="1.2" fill="currentColor" stroke="none" />
  </svg>
);

const TOOLS: Array<{ command: string; label: string; text: ReactNode; className?: string }> = [
  { command: "bold", label: "Bold (Ctrl+B)", text: "B", className: "tool-bold" },
  { command: "italic", label: "Italic (Ctrl+I)", text: "I", className: "tool-italic" },
  { command: "underline", label: "Underline (Ctrl+U)", text: "U", className: "tool-underline" },
  { command: "insertUnorderedList", label: "Bulleted list", text: <BulletIcon />, className: "tool-icon" },
];

const SHORTCUTS: Record<string, string> = { b: "bold", i: "italic", u: "underline" };

export function ProviderNotes({ notes, syncError, onAdd, onUpdate, onRemove }: Props) {
  const [saving, setSaving] = useState(false);
  const [title, setTitle] = useState("");
  const [editingId, setEditingId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [menuId, setMenuId] = useState<string | null>(null);
  // Notes the reader has explicitly opened or closed. Anything else follows the default: only the most recent note is open.
  const [toggled, setToggled] = useState<Record<string, boolean>>({});
  const isOpen = (id: string) => toggled[id] ?? id === notes[0]?.id;
  const toggle = (id: string) => setToggled((current) => ({ ...current, [id]: !isOpen(id) }));
  const editor = useRef<HTMLDivElement>(null);
  const [active, setActive] = useState<Record<string, boolean>>({});

  const refreshActive = useCallback(() => {
    const node = editor.current;
    const selection = document.getSelection();
    if (!node || !selection?.anchorNode || !node.contains(selection.anchorNode)) return setActive({});
    const next: Record<string, boolean> = {};
    for (const tool of TOOLS) {
      try { next[tool.command] = document.queryCommandState(tool.command); } catch { next[tool.command] = false; }
    }
    setActive(next);
  }, []);

  useEffect(() => {
    document.addEventListener("selectionchange", refreshActive);
    return () => document.removeEventListener("selectionchange", refreshActive);
  }, [refreshActive]);

  useEffect(() => {
    if (!menuId) return;
    const close = () => setMenuId(null);
    document.addEventListener("click", close);
    return () => document.removeEventListener("click", close);
  }, [menuId]);

  function reset() {
    setTitle("");
    setEditingId(null);
    setError(null);
    if (editor.current) editor.current.innerHTML = "";
  }

  function startEdit(note: ProviderNote) {
    setTitle(note.title);
    setEditingId(note.id);
    setError(null);
    setMenuId(null);
    if (editor.current) {
      editor.current.innerHTML = note.body;
      editor.current.focus();
    }
  }

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (saving) return;
    const body = sanitizeHtml(editor.current?.innerHTML ?? "");
    const cleanTitle = title.trim();
    if (!cleanTitle) return setError("Add a header for the note.");
    if (!plainText(body)) return setError("Write the note before posting.");
    setSaving(true);
    try {
      if (editingId) await onUpdate(editingId, cleanTitle, body);
      else {
        await onAdd(cleanTitle, body);
        setToggled({});
      }
      reset();
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Could not save the note.");
    } finally {
      setSaving(false);
    }
  }

  async function removeNote(id: string) {
    setMenuId(null);
    try {
      await onRemove(id);
      if (editingId === id) reset();
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Could not delete the note.");
    }
  }

  function run(command: string) {
    editor.current?.focus();
    // Emit <b>, <i>, <u> tags rather than inline styles, so the sanitizer keeps them.
    document.execCommand("styleWithCSS", false, "false");
    document.execCommand(command);
    refreshActive();
  }

  // Paste and drop insert plain text only, so outside colors, fonts, and alignment never enter a note.
  function insertPlain(text: string) {
    editor.current?.focus();
    document.execCommand("insertText", false, text.replace(/\r\n?/g, "\n"));
    refreshActive();
  }

  function onEditorPaste(event: ClipboardEvent<HTMLDivElement>) {
    event.preventDefault();
    insertPlain(event.clipboardData.getData("text/plain"));
  }

  function onEditorDrop(event: DragEvent<HTMLDivElement>) {
    event.preventDefault();
    const text = event.dataTransfer.getData("text/plain");
    if (!text) return;
    const range = document.caretRangeFromPoint?.(event.clientX, event.clientY);
    const selection = document.getSelection();
    if (range && selection) {
      selection.removeAllRanges();
      selection.addRange(range);
    }
    insertPlain(text);
  }

  function onEditorKeyDown(event: KeyboardEvent<HTMLDivElement>) {
    if (!(event.ctrlKey || event.metaKey) || event.altKey || event.shiftKey) return;
    const command = SHORTCUTS[event.key.toLowerCase()];
    if (!command) return;
    event.preventDefault();
    run(command);
  }

  return (
    <section className="provider-notes" aria-labelledby="notes-title">
      <h3 id="notes-title">Provider notes</h3>
      <form className="note-composer" onSubmit={submit}>
        <input value={title} onChange={(event) => setTitle(event.target.value)} placeholder="Header" aria-label="Note header" />
        <div ref={editor} className="note-editor" onKeyDown={onEditorKeyDown} onPaste={onEditorPaste} onDrop={onEditorDrop} contentEditable suppressContentEditableWarning role="textbox" aria-multiline="true" aria-label="Note" data-placeholder="Write a note" />
        <div className="note-footer">
          <div className="note-toolbar" role="toolbar" aria-label="Text formatting">
            {TOOLS.map((tool) => (
              <button key={tool.command} type="button" className={tool.className} aria-label={tool.label} aria-pressed={Boolean(active[tool.command])} title={tool.label} onMouseDown={(event) => event.preventDefault()} onClick={() => run(tool.command)}>{tool.text}</button>
            ))}
          </div>
          <div className="note-actions">
            {editingId && <button type="button" className="text-button" onClick={reset}>Cancel</button>}
            <button type="submit" className="primary-button" disabled={saving}>{saving ? "Saving" : editingId ? "Save" : "Post"}</button>
          </div>
        </div>
      </form>
      {(error || syncError) && <p className="form-error" role="alert">{error ?? `Notes could not sync: ${syncError}`}</p>}

      {notes.length > 0 && (
        <ul className="note-list">
          {notes.map((note) => {
            const created = new Date(note.createdAt);
            const edited = note.updatedAt !== note.createdAt;
            const open = isOpen(note.id);
            return (
              <li key={note.id} className={open ? "note open" : "note"}>
                <div className="note-header">
                  <button type="button" className="note-toggle" aria-expanded={open} onClick={() => toggle(note.id)}>
                    <span>{format.numericDate(created)}{open && edited ? ", edited" : ""}</span>
                    <h4>{note.title}</h4>
                  </button>
                  <div className="note-menu" onClick={(event) => event.stopPropagation()}>
                    {menuId === note.id && (
                      <>
                        <button type="button" className="text-button" onClick={() => startEdit(note)}>Edit</button>
                        <button type="button" className="text-button danger" onClick={() => void removeNote(note.id)}>Delete</button>
                      </>
                    )}
                    <button type="button" className="note-dots" aria-label="Note actions" aria-expanded={menuId === note.id} onClick={() => setMenuId(menuId === note.id ? null : note.id)}>···</button>
                  </div>
                </div>
                <div className="note-body-clip" aria-hidden={open ? undefined : true}>
                  <div>
                    <div className="note-body" dangerouslySetInnerHTML={{ __html: sanitizeHtml(note.body) }} />
                  </div>
                </div>
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}
