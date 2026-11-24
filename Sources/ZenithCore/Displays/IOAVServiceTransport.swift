import Foundation
import IOKit

/// The private `IOAVService` calls, looked up at run time. A missing symbol means "no DDC on this Mac", never a crash.
enum IOAVServiceAPI {
    typealias CreateWithService = @convention(c) (CFAllocator?, io_service_t) -> UnsafeMutableRawPointer?
    typealias Transfer = @convention(c) (UnsafeRawPointer, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32

    struct Functions: @unchecked Sendable {
        let createWithService: CreateWithService
        let readI2C: Transfer
        let writeI2C: Transfer
    }

    static let functions: Functions? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let create = dlsym(handle, "IOAVServiceCreateWithService"),
              let read = dlsym(handle, "IOAVServiceReadI2C"),
              let write = dlsym(handle, "IOAVServiceWriteI2C") else { return nil }
        return Functions(
            createWithService: unsafeBitCast(create, to: CreateWithService.self),
            readI2C: unsafeBitCast(read, to: Transfer.self),
            writeI2C: unsafeBitCast(write, to: Transfer.self)
        )
    }()
}

/// The real DDC bus of one external display: Apple silicon's `IOAVService`, created from a `DCPAVServiceProxy`
/// registry entry. Calls block for the time the bus needs.
public final class IOAVServiceTransport: DDCTransport, @unchecked Sendable {
    /// The `IOAVServiceRef` (a CF object), owned by this instance.
    private let service: UnsafeMutableRawPointer

    /// `nil` if the private calls are missing or the proxy gives no service.
    init?(proxy: io_service_t) {
        guard let functions = IOAVServiceAPI.functions,
              let service = functions.createWithService(kCFAllocatorDefault, proxy) else { return nil }
        self.service = service
    }

    deinit {
        Unmanaged<AnyObject>.fromOpaque(service).release()
    }

    public func write(chip: UInt8, offset: UInt8, bytes: [UInt8]) -> Bool {
        guard let functions = IOAVServiceAPI.functions else { return false }
        var buffer = bytes
        return buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return false }
            return functions.writeI2C(UnsafeRawPointer(service), UInt32(chip), UInt32(offset), base, UInt32(bytes.count)) == 0
        }
    }

    public func read(chip: UInt8, offset: UInt8, count: Int) -> [UInt8]? {
        guard let functions = IOAVServiceAPI.functions, count > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: count)
        let status = buffer.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return functions.readI2C(UnsafeRawPointer(service), UInt32(chip), UInt32(offset), base, UInt32(count))
        }
        return status == 0 ? buffer : nil
    }
}
