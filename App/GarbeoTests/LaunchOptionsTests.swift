import Foundation
import Testing
@testable import Garbeo

/// Unit tests run hosted in the app, which keeps them away from the user's settings and Keychain.
@Suite struct LaunchOptionsTests {
    @Test func hostedTestsAreEphemeral() {
        #expect(LaunchOptions.isHostingUnitTests)
        #expect(LaunchOptions.isEphemeral)
        #expect(UserDefaults.app !== UserDefaults.standard)
    }

    @Test func secretsStayInMemory() {
        let account = "test:\(UUID().uuidString)"
        Keychain.setPassword("hunter2", for: account)
        #expect(Keychain.password(for: account) == "hunter2")
        Keychain.setPassword(nil, for: account)
        #expect(Keychain.password(for: account) == nil)
    }
}
