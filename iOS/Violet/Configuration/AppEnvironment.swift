import Foundation
import ReferentRekognition

struct AppEnvironment: Sendable {
  let elevenLabsKey: String
  let elevenLabsVoiceID: String
  let mongoURI: String
  let mongoDatabase: String
  let relationshipsPath: String
  let logsPath: String
  /// Nil unless all four `AWS_REKOGNITION_*` keys are set.
  let rekognition: RekognitionConfig?

  static func load(bundle: Bundle = .main) -> AppEnvironment {
    let values: [String: String]
    if let url = bundle.url(forResource: "Secrets", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let decoded = try? JSONDecoder().decode([String: String].self, from: data)
    {
      values = decoded
    } else {
      values = [:]
    }

    return AppEnvironment(
      elevenLabsKey: values["ELEVEN_LABS_API_KEY", default: ""],
      elevenLabsVoiceID: values["ELEVEN_LABS_VOICE_ID", default: ""],
      mongoURI: values["MONGO_URI", default: ""].trimmingCharacters(in: .whitespacesAndNewlines),
      mongoDatabase: values["MONGO_DB_NAME"].nonEmpty ?? "violet",
      relationshipsPath: values["MONGO_RELATIONSHIPS_PATH"].nonEmpty ?? "relationships",
      logsPath: values["MONGO_LOGS_PATH"].nonEmpty ?? "logs",
      rekognition: RekognitionConfig(values: values)
    )
  }

  var elevenLabsIsConfigured: Bool { !elevenLabsKey.isEmpty && !elevenLabsVoiceID.isEmpty }
  var mongoIsConfigured: Bool {
    mongoURI.hasPrefix("mongodb://") || mongoURI.hasPrefix("mongodb+srv://")
  }
}

private extension Optional where Wrapped == String {
  var nonEmpty: String? {
    guard let self, !self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return self
  }
}

