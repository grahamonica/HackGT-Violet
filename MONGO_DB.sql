-- ============================================================
-- RELATIONSHIP DATABASE
-- Stores the people familiar to the patient.
-- ============================================================

CREATE TABLE relationships (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- 1. Familiar person's name
    name VARCHAR(255) NOT NULL,

    -- 2. Front-facing photo
    front_photo TEXT NOT NULL,

    -- 3. Left-facing photo
    left_photo TEXT NOT NULL,

    -- 4. Right-facing photo
    right_photo TEXT NOT NULL,

    -- 5. Relationship to the patient
    relation VARCHAR(255) NOT NULL,

    -- 6. Short biography
    bio TEXT,

    -- 7. Year the patient met this person
    year_met INTEGER,

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);