import Foundation

/// Ultra HDR JPEG 元数据修补器：保留 ISO 21496-1 增益参数，补写等价 Adobe XMP 并同步更新 MPF 偏移
enum UltraHDRMetadataPatcher {
    private enum TIFFByteOrder {
        case bigEndian
        case littleEndian
    }

    private struct MPFEntryPositions {
        let byteOrder: TIFFByteOrder
        let tiffStart: Int
        let primaryLengthOffset: Int
        let primaryStartOffset: Int
        let secondaryLengthOffset: Int
        let secondaryStartOffset: Int
    }

    private struct GainMapMetadata {
        let gainMapMin: Double
        let gainMapMax: Double
        let gamma: Double
        let offsetSDR: Double
        let offsetHDR: Double
        let hdrCapacityMin: Double
        let hdrCapacityMax: Double
    }

    static func ensureXMPMetadata(at url: URL) throws {
        var fileData = try Data(contentsOf: url)

        try removeExistingXMPSegments(in: &fileData)

        guard let primaryImageEnd = findJPEGImageEnd(in: fileData, start: 0),
              primaryImageEnd + 1 < fileData.count,
              fileData[primaryImageEnd] == 0xff,
              fileData[primaryImageEnd + 1] == 0xd8,
              let secondaryImageEnd = findJPEGImageEnd(in: fileData, start: primaryImageEnd) else {
            throw ExportError.failedUltraHDRMetadataPatch("无法定位 Ultra HDR JPEG 的 MPF 双图像结构")
        }

        let primaryImageLength = primaryImageEnd
        let secondaryImageStart = primaryImageEnd
        let secondaryImageLength = secondaryImageEnd - secondaryImageStart

        guard let mpfEntries = findMPFEntryPositions(in: fileData, primaryImageEnd: primaryImageEnd) else {
            throw ExportError.failedUltraHDRMetadataPatch("无法定位 MPF 图像目录")
        }

        guard let gainMapMetadata = readISOGainMapMetadata(
            in: fileData,
            imageStart: secondaryImageStart,
            imageEnd: secondaryImageEnd
        ) else {
            throw ExportError.failedUltraHDRMetadataPatch(
                "ISO gain map 元数据无效，或无法无损表示为 SDR 基底、基底色域的单通道 XMP"
            )
        }

        guard let secondaryXMPData = makeJPEGAPP1XMPData(
            xml: makeSecondaryXMP(metadata: gainMapMetadata)
        ) else {
            throw ExportError.failedUltraHDRMetadataPatch("gain map XMP 超出 JPEG APP1 段长度限制")
        }
        let patchedSecondaryImageLength = secondaryImageLength + secondaryXMPData.count

        guard let primaryXMPData = makeJPEGAPP1XMPData(
            xml: makePrimaryXMP(secondaryImageLength: patchedSecondaryImageLength)
        ) else {
            throw ExportError.failedUltraHDRMetadataPatch("主图 XMP 超出 JPEG APP1 段长度限制")
        }
        let patchedPrimaryImageLength = primaryImageLength + primaryXMPData.count
        let patchedSecondaryImageStart = secondaryImageStart + primaryXMPData.count

        guard updateMPFEntries(
            in: &fileData,
            entries: mpfEntries,
            primaryImageLength: patchedPrimaryImageLength,
            secondaryImageStart: patchedSecondaryImageStart,
            secondaryImageLength: patchedSecondaryImageLength,
            tiffStartOffsetAdjustment: primaryXMPData.count
        ) else {
            throw ExportError.failedUltraHDRMetadataPatch("MPF 图像长度或偏移超出可表示范围")
        }

        fileData.insert(contentsOf: secondaryXMPData, at: secondaryImageStart + 2)
        fileData.insert(contentsOf: primaryXMPData, at: 2)

        try fileData.write(to: url, options: .atomic)
    }

