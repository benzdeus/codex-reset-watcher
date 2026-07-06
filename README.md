# Codex Reset Watcher for Windows

Small Windows tray utility for checking Codex usage limits and banked bonus/reset credit expiry.

It is read-only. It reads your existing local Codex Desktop login from `CODEX_HOME` or `%USERPROFILE%\.codex\auth.json`, then calls the same internal Codex Desktop endpoints:

```text
GET https://chatgpt.com/backend-api/wham/usage
GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits
```

The app shows:

- 5-hour and weekly usage remaining
- model-specific usage windows when Codex returns them
- reset timing for each usage window
- banked bonus/reset credits and how many days remain before expiry
- dark compact UI
- always-on-top by default, with an in-window toggle
- optional launch on Windows startup

No OpenAI API key is required.

## Run

From PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File script\build_and_run.ps1
```

For a one-shot console check:

```powershell
powershell -ExecutionPolicy Bypass -File script\build_and_run.ps1 -Check
```

## Install Shortcuts

Create Desktop and Start Menu shortcuts:

```powershell
powershell -ExecutionPolicy Bypass -File script\build_and_run.ps1 -InstallShortcut
```

After that, launch **Codex Reset Watcher** from the shortcut.

Remove the shortcuts:

```powershell
powershell -ExecutionPolicy Bypass -File script\build_and_run.ps1 -UninstallShortcut
```

## Settings

Settings are stored locally at:

```text
%APPDATA%\Codex Reset Watcher\settings.json
```

Windows startup is stored under the current user Run key:

```text
HKCU\Software\Microsoft\Windows\CurrentVersion\Run
```

No admin permission is required.

## Files

```text
Windows/CodexResetWatcherTray.ps1
script/build_and_run.ps1
```

## Limitations

- This is unofficial and not affiliated with OpenAI.
- The Codex endpoints are internal and may change without notice.
- The app does not redeem resets, reset usage, mutate account state, or send analytics.

## License

MIT. See [LICENSE](LICENSE).
