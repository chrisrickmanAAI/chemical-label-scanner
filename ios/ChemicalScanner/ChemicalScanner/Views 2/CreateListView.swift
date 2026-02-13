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
