# Contributing to Switch

Open an issue before you start, so we agree on the change first. Reference it in the PR (`Closes #104`).

PRs must be written by hand. I'll take feature ideas from AI-generated PRs, but I won't merge them.

## Build

```
brew install xcodegen
xcodegen generate
xcodebuild -project Switch.xcodeproj -scheme Switch -configuration Debug CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

`project.yml` is the source of truth; `Switch.xcodeproj` is generated and not tracked. The overrides above sign ad hoc, since the project is set up for my Developer ID.

Debug builds use the bundle ID `com.sanyamgarg.switch.debug`, so they keep their own settings and need their own Accessibility (and Screen Recording) grant. An ad-hoc rebuild changes the signature, so toggle Switch off and on again in System Settings → Privacy & Security → Accessibility after rebuilding.

## Pull requests

- Match the existing code style.
- Test your change, and attach a screenshot for anything visual.
