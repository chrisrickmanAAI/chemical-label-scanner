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
