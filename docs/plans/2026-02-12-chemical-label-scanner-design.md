# Chemical Label Scanner POC - Design

## Purpose

iOS app that allows users to photograph agricultural chemical labels (pesticides, herbicides, fertilizers), automatically look up full label data via web search, and store the results in organized lists. The rantizo-aam React web app consumes this data.

## Architecture

### Tech Stack

| Component | Technology | Cost |
|-----------|-----------|------|
| iOS App | SwiftUI (native) | Free |
| Backend/API | Supabase Edge Functions (Deno/TypeScript) | Free tier |
| Database | Supabase Postgres | Free tier (500MB) |
| Photo Storage | Supabase Storage | Free tier (1GB) |
| AI Vision + Search | Google Gemini w/ Search Grounding | Free tier (15 RPM) |
| rantizo-aam Integration | Supabase REST API (auto-generated) | Included |

### Data Flow

1. User creates a chemical list (name + date, defaults to device date)
2. User takes photo of a chemical label; device captures GPS coordinates
3. iOS app sends photo + lat/lng to Supabase Edge Function (`/analyze-label`)
4. Edge Function uploads photo to Supabase Storage
5. Edge Function sends photo to Gemini with Google Search Grounding — Gemini identifies the product from the label, searches the web for full label data, returns structured JSON
6. Edge Function returns extracted data to iOS app
7. User reviews data on confirmation screen, accepts or rejects
8. Accept: record saved to Supabase Postgres linked to the list
9. Reject: nothing saved, user can retake
10. If Gemini can't identify: status set to "unidentified", user can still save photo + location
11. User can add another chemical to the list (max 20 per list)

### Key Decisions

- No authentication — Supabase anon key used directly
- Gemini API key stored as Supabase Edge Function secret (not in client)
- rantizo-aam reads data via Supabase REST API (project URL + anon key)

## Data Model

### chemical_lists

| Column | Type | Notes |
|--------|------|-------|
| id | uuid, PK | Auto-generated |
| created_at | timestamp | Auto-generated |
| name | text | User-provided list name |
| date | date | Defaults to device date, user-editable |
| chemical_count | int | Tracked for 20-item cap, default 0 |

### chemical_records

| Column | Type | Notes |
|--------|------|-------|
| id | uuid, PK | Auto-generated |
| list_id | uuid, FK | References chemical_lists.id |
| created_at | timestamp | Auto-generated |
| photo_url | text | Supabase Storage URL |
| status | text | 'identified' or 'unidentified' |
| epa_registration_number | text, nullable | From label/web lookup |
| product_name | text, nullable | From label/web lookup |
| manufacturer | text, nullable | From label/web lookup |
| signal_word | text, nullable | Danger/Warning/Caution |
| active_ingredients | jsonb, nullable | [{name, concentration}] |
| precautionary_statements | text[], nullable | Array of statements |
| first_aid | jsonb, nullable | {eyes, skin, ingestion, inhalation} |
| storage_and_disposal | text, nullable | From label/web lookup |
| raw_extraction | jsonb, nullable | Full Gemini response for debugging |
| latitude | double precision, nullable | Device GPS at photo time |
| longitude | double precision, nullable | Device GPS at photo time |
| user_notes | text, nullable | Optional user notes |

## iOS App Screens

1. **Home** — "New List" button + list of existing lists
2. **Create List** — Name field + date picker (defaults to today) → creates list, goes to camera
3. **Camera** — Take photo, captures GPS
4. **Review** — Shows extracted label data, Accept/Reject
5. **List Detail** — Shows all chemicals in the list, "Add Another" button (disabled at 20)

## Repo Structure

```
chemical-label-scanner/
├── ios/                    — SwiftUI Xcode project
├── supabase/
│   ├── functions/
│   │   └── analyze-label/  — Edge Function (Deno/TS)
│   └── migrations/         — SQL table definitions
└── docs/
    └── plans/              — Design doc
```

## Integration with rantizo-aam

The rantizo-aam React app reads chemical data from the same Supabase instance via the auto-generated REST API. It only needs the Supabase project URL and anon key.
