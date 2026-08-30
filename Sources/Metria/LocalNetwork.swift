import Darwin
import Foundation

enum LocalNetwork {
    static func primaryIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let interfaces else { return nil }
        defer { freeifaddrs(interfaces) }

        var addresses: [(name: String, address: String)] = []
        var current: UnsafeMutablePointer<ifaddrs>? = interfaces
        while let interface = current {
            defer { current = interface.pointee.ifa_next }
            guard let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  (interface.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }

            var ipv4Address = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ipv4Address.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            addresses.append((String(cString: interface.pointee.ifa_name), String(cString: buffer)))
        }

        return addresses.first(where: { $0.name == "en0" })?.address
            ?? addresses.first(where: { $0.name.hasPrefix("en") })?.address
            ?? addresses.first?.address
    }
}