    static func formatNumber(_ value: Double) -> String {
        String(format: "%.17g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func removeExistingXMPSegments(in data: inout Data) throws {
        guard let primaryImageEnd = findJPEGImageEnd(in: data, start: 0),
              primaryImageEnd + 1 < data.count,
              data[primaryImageEnd] == 0xff,
              data[primaryImageEnd + 1] == 0xd8,
              let secondaryImageEnd = findJPEGImageEnd(in: data, start: primaryImageEnd) else {
            throw ExportError.failedUltraHDRMetadataPatch("无法定位 Ultra HDR JPEG 的 MPF 双图像结构")
        }

        try removeGainMapXMPSegments(
            in: &data,
            imageStart: primaryImageEnd,
            imageEnd: secondaryImageEnd
        )

        guard let refreshedPrimaryImageEnd = findJPEGImageEnd(in: data, start: 0),
              refreshedPrimaryImageEnd + 1 < data.count,
              data[refreshedPrimaryImageEnd] == 0xff,
              data[refreshedPrimaryImageEnd + 1] == 0xd8,
              let refreshedSecondaryImageEnd = findJPEGImageEnd(
                  in: data,
                  start: refreshedPrimaryImageEnd
              ) else {
            throw ExportError.failedUltraHDRMetadataPatch("移除旧 XMP 后无法重新定位 JPEG 双图像结构")
        }

        try removeGainMapXMPSegments(
            in: &data,
            imageStart: 0,
            imageEnd: refreshedPrimaryImageEnd
        )

        guard findJPEGImageEnd(in: data, start: 0) != nil,
              refreshedSecondaryImageEnd > refreshedPrimaryImageEnd else {
            throw ExportError.failedUltraHDRMetadataPatch("移除旧 XMP 后 JPEG 结构无效")
        }
    }

    private static func removeGainMapXMPSegments(
        in data: inout Data,
        imageStart: Int,
        imageEnd: Int
    ) throws {
        let xmpNamespace = Data("http://ns.adobe.com/xap/1.0/\u{0}".utf8)
        let gainMapNamespace = Data("http://ns.adobe.com/hdr-gain-map/1.0/".utf8)
        var ranges: [Range<Int>] = []
        var offset = imageStart + 2

        while offset + 3 < imageEnd {
            guard data[offset] == 0xff else {
                throw ExportError.failedUltraHDRMetadataPatch("JPEG marker 无效")
            }

            let marker = data[offset + 1]
            if marker == 0xda || marker == 0xd9 {
                break
            }

            guard let segmentLength = readUInt16(data, at: offset + 2, byteOrder: .bigEndian),
                  segmentLength >= 2 else {
                throw ExportError.failedUltraHDRMetadataPatch("JPEG APP 段长度无效")
            }

            let payloadStart = offset + 4
            let segmentEnd = payloadStart + Int(segmentLength) - 2
            guard segmentEnd <= imageEnd else {
                throw ExportError.failedUltraHDRMetadataPatch("JPEG APP 段越界")
            }

            if marker == 0xe1,
               segmentEnd - payloadStart >= xmpNamespace.count,
               data[payloadStart ..< payloadStart + xmpNamespace.count].elementsEqual(xmpNamespace),
               data[payloadStart ..< segmentEnd].range(of: gainMapNamespace) != nil {
                ranges.append(offset ..< segmentEnd)
            }

            offset = segmentEnd
        }

        for range in ranges.reversed() {
            data.removeSubrange(range)
        }
    }

    private static func findJPEGImageEnd(in data: Data, start: Int) -> Int? {
        guard start >= 0, start + 2 <= data.count,
              data[start] == 0xff, data[start + 1] == 0xd8 else { return nil }

        var offset = start + 2
        var isEntropyData = false
        while offset < data.count {
            if isEntropyData {
                while offset < data.count, data[offset] != 0xff { offset += 1 }
            }
            guard offset < data.count, data[offset] == 0xff else { return nil }
            while offset < data.count, data[offset] == 0xff { offset += 1 }
            guard offset < data.count else { return nil }
            let marker = data[offset]
            offset += 1

            if marker == 0x00 || (0xd0 ... 0xd7).contains(marker) {
                guard isEntropyData else { return nil }
                continue
            }
            if marker == 0xd9 { return offset }
            if marker == 0xd8 { return nil }
            if marker == 0x01 { continue }

            guard let length = readUInt16(data, at: offset, byteOrder: .bigEndian),
                  length >= 2, offset + Int(length) <= data.count else { return nil }
            offset += Int(length)
            isEntropyData = marker == 0xda
        }
        return nil
    }

    private static func findMPFEntryPositions(in data: Data, primaryImageEnd: Int) -> MPFEntryPositions? {
        var offset = 2
        while offset + 3 < primaryImageEnd {
            guard data[offset] == 0xff else { return nil }

            let marker = data[offset + 1]
            if marker == 0xda || marker == 0xd9 {
                return nil
            }

            guard let segmentLength = readUInt16(data, at: offset + 2, byteOrder: .bigEndian),
                  segmentLength >= 2 else {
                return nil
            }

            let payloadStart = offset + 4
            let payloadLength = Int(segmentLength) - 2
            let segmentEnd = payloadStart + payloadLength
            guard segmentEnd <= primaryImageEnd else { return nil }

            if marker == 0xe2,
               payloadLength >= 4,
               data[payloadStart ..< payloadStart + 4].elementsEqual(Data("MPF\u{0}".utf8)) {
                return parseMPFEntryPositions(in: data, payloadStart: payloadStart, payloadEnd: segmentEnd)
            }

            offset = segmentEnd
        }

        return nil
    }

    private static func parseMPFEntryPositions(
        in data: Data,
        payloadStart: Int,
        payloadEnd: Int
    ) -> MPFEntryPositions? {
        let tiffStart = payloadStart + 4
        guard tiffStart + 8 <= payloadEnd else { return nil }

        let byteOrder: TIFFByteOrder
        if data[tiffStart] == 0x4d, data[tiffStart + 1] == 0x4d {
            byteOrder = .bigEndian
        } else if data[tiffStart] == 0x49, data[tiffStart + 1] == 0x49 {
            byteOrder = .littleEndian
        } else {
            return nil
        }

        guard readUInt16(data, at: tiffStart + 2, byteOrder: byteOrder) == 42,
              let ifdOffset = readUInt32(data, at: tiffStart + 4, byteOrder: byteOrder) else {
            return nil
        }

        let ifdStart = tiffStart + Int(ifdOffset)
        guard ifdStart + 2 <= payloadEnd,
              let entryCount = readUInt16(data, at: ifdStart, byteOrder: byteOrder) else {
            return nil
        }

        for entryIndex in 0 ..< Int(entryCount) {
            let entryStart = ifdStart + 2 + entryIndex * 12
            guard entryStart + 12 <= payloadEnd,
                  readUInt16(data, at: entryStart, byteOrder: byteOrder) == 0xb002,
                  let valueCount = readUInt32(data, at: entryStart + 4, byteOrder: byteOrder),
                  let valueOffset = readUInt32(data, at: entryStart + 8, byteOrder: byteOrder) else {
                continue
            }

            let mpEntryStart = tiffStart + Int(valueOffset)
            guard valueCount >= 32,
                  mpEntryStart + Int(valueCount) <= payloadEnd else {
                return nil
            }

            return MPFEntryPositions(
                byteOrder: byteOrder,
                tiffStart: tiffStart,
                primaryLengthOffset: mpEntryStart + 4,
                primaryStartOffset: mpEntryStart + 8,
                secondaryLengthOffset: mpEntryStart + 20,
                secondaryStartOffset: mpEntryStart + 24
            )
        }

        return nil
    }

    private static func updateMPFEntries(
        in data: inout Data,
        entries: MPFEntryPositions,
        primaryImageLength: Int,
        secondaryImageStart: Int,
        secondaryImageLength: Int,
        tiffStartOffsetAdjustment: Int = 0
    ) -> Bool {
        let patchedTIFFStart = entries.tiffStart + tiffStartOffsetAdjustment
        guard secondaryImageStart >= patchedTIFFStart,
              let primaryLength = UInt32(exactly: primaryImageLength),
              let secondaryLength = UInt32(exactly: secondaryImageLength),
              let secondaryRelativeStart = UInt32(exactly: secondaryImageStart - patchedTIFFStart)
        else {
            return false
        }

        writeUInt32(&data, at: entries.primaryLengthOffset, value: primaryLength, byteOrder: entries.byteOrder)
        writeUInt32(&data, at: entries.primaryStartOffset, value: 0, byteOrder: entries.byteOrder)
        writeUInt32(&data, at: entries.secondaryLengthOffset, value: secondaryLength, byteOrder: entries.byteOrder)
        writeUInt32(
            &data,
            at: entries.secondaryStartOffset,
            value: secondaryRelativeStart,
            byteOrder: entries.byteOrder
        )

        return true
    }

    private static func readISOGainMapMetadata(
        in data: Data,
        imageStart: Int,
        imageEnd: Int
    ) -> GainMapMetadata? {
        let isoNamespaceData = Data("urn:iso:std:iso:ts:21496:-1\u{0}".utf8)
        var offset = imageStart + 2

        while offset + 3 < imageEnd {
            guard data[offset] == 0xff else { return nil }

            let marker = data[offset + 1]
            if marker == 0xda || marker == 0xd9 {
                return nil
            }

            guard let segmentLength = readUInt16(data, at: offset + 2, byteOrder: .bigEndian),
                  segmentLength >= 2 else {
                return nil
            }

            let payloadStart = offset + 4
            let payloadLength = Int(segmentLength) - 2
            let segmentEnd = payloadStart + payloadLength
            guard segmentEnd <= imageEnd else { return nil }

            if marker == 0xe2,
               payloadLength > isoNamespaceData.count,
               data[payloadStart ..< payloadStart + isoNamespaceData.count].elementsEqual(isoNamespaceData) {
                return parseISOGainMapMetadata(
                    in: data,
                    start: payloadStart + isoNamespaceData.count,
                    end: segmentEnd
                )
            }

            offset = segmentEnd
        }

        return nil
    }

    private static func parseISOGainMapMetadata(
        in data: Data,
        start: Int,
        end: Int
    ) -> GainMapMetadata? {
        var offset = start

        guard offset + 5 <= end else { return nil }
        guard readUInt16(data, at: offset, byteOrder: .bigEndian) == 0,
              readUInt16(data, at: offset + 2, byteOrder: .bigEndian) == 0 else { return nil }
        offset += 4

        let flags = data[offset]
        guard flags & 0x40 != 0, flags & 0x37 == 0 else { return nil }
        offset += 1

        let channelCount = (flags & 0x80) == 0 ? 1 : 3
        let usesCommonDenominator = (flags & 0x08) != 0

        var gainMapMin = [Double](repeating: 0, count: 3)
        var gainMapMax = [Double](repeating: 0, count: 3)
        var gamma = [Double](repeating: 1, count: 3)
        var offsetSDR = [Double](repeating: 0, count: 3)
        var offsetHDR = [Double](repeating: 0, count: 3)
        var hdrCapacityMin = 0.0
        var hdrCapacityMax = 0.0

        if usesCommonDenominator {
            guard offset + 12 + channelCount * 20 <= end,
                  let denominator = readUInt32(data, at: offset, byteOrder: .bigEndian),
                  denominator != 0,
                  let baseHeadroomNumerator = readUInt32(data, at: offset + 4, byteOrder: .bigEndian),
                  let alternateHeadroomNumerator = readUInt32(data, at: offset + 8, byteOrder: .bigEndian) else {
                return nil
            }

            offset += 12
            hdrCapacityMin = fractionValue(baseHeadroomNumerator, denominator)
            hdrCapacityMax = fractionValue(alternateHeadroomNumerator, denominator)

            for channelIndex in 0 ..< channelCount {
                guard let minNumerator = readInt32(data, at: offset, byteOrder: .bigEndian),
                      let maxNumerator = readInt32(data, at: offset + 4, byteOrder: .bigEndian),
                      let gammaNumerator = readUInt32(data, at: offset + 8, byteOrder: .bigEndian),
                      let offsetSDRNumerator = readInt32(data, at: offset + 12, byteOrder: .bigEndian),
                      let offsetHDRNumerator = readInt32(data, at: offset + 16, byteOrder: .bigEndian) else {
                    return nil
                }

                gainMapMin[channelIndex] = fractionValue(minNumerator, denominator)
                gainMapMax[channelIndex] = fractionValue(maxNumerator, denominator)
                gamma[channelIndex] = fractionValue(gammaNumerator, denominator)
                offsetSDR[channelIndex] = fractionValue(offsetSDRNumerator, denominator)
                offsetHDR[channelIndex] = fractionValue(offsetHDRNumerator, denominator)
                offset += 20
            }
        } else {
            guard offset + 16 + channelCount * 40 <= end,
                  let baseHeadroomNumerator = readUInt32(data, at: offset, byteOrder: .bigEndian),
                  let baseHeadroomDenominator = readUInt32(data, at: offset + 4, byteOrder: .bigEndian),
                  let alternateHeadroomNumerator = readUInt32(data, at: offset + 8, byteOrder: .bigEndian),
                  let alternateHeadroomDenominator = readUInt32(data, at: offset + 12, byteOrder: .bigEndian),
                  baseHeadroomDenominator != 0,
                  alternateHeadroomDenominator != 0 else {
                return nil
            }

            offset += 16
            hdrCapacityMin = fractionValue(baseHeadroomNumerator, baseHeadroomDenominator)
            hdrCapacityMax = fractionValue(alternateHeadroomNumerator, alternateHeadroomDenominator)

            for channelIndex in 0 ..< channelCount {
                guard let minNumerator = readInt32(data, at: offset, byteOrder: .bigEndian),
                      let minDenominator = readUInt32(data, at: offset + 4, byteOrder: .bigEndian),
                      let maxNumerator = readInt32(data, at: offset + 8, byteOrder: .bigEndian),
                      let maxDenominator = readUInt32(data, at: offset + 12, byteOrder: .bigEndian),
                      let gammaNumerator = readUInt32(data, at: offset + 16, byteOrder: .bigEndian),
                      let gammaDenominator = readUInt32(data, at: offset + 20, byteOrder: .bigEndian),
                      let offsetSDRNumerator = readInt32(data, at: offset + 24, byteOrder: .bigEndian),
                      let offsetSDRDenominator = readUInt32(data, at: offset + 28, byteOrder: .bigEndian),
                      let offsetHDRNumerator = readInt32(data, at: offset + 32, byteOrder: .bigEndian),
                      let offsetHDRDenominator = readUInt32(data, at: offset + 36, byteOrder: .bigEndian),
                      minDenominator != 0,
                      maxDenominator != 0,
                      gammaDenominator != 0,
                      offsetSDRDenominator != 0,
                      offsetHDRDenominator != 0 else {
                    return nil
                }

                gainMapMin[channelIndex] = fractionValue(minNumerator, minDenominator)
                gainMapMax[channelIndex] = fractionValue(maxNumerator, maxDenominator)
                gamma[channelIndex] = fractionValue(gammaNumerator, gammaDenominator)
                offsetSDR[channelIndex] = fractionValue(offsetSDRNumerator, offsetSDRDenominator)
                offsetHDR[channelIndex] = fractionValue(offsetHDRNumerator, offsetHDRDenominator)
                offset += 40
            }
        }

        if channelCount == 1 {
            for index in 1 ... 2 {
                gainMapMin[index] = gainMapMin[0]
                gainMapMax[index] = gainMapMax[0]
                gamma[index] = gamma[0]
                offsetSDR[index] = offsetSDR[0]
                offsetHDR[index] = offsetHDR[0]
            }
        }

        guard gainMapMin.allSatisfy({ $0 == gainMapMin[0] }),
              gainMapMax.allSatisfy({ $0 == gainMapMax[0] }),
              gamma.allSatisfy({ $0 == gamma[0] && $0 > 0 }),
              offsetSDR.allSatisfy({ $0 == offsetSDR[0] }),
              offsetHDR.allSatisfy({ $0 == offsetHDR[0] }),
              gainMapMax[0] >= gainMapMin[0],
              hdrCapacityMax > hdrCapacityMin else { return nil }

        return GainMapMetadata(
            gainMapMin: gainMapMin[0],
            gainMapMax: gainMapMax[0],
            gamma: gamma[0],
            offsetSDR: offsetSDR[0],
            offsetHDR: offsetHDR[0],
            hdrCapacityMin: hdrCapacityMin,
            hdrCapacityMax: hdrCapacityMax
        )
    }

    private static func makeJPEGAPP1XMPData(xml: String) -> Data? {
        let xmpNamespace = Data("http://ns.adobe.com/xap/1.0/\u{0}".utf8)
        let xmlData = Data(xml.utf8)
        let segmentLength = 2 + xmpNamespace.count + xmlData.count
        guard segmentLength <= Int(UInt16.max) else { return nil }

        var segmentData = Data([0xff, 0xe1])
        segmentData.append(UInt8(segmentLength >> 8))
        segmentData.append(UInt8(segmentLength & 0xff))
        segmentData.append(xmpNamespace)
        segmentData.append(xmlData)

        return segmentData
    }

    private static func makePrimaryXMP(secondaryImageLength: Int) -> String {
        """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 5.1.2"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:Container="http://ns.google.com/photos/1.0/container/" xmlns:Item="http://ns.google.com/photos/1.0/container/item/" xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/" hdrgm:Version="1.0"><Container:Directory><rdf:Seq><rdf:li rdf:parseType="Resource"><Container:Item Item:Semantic="Primary" Item:Mime="image/jpeg"/></rdf:li><rdf:li rdf:parseType="Resource"><Container:Item Item:Semantic="GainMap" Item:Mime="image/jpeg" Item:Length="\(secondaryImageLength)"/></rdf:li></rdf:Seq></Container:Directory></rdf:Description></rdf:RDF></x:xmpmeta>
        """
    }

    private static func makeSecondaryXMP(metadata: GainMapMetadata) -> String {
        """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 5.1.2"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/" hdrgm:Version="1.0" hdrgm:GainMapMin="\(formatNumber(metadata.gainMapMin))" hdrgm:GainMapMax="\(formatNumber(metadata.gainMapMax))" hdrgm:Gamma="\(formatNumber(metadata.gamma))" hdrgm:OffsetSDR="\(formatNumber(metadata.offsetSDR))" hdrgm:OffsetHDR="\(formatNumber(metadata.offsetHDR))" hdrgm:HDRCapacityMin="\(formatNumber(metadata.hdrCapacityMin))" hdrgm:HDRCapacityMax="\(formatNumber(metadata.hdrCapacityMax))" hdrgm:BaseRenditionIsHDR="False"/></rdf:RDF></x:xmpmeta>
        """
    }

    private static func fractionValue(_ numerator: UInt32, _ denominator: UInt32) -> Double {
        Double(numerator) / Double(denominator)
    }

    private static func fractionValue(_ numerator: Int32, _ denominator: UInt32) -> Double {
        Double(numerator) / Double(denominator)
    }

    private static func readUInt16(_ data: Data, at offset: Int, byteOrder: TIFFByteOrder) -> UInt16? {
        guard offset >= 0, offset + 1 < data.count else { return nil }

        switch byteOrder {
        case .bigEndian:
            return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
        case .littleEndian:
            return UInt16(data[offset + 1]) << 8 | UInt16(data[offset])
        }
    }

    private static func readUInt32(_ data: Data, at offset: Int, byteOrder: TIFFByteOrder) -> UInt32? {
        guard offset >= 0, offset + 3 < data.count else { return nil }

        switch byteOrder {
        case .bigEndian:
            return UInt32(data[offset]) << 24 |
                UInt32(data[offset + 1]) << 16 |
                UInt32(data[offset + 2]) << 8 |
                UInt32(data[offset + 3])
        case .littleEndian:
            return UInt32(data[offset + 3]) << 24 |
                UInt32(data[offset + 2]) << 16 |
                UInt32(data[offset + 1]) << 8 |
                UInt32(data[offset])
        }
    }

    private static func readInt32(_ data: Data, at offset: Int, byteOrder: TIFFByteOrder) -> Int32? {
        guard let unsignedValue = readUInt32(data, at: offset, byteOrder: byteOrder) else {
            return nil
        }

        return Int32(bitPattern: unsignedValue)
    }

    private static func writeUInt32(
        _ data: inout Data,
        at offset: Int,
        value: UInt32,
        byteOrder: TIFFByteOrder
    ) {
        guard offset >= 0, offset + 3 < data.count else { return }

        switch byteOrder {
        case .bigEndian:
            data[offset] = UInt8((value >> 24) & 0xff)
            data[offset + 1] = UInt8((value >> 16) & 0xff)
            data[offset + 2] = UInt8((value >> 8) & 0xff)
            data[offset + 3] = UInt8(value & 0xff)
        case .littleEndian:
            data[offset] = UInt8(value & 0xff)
            data[offset + 1] = UInt8((value >> 8) & 0xff)
            data[offset + 2] = UInt8((value >> 16) & 0xff)
            data[offset + 3] = UInt8((value >> 24) & 0xff)
        }
    }
}
