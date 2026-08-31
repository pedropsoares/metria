import Foundation

enum MetriaResources {
    static var bundle: Bundle {
#if SWIFT_PACKAGE
        Bundle.module
#else
        Bundle.main
#endif
    }
}
