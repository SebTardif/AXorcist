import ApplicationServices
import Foundation

private struct ObserveNotificationError: Error {
    let message: String
}

@MainActor
func observationDetailText(element: Element, names: [String]) -> String? {
    guard !names.isEmpty else { return nil }
    return names.map { name in
        let value = element.rawAttributeValue(named: name)
        let text = value.map { String(describing: $0) } ?? "nil"
        return "\(name)=\(text)"
    }.joined(separator: ", ")
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
        self.handleObserve(
            command: command,
            traversalOptions: traversalOptions,
            now: { ProcessInfo.processInfo.systemUptime })
    }

    func handleObserve(
        command: ObserveCommand,
        traversalOptions: AXTraversalOptions,
        now: @escaping AXTraversalClock) -> AXResponse
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

        let callback = self.makeObservationCallback(details: command.includeElementDetails)
        let elements = self.elementsToObserve(
            root: elementToObserve,
            command: command,
            timeout: traversalOptions.timeout,
            now: now)
        return self.startObservation(
            elements: elements,
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

    private func elementsToObserve(
        root: Element,
        command: ObserveCommand,
        timeout: TimeInterval,
        now: @escaping AXTraversalClock) -> [Element]
    {
        guard command.watchChildren else { return [root] }
        var ordered = [root]
        var seen: Set<CFHashCode> = [CFHash(root.underlyingElement)]
        traverseAXTree(
            from: root,
            maxDepth: max(command.maxDepthForSearch, 0),
            strictChildren: true,
            timeout: timeout,
            now: now,
            children: { element, _ in self.observationChildren(of: element) },
            onTimeout: {
                GlobalAXLogger.shared.log(AXLogEntry(
                    level: .warning,
                    message: "HandleObserve: traversal timeout (\(timeout)s) reached. Stopping child walk."))
            },
            visit: { element, _ in
                let identity = CFHash(element.underlyingElement)
                if seen.insert(identity).inserted {
                    ordered.append(element)
                }
                return .continueTraversal
            })
        return ordered
    }

    private func startObservation(
        elements: [Element],
        notifications: [AXNotification],
        callback: @escaping AXNotificationSubscriptionHandler) -> AXResponse
    {
        let names = notifications.map(\.rawValue).joined(separator: ", ")
        var subscribed: [SubscriptionToken] = []
        for element in elements {
            for notification in notifications {
                switch self.subscribeToObservation(
                    pid: element.pid(),
                    element: element,
                    notification: notification,
                    handler: callback)
                {
                case let .success(token):
                    subscribed.append(token)
                case let .failure(error):
                    self.rollbackObservationSubscriptions(subscribed)
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
        }
        guard let target = elements.first else {
            return .errorResponse(
                message: "HandleObserve: no element to observe.",
                code: .observationFailed)
        }
        let successMessage = [
            "HandleObserve: Successfully started observing '\(names)' on",
            "\(elements.count) element(s) from",
            target.briefDescription(option: ValueFormatOption.smart),
        ].joined(separator: " ")
        GlobalAXLogger.shared.log(AXLogEntry(level: .info, message: successMessage))
        return .successResponse(payload: AnyCodable(["message": successMessage]))
    }

    private func makeObservationCallback(details: [String]?) -> AXNotificationSubscriptionHandler {
        let names = details ?? []
        return { _, notification, axUIElement, userInfo in
            let element = Element(axUIElement)
            let userInfoDesc = userInfo.map(String.init(describing:)) ?? "nil"
            var parts = [
                "AXObserver CALLBACK:",
                "Element: \(element.briefDescription(option: ValueFormatOption.smart))",
                "Notification: \(notification.rawValue)",
                "UserInfo: \(userInfoDesc)",
            ]
            if let rendered = observationDetailText(element: element, names: names) {
                parts.append("Details: \(rendered)")
            }
            GlobalAXLogger.shared.log(AXLogEntry(
                level: .info,
                message: parts.joined(separator: " ")))
        }
    }
}
