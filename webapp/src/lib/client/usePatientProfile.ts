"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import type { PatientProfile } from "@/lib/types";
import { readStored, writeStored } from "./storage";

const CACHE_KEY = "patient-profile-v1";
const EMPTY: PatientProfile = { name: "", gender: "Male", dateOfBirth: "1950-01-05", caregiverName: "", caregiverPhone: "" };

export function usePatientProfile() {
  const [profile, setProfile] = useState(EMPTY);
  const [hydrated, setHydrated] = useState(false);
  const profileRef = useRef(EMPTY);

  useEffect(() => {
    let cancelled = false;
    void readStored<Partial<PatientProfile>>(CACHE_KEY, EMPTY).then((partial) => {
      if (cancelled) return;
      const stored: PatientProfile = {
        name: partial.name ?? "",
        gender: partial.gender || EMPTY.gender,
        dateOfBirth: partial.dateOfBirth || EMPTY.dateOfBirth,
        caregiverName: partial.caregiverName ?? "",
        caregiverPhone: partial.caregiverPhone ?? "",
      };
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
