import Testing
@testable import axorc
@testable import AXorcist

@Suite("Observe conversion")
@MainActor
struct ObserveConversionTests {
    @Test
    func `observe conversion keeps every valid notification`() {
        let envelope = CommandEnvelope(
            commandId: "observe",
            command: .observe,
            notifications: ["AXValueChanged", "AXFocusedUIElementChanged"])

        guard case let .observe(command)? = envelope.command.toAXCommand(commandEnvelope: envelope) else {
            Issue.record("Expected an observe command")
            return
        }

        #expect(command.notifications == ["AXValueChanged", "AXFocusedUIElementChanged"])
        #expect(command.notificationName == .valueChanged)
    }

    @Test
    func `observe conversion rejects an invalid later notification`() {
        let envelope = CommandEnvelope(
            commandId: "observe",
            command: .observe,
            notifications: ["AXValueChanged", "NotANotification"])

        #expect(envelope.command.toAXCommand(commandEnvelope: envelope) == nil)
    }
}
