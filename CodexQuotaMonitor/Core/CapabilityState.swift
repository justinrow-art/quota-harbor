import Foundation

enum CapabilityFailure: Equatable, Sendable {
    case unauthenticated
    case unsupportedAuthMode
    case invalidSchema
    case temporaryTransport
    case temporaryBackend
    case serverRejected
    case binaryNotFound
    case trustValidationFailed
    case processLaunchFailed
    case stale
}

enum CapabilityState<Value: Equatable & Sendable>: Equatable, Sendable {
    case loading
    case fresh(Value, Date)
    case stale(Value, Date, CapabilityFailure)
    case unsupported
    case unavailable(CapabilityFailure)
}

enum GenerationComponent: Equatable, Sendable {
    case auth
    case session
    case connection
}

enum GenerationAdvanceError: Error, Equatable, Sendable {
    case overflow(GenerationComponent)
}

struct GenerationToken: Equatable, Hashable, Sendable {
    let auth: UInt64
    let session: UInt64
    let connection: UInt64

    func advanced(_ component: GenerationComponent) throws -> GenerationToken {
        switch component {
        case .auth:
            return GenerationToken(
                auth: try Self.increment(auth, component: component),
                session: 0,
                connection: 0
            )
        case .session:
            return GenerationToken(
                auth: auth,
                session: try Self.increment(session, component: component),
                connection: 0
            )
        case .connection:
            return GenerationToken(
                auth: auth,
                session: session,
                connection: try Self.increment(connection, component: component)
            )
        }
    }

    private static func increment(
        _ value: UInt64,
        component: GenerationComponent
    ) throws -> UInt64 {
        let result = value.addingReportingOverflow(1)
        guard !result.overflow else {
            throw GenerationAdvanceError.overflow(component)
        }
        return result.partialValue
    }
}
