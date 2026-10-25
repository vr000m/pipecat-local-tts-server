import Foundation
import Testing

@testable import PipecatToolbarCore

/// The download-size estimate follows `ServiceCatalog.snapshots(for:)`, which
/// `tests/test_macos_catalog_drift.py` keeps equal to the Python `prefetch_specs`.
@Suite struct HubSizesTests {
    /// `fnmatch` without FNM_PATHNAME, like `snapshot_download(allow_patterns=)`.
    @Test func patternsMatchLikeHuggingFace() {
        let mlx = HubSnapshot.Files.mlxAudioDefault
        #expect(mlx.includes("config.json"))
        #expect(mlx.includes("speech_tokenizer/model.safetensors"))  // `*` crosses `/`
        #expect(!mlx.includes("model.gguf"))
        #expect(!mlx.includes("README.md"))
        let voices = HubSnapshot.Files.patterns(["embeddings/*.safetensors"])
        #expect(voices.includes("embeddings/alba.safetensors"))
        #expect(!voices.includes("model.safetensors"))
    }

    @Test func allButDocsIsTheHelperFilter() {
        let files = HubSnapshot.Files.allButDocs
        #expect(files.includes("weights.npz"))
        #expect(files.includes("sub/.hidden"))  // only a top-level dot path is skipped
        #expect(!files.includes(".gitattributes"))
        #expect(!files.includes("README.MD"))
        #expect(!files.includes(".cache/x"))
    }

    @Test func sizeSumsOnlyIncludedFilesPreferringLFS() throws {
        let tree: [[String: Any]] = [
            ["type": "file", "path": "model.safetensors", "size": 134, "lfs": ["size": 1_000]],
            ["type": "file", "path": "config.json", "size": 20],
            ["type": "file", "path": "model.gguf", "size": 5_000],
            ["type": "directory", "path": "sub", "size": 0],
        ]
        let data = try JSONSerialization.data(withJSONObject: tree)
        #expect(HubSizes.size(fromTreeJSON: data, files: .mlxAudioDefault) == 1_020)
        #expect(HubSizes.size(fromTreeJSON: data, files: .allButDocs) == 6_020)
    }

    /// The pinned revision is what gets sized, not `main`.
    @Test func treeURLUsesThePin() {
        let phonon = ServiceCatalog.snapshots(for: .phononQ8)
        #expect(phonon.count == 1)
        #expect(HubSizes.treeURL(phonon[0])?.absoluteString.contains("/tree/52433c46975bfa13144c56204c9f4ee1c5b148aa?") == true)
        let kokoro = ServiceCatalog.snapshots(for: .kokoro)
        #expect(HubSizes.treeURL(kokoro[0])?.absoluteString.hasSuffix("/tree/main?recursive=true") == true)
        // STT sizes the helper's pinned commit (`MODEL_REVISIONS`), never `main`.
        for service in Service.allCases where service.kind == .stt {
            guard let repo = service.info.modelRepo else { continue }
            let pin = ServiceCatalog.sttModelRevisions[repo]
            #expect(pin != nil, "\(service)")
            #expect(ServiceCatalog.snapshots(for: service).first?.revision == pin, "\(service)")
            #expect(HubSizes.treeURL(ServiceCatalog.snapshots(for: service)[0])?.absoluteString.contains("/tree/main") == false)
        }
    }

    @Test func everyServiceSizesItsModelRepoFirst() {
        for service in Service.allCases {
            let snapshots = ServiceCatalog.snapshots(for: service)
            guard let repo = service.info.modelRepo else {
                #expect(snapshots.isEmpty, "\(service)")
                continue
            }
            #expect(snapshots.first?.repo == repo, "\(service)")
            #expect(snapshots.first?.kind == .model, "\(service)")
        }
        #expect(ServiceCatalog.snapshots(for: .dia).map(\.kind) == [.model, .codec])
        #expect(ServiceCatalog.snapshots(for: .pocketTTS).last?.required == false)
        #expect(ServiceCatalog.snapshots(for: .whisperSmall).first?.files == .allButDocs)
    }
}
