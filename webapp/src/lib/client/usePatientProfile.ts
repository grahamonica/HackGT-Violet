"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import type { PatientProfile } from "@/lib/types";
import { readStored, writeStored } from "./storage";

const CACHE_KEY = "patient-profile-v1";
const EMPTY: PatientProfile = { name: "", dateOfBirth: "", providerNotes: "" };

export function usePatientProfile() {
  const [profile, setProfile] = useState(EMPTY);
  const [hydrated, setHydrated] = useState(false);
  const profileRef = useRef(EMPTY);

  useEffect(() => {
    let cancelled = false;
    void readStored(CACHE_KEY, EMPTY).then((stored) => {
      if (cancelled) return;
      profileRef.current = stored;
      setProfile(stored);
      setHydrated(true);
    });
    return () => { cancelled = true; };
  }, []);

  const save = useCallback((next: PatientProfile) => {
    profileRef.current = next;
    setProfile(next);
    void writeStored(CACHE_KEY, next);
  }, []);

  const applyGoogleName = useCallback((name: string) => {
    if (!name || profileRef.current.name) return;
    save({ ...profileRef.current, name });
  }, [save]);

  return { profile, hydrated, save, applyGoogleName };
}
