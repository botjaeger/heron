import Foundation
import Testing

@testable import HeronCore

/// Process rows are named after their app and grouped; the Mac is named from the device tree.
@Suite struct AppNamingTests {
    @Test func helpersAreNamedAfterTheOutermostApp() {
        let edge =
            "/Applications/Microsoft Edge.app/Contents/Frameworks/Microsoft Edge Framework.framework/Versions/131.0/Helpers/Microsoft Edge Helper (Renderer).app/Contents/MacOS/Microsoft Edge Helper (Renderer)"
        #expect(ProcessNaming.appBundle(path: edge) == "/Applications/Microsoft Edge.app")
        #expect(ProcessNaming.appBundle(path: "/Applications/Safari.app/Contents/MacOS/Safari") == "/Applications/Safari.app")
        let xpc =
            "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
        #expect(ProcessNaming.appBundle(path: xpc) == "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc")
        #expect(ProcessNaming.appBundle(path: "/opt/homebrew/bin/node") == nil)
        #expect(ProcessNaming.appBundle(path: "/Applications/Foo.app") == nil)  // the bundle itself is not a process inside it
    }

    @Test func aBundleIsCalledByItsDisplayNameThenItsName() {
        #expect(ProcessNaming.bundleName(info: ["CFBundleDisplayName": "Microsoft Edge", "CFBundleName": "Edge"]) == "Microsoft Edge")
        #expect(ProcessNaming.bundleName(info: ["CFBundleDisplayName": " ", "CFBundleName": "Virtual Machine Service"]) == "Virtual Machine Service")
        #expect(ProcessNaming.bundleName(info: [:]) == nil)
    }

    @Test func rowsWithOneNameAreSummedIntoOne() {
        let rows = [
            ProcessUsage(pid: 1, name: "Microsoft Edge", cpu: 0.2, memory: 100),
            ProcessUsage(pid: 2, name: "node", cpu: 0.5, memory: 10),
            ProcessUsage(pid: 3, name: "Microsoft Edge", cpu: 0.1, memory: 50),
            ProcessUsage(pid: 4, name: "Microsoft Edge", cpu: 0.3, memory: 25),
        ]
        let grouped = ProcessNaming.grouped(rows)
        #expect(grouped.map(\.title) == ["Microsoft Edge (3)", "node"])
        #expect(grouped[0].pid == 1 && grouped[0].memory == 175 && abs(grouped[0].cpu - 0.6) < 1e-9)
        #expect(grouped[1].count == 1 && grouped[1].title == "node")
    }

    @Test func theMacIsNamedFromItsProductNameOrItsChip() {
        #expect(SystemInfo.shortProduct("MacBook Pro (14-inch, Nov 2023)") == "MacBook Pro 14″")
        #expect(SystemInfo.shortProduct("MacBook Air (13.6-inch, M2, 2022)") == "MacBook Air 13.6″")
        #expect(SystemInfo.shortProduct("Mac Studio (2023)") == "Mac Studio (2023)")
        #expect(SystemInfo.shortProduct("Mac mini") == "Mac mini")
        #expect(SystemInfo.friendlyName(product: "MacBook Pro (16-inch, Nov 2023)", chip: "Apple M3 Max") == "MacBook Pro 16″ · M3 Max")
        #expect(SystemInfo.friendlyName(product: nil, chip: "Apple M3 Max") == "Apple M3 Max")  // never a made-up name
        #expect(SystemInfo.productName(from: Data("MacBook Pro (14-inch, Nov 2023)\0".utf8)) == "MacBook Pro (14-inch, Nov 2023)")
        #expect(SystemInfo.productName(from: Data([0])) == nil)
    }
}
