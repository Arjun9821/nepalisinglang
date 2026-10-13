# Nepali Sign Language Recognition (NSL FYP)

A Flutter application for recognizing Nepali Sign Language (NSL) gestures, built as a final year project (B.Sc. CSIT, 7th Semester). The app supports two recognition modes:

- **Offline Mode** — on-device gesture recognition using TensorFlow Lite
- **Online Mode** — cloud-based recognition via a REST API

> **Project status:** The core app scaffold, navigation, and UI are in place. The actual AI recognition pipelines (TFLite model integration and API-based inference) are still under development.

---

## 📋 Prerequisites

Before running this project, install the following on your machine:

| Tool | Minimum Version | Notes |
|---|---|---|
| [Flutter SDK](https://docs.flutter.dev/get-started/install) | 3.44.x (stable) | Install to a short path with no spaces, e.g. `C:\src\flutter` or `D:\develop\flutter` |
| [Android Studio](https://developer.android.com/studio) | Latest | Provides the Android SDK, an emulator, and a bundled JDK |
| JDK | 17 or 21 | Use the JDK bundled with Android Studio (found at `Android Studio installation folder\jbr`) rather than a separately installed JDK — newer JDKs (e.g. 23+) can cause Gradle build failures |
| Git | Latest | To clone this repository |

Verify your setup once everything is installed:

```bash
flutter doctor -v
```

Every item should show a green checkmark (or only unrelated warnings, e.g. about desktop app support if you don't need it).

---

## 🚀 Getting Started

### 1. Clone the repository

```bash
git clone https://github.com/yourusername/nsl-fyp.git
cd nsl-fyp
```

### 2. Install dependencies

```bash
flutter pub get
```

This downloads all the packages listed in `pubspec.yaml` (Riverpod, go_router, camera, flutter_tts, etc.) into your local package cache — no manual setup needed.

### 3. Set your Gradle JDK (Android only, first-time setup)

If you hit a Gradle/Kotlin build error on Android, it's almost always a JDK mismatch — Flutter's Android build tooling is unreliable on very new JDKs (e.g. 23+). Point Gradle at Android Studio's own bundled JDK instead of your system Java:

Open `android/gradle.properties` and add this line, using the path for your OS:

**Windows:**
```properties
org.gradle.java.home=C:\\Program Files\\Android\\Android Studio\\jbr
```

**macOS:**
```properties
org.gradle.java.home=/Applications/Android Studio.app/Contents/jbr/Contents/Home
```

**Linux:**
```properties
org.gradle.java.home=/opt/android-studio/jbr
```

If your Android Studio is installed somewhere else, check the exact path under `Android Studio → Settings/Preferences → Build, Execution, Deployment → Build Tools → Gradle → Gradle JDK`.

### 4. First-time Android Studio open (if using the IDE)

Since `android/local.properties` is intentionally excluded from this repo (it contains machine-specific SDK paths), Android Studio may show an **"SDK not found"** prompt the first time you open the project. This is expected — just point it at your local Android SDK location (usually auto-detected, or found via `Android Studio → Settings → Languages & Frameworks → Android SDK`). The file will be regenerated automatically.

### 5. Connect a device

- **Physical Android phone:** Enable Developer Options → USB Debugging, then connect via USB. Accept the "Allow USB debugging" prompt on the phone.
- **Emulator:** Open one from Android Studio's Device Manager.
- **Desktop/Web:** Also supported — see `flutter devices` for all available targets.

Check your device is detected:

```bash
flutter devices
```

### 6. Run the app

```bash
flutter run
```

Select your device from the list if prompted. The first build can take several minutes (Gradle downloads dependencies fresh); subsequent runs are much faster.

---

## 🗂️ Project Structure

```
lib/
├── core/                    # App-wide config, routing, and theming
│   ├── config/
│   ├── routing/
│   └── theme/
├── data/                    # Data layer: models and repository implementations
│   ├── models/
│   └── repositories/
├── domain/                  # Domain layer: repository interfaces
│   └── repositories/
├── presentation/            # UI layer
│   ├── home/
│   ├── offline/
│   ├── online/
│   ├── providers/           # Riverpod providers wiring everything together
│   └── widgets/
├── services/                # Feature services
│   ├── api/                 # Online REST API recognition service
│   ├── camera/              # Camera capture & preprocessing
│   ├── offline_model/       # TensorFlow Lite integration (in progress)
│   └── tts/                 # Text-to-speech (Nepali + English)
└── main.dart
```

---

## 🧠 Recognition Pipelines

**Offline flow:**
```
Camera Preview → Capture Frame → Preprocessing → TFLite Model → Prediction → Display Result → Text-to-Speech
```

**Online flow:**
```
Camera Preview → Capture Frame → Compress Image → HTTP API Request → Receive JSON → Prediction → Text-to-Speech
```

---

## 🛠️ Troubleshooting

**Gradle build fails with `Unresolved reference: Version` in `dependency_version_checker.gradle.kts`**
This is a known Flutter SDK tooling bug tied to using a JDK that's too new. Fix: set `org.gradle.java.home` in `android/gradle.properties` to Android Studio's bundled JDK (see Step 3 above), then run:

*macOS/Linux (bash/zsh):*
```bash
flutter clean
cd android && ./gradlew clean && cd ..
flutter pub get
flutter run
```

*Windows PowerShell:*
```powershell
flutter clean
cd android
.\gradlew clean
cd ..
flutter pub get
flutter run
```

*Windows Command Prompt (cmd.exe):*
```cmd
flutter clean
cd android
gradlew clean
cd ..
flutter pub get
flutter run
```

> ⚠️ Note the difference: `./gradlew` (macOS/Linux), `.\gradlew` (PowerShell), and plain `gradlew` (cmd.exe) are **not interchangeable** — using the wrong one for your shell will give a "not recognized" error.

**"File in use" or corrupted Gradle cache errors**
Stop any running Gradle daemon first:
```bash
cd android
./gradlew --stop      # or .\gradlew --stop (PowerShell) / gradlew --stop (cmd)
cd ..
```
Then delete the folder shown in the error under your Gradle cache (`~/.gradle/caches` on macOS/Linux, `C:\Users\<you>\.gradle\caches` on Windows) and re-run `flutter run`. If the delete fails with a "file in use" error, close Android Studio and any open terminals first, then retry.

**Antivirus locking build files mid-build (Windows)**
If builds intermittently fail with "process cannot access the file," add an exclusion for your project folder and `%USERPROFILE%\.gradle` in Windows Security → Virus & threat protection → Manage settings → Exclusions.

---

## 📦 Tech Stack

- **Flutter** — cross-platform UI framework
- **Riverpod** — state management & dependency injection
- **go_router** — declarative navigation
- **camera** — device camera access
- **flutter_tts** — Nepali/English text-to-speech
- **shared_preferences** — local key-value storage
- **TensorFlow Lite** *(planned)* — offline gesture recognition model

---

## 📄 License

This project is a final year academic project. Add a license here if you intend to share or open-source it further.
