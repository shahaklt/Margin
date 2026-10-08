# Margin for iPhone

Same app as the Mac version (shared code in `Sources/MarginKit`), synced through an iCloud Drive folder.

## Install

Easiest: grab `Margin.ipa` from the "Build iPhone IPA" GitHub Actions run (or Releases) and install it
with [Sideloadly](https://sideloadly.io). See the main README.

With Xcode instead: `cd iOS && xcodegen && open MarginPhone.xcodeproj`, set your Personal Team under
Signing & Capabilities (change the bundle ID if it's taken), plug in the phone and press ▶︎.
Free Apple IDs re-sign every 7 days.

## First run on the phone

1. Open Margin → ⚙︎ → **Choose iCloud Drive Folder…** → iCloud Drive → select **Margin** (created by the Mac app).
2. Choose **Transcribe on: This iPhone** (Whisper Small runs on the phone) or **My Mac** (phone only records; saves battery).
3. Record, or share a voice memo: Voice Memos → ••• → Share → **Margin**.

The Mac does what the phone can't: writes the full LaTeX note sheet with Claude, compiles the PDF,
and answers questions you ask on the phone. Results sync back automatically.

## Checking the code without Xcode

`./check.sh` type-checks the whole iPhone app (shared code + iPhone-only code) by compiling it for
Mac Catalyst, which uses the same UIKit/AVAudioSession APIs.
