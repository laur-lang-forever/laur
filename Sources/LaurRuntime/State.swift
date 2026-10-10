import Combine
import Foundation
import LaurCore

/// Holds every `state` value on a previewed screen.
///
/// Values are keyed by the owning component's context path plus the state name, like
/// `SignUpForm#email` or `Cart/Stepper[1]#value`. Keys survive hot reloads, so editing
/// the file keeps what you typed; `reset()` starts over.
public final class StateStore: ObservableObject {
    private var values: [String: Value] = [:]
    private var loads: [String: LoadState] = [:]
    /// What each load returns in a preview, once its simulated delay is over.
    private var simulations: [String: LoadState] = [:]
    /// Loads waiting to finish, with a generation number so a stale timer can't finish
    /// a load that was reset or restarted since.
    private var pending: [String: Int] = [:]
    private var generation = 0

    /// How long a simulated load takes in a preview, so the loading screen is visible.
    public var simulatedDelay: TimeInterval = 0.8
    /// Tests turn this off and call `completePendingLoads()` themselves.
    public var completesLoadsAutomatically = true

    /// Bumped on every change a person makes, so views know to re-render.
    @Published public private(set) var version = 0
    /// The last error an action hit, shown under the preview.
    @Published public var lastError: String?

    public init() {}

    public func value(_ key: String) -> Value? {
        values[key]
    }

    /// Sets a starting value while a screen is being resolved. Doesn't notify, because
    /// it happens during rendering.
    func initialize(_ key: String, _ value: Value) {
        if values[key] == nil {
            values[key] = value
        }
    }

    public func set(_ key: String, _ value: Value) {
        values[key] = value
        version += 1
    }

    public func reset() {
        values = [:]
        loads = [:]
        simulations = [:]
        pending = [:]
        lastError = nil
        version += 1
    }

    // MARK: - Loads

    public func loadState(_ key: String) -> LoadState? {
        loads[key]
    }

    /// Starts a load that will finish with `result` after the simulated delay.
    func startLoad(_ key: String, simulating result: LoadState) {
        guard loads[key] == nil else { return }
        loads[key] = .loading
        simulations[key] = result
        schedule(key)
    }

    /// Fixes a load at `state`, as a preview asks. `reload()` still simulates `result`.
    func pinLoad(_ key: String, at state: LoadState, simulating result: LoadState) {
        guard loads[key] == nil else { return }
        loads[key] = state
        simulations[key] = result
    }

    /// `orders.reload()`: back to loading, then the simulated result.
    public func reload(_ key: String) {
        loads[key] = .loading
        version += 1
        schedule(key)
    }

    /// Finishes every load that's waiting, immediately.
    public func completePendingLoads() {
        for (key, ticket) in pending {
            complete(key, ticket: ticket)
        }
    }

    public var hasPendingLoads: Bool { !pending.isEmpty }

    private func schedule(_ key: String) {
        generation += 1
        let ticket = generation
        pending[key] = ticket
        guard completesLoadsAutomatically else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + simulatedDelay) { [weak self] in
            self?.complete(key, ticket: ticket)
        }
    }

    private func complete(_ key: String, ticket: Int) {
        guard pending[key] == ticket else { return }
        pending[key] = nil
        loads[key] = simulations[key] ?? .failed(kind: "other", message: "Nothing to load.")
        version += 1
    }

    /// Every key and value, for tests and debugging.
    public var snapshot: [String: Value] { values }
}

/// Where a `load` is: what `when` switches on.
public enum LoadState: Equatable {
    case loading
    case failed(kind: String, message: String)
    case loaded(Value)

    /// The message a preview shows for `.failed(.network)` when it doesn't give one.
    static func defaultMessage(for kind: String) -> String {
        switch kind {
        case "network": return "The Internet connection appears to be offline."
        case "notFound": return "We couldn't find that."
        case "unauthorized": return "Please sign in again."
        case "server": return "Something went wrong on our end."
        default: return "Something went wrong."
        }
    }
}

/// What code inside one component instance can see and change.
public struct InstanceScope {
    /// Values by name: parameters, state, derived values, list items and `context`.
    public var values: Scope
    /// Names that can be assigned or bound (state and `bind` parameters), mapped to
    /// their key in the `StateStore`.
    public var stateKeys: [String: String]
    /// Each `load`'s key in the `StateStore`.
    public var loads: [String: String] = [:]
    /// The component whose actions `name()` refers to.
    public var component: Component?

    public init(values: Scope = [:], stateKeys: [String: String] = [:], component: Component? = nil) {
        self.values = values
        self.stateKeys = stateKeys
        self.component = component
    }

    /// Recomputes every `derived` value, in order, after state changes.
    mutating func recomputeDerived() throws {
        for derived in component?.derived ?? [] {
            values[derived.name] = try Evaluator.evaluate(derived.value, in: values)
        }
    }
}

/// Runs an action or a button's block.
public enum ActionRunner {
    /// Runs `statements`, writing state changes to `store`. Errors go to `store.lastError`
    /// so a mistake shows up under the preview instead of crashing it.
    public static func run(_ statements: [Statement], in environment: InstanceScope, store: StateStore) {
        var env = environment
        do {
            try execute(statements, env: &env, store: store, depth: 0)
            store.lastError = nil
        } catch let error as RuntimeError {
            store.lastError = error.range.map { "line \($0.start.line): \(error.message)" } ?? error.message
        } catch {
            store.lastError = "\(error)"
        }
    }

    static func execute(_ statements: [Statement], env: inout InstanceScope, store: StateStore, depth: Int) throws {
        guard depth < 32 else {
            throw RuntimeError("actions call each other more than 32 levels deep; is one calling itself?")
        }
        for statement in statements {
            switch statement {
            case .assign(let target, let targetRange, let op, let valueExpr):
                guard let key = env.stateKeys[target] else {
                    throw RuntimeError("`\(target)` isn't state, so it can't be changed", at: targetRange)
                }
                var value = try Evaluator.evaluate(valueExpr, in: env.values)
                if op != "=" {
                    guard case .number(let current) = env.values[target] ?? .null, case .number(let change) = value else {
                        throw RuntimeError("`\(op)` needs numbers", at: statement.range)
                    }
                    value = .number(op == "+=" ? current + change : current - change)
                }
                store.set(key, value)
                env.values[target] = value
                try env.recomputeDerived()

            case .call(let name, let range):
                guard let action = env.component?.action(named: name) else {
                    throw RuntimeError("there's no action `\(name)`", at: range)
                }
                try execute(action.body, env: &env, store: store, depth: depth + 1)

            case .reload(let name, let range):
                guard let key = env.loads[name] else {
                    throw RuntimeError("`\(name)` isn't a load", at: range)
                }
                store.reload(key)

            case .conditional(let branches, let otherwise, _):
                var chosen = otherwise
                for branch in branches {
                    let value = try Evaluator.evaluate(branch.condition, in: env.values)
                    if try Evaluator.truth(value, at: branch.condition.range) {
                        chosen = branch.body
                        break
                    }
                }
                try execute(chosen ?? [], env: &env, store: store, depth: depth)
            }
        }
    }
}
