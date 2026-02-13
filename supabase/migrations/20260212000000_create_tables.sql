-- Chemical lists table
CREATE TABLE chemical_lists (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
    name TEXT NOT NULL,
    date DATE NOT NULL DEFAULT CURRENT_DATE,
    chemical_count INTEGER DEFAULT 0 NOT NULL
);

-- Chemical records table
CREATE TABLE chemical_records (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    list_id UUID NOT NULL REFERENCES chemical_lists(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
    photo_url TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('identified', 'unidentified')),
    epa_registration_number TEXT,
    product_name TEXT,
    manufacturer TEXT,
    signal_word TEXT CHECK (signal_word IN ('Danger', 'Warning', 'Caution') OR signal_word IS NULL),
    active_ingredients JSONB,
    precautionary_statements TEXT[],
    first_aid JSONB,
    storage_and_disposal TEXT,
    raw_extraction JSONB,
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    user_notes TEXT
);

-- Index for fast list lookups
CREATE INDEX idx_chemical_records_list_id ON chemical_records(list_id);

-- Disable RLS for POC (no auth)
ALTER TABLE chemical_lists ENABLE ROW LEVEL SECURITY;
ALTER TABLE chemical_records ENABLE ROW LEVEL SECURITY;

-- Allow all access (no auth POC)
CREATE POLICY "Allow all access to chemical_lists" ON chemical_lists
    FOR ALL USING (true) WITH CHECK (true);

CREATE POLICY "Allow all access to chemical_records" ON chemical_records
    FOR ALL USING (true) WITH CHECK (true);
