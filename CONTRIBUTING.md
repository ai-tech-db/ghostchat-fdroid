# Contributing to GhostChat

Thanks for your interest in contributing to GhostChat!

## How to contribute

### Reporting bugs

Open an issue on GitHub with:
- **Description**: what happened vs what you expected
- **Steps to reproduce**: minimal steps
- **Environment**: Android version, device model, Flutter version
- **Logs**: `adb logcat -s qttunnel flutter` (filtered)
- **Screenshots**: if applicable

### Suggesting features

Open an issue with:
- **Use case**: why you need it
- **Proposal**: how you would implement it
- **Alternatives**: what else could solve it

### Pull requests

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-feature`
3. Make your changes
4. Test on a real Android device
5. Commit with a clear message
6. Push and open a Pull Request

## Development setup

See [README.md](README.md) for build instructions.

## Code style

- **Dart**: `flutter analyze` must pass
- **Kotlin**: follow Android style
- **Rust**: `cargo fmt` and `cargo clippy`
- **JS**: 2-space indent, semicolons
- **Comments**: explain "why", not "what"

## Security

If you find a security issue, **do NOT open a public issue**.
See [SECURITY.md](SECURITY.md) for responsible disclosure.

## License

By contributing, you agree that your contributions will be licensed
under the Apache License 2.0 (see [LICENSE](LICENSE)).
