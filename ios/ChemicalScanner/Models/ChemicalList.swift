import Foundation

struct ChemicalList: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    var name: String
    var date: String
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
