import Foundation
import zlib

enum ZipExtractor {
    private static let maxSingleFileBytes = 512 * 1024 * 1024
    private static let maxTotalExtractedBytes = 1024 * 1024 * 1024
    private static let maxEntryCount = 20000

    static func unzip(archiveURL: URL, destinationURL: URL) throws {
        let ext = archiveURL.pathExtension.lowercased()
        if ext == "gz" {
            try extractGzip(archiveURL: archiveURL, destinationURL: destinationURL)
            return
        }

        let fileData = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        guard fileData.count >= 22 else {
            throw NSError(domain: "ZipExtractor", code: 1, userInfo: [NSLocalizedDescriptionKey: "文件格式无效"])
        }

        let fm = FileManager.default
        if !fm.fileExists(atPath: destinationURL.path) {
            try fm.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        }

        let eocdSignature: UInt32 = 0x06054b50
        let maxSearchLength = min(fileData.count, 65557)
        let searchStartIndex = fileData.count - maxSearchLength
        var eocdOffset: Int?

        for i in stride(from: fileData.count - 22, through: searchStartIndex, by: -1) {
            if readUInt32LE(fileData, at: i) == eocdSignature {
                eocdOffset = i
                break
            }
        }

        if let offset = eocdOffset {
            try extractViaCentralDirectory(data: fileData, eocdOffset: offset, destinationURL: destinationURL)
        } else {
            try extractViaLocalHeaders(data: fileData, destinationURL: destinationURL)
        }
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        let b0 = UInt16(data[offset])
        let b1 = UInt16(data[offset + 1]) << 8
        return b0 | b1
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1]) << 8
        let b2 = UInt32(data[offset + 2]) << 16
        let b3 = UInt32(data[offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }

    private static func safeDestinationURL(
        for rawFilename: String,
        under destinationURL: URL,
        destCanonical: String
    ) -> URL? {
        let normalizedName = rawFilename.replacingOccurrences(of: "\\", with: "/")
        guard !normalizedName.isEmpty, !normalizedName.hasPrefix("/") else {
            return nil
        }

        let targetURL = destinationURL.appendingPathComponent(normalizedName).standardizedFileURL
        let canonicalPrefix = destCanonical.hasSuffix("/") ? destCanonical : destCanonical + "/"

        if normalizedName.hasSuffix("/") {
            guard targetURL.path == destCanonical || targetURL.path.hasPrefix(canonicalPrefix) else {
                return nil
            }
        } else {
            guard targetURL.path.hasPrefix(canonicalPrefix) else {
                return nil
            }
        }
        return targetURL
    }

    private static func writeEntry(
        filename: String,
        method: UInt16,
        compressedPayload: Data,
        uncompressedSize: Int,
        destinationURL: URL,
        destCanonical: String,
        totalExtractedBytes: inout Int
    ) throws {
        guard let targetURL = safeDestinationURL(for: filename, under: destinationURL, destCanonical: destCanonical) else {
            return
        }

        let fm = FileManager.default
        if filename.hasSuffix("/") || filename.hasSuffix("\\") {
            try fm.createDirectory(at: targetURL, withIntermediateDirectories: true)
            return
        }

        guard uncompressedSize <= maxSingleFileBytes else {
            throw NSError(domain: "ZipExtractor", code: 3, userInfo: [NSLocalizedDescriptionKey: "压缩包内单个文件体积超出安全限制"])
        }

        let extractedData: Data?
        if method == 0 {
            guard compressedPayload.count <= maxSingleFileBytes else {
                throw NSError(domain: "ZipExtractor", code: 3, userInfo: [NSLocalizedDescriptionKey: "压缩包内单个文件体积超出安全限制"])
            }
            extractedData = compressedPayload
        } else if method == 8 {
            let maxAllowed = min(maxSingleFileBytes, maxTotalExtractedBytes - totalExtractedBytes)
            guard maxAllowed > 0 else {
                throw NSError(domain: "ZipExtractor", code: 4, userInfo: [NSLocalizedDescriptionKey: "压缩包解压总体积超出安全限制"])
            }
            extractedData = decompressZlib(
                data: compressedPayload,
                windowBits: -MAX_WBITS,
                initialCapacity: uncompressedSize,
                maxOutputBytes: maxAllowed
            )
        } else {
            return
        }

        guard let finalData = extractedData else {
            return
        }

        guard totalExtractedBytes + finalData.count <= maxTotalExtractedBytes else {
            throw NSError(domain: "ZipExtractor", code: 4, userInfo: [NSLocalizedDescriptionKey: "压缩包解压总体积超出安全限制"])
        }
        totalExtractedBytes += finalData.count

        let parentDir = targetURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: parentDir.path) {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        try finalData.write(to: targetURL)
    }

    private static func extractGzip(archiveURL: URL, destinationURL: URL) throws {
        let compressedData = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        guard let decompressed = decompressZlib(
            data: compressedData,
            windowBits: 16 + MAX_WBITS,
            initialCapacity: compressedData.count * 2,
            maxOutputBytes: maxSingleFileBytes
        ) else {
            throw NSError(domain: "ZipExtractor", code: 2, userInfo: [NSLocalizedDescriptionKey: "解压失败"])
        }

        let fm = FileManager.default
        if !fm.fileExists(atPath: destinationURL.path) {
            try fm.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        }

        var outputName = (archiveURL.lastPathComponent as NSString).deletingPathExtension
        if outputName.isEmpty {
            outputName = "extracted_file"
        }
        let destCanonical = destinationURL.standardizedFileURL.path
        guard let outputFile = safeDestinationURL(for: outputName, under: destinationURL, destCanonical: destCanonical) else {
            throw NSError(domain: "ZipExtractor", code: 5, userInfo: [NSLocalizedDescriptionKey: "输出路径无效"])
        }
        try decompressed.write(to: outputFile)
    }

    private static func extractViaCentralDirectory(data: Data, eocdOffset: Int, destinationURL: URL) throws {
        let entriesCount = Int(readUInt16LE(data, at: eocdOffset + 10))
        let cdOffset = Int(readUInt32LE(data, at: eocdOffset + 16))
        guard entriesCount <= maxEntryCount, cdOffset >= 0, cdOffset <= data.count else {
            throw NSError(domain: "ZipExtractor", code: 6, userInfo: [NSLocalizedDescriptionKey: "压缩包目录结构异常"])
        }

        var currentOffset = cdOffset
        let destCanonical = destinationURL.standardizedFileURL.path
        var totalExtractedBytes = 0

        for _ in 0..<entriesCount {
            guard currentOffset + 46 <= data.count else { break }

            let sig = readUInt32LE(data, at: currentOffset)
            guard sig == 0x02014b50 else { break }

            let method = readUInt16LE(data, at: currentOffset + 10)
            let compressedSize = Int(readUInt32LE(data, at: currentOffset + 20))
            let uncompressedSize = Int(readUInt32LE(data, at: currentOffset + 24))
            let filenameLen = Int(readUInt16LE(data, at: currentOffset + 28))
            let extraLen = Int(readUInt16LE(data, at: currentOffset + 30))
            let commentLen = Int(readUInt16LE(data, at: currentOffset + 32))
            let localHeaderOffset = Int(readUInt32LE(data, at: currentOffset + 42))

            guard currentOffset + 46 + filenameLen + extraLen + commentLen <= data.count else { break }

            let filenameBytes = data.subdata(in: (currentOffset + 46)..<(currentOffset + 46 + filenameLen))
            let filename = decodeFilename(data: filenameBytes)

            currentOffset += 46 + filenameLen + extraLen + commentLen

            guard !filename.isEmpty else { continue }
            guard localHeaderOffset >= 0, localHeaderOffset + 30 <= data.count else { continue }
            let localFilenameLen = Int(readUInt16LE(data, at: localHeaderOffset + 26))
            let localExtraLen = Int(readUInt16LE(data, at: localHeaderOffset + 28))

            let fileDataOffset = localHeaderOffset + 30 + localFilenameLen + localExtraLen
            guard compressedSize >= 0, fileDataOffset + compressedSize <= data.count else { continue }

            let compressedPayload = data.subdata(in: fileDataOffset..<(fileDataOffset + compressedSize))
            try writeEntry(
                filename: filename,
                method: method,
                compressedPayload: compressedPayload,
                uncompressedSize: uncompressedSize,
                destinationURL: destinationURL,
                destCanonical: destCanonical,
                totalExtractedBytes: &totalExtractedBytes
            )
        }
    }

    private static func extractViaLocalHeaders(data: Data, destinationURL: URL) throws {
        var offset = 0
        let destCanonical = destinationURL.standardizedFileURL.path
        var totalExtractedBytes = 0
        var processedEntries = 0

        while offset + 30 <= data.count {
            let sig = readUInt32LE(data, at: offset)
            guard sig == 0x04034b50 else { break }
            processedEntries += 1
            if processedEntries > maxEntryCount {
                throw NSError(domain: "ZipExtractor", code: 6, userInfo: [NSLocalizedDescriptionKey: "压缩包文件数量超出安全限制"])
            }

            let flags = readUInt16LE(data, at: offset + 6)
            let method = readUInt16LE(data, at: offset + 8)
            let compressedSize = Int(readUInt32LE(data, at: offset + 18))
            let uncompressedSize = Int(readUInt32LE(data, at: offset + 22))
            let filenameLen = Int(readUInt16LE(data, at: offset + 26))
            let extraLen = Int(readUInt16LE(data, at: offset + 28))

            guard offset + 30 + filenameLen + extraLen <= data.count else { break }

            let filenameBytes = data.subdata(in: (offset + 30)..<(offset + 30 + filenameLen))
            let filename = decodeFilename(data: filenameBytes)

            let dataOffset = offset + 30 + filenameLen + extraLen

            if flags & 0x08 != 0 && compressedSize == 0 {
                break
            }

            guard compressedSize >= 0, dataOffset + compressedSize <= data.count else { break }

            offset = dataOffset + compressedSize

            guard !filename.isEmpty else { continue }

            let compressedPayload = data.subdata(in: dataOffset..<(dataOffset + compressedSize))
            try writeEntry(
                filename: filename,
                method: method,
                compressedPayload: compressedPayload,
                uncompressedSize: uncompressedSize,
                destinationURL: destinationURL,
                destCanonical: destCanonical,
                totalExtractedBytes: &totalExtractedBytes
            )
        }
    }

    private static func decodeFilename(data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        let gbkEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let gbk = String(data: data, encoding: String.Encoding(rawValue: gbkEncoding)) {
            return gbk
        }
        return String(data: data, encoding: .isoLatin1) ?? "unnamed"
    }

    private static func decompressZlib(
        data: Data,
        windowBits: Int32,
        initialCapacity: Int,
        maxOutputBytes: Int
    ) -> Data? {
        if data.isEmpty {
            return Data()
        }
        guard data.count <= Int(uInt.max) else {
            return nil
        }

        var stream = z_stream()
        let initStatus = inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else {
            return nil
        }
        defer {
            inflateEnd(&stream)
        }

        let safeInitial = min(max(initialCapacity, 4096), min(1024 * 1024, maxOutputBytes))
        var output = Data(count: max(safeInitial, 1))
        var status = Z_OK

        data.withUnsafeBytes { inputPtr in
            guard let inBase = inputPtr.bindMemory(to: Bytef.self).baseAddress else { return }
            stream.next_in = UnsafeMutablePointer(mutating: inBase)
            stream.avail_in = uInt(data.count)

            while status == Z_OK {
                if Int(stream.total_out) >= output.count {
                    if output.count >= maxOutputBytes {
                        status = Z_DATA_ERROR
                        break
                    }
                    output.count = min(maxOutputBytes, max(output.count * 2, output.count + 8192))
                }

                let prevOut = stream.total_out
                output.withUnsafeMutableBytes { outPtr in
                    guard let outBase = outPtr.bindMemory(to: Bytef.self).baseAddress else { return }
                    stream.next_out = outBase.advanced(by: Int(stream.total_out))
                    stream.avail_out = uInt(outPtr.count - Int(stream.total_out))
                    status = inflate(&stream, Z_NO_FLUSH)
                }

                if status == Z_OK && stream.avail_in == 0 && stream.avail_out > 0 && stream.total_out == prevOut {
                    break
                }
            }
        }

        guard status == Z_STREAM_END || status == Z_OK else {
            return nil
        }
        guard Int(stream.total_out) <= maxOutputBytes else {
            return nil
        }

        output.count = Int(stream.total_out)
        return output
    }
}
    }
}
