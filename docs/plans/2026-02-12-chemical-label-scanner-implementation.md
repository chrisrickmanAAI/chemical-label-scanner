# Chemical Label Scanner - Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build an iOS POC app that photographs agricultural chemical labels, identifies them via Gemini AI + web search, and stores results in Supabase for consumption by rantizo-aam.

**Architecture:** SwiftUI iOS app → Supabase Edge Function → Gemini Vision + Google Search Grounding → Supabase Postgres + Storage. No authentication. rantizo-aam reads via Supabase REST API.

**Tech Stack:** SwiftUI, Supabase (Postgres, Storage, Edge Functions, Deno/TS), Google Gemini API (free tier)

**Refs:**
- [Gemini Search Grounding](https://ai.google.dev/gemini-api/docs/google-search)
- [Supabase Edge Functions](https://supabase.com/docs/guides/functions)
- [Supabase Swift SDK](https://github.com/supabase/supabase-swift)
- [Supabase iOS Quickstart](https://supabase.com/docs/guides/getting-started/quickstarts/ios-swiftui)

---

## Task 1: Repository & GitHub Setup

**Files:**
- Create: `.gitignore`
- Create: `README.md`

**Step 1: Create GitHub repository**

```bash
gh repo create chemical-label-scanner --public --clone
cd chemical-label-scanner
```

**Step 2: Create .gitignore**

```gitignore
# Xcode
ios/ChemicalScanner.xcodeproj/xcuserdata/
ios/ChemicalScanner.xcodeproj/project.xcworkspace/xcuserdata/
ios/*.xcworkspace/xcuserdata/
DerivedData/
*.pbxuser
*.mode1v3
*.mode2v3
*.perspectivev3
*.hmap
*.ipa
*.dSYM.zip
*.dSYM

# Swift Package Manager
.build/
.swiftpm/

# Supabase
supabase/.temp/
supabase/.env

# Environment
.env
.env.local

# OS
.DS_Store
Thumbs.db
```

**Step 3: Create directory structure**

```bash
mkdir -p ios/ChemicalScanner/App
mkdir -p ios/ChemicalScanner/Models
mkdir -p ios/ChemicalScanner/Services
mkdir -p ios/ChemicalScanner/Views
mkdir -p supabase/functions/analyze-label
mkdir -p supabase/migrations
mkdir -p docs/plans
```

**Step 4: Copy design doc into repo**

Move the existing design doc from `docs/plans/`.

**Step 5: Commit**

```bash
git add -A
git commit -m "chore: initial project structure"
git push -u origin main
```

---

## Task 2: Supabase Project Setup (Manual)

> These steps are performed in the Supabase Dashboard (https://supabase.com/dashboard) and terminal.

**Step 1: Create Supabase project**

1. Go to https://supabase.com/dashboard → "New Project"
2. Name: `chemical-label-scanner`
3. Generate a database password (save it)
4. Region: closest to you
5. Wait for project to finish provisioning

**Step 2: Note credentials**

From Project Settings → API:
- `Project URL` (e.g., `https://xxxxx.supabase.co`)
- `anon / public` key
- `service_role` key (keep secret — for Edge Functions only)

**Step 3: Initialize Supabase CLI locally**

```bash
# Install Supabase CLI if not already installed
brew install supabase/tap/supabase

# Link to your project (from repo root)
cd chemical-label-scanner
supabase init
supabase link --project-ref <your-project-ref>
```

**Step 4: Create storage bucket**

In Supabase Dashboard → Storage:
1. Create bucket: `chemical-photos`
2. Set to **Public** (photos need public URLs)
3. No file size limit changes needed for POC

**Step 5: Set Gemini API key as Edge Function secret**

1. Get a free Gemini API key from https://aistudio.google.com/apikey
2. Set it as a secret:

```bash
supabase secrets set GEMINI_API_KEY=your_gemini_api_key_here
```

**Step 6: Commit Supabase config**

```bash
git add supabase/config.toml
git commit -m "chore: add supabase config"
```

---

## Task 3: Database Schema

**Files:**
- Create: `supabase/migrations/20260212000000_create_tables.sql`

**Step 1: Write migration SQL**

```sql
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
```

**Step 2: Apply migration**

```bash
supabase db push
```

Expected: Tables created successfully.

**Step 3: Verify in Dashboard**

Check Supabase Dashboard → Table Editor — both tables should appear with correct columns.

**Step 4: Commit**

```bash
git add supabase/migrations/
git commit -m "feat: add database schema for chemical lists and records"
```

---

## Task 4: Edge Function — analyze-label

**Files:**
- Create: `supabase/functions/analyze-label/index.ts`

**Step 1: Write the Edge Function**

```typescript
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
}

interface AnalyzeRequest {
  photoBase64: string
  latitude: number | null
  longitude: number | null
}

interface LabelData {
  epa_registration_number: string | null
  product_name: string | null
  manufacturer: string | null
  signal_word: string | null
  active_ingredients: { name: string; concentration: string }[] | null
  precautionary_statements: string[] | null
  first_aid: {
    eyes: string | null
    skin: string | null
    ingestion: string | null
    inhalation: string | null
  } | null
  storage_and_disposal: string | null
}

Deno.serve(async (req) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders })
  }

  try {
    const { photoBase64, latitude, longitude }: AnalyzeRequest =
      await req.json()

    if (!photoBase64) {
      return new Response(
        JSON.stringify({ error: "photoBase64 is required" }),
        {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      )
    }

    // Create Supabase client with service role for storage access
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    )

    // Decode base64 and upload photo to storage
    const binaryString = atob(photoBase64)
    const bytes = new Uint8Array(binaryString.length)
    for (let i = 0; i < binaryString.length; i++) {
      bytes[i] = binaryString.charCodeAt(i)
    }

    const fileName = `${crypto.randomUUID()}.jpg`
    const { error: uploadError } = await supabase.storage
      .from("chemical-photos")
      .upload(fileName, bytes, {
        contentType: "image/jpeg",
        cacheControl: "3600",
      })

    if (uploadError) {
      throw new Error(`Storage upload failed: ${uploadError.message}`)
    }

    const {
      data: { publicUrl },
    } = supabase.storage.from("chemical-photos").getPublicUrl(fileName)

    // Call Gemini API with vision + Google Search grounding
    const geminiApiKey = Deno.env.get("GEMINI_API_KEY")
    if (!geminiApiKey) {
      throw new Error("GEMINI_API_KEY not configured")
    }

    const geminiResponse = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=${geminiApiKey}`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          contents: [
            {
              parts: [
                {
                  text: `You are analyzing a photo of an agricultural chemical product label (pesticide, herbicide, or fertilizer).

1. First, identify the product from the label image — extract the EPA registration number, product name, and manufacturer.
2. Then search the web for complete label data for this product.
3. Return the data as JSON with this exact structure:

{
  "epa_registration_number": "string or null",
  "product_name": "string or null",
  "manufacturer": "string or null",
  "signal_word": "Danger or Warning or Caution or null",
  "active_ingredients": [{"name": "string", "concentration": "string"}],
  "precautionary_statements": ["string"],
  "first_aid": {"eyes": "string", "skin": "string", "ingestion": "string", "inhalation": "string"},
  "storage_and_disposal": "string or null"
}

Return ONLY valid JSON. No markdown fences, no extra text. If you cannot identify the product, return all fields as null.`,
                },
                {
                  inline_data: {
                    mime_type: "image/jpeg",
                    data: photoBase64,
                  },
                },
              ],
            },
          ],
          tools: [{ google_search: {} }],
        }),
      }
    )

    if (!geminiResponse.ok) {
      const errText = await geminiResponse.text()
      throw new Error(`Gemini API error: ${geminiResponse.status} ${errText}`)
    }

    const geminiResult = await geminiResponse.json()

    // Extract text from Gemini response
    const responseText =
      geminiResult.candidates?.[0]?.content?.parts
        ?.filter((p: { text?: string }) => p.text)
        ?.map((p: { text: string }) => p.text)
        ?.join("") || ""

    // Parse JSON from response
    let labelData: LabelData = {
      epa_registration_number: null,
      product_name: null,
      manufacturer: null,
      signal_word: null,
      active_ingredients: null,
      precautionary_statements: null,
      first_aid: null,
      storage_and_disposal: null,
    }

    try {
      const jsonMatch = responseText.match(/\{[\s\S]*\}/)
      if (jsonMatch) {
        labelData = JSON.parse(jsonMatch[0])
      }
    } catch {
      console.error("Failed to parse Gemini response as JSON:", responseText)
    }

    const status =
      labelData.epa_registration_number || labelData.product_name
        ? "identified"
        : "unidentified"

    return new Response(
      JSON.stringify({
        photo_url: publicUrl,
        status,
        ...labelData,
        raw_extraction: geminiResult,
        latitude,
        longitude,
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    )
  } catch (error) {
    console.error("analyze-label error:", error)
    return new Response(
      JSON.stringify({ error: (error as Error).message }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    )
  }
})
```

**Step 2: Test locally**

```bash
supabase functions serve analyze-label --env-file supabase/.env
```

Test with curl (use a small base64 test image):
```bash
curl -X POST http://localhost:54321/functions/v1/analyze-label \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <your-anon-key>" \
  -d '{"photoBase64":"<base64-of-test-label-image>","latitude":41.8781,"longitude":-87.6298}'
```

Expected: JSON response with label data fields.

**Step 3: Deploy**

```bash
supabase functions deploy analyze-label
```

**Step 4: Commit**

```bash
git add supabase/functions/
git commit -m "feat: add analyze-label edge function with Gemini vision + search"
```

---

## Task 5: iOS Project Setup (Manual Xcode Steps)

> These steps must be performed in Xcode.

**Step 1: Create Xcode project**

1. Open Xcode → File → New → Project
2. Template: iOS → App
3. Product Name: `ChemicalScanner`
4. Organization Identifier: `com.rantizo`
5. Interface: SwiftUI
6. Language: Swift
7. Save location: `chemical-label-scanner/ios/`

**Step 2: Add Supabase Swift package**

1. File → Add Package Dependencies
2. Enter URL: `https://github.com/supabase/supabase-swift`
3. Dependency Rule: Up to Next Major Version → `2.0.0`
4. Add to target: `ChemicalScanner`

**Step 3: Configure Info.plist permissions**

Add these keys to Info.plist (or in target → Info → Custom iOS Target Properties):

| Key | Value |
|-----|-------|
| `NSCameraUsageDescription` | This app needs camera access to photograph chemical labels. |
| `NSLocationWhenInUseUsageDescription` | This app records your location when photographing chemical labels. |

**Step 4: Commit**

```bash
git add ios/
git commit -m "chore: create Xcode project with Supabase dependency"
```

---

## Task 6: iOS Configuration & Data Models

**Files:**
- Create: `ios/ChemicalScanner/App/Config.swift`
- Create: `ios/ChemicalScanner/Models/ChemicalList.swift`
- Create: `ios/ChemicalScanner/Models/ChemicalRecord.swift`
- Create: `ios/ChemicalScanner/Models/AnalyzeLabelResponse.swift`

**Step 1: Create Config.swift**

```swift
import Foundation

enum Config {
    static let supabaseURL = "https://YOUR_PROJECT_REF.supabase.co"
    static let supabaseAnonKey = "YOUR_ANON_KEY"
}
```

> Replace with actual values from Task 2.

**Step 2: Create ChemicalList.swift**

```swift
import Foundation

struct ChemicalList: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    var name: String
    var date: String  // "YYYY-MM-DD" format
    var chemicalCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case name
        case date
        case chemicalCount = "chemical_count"
    }
}

struct CreateListRequest: Codable {
    let name: String
    let date: String
}
```

**Step 3: Create ChemicalRecord.swift**

```swift
import Foundation

struct ChemicalRecord: Codable, Identifiable {
    let id: UUID
    let listId: UUID
    let createdAt: Date
    let photoUrl: String
    let status: String
    var epaRegistrationNumber: String?
    var productName: String?
    var manufacturer: String?
    var signalWord: String?
    var activeIngredients: [ActiveIngredient]?
    var precautionaryStatements: [String]?
    var firstAid: FirstAid?
    var storageAndDisposal: String?
    var latitude: Double?
    var longitude: Double?
    var userNotes: String?

    enum CodingKeys: String, CodingKey {
        case id
        case listId = "list_id"
        case createdAt = "created_at"
        case photoUrl = "photo_url"
        case status
        case epaRegistrationNumber = "epa_registration_number"
        case productName = "product_name"
        case manufacturer
        case signalWord = "signal_word"
        case activeIngredients = "active_ingredients"
        case precautionaryStatements = "precautionary_statements"
        case firstAid = "first_aid"
        case storageAndDisposal = "storage_and_disposal"
        case latitude
        case longitude
        case userNotes = "user_notes"
    }
}

struct ActiveIngredient: Codable {
    let name: String
    let concentration: String
}

struct FirstAid: Codable {
    let eyes: String?
    let skin: String?
    let ingestion: String?
    let inhalation: String?
}
```

**Step 4: Create AnalyzeLabelResponse.swift**

```swift
import Foundation

struct AnalyzeLabelResponse: Codable {
    let photoUrl: String
    let status: String
    var epaRegistrationNumber: String?
    var productName: String?
    var manufacturer: String?
    var signalWord: String?
    var activeIngredients: [ActiveIngredient]?
    var precautionaryStatements: [String]?
    var firstAid: FirstAid?
    var storageAndDisposal: String?
    var latitude: Double?
    var longitude: Double?

    enum CodingKeys: String, CodingKey {
        case photoUrl = "photo_url"
        case status
        case epaRegistrationNumber = "epa_registration_number"
        case productName = "product_name"
        case manufacturer
        case signalWord = "signal_word"
        case activeIngredients = "active_ingredients"
        case precautionaryStatements = "precautionary_statements"
        case firstAid = "first_aid"
        case storageAndDisposal = "storage_and_disposal"
        case latitude
        case longitude
    }
}
```

**Step 5: Commit**

```bash
git add ios/ChemicalScanner/
git commit -m "feat: add config and data models"
```

---

## Task 7: iOS Services

**Files:**
- Create: `ios/ChemicalScanner/Services/SupabaseService.swift`
- Create: `ios/ChemicalScanner/Services/LocationService.swift`

**Step 1: Create SupabaseService.swift**

```swift
import Foundation
import Supabase

class SupabaseService {
    static let shared = SupabaseService()

    let client: SupabaseClient

    private init() {
        client = SupabaseClient(
            supabaseURL: URL(string: Config.supabaseURL)!,
            supabaseKey: Config.supabaseAnonKey
        )
    }

    // MARK: - Chemical Lists

    func createList(name: String, date: Date) async throws -> ChemicalList {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateString = formatter.string(from: date)

        let request = CreateListRequest(name: name, date: dateString)

        return try await client
            .from("chemical_lists")
            .insert(request)
            .select()
            .single()
            .execute()
            .value
    }

    func fetchLists() async throws -> [ChemicalList] {
        return try await client
            .from("chemical_lists")
            .select()
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func fetchRecords(listId: UUID) async throws -> [ChemicalRecord] {
        return try await client
            .from("chemical_records")
            .select()
            .eq("list_id", value: listId.uuidString)
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    // MARK: - Analyze Label (calls Edge Function)

    func analyzeLabel(
        photoData: Data,
        latitude: Double?,
        longitude: Double?
    ) async throws -> AnalyzeLabelResponse {
        struct RequestBody: Encodable {
            let photoBase64: String
            let latitude: Double?
            let longitude: Double?
        }

        let body = RequestBody(
            photoBase64: photoData.base64EncodedString(),
            latitude: latitude,
            longitude: longitude
        )

        return try await client.functions
            .invoke(
                "analyze-label",
                options: .init(body: body)
            )
    }

    // MARK: - Save Record

    func saveRecord(
        listId: UUID,
        response: AnalyzeLabelResponse
    ) async throws -> ChemicalRecord {
        struct InsertRecord: Encodable {
            let list_id: String
            let photo_url: String
            let status: String
            let epa_registration_number: String?
            let product_name: String?
            let manufacturer: String?
            let signal_word: String?
            let active_ingredients: [ActiveIngredient]?
            let precautionary_statements: [String]?
            let first_aid: FirstAid?
            let storage_and_disposal: String?
            let latitude: Double?
            let longitude: Double?
        }

        let record = InsertRecord(
            list_id: listId.uuidString,
            photo_url: response.photoUrl,
            status: response.status,
            epa_registration_number: response.epaRegistrationNumber,
            product_name: response.productName,
            manufacturer: response.manufacturer,
            signal_word: response.signalWord,
            active_ingredients: response.activeIngredients,
            precautionary_statements: response.precautionaryStatements,
            first_aid: response.firstAid,
            storage_and_disposal: response.storageAndDisposal,
            latitude: response.latitude,
            longitude: response.longitude
        )

        let saved: ChemicalRecord = try await client
            .from("chemical_records")
            .insert(record)
            .select()
            .single()
            .execute()
            .value

        // Update chemical count on the list
        let count: Int = try await client
            .from("chemical_records")
            .select("id", head: true, count: .exact)
            .eq("list_id", value: listId.uuidString)
            .execute()
            .count ?? 0

        try await client
            .from("chemical_lists")
            .update(["chemical_count": count])
            .eq("id", value: listId.uuidString)
            .execute()

        return saved
    }
}
```

**Step 2: Create LocationService.swift**

```swift
import CoreLocation

class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    @Published var latitude: Double?
    @Published var longitude: Double?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func requestLocation() {
        manager.requestLocation()
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        if let location = locations.last {
            latitude = location.coordinate.latitude
            longitude = location.coordinate.longitude
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        print("Location error: \(error.localizedDescription)")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedWhenInUse {
            manager.requestLocation()
        }
    }
}
```

**Step 3: Commit**

```bash
git add ios/ChemicalScanner/Services/
git commit -m "feat: add SupabaseService and LocationService"
```

---

## Task 8: iOS Views — Home & Create List

**Files:**
- Modify: `ios/ChemicalScanner/App/ChemicalScannerApp.swift`
- Create: `ios/ChemicalScanner/Views/HomeView.swift`
- Create: `ios/ChemicalScanner/Views/CreateListView.swift`

**Step 1: Update ChemicalScannerApp.swift**

```swift
import SwiftUI

@main
struct ChemicalScannerApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}
```

**Step 2: Create HomeView.swift**

```swift
import SwiftUI

struct HomeView: View {
    @State private var lists: [ChemicalList] = []
    @State private var showCreateList = false
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading lists...")
                } else if lists.isEmpty {
                    ContentUnavailableView(
                        "No Chemical Lists",
                        systemImage: "list.clipboard",
                        description: Text("Tap + to create your first list.")
                    )
                } else {
                    List(lists) { list in
                        NavigationLink(destination: ListDetailView(list: list)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(list.name)
                                    .font(.headline)
                                HStack {
                                    Text(list.date)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(list.chemicalCount)/20 chemicals")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Chemical Lists")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showCreateList = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showCreateList) {
                CreateListView { newList in
                    lists.insert(newList, at: 0)
                }
            }
            .task {
                await loadLists()
            }
            .refreshable {
                await loadLists()
            }
        }
    }

    private func loadLists() async {
        do {
            lists = try await SupabaseService.shared.fetchLists()
        } catch {
            print("Error loading lists: \(error)")
        }
        isLoading = false
    }
}
```

**Step 3: Create CreateListView.swift**

```swift
import SwiftUI

struct CreateListView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var date = Date()
    @State private var isCreating = false

    let onCreate: (ChemicalList) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("List Details") {
                    TextField("List Name", text: $name)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }
            }
            .navigationTitle("New Chemical List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await createList() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
                }
            }
        }
    }

    private func createList() async {
        isCreating = true
        do {
            let newList = try await SupabaseService.shared.createList(
                name: name.trimmingCharacters(in: .whitespaces),
                date: date
            )
            onCreate(newList)
            dismiss()
        } catch {
            print("Error creating list: \(error)")
        }
        isCreating = false
    }
}
```

**Step 4: Commit**

```bash
git add ios/ChemicalScanner/
git commit -m "feat: add HomeView and CreateListView"
```

---

## Task 9: iOS Views — Camera

**Files:**
- Create: `ios/ChemicalScanner/Views/CameraView.swift`

**Step 1: Create CameraView.swift**

This wraps UIImagePickerController for camera access:

```swift
import SwiftUI
import UIKit

struct CameraView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onPhotoTaken: (Data) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIImagePickerController,
        context: Context
    ) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject,
        UIImagePickerControllerDelegate,
        UINavigationControllerDelegate
    {
        let parent: CameraView

        init(_ parent: CameraView) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage,
               let data = image.jpegData(compressionQuality: 0.7)
            {
                parent.onPhotoTaken(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(
            _ picker: UIImagePickerController
        ) {
            parent.dismiss()
        }
    }
}
```

> Note: `compressionQuality: 0.7` keeps photos under ~2MB for the Edge Function.

**Step 2: Commit**

```bash
git add ios/ChemicalScanner/Views/CameraView.swift
git commit -m "feat: add CameraView with UIImagePickerController"
```

---

## Task 10: iOS Views — Review Screen

**Files:**
- Create: `ios/ChemicalScanner/Views/ReviewView.swift`

**Step 1: Create ReviewView.swift**

```swift
import SwiftUI

struct ReviewView: View {
    let response: AnalyzeLabelResponse
    let listId: UUID
    let onAccept: (ChemicalRecord) -> Void
    let onReject: () -> Void

    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Status badge
                    HStack {
                        Image(systemName: response.status == "identified"
                            ? "checkmark.circle.fill"
                            : "questionmark.circle.fill")
                        Text(response.status == "identified"
                            ? "Chemical Identified"
                            : "Could Not Identify")
                    }
                    .font(.headline)
                    .foregroundStyle(response.status == "identified" ? .green : .orange)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(response.status == "identified"
                                ? Color.green.opacity(0.1)
                                : Color.orange.opacity(0.1))
                    )

                    // Photo thumbnail
                    if let url = URL(string: response.photoUrl) {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            ProgressView()
                        }
                        .frame(maxHeight: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    // Label data
                    if response.status == "identified" {
                        labelDataSection
                    }
                }
                .padding()
            }
            .navigationTitle("Review Label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reject") {
                        onReject()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Accept") {
                        Task { await saveRecord() }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }

    @ViewBuilder
    private var labelDataSection: some View {
        Group {
            fieldRow("Product", response.productName)
            fieldRow("EPA Reg #", response.epaRegistrationNumber)
            fieldRow("Manufacturer", response.manufacturer)
            fieldRow("Signal Word", response.signalWord)

            if let ingredients = response.activeIngredients, !ingredients.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Active Ingredients")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(ingredients, id: \.name) { ingredient in
                        Text("\(ingredient.name): \(ingredient.concentration)")
                    }
                }
            }

            if let statements = response.precautionaryStatements, !statements.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Precautionary Statements")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(statements, id: \.self) { statement in
                        Text("• \(statement)")
                            .font(.subheadline)
                    }
                }
            }

            if let firstAid = response.firstAid {
                VStack(alignment: .leading, spacing: 4) {
                    Text("First Aid")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let eyes = firstAid.eyes { Text("Eyes: \(eyes)").font(.subheadline) }
                    if let skin = firstAid.skin { Text("Skin: \(skin)").font(.subheadline) }
                    if let ingestion = firstAid.ingestion { Text("Ingestion: \(ingestion)").font(.subheadline) }
                    if let inhalation = firstAid.inhalation { Text("Inhalation: \(inhalation)").font(.subheadline) }
                }
            }

            fieldRow("Storage & Disposal", response.storageAndDisposal)
        }
    }

    @ViewBuilder
    private func fieldRow(_ label: String, _ value: String?) -> some View {
        if let value = value {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
            }
        }
    }

    private func saveRecord() async {
        isSaving = true
        do {
            let record = try await SupabaseService.shared.saveRecord(
                listId: listId,
                response: response
            )
            onAccept(record)
            dismiss()
        } catch {
            print("Error saving record: \(error)")
        }
        isSaving = false
    }
}
```

**Step 2: Commit**

```bash
git add ios/ChemicalScanner/Views/ReviewView.swift
git commit -m "feat: add ReviewView for label data confirmation"
```

---

## Task 11: iOS Views — List Detail

**Files:**
- Create: `ios/ChemicalScanner/Views/ListDetailView.swift`

**Step 1: Create ListDetailView.swift**

This is the main working screen — shows chemicals in the list and orchestrates the camera → review → save flow.

```swift
import SwiftUI

struct ListDetailView: View {
    let list: ChemicalList
    @StateObject private var locationService = LocationService()
    @State private var records: [ChemicalRecord] = []
    @State private var isLoading = true
    @State private var showCamera = false
    @State private var showReview = false
    @State private var isAnalyzing = false
    @State private var analyzeResponse: AnalyzeLabelResponse?
    @State private var errorMessage: String?

    private var canAddMore: Bool {
        records.count < 20
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading chemicals...")
            } else if records.isEmpty {
                ContentUnavailableView(
                    "No Chemicals Yet",
                    systemImage: "leaf",
                    description: Text("Tap the camera button to scan a label.")
                )
            } else {
                List(records) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.productName ?? "Unidentified Chemical")
                            .font(.headline)
                        HStack {
                            if let epa = record.epaRegistrationNumber {
                                Text("EPA: \(epa)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: record.status == "identified"
                                ? "checkmark.circle.fill"
                                : "questionmark.circle.fill")
                            .foregroundStyle(record.status == "identified" ? .green : .orange)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle(list.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showCamera = true }) {
                    Image(systemName: "camera")
                }
                .disabled(!canAddMore || isAnalyzing)
            }
            ToolbarItem(placement: .status) {
                if isAnalyzing {
                    ProgressView("Analyzing label...")
                } else {
                    Text("\(records.count)/20")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraView { photoData in
                Task { await analyzePhoto(photoData) }
            }
        }
        .sheet(isPresented: $showReview) {
            if let response = analyzeResponse {
                ReviewView(
                    response: response,
                    listId: list.id,
                    onAccept: { record in
                        records.append(record)
                        analyzeResponse = nil
                    },
                    onReject: {
                        analyzeResponse = nil
                    }
                )
            }
        }
        .alert("Error", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            locationService.requestPermission()
            await loadRecords()
        }
    }

    private func loadRecords() async {
        do {
            records = try await SupabaseService.shared.fetchRecords(listId: list.id)
        } catch {
            print("Error loading records: \(error)")
        }
        isLoading = false
    }

    private func analyzePhoto(_ photoData: Data) async {
        isAnalyzing = true
        do {
            let response = try await SupabaseService.shared.analyzeLabel(
                photoData: photoData,
                latitude: locationService.latitude,
                longitude: locationService.longitude
            )
            analyzeResponse = response
            showReview = true
        } catch {
            errorMessage = "Failed to analyze label: \(error.localizedDescription)"
        }
        isAnalyzing = false
    }
}
```

**Step 2: Commit**

```bash
git add ios/ChemicalScanner/Views/ListDetailView.swift
git commit -m "feat: add ListDetailView with camera and review flow"
```

---

## Task 12: End-to-End Verification

**Step 1: Deploy all Supabase resources**

```bash
supabase db push
supabase functions deploy analyze-label
```

**Step 2: Build and run iOS app**

1. Open `ios/ChemicalScanner.xcodeproj` in Xcode
2. Select a physical iPhone as the target (camera requires real device)
3. Build and run (Cmd+R)

**Step 3: Manual test walkthrough**

1. App launches → Home screen shows "No Chemical Lists"
2. Tap `+` → Create List screen appears
3. Enter name "Test Spray Job", date defaults to today → tap Create
4. Navigates to List Detail → shows "No Chemicals Yet"
5. Tap camera icon → camera opens
6. Photograph an agricultural chemical label
7. Loading indicator shows "Analyzing label..."
8. Review screen appears with extracted data
9. Tap Accept → record appears in the list
10. Tap camera again → repeat for a second chemical
11. Navigate back → Home screen shows "Test Spray Job" with "2/20 chemicals"

**Step 4: Verify Supabase data**

Check Supabase Dashboard:
- Table Editor → `chemical_lists` should have the test list
- Table Editor → `chemical_records` should have the accepted records
- Storage → `chemical-photos` bucket should have the uploaded photos

**Step 5: Verify rantizo-aam can access data**

Test the REST API:
```bash
curl "https://YOUR_PROJECT_REF.supabase.co/rest/v1/chemical_lists?select=*" \
  -H "apikey: YOUR_ANON_KEY" \
  -H "Authorization: Bearer YOUR_ANON_KEY"
```

Expected: JSON array of chemical lists.

**Step 6: Final commit**

```bash
git add -A
git commit -m "chore: final POC wiring and verification"
git push
```
