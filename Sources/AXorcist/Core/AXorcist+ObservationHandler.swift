import ApplicationServices
import Foundation

private struct ObserveNotificationError: Error {
    let message: String
}

/// Extension providing accessibility notification observation handlers for AXorcist.
///
/// This extension handles:
/// - Setting up AXObserver instances for notifications
/// - Managing notification subscriptions and callbacks
/// - Real-time event monitoring and processing
/// - Element detail extraction for observed events
/// - Cleanup and lifecycle management of observers
@MainActor
extension AXorcist {
    public func handleObserve(command: ObserveCommand) -> AXResponse {
        self.handleObserve(command: command, traversalOptions: .snapshotDefaults())
    }

    public func handleObserve(
        command: ObserveCommand,
        traversalOptions: AXTraversalOptions) -> AXResponse
    {
        let notifications: [AXNotification]
        switch self.validatedNotifications(command.notifications) {
        case let .success(parsed):
            notifications = parsed
        case let .failure(error):
            GlobalAXLogger.shared.log(AXLogEntry(level: .error, message: error.message))
            return .errorResponse(message: error.message, code: .invalidParameter)
        }

        self.logObservationStart(command, notifications: notifications)

        let locator = command.locator ?? Locator(criteria: [
            Criterion(attribute: "AXRole", value: AXRoleNames.kAXApplicationRole, matchType: .exact),
        ])

        let elementToObserve: Element
        switch self.resolveObservationTarget(
            appIdentifier: command.appIdentifier,
            pid: command.pid,
            locator: locator,
            maxDepth: command.maxDepthForSearch,
            traversalOptions: traversalOptions)
        {
        case let .success(resolvedElement):
            elementToObserve = resolvedElement
        case let .failure(error):
            GlobalAXLogger.shared.log(AXLogEntry(level: .error, message: error.message))
            return error.response
        }

        self.logObservationTarget(elementToObserve)

        let callback = self.makeObservationCallback()
        return self.startObservation(
            element: elementToObserve,
            notifications: notifications,
            callback: callback)
    }

    private func validatedNotifications(_ names: [String]) -> Result<[AXNotification], ObserveNotificationError> {
        guard !names.isEmpty else {
            return .failure(ObserveNotificationError(message: "HandleObserve: missing notifications."))
        }
        var parsed: [AXNotification] = []
        for name in names {
            guard let notification = AXNotification(rawValue: name) else {
                return .failure(ObserveNotificationError(
                    message: "HandleObserve: invalid notification name \(name)."))
            }
            parsed.append(notification)
        }
        return .success(parsed)
    }

    private func logObservationStart(_ command: ObserveCommand, notifications: [AXNotification]) {
        let details = command.includeElementDetails?.joined(separator: ", ") ?? "none"
        let names = notifications.map(\.rawValue).joined(separator: ", ")
        let message = [
            "HandleObserve: App \(command.appIdentifier ?? "focused")",
            "Notifications: \(names)",
            "Details: \(details)",
        ].joined(separator: ", ")
        GlobalAXLogger.shared.log(AXLogEntry(level: .info, message: message))
    }

    private func logObservationTarget(_ element: Element) {
        let message = [
            "HandleObserve: Element to observe:",
            element.briefDescription(option: ValueFormatOption.smart),
        ].joined(separator: " ")
        GlobalAXLogger.shared.log(AXLogEntry(level: .debug, message: message))
    }

    private func startObservation(
        element: Element,
        notifications: [AXNotification],
        callback: @escaping AXNotificationSubscriptionHandler) -> AXResponse
    {
        let names = notifications.map(\.rawValue).joined(separator: ", ")
        switch self.subscribeToNotifications(
            element: element,
            notifications: notifications,
            handler: callback)
        {
        case .success:
            let successMessage = [
                "HandleObserve: Successfully started observing '\(names)' on",
                element.briefDescription(option: ValueFormatOption.smart),
            ].joined(separator: " ")
            GlobalAXLogger.shared.log(AXLogEntry(level: .info, message: successMessage))
            return .successResponse(payload: AnyCodable(["message": successMessage]))
        case let .failure(error):
            let details = [
                "HandleObserve: Failed to add observer.",
                "Error: \(error.localizedDescription) (Code: \(error))",
                "Pid: \(element.pid()?.description ?? "N/A")",
                "Notifications: \(names)",
            ].joined(separator: " ")
            GlobalAXLogger.shared.log(AXLogEntry(level: .error, message: details))
            return .errorResponse(message: details, code: .observationFailed)
        }
    }

    private func makeObservationCallback() -> AXNotificationSubscriptionHandler {
        { _, notification, axUIElement, userInfo in
            let element = Element(axUIElement)
            let userInfoDesc = userInfo.map(String.init(describing:)) ?? "nil"
            let message = [
                "AXObserver CALLBACK:",
                "Element: \(element.briefDescription(option: ValueFormatOption.smart))",
                "Notification: \(notification.rawValue)",
                "UserInfo: \(userInfoDesc)",
            ].joined(separator: " ")
            GlobalAXLogger.shared.log(AXLogEntry(level: .info, message: message))
        }
    }
}
