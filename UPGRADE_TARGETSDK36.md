# Runbook: targetSdk 36 upgrade (Google Play deadline Aug 31 2026)

**Why:** Google Play requires apps to target API level 36 by **Aug 31 2026**. ClearRent
currently targets **35** (inherited from Flutter 3.29.3). This requires a Flutter SDK
upgrade — `targetSdk` is not pinned in the repo, it comes from the Flutter toolchain.

**When:** Do this AFTER the Paystack split-settlement migration ships. Both touch the
App Check / payment path; sequencing them means any failure has one suspect.

**Effort:** ~3–5 focused days. The *code* changes are ~half a day (spiked & verified —
see "Verified findings" at the bottom). The rest is toolchain + device QA + edge-to-edge.

**Do all of this on a dedicated branch**, never directly on `develop`:
```
git switch -c chore/targetsdk36-upgrade
```

---

## Step 1 — Upgrade the Flutter SDK

The current SDK (`C:\flutter`, 3.29.3) hardcodes targetSdk 35. You need a stable Flutter
whose Gradle plugin defaults to 36.

```powershell
cd C:\flutter
git fetch --tags
git checkout stable
git pull
flutter --version          # confirm you moved off 3.29.3
flutter doctor
```

**Verify the SDK actually targets 36** before going further:
```powershell
Select-String -Path "C:\flutter\packages\flutter_tools\gradle\src\main\groovy\flutter.groovy" -Pattern "targetSdkVersion|compileSdkVersion"
```
Both must read `36`. If they still say 35, the Flutter version isn't new enough — stop and
get a newer stable. **Also re-confirm the required level is still 36** on Google's page
(https://developer.android.com/google/play/requirements/target-sdk) — deadlines can shift.

> No repo change is needed for the SDK version itself. `android/app/build.gradle.kts` already
> uses `flutter.targetSdkVersion` / `flutter.compileSdkVersion`, so it picks up 36 automatically.

---

## Step 2 — Bump the Android build toolchain (mandatory)

API 36 needs newer AGP + Gradle. Edit two files:

**`android/settings.gradle.kts`** (line ~21):
```kotlin
id("com.android.application") version "8.9.0" apply false   // was 8.7.0
```
(Use the AGP version the new Flutter's templates ship with — check
`flutter create --platforms=android test_app` in a temp dir if unsure. 8.9+ is the floor for API 36.)

**`android/gradle/wrapper/gradle-wrapper.properties`** (line 5):
```
distributionUrl=https\://services.gradle.org/distributions/gradle-8.11.1-all.zip
```
(Match the minimum Gradle the new AGP requires; 8.11.1+ pairs with AGP 8.9.)

Kotlin (2.1.20) and google-services (4.4.0) are already fine — leave them.

---

## Step 3 — Upgrade the Dart packages

```powershell
cd C:\Users\MIDE\clearrent
flutter pub upgrade --major-versions
flutter pub get
```
This rewrites the 14 major constraints in `pubspec.yaml` (firebase_core 3→4 and siblings,
go_router 14→17, cloud_firestore 5→6, flutter_map 6→8, share_plus 7→12, etc.). All were
confirmed to resolve cleanly.

---

## Step 4 — Fix the one breaking file: Riverpod 3 (`lib/core/theme/theme_provider.dart`)

Riverpod 3 removed `StateNotifier`/`StateNotifierProvider`. Migrate to `Notifier`.
Every `state = ...` line stays identical — only the declaration changes.

**Replace lines 13–23:**
```dart
// OLD
final themeModeProvider =
    StateNotifierProvider<ThemeModeNotifier, ThemeMode>((ref) {
  return ThemeModeNotifier();
});

class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  ThemeModeNotifier() : super(ThemeMode.system) {
    _load();
  }
```
```dart
// NEW
final themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    _load();
    return ThemeMode.system;
  }
```
Everything below (`_load`, `setThemeMode`, `_syncAppColors`, the `state = ...` assignments)
is unchanged. That's the entire required code fix.

---

## Step 5 — Deprecation swaps (not blocking, but do them now while you're here)

**5a. share_plus (5 sites).** `Share.share(x)` → `SharePlus.instance.share(ShareParams(text: x))`.
Update the import to `import 'package:share_plus/share_plus.dart';` (unchanged) and edit:
- `lib/shared/widgets/share_property_sheet_external.dart:40`
- `lib/features/agent/presentation/screens/agent_property_detail_screen.dart:1763` and `:1770`
- `lib/features/tenant/presentation/screens/documents_screen.dart:887` and `:1079`

Example:
```dart
// OLD
await Share.share(_shareText);
// NEW
await SharePlus.instance.share(ShareParams(text: _shareText));
```

**5b. firebase_app_check** — `lib/main.dart:38`:
```dart
// OLD:  androidProvider: kReleaseMode ? ... : ...
// NEW:  providerAndroid: kReleaseMode ? ... : ...
```

**5c. flutter_secure_storage** — `lib/services/biometric_service.dart:10-12`.
`encryptedSharedPreferences` is deprecated and ignored; remove it:
```dart
// OLD
aOptions: AndroidOptions(
  encryptedSharedPreferences: true,
),
// NEW
aOptions: AndroidOptions(),
```

---

## Step 6 — Compile clean

```powershell
flutter analyze
```
Target: **0 errors.** After Steps 4–5 the only file with errors is fixed. If the *newer*
Flutter framework surfaces additional deprecations (possible — this wasn't exercised in the
spike, which ran on 3.29.3), fix them here. They should be small and mechanical.

---

## Step 7 — Edge-to-edge (the real QA cost)

Android 16 (API 36) **enforces** edge-to-edge — you can no longer opt out. Content draws
behind the status/navigation bars by default.

- System-bar styling currently lives in `lib/main.dart` and `lib/app/app.dart`
  (`SystemChrome` / overlay style). Verify these still produce correct bar contrast.
- **Walk every screen (~40).** Look for content hidden behind the top status bar or bottom
  nav bar. Fix with `SafeArea` / correct `Scaffold` insets where clipping appears.
- Pay special attention to: bottom sheets, full-screen media (video_player/chewie),
  the map picker, and any screen with a custom bottom bar.

This is visual inspection, not code churn, but budget 1–2 days for it.

---

## Step 8 — Device regression test (do NOT skip — analyzer can't catch this)

Build a **release** bundle and test on a real device, because App Check + Play Integrity
only attest on a Play-signed install:
```powershell
flutter build appbundle --release
```
Then verify on device (upload to Play **internal testing track**, not just `flutter run`):

- [ ] **Phone OTP login** end to end (firebase_auth 5→6 + Play Integrity).
- [ ] **App Check**: the 4 enforced payment callables succeed (no `unauthenticated`).
      This is the historical failure mode — test it deliberately.
- [ ] **Push notifications** arrive (firebase_messaging 15→16).
- [ ] **Firestore** reads/writes across roles (cloud_firestore 5→6).
- [ ] **Map picker** renders, pans, drops a marker (flutter_map 6→8 — biggest runtime API jump).
- [ ] **Share** sheet opens from all 5 entry points (share_plus 12).
- [ ] **Biometric** unlock still works (flutter_secure_storage AndroidOptions change).
- [ ] **Image upload** (image_picker) and **video playback** (video_player/chewie).
- [ ] Navigation across all tabs (go_router 14→17).
- [ ] Edge-to-edge: no clipped content, correct bar contrast in light AND dark.

---

## Step 9 — Ship

```powershell
git add -A
git commit    # message describing the toolchain + dep upgrade
```
Open a PR into `develop`. Upload the release bundle to the Play **internal testing** track
and confirm the target API level reads **36** in the Play Console before promoting.

---

## Verified findings from the spike (2026-07-23)

Ran the full upgrade in a throwaway worktree on Flutter 3.29.3:
- All 14 major bumps **resolved cleanly** under Dart 3.7.2.
- `flutter analyze` = **16 issues, only 8 errors, ALL in `theme_provider.dart`** (Step 4).
- The other 8 were non-blocking deprecation infos (Step 5).
- **Zero errors** from go_router 14→17, all 7 Firebase majors, or flutter_map 6→8.

**Caveats:** the spike ran on the *old* Flutter (targetSdk 35), so Steps 1, 2, 7 (newer
framework, AGP, edge-to-edge) were not exercised — treat "one file" as the floor. And
`analyze` proves API compatibility, not runtime behavior — Step 8 is where flutter_map and
Firebase majors actually get validated.
