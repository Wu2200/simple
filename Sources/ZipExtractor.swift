import Foundation
import zlib

enum ZipExtractor {
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
            let sig = fileData.withUnsafeBytes { $0.load(fromByteOffset: i, as: UInt32.self) }
            if UInt32(littleEndian: sig) == eocdSignature {
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

    private static func extractGzip(archiveURL: URL, destinationURL: URL) throws {
        let compressedData = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        guard let decompressed = decompressGzip(data: compressedData) else {
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
        let outputFile = destinationURL.appendingPathComponent(outputName)
        try decompressed.write(to: outputFile)
    }

    private static func extractViaCentralDirectory(data: Data, eocdOffset: Int, destinationURL: URL) throws {
        let entriesCount = Int(UInt16(littleEndian: data.withUnsafeBytes { $0.load(fromByteOffset: eocdOffset + 10, as: UInt16.self) }))
        let cdOffset = Int(UInt32(littleEndian: data.withUnsafeBytes { $0.load(fromByteOffset: eocdOffset + 16, as: UInt32.self) }))

        var currentOffset = cdOffset
        let fm = FileManager.default
        let destCanonical = destinationURL.standardizedFileURL.path

        for _ in 0..<entriesCount {
            guard currentOffset + 46 <= data.count else { break }

            let sig = UInt32(littleEndian: data.withUnsafeBytes { $0.load(fromByteOffset: currentOffset, as: UInt32.self) })
            guard sig == 0x02014b50 else { break }

            let method = UInt16(littleEndian: data.withUnsafeBytes { $0.load(fromByteOffset: currentOffset + 10, as: UInt16.self) })
            let compressedSize = Int(UInt32(littleEndian: data.withUnsafeBytes { $0.load(fromByteOffset: currentOffset + 20, as: UInt32.self) }))
            let uncompressedSize = Int(UInt32(littleEndian: data.withUnsafeBytes { $0.load(fromByteOffset: currentOffset + 24, as: UInt32.self) }))
            let filenameLen = Int(UInt16(littleEndian: data.withUnsafeBytes { $0.load(fromByteOffset: currentOffset + 28, as: UInt16.self) }))
            let extraLen = Int(UInt16(littleEndian: data.withUnsafeBytes { $0.load(fromByteOffset: currentOffset + 30, as: UInt16.self) }))
            let commentLen = Int(UInt16(littleEndian: data.withUnsafeBytes { $0.load(fromByteOffset: currentOffset + 32, as: UInt16.self) }))
            let localHeaderOffset = Int(UInt32(littleEndian: data.withUnsafeBytes { $0.load(fromByteOffset: currentOffset + 42, as: UInt32.self) }))

            let filenameBytes = data.subdata(in: (currentOffset + 46)..<(currentOffset + 46 + filenameLen))
            let filename = decodeFilename(data: filenameBytes)

            currentOffset += 46 + filenameLen + extraLen + commentLen

            guard !filename.isEmpty else { continue }

            let targetURL = destinationURL.appendingPathComponent(filename).standardizedFileURL
            guard targetURL.path.hasPrefix(destCanonical) else { continue }

            if filename.hasSuffix("/") {
                try fm.createDirectory(at: targetURL, withIntermediateDirectories: true)
                continue
            }

            guard localHeaderOffset + 30 <= data.count else { continue }
            let localFilenameLen = Int(UInt16(littleEndian: data.withUnsafeBytes { $0.load(fromByteOffset: localHeaderOffset + 26, as: UInt16.self) }))
            let localExtraLen = Int(UInt16(littleEndian: data.withUnsafeBytes { $0.load(fromByteOffset: localHeaderOffset + 28, as: UInt16.self) }))

            let fileDataOffset = localHeaderOffset + 30 + localFilenameLen + localExtraLen
            guard fileDataOffset + compressedSize <= data.count else { continue }

            let compressedPayload = data.subdata(in: fileDataOffset..<(fileDataOffset + compressedSize))
            let extractedData: Data?

            if method == 0 {
                extractedData = compressedPayload
            } else if method == 8 {
                extractedData = decompressDeflate(data: compressedPayload, uncompressedSize: uncompressedSize)
            } else {
                continue
            }

            guard let finalData = extractedData else { continue }

            let parentDir = targetURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: parentDir.path) {
                try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }

            try finalData.write(to: targetURL)
        }
    }

    private static func extractViaLocalHeaders(data: Data, destinationURL: URL) throws {
        var offset = 0
        let fm = FileManager.default
        let destCanonical = destinationURL.standardizedFileURL.path

        while offset + 30 <= data.count {
            let sig = UInt32(littleEndian: data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) })
            guard sig == 0x04034b50 else { break }

            let flags = UInt16(littleEndian: data.withUnsafeBytes { $0.load(fromByteOffset: offset + 6, as: UInt16.self) })
            let method = UInt16(littleEndian: data.withUnsafeBytes { $0.load(fromByteOffset: offset + 8, as: UInt16.self) })
            let compressedSize = Int(UInt32(littleEndian: data.withUnsafeBytes { $0.load(fromByteOffset: offset + 18, as: UInt32.self) }))
            let uncompressedSize = Int(UInt32(littleEndian: data.withUnsafeBytes { $0.load(fromByteOffset: offset + 22, as: UInt32.self) }))
            let filenameLen = Int(UInt16(littleEndian: data.withUnsafeBytes { $0.load(fromByteOffset: offset + 26, as: UInt16.self) }))
            let extraLen = Int(UInt16(littleEndian: data.withUnsafeBytes { $0.load(fromByteOffset: offset + 28, as: UInt16.self) }))

            guard offset + 30 + filenameLen + extraLen <= data.count else { break }

            let filenameBytes = data.subdata(in: (offset + 30)..<(offset + 30 + filenameLen))
            let filename = decodeFilename(data: filenameBytes)

            let dataOffset = offset + 30 + filenameLen + extraLen

            if flags & 0x08 != 0 && compressedSize == 0 {
                break
            }

            guard dataOffset + compressedSize <= data.count else { break }

            offset = dataOffset + compressedSize

            guard !filename.isEmpty else { continue }

            let targetURL = destinationURL.appendingPathComponent(filename).standardizedFileURL
            guard targetURL.path.hasPrefix(destCanonical) else { continue }

            if filename.hasSuffix("/") {
                try fm.createDirectory(at: targetURL, withIntermediateDirectories: true)
                continue
            }

            let compressedPayload = data.subdata(in: dataOffset..<(dataOffset + compressedSize))
            let extractedData: Data?

            if method == 0 {
                extractedData = compressedPayload
            } else if method == 8 {
                extractedData = decompressDeflate(data: compressedPayload, uncompressedSize: uncompressedSize)
            } else {
                continue
            }

            guard let finalData = extractedData else { continue }

            let parentDir = targetURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: parentDir.path) {
                try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }

