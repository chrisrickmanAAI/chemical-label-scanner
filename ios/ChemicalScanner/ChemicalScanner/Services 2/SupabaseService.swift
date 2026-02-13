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
