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
            CameraView(showCamera: $showCamera) { photoData in
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
            // Small delay to ensure camera is fully dismissed before showing review sheet
            try? await Task.sleep(for: .milliseconds(300))
            analyzeResponse = response
            showReview = true
        } catch {
            errorMessage = "Failed to analyze label: \(error.localizedDescription)"
        }
        isAnalyzing = false
    }
}
