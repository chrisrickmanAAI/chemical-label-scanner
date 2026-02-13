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
