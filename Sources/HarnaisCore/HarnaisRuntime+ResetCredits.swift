import Domain
import Foundation
import Infrastructure

public struct ResetPrompt: Identifiable, Sendable, Equatable {
    public var account: Account
    public var plan: ResetPlan
    public var id: UUID { account.id }
}

extension HarnaisRuntime {
    /// Why a banked reset cannot be offered yet, from the last refresh. Nil when it can.
    /// The confirmation re-checks with live data before anything is spent.
    public func resetBlocker(for account: Account) -> String? {
        guard let credits = resetCredits(for: account), credits.availableCount > 0 else { return nil }
        return ResetPlan.weeklyGate(quotas(for: account).map {
            ResetPlan.Window(name: $0.compactTitle ?? $0.type, percentRemaining: $0.percentRemaining)
        })
    }

    /// Step 1: read live state and ask. Spends nothing.
    public func prepareResetCredit(_ account: Account) {
        guard account.provider == .claude || account.provider == .codex,
              !busyResets.contains(account.id), resetPrompt == nil else { return }
        busyResets.insert(account.id)
        errorMessage = nil
        Task {
            do {
                let plan = try await Task.detached {
                    try ResetCreditRedeemer().plan(for: account, environment: IsolationEngine().spawnEnvironment(for: account))
                }.value
                resetPrompt = ResetPrompt(account: account, plan: plan)
            } catch { errorMessage = error.localizedDescription }
            busyResets.remove(account.id)
        }
    }

    public func cancelResetCredit() {
        resetPrompt = nil
    }

    /// Step 2: the only path that spends a credit, and only for a plan the user just confirmed.
    public func confirmResetCredit() {
        guard let prompt = resetPrompt, prompt.plan.blocker == nil, !busyResets.contains(prompt.account.id) else { return }
        resetPrompt = nil
        busyResets.insert(prompt.account.id)
        errorMessage = nil
        Task {
            let outcome = await Task.detached {
                ResetCreditRedeemer().redeem(prompt.plan, account: prompt.account,
                                             environment: IsolationEngine().spawnEnvironment(for: prompt.account))
            }.value
            busyResets.remove(prompt.account.id)
            if outcome.succeeded { presentSuccess(outcome.message) } else { errorMessage = outcome.message }
            // A running refresh would ignore ours and leave the old count on screen.
            for _ in 0..<150 where isRefreshingQuotas { try? await Task.sleep(for: .milliseconds(200)) }
            let message = errorMessage
            refreshQuotas()
            if let message { errorMessage = message }
        }
    }
}
