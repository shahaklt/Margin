# Margin for iPhone

Same app as the Mac version (shared code in `Sources/MarginKit`), synced through an iCloud Drive folder.

## Install (needs full Xcode once)

1. Install **Xcode** from the App Store, open it once, and add the iOS platform when asked.
2. In Terminal:
   ```sh
   cd ~/Developer/Margin/iOS
   xcodegen            # regenerates MarginPhone.xcodeproj (brew install xcodegen)
   open MarginPhone.xcodeproj
   ```
3. Xcode → Settings → Accounts → add your Apple ID.
4. Select the **MarginPhone** target → Signing & Capabilities → Team: your Personal Team.
   If the bundle ID is taken, change `com.ltshahak.margin.phone` to anything unique.
5. Plug in your iPhone, turn on **Settings → Privacy & Security → Developer Mode**, pick the phone as the run destination, press ▶︎.
6. On the phone: **Settings → General → VPN & Device Management** → trust your developer certificate.

With a free Apple ID the app expires after 7 days. Press ▶︎ again in Xcode to refresh it
(or use a $99/yr developer account for 1-year installs).

## First run on the phone

1. Open Margin → ⚙︎ → **Choose iCloud Drive Folder…** → iCloud Drive → select **Margin** (created by the Mac app).
2. Choose **Transcribe on: This iPhone** (Whisper Small runs on the phone) or **My Mac** (phone only records; saves battery).
3. Record, or share a voice memo: Voice Memos → ••• → Share → **Margin**.

The Mac does what the phone can't: writes the full LaTeX note sheet with Claude, compiles the PDF,
and answers questions you ask on the phone. Results sync back automatically.

## Checking the code without Xcode

`./check.sh` type-checks the whole iPhone app (shared code + iPhone-only code) by compiling it for
Mac Catalyst, which uses the same UIKit/AVAudioSession APIs.
