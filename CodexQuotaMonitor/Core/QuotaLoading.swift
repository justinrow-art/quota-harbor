protocol QuotaLoading: Sendable {
    func loadQuota() async throws -> NormalizedQuota
}
