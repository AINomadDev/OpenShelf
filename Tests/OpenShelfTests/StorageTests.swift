import XCTest
@testable import OpenShelf

final class StorageTests: XCTestCase {
    func testProvidersNeverShareRemoteMountOrCache() {
        let home = URL(fileURLWithPath: "/tmp/openshelf-test")
        let google = Storage.googleDrive
        let apple = Storage.iCloud
        XCTAssertNotEqual(google.remote, apple.remote)
        XCTAssertNotEqual(google.mountPoint(home: home), apple.mountPoint(home: home))
        XCTAssertNotEqual(google.cache(home: home), apple.cache(home: home))
        for storage in Storage.legacy {
            let args = storage.arguments(home: home)
            XCTAssertEqual(Array(args.prefix(3)), ["nfsmount", "\(storage.remote):", storage.mountPoint(home: home).path])
            let index = args.firstIndex(of: "--cache-dir")!
            XCTAssertEqual(args[index + 1], storage.cache(home: home).path)
            XCTAssertFalse(args.contains("--allow-non-empty"))
            XCTAssertFalse(args.contains("--daemon"))
        }
    }
}
