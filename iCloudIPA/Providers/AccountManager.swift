import Foundation
import SwiftData

/// Central multi-account management: connects, removes and refreshes accounts, caches provider
/// adapters and picks a destination account automatically by available space.
@MainActor
final class AccountManager: ObservableObject {
    let store: DataStore
    private var providers: [UUID: CloudProvider] = [:]
    @Published private(set) var refreshing = false
    @Published var lastError: String?
    /// Bumped whenever accounts change so views can refresh derived data.
    @Published private(set) var revision = 0

    init(store: DataStore) {
        self.store = store
    }

    var accounts: [CloudAccount] { store.accounts() }

    var activeAccount: CloudAccount? {
        accounts.first(where: \.isActive) ?? accounts.first
    }

    func provider(for id: UUID) throws -> CloudProvider {
        if let p = providers[id] { return p }
        guard let acc = store.account(id) else { throw AppError.notFound(L("account")) }
        let p: CloudProvider
        switch acc.provider {
        case .googleDrive: p = GoogleDriveProvider(accountID: id)
        case .teraBox: p = TeraBoxProvider(accountID: id)
        }
        providers[id] = p
        return p
    }

    /// Test hook / dependency injection.
    func register(_ provider: CloudProvider) { providers[provider.accountID] = provider }

    // MARK: Connect

    func addGoogleAccount() async throws -> CloudAccount {
        let cred = try await GoogleSignInCoordinator().signIn()
        let newID = UUID()
        let tokens = GoogleTokenStore(accountID: newID)
        try await tokens.save(cred)
        let provider = GoogleDriveProvider(accountID: newID, tokens: tokens)
        let info: ProviderAccountInfo
        do { info = try await provider.accountInfo() } catch { await tokens.clear(); throw error }

        if let existing = accounts.first(where: { $0.provider == .googleDrive && $0.externalUserID != nil && $0.externalUserID == info.userID }) {
            // Same Google account again → refresh its credentials instead of duplicating it.
            try await GoogleTokenStore(accountID: existing.id).save(cred)
            KeychainStore().remove(KeychainStore.credentialKey(newID))
            providers[existing.id] = nil
            existing.status = .connected
            existing.lastError = nil
            store.save()
            await refresh(existing)
            store.logActivity(.account, LF("Reconnected %@", existing.email), account: existing.id)
            revision += 1
            return existing
        }
        let acc = CloudAccount(id: newID, provider: .googleDrive, displayName: info.displayName, email: info.email, externalUserID: info.userID)
        acc.avatarURL = info.avatarURL?.absoluteString
        finishAdding(acc, provider: provider)
        await refresh(acc)
        return acc
    }

    func addTeraBoxAccount(id: UUID, session: TeraBoxSession) async throws -> CloudAccount {
        let provider = TeraBoxProvider(accountID: id, session: session)
        try provider.store(session)
        do {
            try await provider.refreshTokens()
            let info = try await provider.accountInfo()
            if let existing = accounts.first(where: { $0.provider == .teraBox && $0.externalUserID != nil && $0.externalUserID == info.userID }) {
                let p = TeraBoxProvider(accountID: existing.id)
                try p.store(try provider.currentSession())
                KeychainStore().remove(KeychainStore.credentialKey(id))
                await TeraBoxWebStore.removeData(for: id)
                providers[existing.id] = p
                existing.status = .experimental
                existing.lastError = nil
                store.save()
                await refresh(existing)
                revision += 1
                return existing
            }
            let acc = CloudAccount(id: id, provider: .teraBox, displayName: info.displayName, email: info.email, externalUserID: info.userID)
            acc.avatarURL = info.avatarURL?.absoluteString
            acc.status = .experimental
            finishAdding(acc, provider: provider)
            await refresh(acc)
            return acc
        } catch {
            await provider.signOut()
            throw error
        }
    }

