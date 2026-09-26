"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import type { CheckIn } from "@/lib/types";
import { readStored, writeStored } from "./storage";

const CACHE_KEY = "caregiver-checkins-v1";
const EMPTY: CheckIn[] = [];

export function useCheckIns() {
  const [checkIns, setCheckIns] = useState(EMPTY);
  const [hydrated, setHydrated] = useState(false);
  const ref = useRef(EMPTY);

  useEffect(() => {
    let cancelled = false;
    void readStored(CACHE_KEY, EMPTY).then((stored) => {
      if (cancelled) return;
      ref.current = stored;
      setCheckIns(stored);
      setHydrated(true);
    });
    return () => { cancelled = true; };
  }, []);

  const add = useCallback((date: string, answers: boolean[]) => {
    const id = typeof crypto !== "undefined" && "randomUUID" in crypto ? crypto.randomUUID() : String(Date.now());
    const next = [...ref.current, { id, date, answers }].sort((a, b) => a.date.localeCompare(b.date));
    ref.current = next;
    setCheckIns(next);
    void writeStored(CACHE_KEY, next);
  }, []);

  return { checkIns, hydrated, add };
}
