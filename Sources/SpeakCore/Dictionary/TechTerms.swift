/// Common software vocabulary the user can add in one click (Dictionary window).
/// Terms are spelled the way they should appear; lowercase ones never recase
/// speech and are there for rescoring and near-miss correction. No plain words
/// whose forced casing would hurt ("rest", "swift", "rust"). Pairs hear at least
/// two words, so they never fire on a lone common word; the only one-word pair
/// hears a word English doesn't have ("Frederix").
public enum TechTerms {
    public static let terms = [
        "pull request", "merge request", "code review", "cache", "retry", "rebase", "commit", "deploy", "main",
        "staging", "endpoint", "API", "JSON", "YAML", "CI", "CD", "SDK", "CLI", "URL", "HTTP", "HTTPS",
        "SQL", "PostgreSQL", "Postgres", "MySQL", "SQLite", "Redis", "GraphQL", "gRPC", "OAuth", "JWT",
        "webhook", "middleware", "refactor", "linter", "regex", "localhost", "backend", "frontend", "async",
        "Kubernetes", "kubectl", "Docker", "Docker Compose", "Terraform", "AWS", "GitHub", "GitLab", "TypeScript", "JavaScript",
        "Python", "SwiftUI", "Xcode", "iOS", "macOS", "npm", "Node.js", "Next.js", "Claude", "LLM", "prompt",
        "PR", "repo", "README", "UI", "UX", "VS Code", "config", "backoff", "timeout", "idempotent",
    ]

    /// Mishearings seen in real and synthetic dictation. Not "really try" → "retry":
    /// it rewrote "I'll really try to…" in every lab run. Everyday words ("darker",
    /// "Maine", "read me", "see I") are fixed only next to a word that makes them
    /// tech ("darker compose", "pushed to Maine", "the read me", "see I is"), never
    /// alone: "the room got darker", "Portland, Maine", "read me a story" and
    /// "See, I told you" stay. Not "darker image" or "in darker" (a darker image
    /// is English), nor "see I should be" without "green" ("See, I should be careful").
    public static let pairs = [
        ReplacementPair(heard: "pool request", write: "pull request"),
        ReplacementPair(heard: "poll request", write: "pull request"),
        ReplacementPair(heard: "create it at", write: "created at"),
        ReplacementPair(heard: "darker compose", write: "Docker Compose"),
        ReplacementPair(heard: "darker hub", write: "Docker Hub"),
        ReplacementPair(heard: "darker container", write: "Docker container"),
        ReplacementPair(heard: "darker containers", write: "Docker containers"),
        ReplacementPair(heard: "darker file", write: "Dockerfile"),
        ReplacementPair(heard: "doctor file", write: "Dockerfile"),
        ReplacementPair(heard: "push to maine", write: "push to main"),
        ReplacementPair(heard: "pushed to maine", write: "pushed to main"),
        ReplacementPair(heard: "merge into maine", write: "merge into main"),
        ReplacementPair(heard: "merged into maine", write: "merged into main"),
        ReplacementPair(heard: "merge it into maine", write: "merge it into main"),
        ReplacementPair(heard: "rebase on maine", write: "rebase on main"),
        ReplacementPair(heard: "maine branch", write: "main branch"),
        // The reverse: a recognizer that leans on "main" can write it for the state.
        ReplacementPair(heard: "portland, main", write: "Portland, Maine"),
        ReplacementPair(heard: "see i should be green", write: "CI should be green"),
        ReplacementPair(heard: "see, i should be green", write: "CI should be green"),
        ReplacementPair(heard: "see i is", write: "CI is"),
        ReplacementPair(heard: "the see i", write: "the CI"),
        ReplacementPair(heard: "see i pipeline", write: "CI pipeline"),
        ReplacementPair(heard: "the read me", write: "the README"),
        ReplacementPair(heard: "a read me", write: "a README"),
        ReplacementPair(heard: "our read me", write: "our README"),
        ReplacementPair(heard: "frederix", write: "regex"),
        ReplacementPair(heard: "kubernati", write: "Kubernetes"),
        ReplacementPair(heard: "cash key", write: "cache key"),
    ]
}