            try finalData.write(to: targetURL)
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

    private static func decompressDeflate(data: Data, uncompressedSize: Int) -> Data? {
        if data.isEmpty {
            return Data()
        }

        var stream = z_stream()
        let initStatus = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else {
            return nil
        }
        defer {
            inflateEnd(&stream)
        }

        var output = Data(count: max(uncompressedSize, 4096))
        var status = Z_OK

        data.withUnsafeBytes { inputPtr in
            guard let inBase = inputPtr.bindMemory(to: Bytef.self).baseAddress else { return }
            stream.next_in = UnsafeMutablePointer(mutating: inBase)
            stream.avail_in = uInt(data.count)

            while status == Z_OK {
                if Int(stream.total_out) >= output.count {
                    output.count = max(output.count * 2, output.count + 8192)
                }

                output.withUnsafeMutableBytes { outPtr in
                    guard let outBase = outPtr.bindMemory(to: Bytef.self).baseAddress else { return }
                    stream.next_out = outBase.advanced(by: Int(stream.total_out))
                    stream.avail_out = uInt(output.count - Int(stream.total_out))
                    status = inflate(&stream, Z_NO_FLUSH)
                }
            }
        }

        guard status == Z_STREAM_END || status == Z_OK else {
            return nil
        }

        output.count = Int(stream.total_out)
        return output
    }

    private static func decompressGzip(data: Data) -> Data? {
        if data.isEmpty {
            return Data()
        }

        var stream = z_stream()
        let initStatus = inflateInit2_(&stream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else {
            return nil
        }
        defer {
            inflateEnd(&stream)
        }

        var output = Data(count: max(data.count * 2, 4096))
        var status = Z_OK

        data.withUnsafeBytes { inputPtr in
            guard let inBase = inputPtr.bindMemory(to: Bytef.self).baseAddress else { return }
            stream.next_in = UnsafeMutablePointer(mutating: inBase)
            stream.avail_in = uInt(data.count)

            while status == Z_OK {
                if Int(stream.total_out) >= output.count {
                    output.count = max(output.count * 2, output.count + 8192)
                }

                output.withUnsafeMutableBytes { outPtr in
                    guard let outBase = outPtr.bindMemory(to: Bytef.self).baseAddress else { return }
                    stream.next_out = outBase.advanced(by: Int(stream.total_out))
                    stream.avail_out = uInt(output.count - Int(stream.total_out))
                    status = inflate(&stream, Z_NO_FLUSH)
                }
            }
        }

        guard status == Z_STREAM_END || status == Z_OK else {
            return nil
        }

        output.count = Int(stream.total_out)
        return output
    }
}
