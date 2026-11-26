import Foundation
@testable import SimBridge
import Testing

/// Stands in for AXPTranslatorRequest, which declares both keys as
/// unsigned integers.
final class FakeRequest: NSObject {
    @objc dynamic var requestType: UInt64
    @objc dynamic var clientType: UInt64

    init(requestType: UInt64, clientType: UInt64 = 0) {
        self.requestType = requestType
        self.clientType = clientType
    }
}

/// Has a request type but no client type to set.
final class RequestWithoutClientType: NSObject {
    @objc dynamic var requestType: UInt64 = 2
}

/// The real request class, from the private framework, when this Mac has it.
let translatorRequestClass: NSObject.Type? = {
    let path = "/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation"
    guard dlopen(path, RTLD_NOW) != nil else { return nil }
    return NSClassFromString("AXPTranslatorRequest") as? NSObject.Type
}()

@Suite struct AXClientTypeTests {
    @Test(arguments: [0, 1, 2, 3, 4, 5, 7] as [UInt64])
    func attributeAndOtherRequestsAskForTheAutomationTree(requestType: UInt64) {
        let request = FakeRequest(requestType: requestType)
        AXClientType.apply(to: request)
        #expect(request.clientType == 2)
    }

    @Test func pointHitTestKeepsTheTranslatorsClientType() {
        let request = FakeRequest(requestType: 6, clientType: 1)
        AXClientType.apply(to: request)
        #expect(request.clientType == 1)
    }

    @Test func objectsWithoutTheKeysAreLeftAlone() {
        AXClientType.apply(to: RequestWithoutClientType())
        AXClientType.apply(to: NSObject())
        AXClientType.apply(to: NSNull())
    }

    @Test(.enabled(if: translatorRequestClass != nil))
    func theTranslatorsRequestClassTakesTheKeys() throws {
        let cls = try #require(translatorRequestClass)
        let attribute = cls.init()
        attribute.setValue(NSNumber(value: 2), forKey: "requestType")
        AXClientType.apply(to: attribute)
        #expect((attribute.value(forKey: "clientType") as? NSNumber)?.intValue == 2)

        let point = cls.init()
        point.setValue(NSNumber(value: 6), forKey: "requestType")
        AXClientType.apply(to: point)
        #expect((point.value(forKey: "clientType") as? NSNumber)?.intValue == 0)
    }
}
