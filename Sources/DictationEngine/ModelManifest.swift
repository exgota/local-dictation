import Foundation

public struct ModelFile: Sendable {
    public let path: String
    public let size: Int64
    public let sha256: String
}

/// Immutable description of the Underdog Bark 3.0 Pro Core ML release used by this application.
public enum ModelManifest {
    public static let repository = "ConwayResearch/Underdog-Bark-3.0-Pro"
    /// Hugging Face commit. Every file below is fetched from this exact revision.
    public static let revision = "4b5c51e04aa8d16dda9ecdff71bc29f7360149e4"
    public static let displayName = "Underdog Bark 3.0 Pro"

    public static let componentNames = ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"]
    public static let vocabularyFileName = "parakeet_v3_vocab.json"

    public static let files: [ModelFile] = [
        ModelFile(path: "Decoder.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 11612, sha256: "00cd3bdf438e859eff16d1376cab86f6214d0e44b1876316e30550e35d012763"),
        ModelFile(path: "Decoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 23604992, sha256: "b6bfa9053e8e20d1e80a7522ddba5c66e2c8c77cfc956d4ebccf749baf4d3d69"),
        ModelFile(path: "Decoder.mlpackage/Manifest.json", size: 617, sha256: "123808ff526bf8d5f47b69d5833ff91477f438f92056a3531ae0a7b4f2945d7e"),
        ModelFile(path: "Encoder.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 1206573, sha256: "d82718558f523dc13f9c0ede57d6f8e37d953950808a5aaa3a4633a7f752dd77"),
        ModelFile(path: "Encoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 1195742464, sha256: "619757bd47bc5cc131a85e54e94ffacc1b8c1bce737c1f1f6569eda8621a30d6"),
        ModelFile(path: "Encoder.mlpackage/Manifest.json", size: 617, sha256: "a6f16e318952af66b69fa84820b6417846ad0c9208a3c2779aa788a7c244a75e"),
        ModelFile(path: "JointDecisionv3.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 8759, sha256: "1057c2d9e9efce23258dbf2e7747e6facf7a42f4fcbcf2a21cdd160e065b18ac"),
        ModelFile(path: "JointDecisionv3.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 12642764, sha256: "90257de4d4582921c31db6efe9668017274b7c4cfdfe5aac9b9183233f7a9bdd"),
        ModelFile(path: "JointDecisionv3.mlpackage/Manifest.json", size: 617, sha256: "264b4403e1cada9a6148a10190e91b9e7fe6ead871db0aedcd87d2f4d84df1e7"),
        ModelFile(path: "LICENSE", size: 18657, sha256: "9ba9550ad48438d0836ddab3da480b3b69ffa0aac7b7878b5a0039e7ab429411"),
        ModelFile(path: "NOTICE", size: 611, sha256: "6bd6d22b4414b3ac97869dd8a97a813d668216ef66b04148ac858b988f8d063d"),
        ModelFile(path: "Preprocessor.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 18839, sha256: "dd4a5266ed9048aae620e73aa983eab93256654a343ded1226f9456b79f79a67"),
        ModelFile(path: "Preprocessor.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 1184512, sha256: "7a31e2bd311bfa97ea3fe73d4a6c029824327a71590397bd8784089a88754a77"),
        ModelFile(path: "Preprocessor.mlpackage/Manifest.json", size: 617, sha256: "75753d7f53c12f47bef18a0f84eacdf8e7e93db1a2e3af368c50b4f686317220"),
        ModelFile(path: "parakeet_v3_vocab.json", size: 143080, sha256: "3c278905d679b4b3e6b7be337edb8f9c0fce73a3708d5fe7a4a3bc7a12e719e1"),
    ]

    public static var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    public static func remoteURL(for file: ModelFile) -> URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/coreml/\(file.path)")!
    }
}

/// Describes the Silero voice activity detection model, as converted to Core ML by FluidInference (MIT). It is
/// published precompiled, so `ModelStore` downloads it with the speech model and uses it as is.
public enum VoiceActivityModelManifest {
    public static let repository = "FluidInference/silero-vad-coreml"
    public static let revision = "b419383c55c110e2c9271fa6ee0ea83d03c70d96"
    public static let compiledModelName = "silero-vad-unified-256ms-v6.2.1.mlmodelc"

    public static let files: [ModelFile] = [
        ModelFile(path: "\(compiledModelName)/analytics/coremldata.bin", size: 243, sha256: "8067594eb3126ab8318af507f0c00cabfed40d5fedb8a0ee5075dd02e903d909"),
        ModelFile(path: "\(compiledModelName)/coremldata.bin", size: 625, sha256: "7db35a4fd995222a7fb0129713473b15d1462572ab4a2e5e4d56bcaad9e40f41"),
        ModelFile(path: "\(compiledModelName)/metadata.json", size: 3335, sha256: "2740be542c611e1ba358e1849b4e265c65cdf0b17192767e1e5de86a31ac94d6"),
        ModelFile(path: "\(compiledModelName)/model.mil", size: 176918, sha256: "c6a9d1bf22d413265da0a07a1d14151c3ea2fad296b3aa5859275b33ef1c3270"),
        ModelFile(path: "\(compiledModelName)/weights/weight.bin", size: 882304, sha256: "53ecc8b5081146140ab654c89109cf001f2183abddd7a2411c5081feeffff063"),
    ]

    public static var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    public static func remoteURL(for file: ModelFile) -> URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.path)")!
    }
}
