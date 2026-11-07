import Foundation

/// One piece of a provider's raw samples, stored as `samples.<provider>.<index>`. Every piece repeats the piece count and the
/// cut-off, so the first piece alone says how many follow and whether history was deleted.
public struct CloudSamplePiece: Codable, Sendable, Equatable {
    public var provider: ProviderID
    public var index: Int
    public var count: Int
    /// Set when history was deleted: samples before it are gone for every Mac.
    public var clearedAt: Date?
    public var samples: [Sample]
}

/// A provider's raw samples as iCloud holds them, with the cut-off their deletion set.
public struct CloudSampleSet: Sendable, Equatable {
    public var samples: [Sample]
    public var clearedAt: Date?
}

/// Raw samples are the bulk of a Mac's history (the mini's 29k points are 3 MB of JSON, about 150 KB compressed), so they go
/// to iCloud in pieces that each fit one record.
public enum CloudSamples {
    /// Splits one provider's samples into records, one piece per record. Pieces hold `policy.samplesPerRecord` samples and
    /// halve until every record fits `policy.maxRecordBytes`. An empty set writes no piece, unless it carries a cut-off, which
    /// the other Macs have to see.
    public static func records(provider: ProviderID, samples: [Sample], clearedAt: Date?, hubName: String, now: Date,
                               policy: CloudSyncPolicy) throws -> [CloudRecord] {
        if samples.isEmpty && clearedAt == nil { return [] }
        var size = max(1, policy.samplesPerRecord)
        while true {
            var pieces = stride(from: 0, to: samples.count, by: size).map { start in
                Array(samples[start..<min(start + size, samples.count)])
            }
            if pieces.isEmpty { pieces = [[]] }
            let records = try pieces.enumerated().map { index, part in
                try CloudRecord(name: CloudPayload.samplesRecord(provider, index), generatedAt: now, hubName: hubName,
                                encoding: CloudSamplePiece(provider: provider, index: index, count: pieces.count, clearedAt: clearedAt, samples: part))
            }
            if records.allSatisfy({ $0.payload.count <= policy.maxRecordBytes }) { return records }
            guard size > 1 else { throw CloudError.other("a sample is larger than \(policy.maxRecordBytes) bytes") }
            size = (size + 1) / 2
            QPLog.cloud.notice("samples for \(provider.rawValue, privacy: .public): piece over \(policy.maxRecordBytes) bytes, now \(size) samples a piece")
        }
    }

    /// Names read on the first pass of a sync: piece 0 of each provider. The rest are named once their count is known.
    public static func firstPieceNames(_ providers: [ProviderID]) -> [String] {
        providers.map { CloudPayload.samplesRecord($0, 0) }
    }

    /// Reassembles each provider's samples. `first` is what the first read returned; the remaining pieces come in one more read.
    /// A piece whose stamp or count disagrees with piece 0 was written by another pass and is left out: the Mac that wrote it
    /// still holds those points and writes them again on its next pass.
    public static func read(_ providers: [ProviderID], first: [String: CloudRecord], store: any CloudRecordStore) async throws -> [ProviderID: CloudSampleSet] {
        var heads: [ProviderID: (record: CloudRecord, piece: CloudSamplePiece)] = [:]
        for p in providers {
            guard let record = first[CloudPayload.samplesRecord(p, 0)] else { continue }
            do {
                let piece = try record.decode(CloudSamplePiece.self)
                guard piece.provider == p, piece.index == 0, piece.count >= 1 else { throw CloudError.corrupt }
                heads[p] = (record, piece)
            } catch {
                QPLog.cloud.error("samples for \(p.rawValue, privacy: .public) unreadable: \(error.localizedDescription, privacy: .public)")
            }
        }
        let laterNames = heads.flatMap { p, head in (1..<max(1, head.piece.count)).map { CloudPayload.samplesRecord(p, $0) } }
        let later = laterNames.isEmpty ? [:] : try await store.fetch(laterNames)

        var out: [ProviderID: CloudSampleSet] = [:]
        for (p, head) in heads {
            var samples = head.piece.samples
            var left = 0
            for index in stride(from: 1, to: head.piece.count, by: 1) {
                guard let record = later[CloudPayload.samplesRecord(p, index)], record.generatedAt == head.record.generatedAt,
                      let piece = try? record.decode(CloudSamplePiece.self), piece.index == index, piece.count == head.piece.count else {
                    left += 1
                    continue
                }
                samples += piece.samples
            }
            if left > 0 {
                QPLog.cloud.notice("samples for \(p.rawValue, privacy: .public): \(left) pieces from another write left out")
            }
            out[p] = CloudSampleSet(samples: samples, clearedAt: head.piece.clearedAt)
        }
        return out
    }
}
