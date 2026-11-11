# Contributing

Bug reports, translations and pull requests are welcome.

- Build and test as described in the README (`xcodegen generate`, then `⌘U`). Tests must pass.
- Keep changes focused. Match the existing style: small SwiftUI views, constants in `PanelMetrics`,
  every user-visible string through `L("key")` with the key added to all 11 `Localizable.strings` files.
- Corner radii follow the concentric rule: outer radius = inner radius + padding.
- No network code and no third-party dependencies: this is a deliberate property of the project.
- Bugs: include your macOS version, the app that misbehaves and what you expected.
