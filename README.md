# Flora

<p align="center">
  <img src="assets/logo.png" alt="Flora logo" width="260" />
</p>

<p align="center">
  <strong>Code. Preview. Chat.</strong>
</p>

Flora is a Flutter desktop workspace for building Flutter apps with a tighter feedback loop. It combines a project-aware chat assistant, an embedded app preview, and DevTools-driven inspection in one glassy interface so you can stay in the flow while you work.

Instead of bouncing between a code editor, a browser window, and a separate debugger, Flora keeps the core development tools together. The app preview can run inside Flora itself, and the inspector context can be captured directly from the currently selected widget so assistant prompts can stay precise and targeted.

The experience is built around speed and focus. Flora remembers your project folder, keeps the preview controls close at hand, and exposes build-type switching for web, desktop app, and mobile workflows. It is designed to feel like a compact command center for Flutter iteration rather than a generic chat UI.

## Highlights

- Embedded app preview for Flutter web runs
- DevTools integration for widget inspection and debugging
- Project-aware Codex chat with file and inspector context
- Persistent workspace settings for project root and assistant preferences
- Clean desktop shell with resizable panes and a focused layout

## Getting Started

1. Install Flutter and ensure `flutter` is available on your `PATH`.
2. Clone this repository and open it in your editor.
3. Run the app with:

```bash
flutter pub get
flutter run
```

## Windows Releases

Flora can be packaged as a normal Windows desktop build or as an installer.

Portable release build:

```powershell
flutter build windows --release
```

The release executable is generated in `build/windows/x64/runner/Release/`.

Installer build:

```powershell
scripts\build-windows-release.bat
```

That script runs `flutter pub get`, builds the Windows release, creates an MSIX installer, and also writes a portable zip bundle under `dist/windows/`.

## Notes

- The preview experience is optimized for desktop use.
- Web preview is the best fit for embedded rendering inside Flora.
- Project settings are stored locally so your workspace feels consistent between sessions.
- If you distribute the MSIX outside a developer machine, you should sign it with a real certificate for a smoother install experience.
