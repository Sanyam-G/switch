# Local Debug build

macOS 14+, Xcode 15+, [XcodeGen](https://github.com/yonaskolb/XcodeGen). The `.xcodeproj` is gitignored; regenerate it every checkout.

```bash
brew install xcodegen
xcodegen generate
```

**Xcode:** open `Switch.xcodeproj`, scheme **Switch**, destination **My Mac**, Run. If Developer ID signing fails, set Signing to **Sign to Run Locally**.

**CLI:**

```bash
xcodebuild -project Switch.xcodeproj \
  -scheme Switch \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  -derivedDataPath build \
  build
open build/Build/Products/Debug/Switch.app
```

Quit any other Switch instance first; this Debug build uses bundle id `com.sanyamgarg.switch.debug`.
