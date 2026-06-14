import CodexBarCore
import Foundation

extension UsageStore {
    func tokenSnapshot(for provider: UsageProvider) -> CostUsageTokenSnapshot? {
        self.tokenSnapshots[provider]
    }

    func tokenError(for provider: UsageProvider) -> String? {
        self.tokenErrors[provider]
    }

    /// Providers whose daily token history is produced by scanning local logs/DBs and can
    /// therefore be re-scanned for an arbitrary window (used by the dashboard to fill a full
    /// year regardless of the menu's `costUsageHistoryDays` setting).
    private static let extendedHistoryProviders: Set<UsageProvider> = [
        .codex,
        .claude,
        .vertexai,
        .opencode,
        .opencodego,
    ]

    /// Providers that expose a per-request log view in the dashboard. Currently
    /// only OpenCode (and its Go tier) — Codex/Claude/VertexAI readers don't
    /// produce per-message granularity, so the request log stays OpenCode-only
    /// for now.
    private static let requestLogProviders: Set<UsageProvider> = [.opencode, .opencodego]

    /// Loads up to `days` of daily token entries for the dashboard. Local-scan providers are
    /// re-scanned for the wider window; everything else falls back to the cached snapshot.
    func dashboardDailyEntries(
        for provider: UsageProvider,
        days: Int) async -> [CostUsageDailyReport.Entry]
    {
        guard Self.extendedHistoryProviders.contains(provider) else {
            return self.tokenSnapshot(for: provider)?.daily ?? []
        }
        let scope = self.tokenCostScope(for: provider)
        do {
            let snapshot = try await self.costUsageFetcher.loadTokenSnapshot(
                provider: provider,
                environment: self.environmentBase,
                now: Date(),
                forceRefresh: false,
                allowVertexClaudeFallback: !self.isEnabled(.claude),
                codexHomePath: scope.codexHomePath,
                historyDays: max(1, min(365, days)))
            return snapshot.daily
        } catch {
            return self.tokenSnapshot(for: provider)?.daily ?? []
        }
    }

    func tokenLastAttemptAt(for provider: UsageProvider) -> Date? {
        self.lastTokenFetchAt[provider]
    }

    func hydrateCachedTokenSnapshots(now: Date = Date()) {
        guard self.settings.costUsageEnabled else { return }
        guard self.settings.enabledProvidersOrdered(metadataByProvider: self.providerMetadata).contains(.codex) else {
            return
        }

        let scope = self.tokenCostScope(for: .codex)
        let historyDays = self.settings.costUsageHistoryDays
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.tokenSnapshots[.codex] == nil else { return }
            guard let snapshot = await self.costUsageFetcher.loadCachedCodexTokenSnapshot(
                now: now,
                codexHomePath: scope.codexHomePath,
                historyDays: historyDays)
            else {
                return
            }
            guard self.settings.costUsageEnabled,
                  self.isEnabled(.codex),
                  self.tokenCostScope(for: .codex).signature == scope.signature,
                  self.tokenSnapshots[.codex] == nil
            else {
                return
            }
            self.tokenSnapshots[.codex] = snapshot
            self.tokenErrors[.codex] = nil
        }
    }

    func isTokenRefreshInFlight(for provider: UsageProvider) -> Bool {
        self.tokenRefreshInFlight.contains(provider)
    }

    func tokenCostScope(for provider: UsageProvider) -> (codexHomePath: String?, signature: String) {
        guard provider == .codex else {
            return (nil, provider.rawValue)
        }
        let homePath = self.settings.activeManagedCodexRemoteHomePath?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let homePath, !homePath.isEmpty else {
            return (nil, "codex:ambient")
        }
        return (homePath, "codex:managed:\(homePath)")
    }

    func tokenSnapshot(
        fromProviderSnapshot snapshot: UsageSnapshot?,
        provider: UsageProvider)
        -> CostUsageTokenSnapshot?
    {
        switch provider {
        case .openai:
            snapshot?.openAIAPIUsage?.toCostUsageTokenSnapshot()
        case .mistral:
            snapshot?.mistralUsage?.toCostUsageTokenSnapshot(historyDays: self.settings.costUsageHistoryDays)
        default:
            nil
        }
    }

    nonisolated static func tokenCostRequiresProviderSnapshot(_ provider: UsageProvider) -> Bool {
        switch provider {
        case .mistral, .openai:
            true
        default:
            false
        }
    }

    nonisolated static func costUsageCacheDirectory(
        fileManager: FileManager = .default) -> URL
    {
        let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("cost-usage", isDirectory: true)
    }

    func clearCostUsageCache() async -> String? {
        let errorMessage: String? = await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let cacheDirs = [
                Self.costUsageCacheDirectory(fileManager: fm),
            ]

            for cacheDir in cacheDirs {
                do {
                    try fm.removeItem(at: cacheDir)
                } catch let error as NSError {
                    if error.domain == NSCocoaErrorDomain, error.code == NSFileNoSuchFileError { continue }
                    return error.localizedDescription
                }
            }
            return nil
        }.value

        guard errorMessage == nil else { return errorMessage }

        self.tokenSnapshots.removeAll()
        self.tokenErrors.removeAll()
        self.lastTokenFetchAt.removeAll()
        self.lastTokenFetchScope.removeAll()
        self.tokenFailureGates[.codex]?.reset()
        self.tokenFailureGates[.claude]?.reset()
        return nil
    }

    nonisolated static func tokenCostNoDataMessage(for provider: UsageProvider) -> String {
        ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.noDataMessage()
    }

    // MARK: - Per-request log (OpenCode only)

    /// Returns the cached per-request log for a provider, or nil if it hasn't
    /// been loaded yet.
    func openCodeRequestLog(for provider: UsageProvider) -> OpenCodeRequestLog? {
        self.openCodeRequestLogs[provider]
    }

    /// Loads the OpenCode per-request log for the dashboard's `range`. Caches
    /// the result on the store so switching away and back doesn't re-scan the
    /// SQLite file. Returns nil for providers that don't support per-request
    /// logs.
    func loadOpenCodeRequestLog(
        for provider: UsageProvider,
        rangeWeeks: Int,
        now: Date = Date(),
        maxEntries: Int = 500) async
    {
        guard Self.requestLogProviders.contains(provider) else { return }

        let days = max(1, min(365, rangeWeeks * 7))
        let until = now
        let since = Calendar.current.date(byAdding: .day, value: -(days - 1), to: now) ?? now

        let log = await Task.detached(priority: .utility) {
            OpenCodeCostUsageReader.loadRequestLog(
                since: since,
                until: until,
                maxEntries: maxEntries,
                environment: ProcessInfo.processInfo.environment)
        }.value
        self.openCodeRequestLogs[provider] = log
    }
}