    private func finishAdding(_ acc: CloudAccount, provider: CloudProvider) {
        acc.sortOrder = (accounts.map(\.sortOrder).max() ?? 0) + 1
        if accounts.isEmpty {
            acc.isActive = true
            acc.role = .primary
        }
        store.context.insert(acc)
        store.save()
        providers[acc.id] = provider
        store.logActivity(.account, LF("Connected %@", acc.provider.title), detail: acc.email, account: acc.id)
        revision += 1
    }

    // MARK: Remove / switch / roles

    /// Signs out at the provider (revokes Google tokens / ends TeraBox web session), deletes the
    /// Keychain entry and every local record for the account.
    func remove(_ account: CloudAccount) async {
        let id = account.id
        let title = account.email.isEmpty ? account.displayName : account.email
        if let p = try? provider(for: id) { await p.signOut() }
        KeychainStore().remove(KeychainStore.credentialKey(id))
        providers[id] = nil
        store.purgeAccountData(id)
        let wasActive = account.isActive
        store.context.delete(account)
        store.save()
        if wasActive, let first = accounts.first { first.isActive = true; store.save() }
        store.logActivity(.account, LF("Removed %@", title))
        revision += 1
    }

    func setActive(_ account: CloudAccount) {
        for a in accounts { a.isActive = (a.id == account.id) }
        store.save()
        revision += 1
    }

    func setRole(_ role: AccountRole, for account: CloudAccount) {
        if role == .primary {
            for a in accounts where a.role == .primary && a.id != account.id { a.role = .normal }
        }
        account.role = role
        store.save()
        revision += 1
    }

    // MARK: Refresh

    func refresh(_ account: CloudAccount) async {
        do {
            let p = try provider(for: account.id)
            let q = try await p.quota()
            account.quotaTotal = q.total
            account.quotaUsed = q.used
            account.quotaTrash = q.trash
            account.quotaUpdatedAt = Date()
            account.status = account.provider == .teraBox ? .experimental : .connected
            account.lastError = nil
        } catch let e as AppError {
            account.status = (e == .sessionExpired || e == .notAuthenticated) ? .expired : .error
            account.lastError = e.localizedDescription
        } catch {
            account.status = .error
            account.lastError = error.localizedDescription
        }
        store.save()
        revision += 1
    }

    func refreshAll() async {
        refreshing = true
        defer { refreshing = false }
        await withTaskGroup(of: Void.self) { group in
            for acc in accounts {
                group.addTask { @MainActor in await self.refresh(acc) }
            }
        }
    }

    // MARK: Automatic storage selection

    /// Picks the account for new data: an explicitly requested account if healthy, else the
    /// primary account if it has room, else backup accounts, else any account with the most free space.
    func pickAccount(forBytes bytes: Int64, preferred: UUID? = nil) throws -> CloudAccount {
        let healthy = accounts.filter { $0.status == .connected || $0.status == .experimental }
        guard !healthy.isEmpty else { throw AppError.notAuthenticated }
        func fits(_ a: CloudAccount) -> Bool { a.quotaFree.map { $0 > bytes + 50 * 1024 * 1024 } ?? true }
        if let preferred, let a = healthy.first(where: { $0.id == preferred }), fits(a) { return a }
        let ordered = Self.rankForUpload(healthy)
        if let a = ordered.first(where: fits) { return a }
        throw AppError.insufficientSpace
    }

    /// Primary first, then backup (fallback) accounts, then the rest; ties broken by most free space.
    static func rankForUpload(_ accounts: [CloudAccount]) -> [CloudAccount] {
        func rank(_ r: AccountRole) -> Int { r == .primary ? 0 : r == .backup ? 1 : 2 }
        return accounts.sorted {
            if rank($0.role) != rank($1.role) { return rank($0.role) < rank($1.role) }
            return ($0.quotaFree ?? .max) > ($1.quotaFree ?? .max)
        }
    }
}
