/// Common software vocabulary the user can add in one click (Dictionary window).
/// Terms are spelled the way they should appear; lowercase ones never recase
/// speech and are there for rescoring and near-miss correction. No plain words
/// whose forced casing would hurt ("rest", "swift", "rust"). Pairs hear at least
/// two words, so they never fire on a lone common word.
public enum TechTerms {
    public static let terms = [
        "pull request", "merge request", "code review", "cache", "retry", "rebase", "commit", "deploy", "main",
        "staging", "endpoint", "API", "JSON", "YAML", "CI", "CD", "SDK", "CLI", "URL", "HTTP", "HTTPS",
        "SQL", "PostgreSQL", "Postgres", "MySQL", "SQLite", "Redis", "GraphQL", "gRPC", "OAuth", "JWT",
        "webhook", "middleware", "refactor", "linter", "regex", "localhost", "backend", "frontend", "async",
        "Kubernetes", "kubectl", "Docker", "Terraform", "AWS", "GitHub", "GitLab", "TypeScript", "JavaScript",
        "Python", "SwiftUI", "Xcode", "iOS", "macOS", "npm", "Node.js", "Next.js", "Claude", "LLM", "prompt",
        "PR", "repo", "README", "UI", "UX", "VS Code", "config", "backoff", "timeout", "idempotent",
    ]

    /// Mishearings seen in real and synthetic dictation. Not "really try" → "retry":
    /// it rewrote "I'll really try to…" in every lab run.
    public static let pairs = [
        ReplacementPair(heard: "pool request", write: "pull request"),
        ReplacementPair(heard: "poll request", write: "pull request"),
        ReplacementPair(heard: "create it at", write: "created at"),
    ]
}
