# SDK development

Keep shared values, validation, deterministic planning and state in Rust. Keep native resources and language scheduling in their adapters. Hosts own product policy, permission prompts, persistence and UI.

Use Git on main. Preserve published commits and pinned dependencies; keep unfinished edits in the working tree and publish coherent main units without PRs.

Swift consumers install through Package.swift and tracked native frameworks. Rebuild native artifacts after Rust/C/input changes; maintain their provenance and runtime notices. Keep C ownership explicit and copy foreign views before invoking host callbacks. Test OS effects only in owned isolated fixtures and report actual runtime coverage separately from compilation.

Automatic macOS source checks include strict Swift tests against the tracked framework. Changed native or permission-dependent behavior still requires separate owned runtime acceptance.

Use English documentation/comments. Keep public GitHub-hosted CI independent of private dependency credentials. Use the SDK Tooling revision in mise.toml and describe distribution checks in sdk-distribution.toml. Human QA/data and existing VM/security/sharing settings are protected. Read README.md and its linked Swift guides before changing a public contract.
