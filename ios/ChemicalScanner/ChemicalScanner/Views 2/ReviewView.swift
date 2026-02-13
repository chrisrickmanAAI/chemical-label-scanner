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
                        Text("- \(statement)")
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
