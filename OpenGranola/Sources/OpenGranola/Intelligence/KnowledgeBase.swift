import Foundation
import CryptoKit

/// A chunk of text from a knowledge base document.
struct KBChunk: Codable, Sendable {
    let text: String
    let sourceFile: String
    let headerContext: String
    let embedding: [Float]
}

/// Disk cache format for embedded KB chunks.
private struct KBCache: Codable {
    /// Keyed by "filename:sha256hash"
    var entries: [String: [KBChunk]]
}

/// Embedding-based knowledge base search using Bedrock Titan Embed v2.
@Observable
@MainActor
final class KnowledgeBase {
    private(set) var chunks: [KBChunk] = []
    private(set) var isIndexed = false
    private(set) var fileCount = 0
    private(set) var indexingProgress: String = ""

    private let settings: AppSettings
    private let embeddingClient = BedrockEmbeddingClient()

    private nonisolated static func cacheURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("OpenGranola")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("kb_cache.json")
    }

    init(settings: AppSettings) {
        self.settings = settings
    }

    func index(folderURL: URL) async {
        guard settings.hasAWSCredentials else {
            indexingProgress = "No AWS credentials configured"
            return
        }

        indexingProgress = "Scanning files..."
        let fileURLs = collectFiles(in: folderURL)
        guard !fileURLs.isEmpty else {
            indexingProgress = ""
            isIndexed = true
            return
        }

        // Load existing cache
        var cache = loadCache()
        var allChunks: [KBChunk] = []
        var filesToEmbed: [(key: String, chunks: [(text: String, header: String)])] = []
        var files = 0

        for fileURL in fileURLs {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            files += 1

            let fileName = fileURL.lastPathComponent
            let hash = sha256(content)
            let cacheKey = "\(fileName):\(hash)"

            // Reuse cached embeddings if content hasn't changed
            if let cached = cache.entries[cacheKey] {
                allChunks.append(contentsOf: cached)
                continue
            }

            let textChunks = chunkMarkdown(content, sourceFile: fileName)
            filesToEmbed.append((key: cacheKey, chunks: textChunks))
        }

        // Embed new/changed files in batches
        if !filesToEmbed.isEmpty {
            let allTextsToEmbed = filesToEmbed.flatMap { entry in
                entry.chunks.map { "\($0.header)\n\($0.text)" }
            }

            indexingProgress = "Embedding \(allTextsToEmbed.count) chunks..."

            let result = await embedInBatches(texts: allTextsToEmbed)
            let embeddings = result.embeddings

            if embeddings == nil, let errMsg = result.error {
                indexingProgress = "Embed error: \(errMsg)"
            }

            if let embeddings {
                var offset = 0
                for entry in filesToEmbed {
                    var fileChunks: [KBChunk] = []
                    for chunk in entry.chunks {
                        let embedding = embeddings[offset]
                        let kbChunk = KBChunk(
                            text: chunk.text,
                            sourceFile: entry.key.components(separatedBy: ":").first ?? "",
                            headerContext: chunk.header,
                            embedding: embedding
                        )
                        fileChunks.append(kbChunk)
                        offset += 1
                    }
                    cache.entries[entry.key] = fileChunks
                    allChunks.append(contentsOf: fileChunks)
                }

                // Remove stale cache entries (files that no longer exist)
                let currentKeys = Set(
                    fileURLs.compactMap { url -> String? in
                        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                        return "\(url.lastPathComponent):\(sha256(content))"
                    }
                )
                let allRelevantKeys = Set(filesToEmbed.map(\.key)).union(currentKeys)
                cache.entries = cache.entries.filter { allRelevantKeys.contains($0.key) }

                saveCache(cache)
            }
        } else {
            // All files were cached — still prune stale entries
            let currentKeys = Set(
                fileURLs.compactMap { url -> String? in
                    guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                    return "\(url.lastPathComponent):\(sha256(content))"
                }
            )
            if cache.entries.keys.count != currentKeys.count {
                cache.entries = cache.entries.filter { currentKeys.contains($0.key) }
                saveCache(cache)
            }
        }

        self.chunks = allChunks
        self.fileCount = files
        self.isIndexed = true
        self.indexingProgress = ""
    }

    func search(query: String, topK: Int = 5) async -> [KBResult] {
        return await search(queries: [query], topK: topK)
    }

    /// Multi-query search with score fusion. Deduplicates by chunk index, uses max score.
    func search(queries: [String], topK: Int = 5) async -> [KBResult] {
        guard isIndexed, !chunks.isEmpty, settings.hasAWSCredentials else { return [] }

        let validQueries = queries.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !validQueries.isEmpty else { return [] }

        // Embed all queries
        let queryEmbeddings: [[Float]]
        do {
            queryEmbeddings = try await embeddingClient.embedBatch(
                accessKeyId: settings.awsAccessKeyId,
                secretAccessKey: settings.awsSecretAccessKey,
                region: settings.awsRegion,
                texts: validQueries
            )
        } catch {
            print("KB search embed error: \(error)")
            return []
        }

        // Score fusion: for each chunk, take max cosine similarity across all queries
        var bestScores: [Int: Float] = [:]
        for queryEmb in queryEmbeddings {
            for (i, chunk) in chunks.enumerated() {
                let sim = cosineSimilarity(queryEmb, chunk.embedding)
                if sim > 0.1 {
                    bestScores[i] = max(bestScores[i] ?? 0, sim)
                }
            }
        }

        var scored = bestScores.map { (index: $0.key, score: $0.value) }
        scored.sort { $0.score > $1.score }

        return scored.prefix(topK).map { candidate in
            let chunk = chunks[candidate.index]
            return KBResult(
                text: chunk.text,
                sourceFile: chunk.sourceFile,
                headerContext: chunk.headerContext,
                score: Double(candidate.score)
            )
        }
    }

    func clear() {
        chunks.removeAll()
        isIndexed = false
        fileCount = 0
        indexingProgress = ""
    }

    // MARK: - File Collection

    private nonisolated func collectFiles(in folderURL: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var urls: [URL] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if ext == "md" || ext == "txt" {
                urls.append(fileURL)
            }
        }
        return urls
    }

    // MARK: - Markdown Chunking

    /// Splits markdown content into chunks aware of header hierarchy.
    private nonisolated func chunkMarkdown(_ text: String, sourceFile: String) -> [(text: String, header: String)] {
        let lines = text.components(separatedBy: .newlines)

        struct Section {
            var headers: [String] // hierarchy stack
            var lines: [String]
        }

        var sections: [Section] = []
        var current = Section(headers: [], lines: [])

        for line in lines {
            if line.hasPrefix("#") {
                // Flush current section
                if !current.lines.isEmpty {
                    sections.append(current)
                }

                // Parse header level
                let trimmed = line.drop(while: { $0 == "#" })
                let level = line.count - trimmed.count
                let headerText = String(trimmed).trimmingCharacters(in: .whitespaces)

                // Build header stack: keep headers at higher levels, replace at current
                var newHeaders = current.headers
                if level <= newHeaders.count {
                    newHeaders = Array(newHeaders.prefix(level - 1))
                }
                newHeaders.append(headerText)

                current = Section(headers: newHeaders, lines: [])
            } else {
                current.lines.append(line)
            }
        }
        if !current.lines.isEmpty {
            sections.append(current)
        }

        // Merge small sections and split large ones
        var result: [(text: String, header: String)] = []
        let targetMin = 80
        let targetMax = 500

        var pendingText = ""
        var pendingHeader = ""

        for section in sections {
            let sectionText = section.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sectionText.isEmpty else { continue }

            let breadcrumb = section.headers.joined(separator: " > ")
            let wordCount = sectionText.split(separator: " ").count

            if wordCount < targetMin {
                // Merge with pending
                if pendingText.isEmpty {
                    pendingText = sectionText
                    pendingHeader = breadcrumb
                } else {
                    pendingText += "\n\n" + sectionText
                    // Keep the more specific header
                    if !breadcrumb.isEmpty { pendingHeader = breadcrumb }
                }

                // Flush if pending is now large enough
                let pendingWords = pendingText.split(separator: " ").count
                if pendingWords >= targetMin {
                    result.append((text: pendingText, header: pendingHeader))
                    pendingText = ""
                    pendingHeader = ""
                }
            } else if wordCount > targetMax {
                // Flush pending first
                if !pendingText.isEmpty {
                    result.append((text: pendingText, header: pendingHeader))
                    pendingText = ""
                    pendingHeader = ""
                }

                // Split large section with overlap
                let words = sectionText.split(separator: " ", omittingEmptySubsequences: true)
                let overlap = targetMax / 5
                var start = 0
                while start < words.count {
                    let end = min(start + targetMax, words.count)
                    let chunk = words[start..<end].joined(separator: " ")
                    result.append((text: chunk, header: breadcrumb))
                    start += targetMax - overlap
                }
            } else {
                // Flush pending first
                if !pendingText.isEmpty {
                    result.append((text: pendingText, header: pendingHeader))
                    pendingText = ""
                    pendingHeader = ""
                }
                result.append((text: sectionText, header: breadcrumb))
            }
        }

        // Flush remaining
        if !pendingText.isEmpty {
            result.append((text: pendingText, header: pendingHeader))
        }

        // If no chunks were produced (e.g. no headers, short doc), chunk the whole text
        if result.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let words = text.split(separator: " ", omittingEmptySubsequences: true)
            if words.count <= targetMax {
                result.append((text: text.trimmingCharacters(in: .whitespacesAndNewlines), header: ""))
            } else {
                let overlap = targetMax / 5
                var start = 0
                while start < words.count {
                    let end = min(start + targetMax, words.count)
                    let chunk = words[start..<end].joined(separator: " ")
                    result.append((text: chunk, header: ""))
                    start += targetMax - overlap
                }
            }
        }

        return result
    }

    // MARK: - Embedding Batches

    private func embedInBatches(texts: [String]) async -> (embeddings: [[Float]]?, error: String?) {
        let batchSize = 16
        var allEmbeddings: [[Float]] = []

        for batchStart in stride(from: 0, to: texts.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, texts.count)
            let batch = Array(texts[batchStart..<batchEnd])

            indexingProgress = "Embedding \(batchStart + 1)-\(batchEnd) of \(texts.count)..."

            do {
                let embeddings = try await embeddingClient.embedBatch(
                    accessKeyId: settings.awsAccessKeyId,
                    secretAccessKey: settings.awsSecretAccessKey,
                    region: settings.awsRegion,
                    texts: batch,
                    maxConcurrency: 8
                )
                allEmbeddings.append(contentsOf: embeddings)
            } catch {
                return (nil, error.localizedDescription)
            }
        }

        return (allEmbeddings, nil)
    }

    // MARK: - Vector Math

    private nonisolated func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dot: Float = 0
        var magA: Float = 0
        var magB: Float = 0

        for i in 0..<a.count {
            dot += a[i] * b[i]
            magA += a[i] * a[i]
            magB += b[i] * b[i]
        }

        let denom = sqrt(magA) * sqrt(magB)
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    // MARK: - Cache

    private nonisolated func loadCache() -> KBCache {
        guard let data = try? Data(contentsOf: Self.cacheURL()),
              let cache = try? JSONDecoder().decode(KBCache.self, from: data) else {
            return KBCache(entries: [:])
        }
        return cache
    }

    private nonisolated func saveCache(_ cache: KBCache) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: Self.cacheURL(), options: .atomic)
    }

    // MARK: - Hashing

    private nonisolated func sha256(_ string: String) -> String {
        let data = Data(string.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
