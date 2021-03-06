//
//  Archive+MemoryFile.swift
//  ZIPFoundation
//
//  Copyright © 2017-2020 Thomas Zoechling, https://www.peakstep.com and the ZIP Foundation project authors.
//  Released under the MIT License.
//
//  See https://github.com/weichsel/ZIPFoundation/blob/master/LICENSE for license information.
//

import Foundation

//#if swift(>=5.0)

extension Archive {
    /// Returns an `Data` object containing a representation of the receiver.
    public var data: Data? { return memoryFile?.data }

    static func configureMemoryBacking(for data: Data, mode: AccessMode)
        -> (UnsafeMutablePointer<FILE>, MemoryFile)? {
            let posixMode: String
            switch mode {
            case .read: posixMode = "rb"
            case .create: posixMode = "wb+"
            case .update: posixMode = "rb+"
            }
            let memoryFile = MemoryFile(data: data)
            guard let archiveFile = memoryFile.open(mode: posixMode) else { return nil }

            if mode == .create {
                let endOfCentralDirectoryRecord = EndOfCentralDirectoryRecord(numberOfDisk: 0, numberOfDiskStart: 0,
                                                                              totalNumberOfEntriesOnDisk: 0,
                                                                              totalNumberOfEntriesInCentralDirectory: 0,
                                                                              sizeOfCentralDirectory: 0,
                                                                              offsetToStartOfCentralDirectory: 0,
                                                                              zipFileCommentLength: 0,
                                                                              zipFileCommentData: Data())
                _ = endOfCentralDirectoryRecord.data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                    fwrite(buffer.baseAddress, buffer.count, 1, archiveFile) // Errors handled during read
                }
            }
            return (archiveFile, memoryFile)
    }
}

class MemoryFile {
    private(set) var data: Data
    private var offset  = 0

    init(data: Data = Data()) {
        self.data = data
    }

    func open(mode: String) -> UnsafeMutablePointer<FILE>? {
        let cookie = Unmanaged.passRetained(self)
        let writable = mode.count > 0 && (mode.first! != "r" || mode.last! == "+")
        let append = mode.count > 0 && mode.first! == "a"
        #if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
        let result = writable
            ? funopen(cookie.toOpaque(), readStub, writeStub, seekStub, closeStub)
            : funopen(cookie.toOpaque(), readStub, nil, seekStub, closeStub)
        #else
        let stubs = cookie_io_functions_t(read: readStub, write: writeStub, seek: seekStub, close: closeStub)
        let result = fopencookie(cookie.toOpaque(), mode, stubs)
        #endif
        if append {
            fseek(result, 0, SEEK_END)
        }
        return result
    }
}

private extension MemoryFile {
    func readData(buffer: UnsafeMutableRawBufferPointer) -> Int {
        let size = min(buffer.count, data.count-offset)
        let start = data.startIndex
        data.copyBytes(to: buffer.bindMemory(to: UInt8.self), from: start+offset..<start+offset+size)
        offset += size
        return size
    }

    func writeData(buffer: UnsafeRawBufferPointer) -> Int {
        let start = data.startIndex
        if offset < data.count && offset+buffer.count > data.count {
            data.removeSubrange(start+offset..<start+data.count)
        } else if offset > data.count {
            data.append(Data(count: offset-data.count))
        }
        if offset == data.count {
            data.append(buffer.bindMemory(to: UInt8.self))
        } else {
            let start = data.startIndex // May have changed in earlier mutation
            data.replaceSubrange(start+offset..<start+offset+buffer.count, with: buffer.bindMemory(to: UInt8.self))
        }
        offset += buffer.count
        return buffer.count
    }

    func seek(offset: Int, whence: Int32) -> Int {
        switch whence {
        case SEEK_SET:
            self.offset = offset
        case SEEK_CUR:
            self.offset += offset
        case SEEK_END:
            self.offset = data.count+offset
        default:
            assertionFailure("Unknown seek whence \(whence)")
        }
        return self.offset
    }
}

private func fileFromCookie(cookie: UnsafeRawPointer) -> MemoryFile {
    return Unmanaged<MemoryFile>.fromOpaque(cookie).takeUnretainedValue()
}

private func closeStub(_ cookie: UnsafeMutableRawPointer?) -> Int32 {
    if let cookie = cookie {
        Unmanaged<MemoryFile>.fromOpaque(cookie).release()
    }
    return 0
}

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
private func readStub(_ cookie: UnsafeMutableRawPointer?,
                      _ bytePtr: UnsafeMutablePointer<Int8>?,
                      _ count: Int32) -> Int32 {
    guard let cookie = cookie, let bytePtr = bytePtr else { return 0 }
    return Int32(fileFromCookie(cookie: cookie).readData(
        buffer: UnsafeMutableRawBufferPointer(start: bytePtr, count: Int(count))))
}

private func writeStub(_ cookie: UnsafeMutableRawPointer?,
                       _ bytePtr: UnsafePointer<Int8>?,
                       _ count: Int32) -> Int32 {
    guard let cookie = cookie, let bytePtr = bytePtr else { return 0 }
    return Int32(fileFromCookie(cookie: cookie).writeData(
        buffer: UnsafeRawBufferPointer(start: bytePtr, count: Int(count))))
}

private func seekStub(_ cookie: UnsafeMutableRawPointer?,
                      _ offset: fpos_t,
                      _ whence: Int32) -> fpos_t {
    guard let cookie = cookie else { return 0 }
    return fpos_t(fileFromCookie(cookie: cookie).seek(offset: Int(offset), whence: whence))
}

#else
private func readStub(_ cookie: UnsafeMutableRawPointer?,
                      _ bytePtr: UnsafeMutablePointer<Int8>?,
                      _ count: Int) -> Int {
    guard let cookie = cookie, let bytePtr = bytePtr else { return 0 }
    return fileFromCookie(cookie: cookie).readData(
        buffer: UnsafeMutableRawBufferPointer(start: bytePtr, count: count))
}

private func writeStub(_ cookie: UnsafeMutableRawPointer?,
                       _ bytePtr: UnsafePointer<Int8>?,
                       _ count: Int) -> Int {
    guard let cookie = cookie, let bytePtr = bytePtr else { return 0 }
    return fileFromCookie(cookie: cookie).writeData(
        buffer: UnsafeRawBufferPointer(start: bytePtr, count: count))
}

private func seekStub(_ cookie: UnsafeMutableRawPointer?,
                      _ offset: UnsafeMutablePointer<Int>?,
                      _ whence: Int32) -> Int32 {
    guard let cookie = cookie, let offset = offset else { return 0 }
    let result = fileFromCookie(cookie: cookie).seek(offset: Int(offset.pointee), whence: whence)
    if result >= 0 {
        offset.pointee = result
        return 0
    } else {
        return -1
    }
}
#endif
//#endif
