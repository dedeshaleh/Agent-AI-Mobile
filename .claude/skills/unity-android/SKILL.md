---
name: unity-android
description: Drive Unity Hub and the Unity Editor headlessly on this PC — list or install editors and Android modules, and build Android APKs in batchmode. Use for any Unity install, module, or build task, or when the Unity Hub CLI prints "Cannot find module '--headless'".
---

# Unity on this PC

- Unity Hub is an MSIX package (location fixed by Windows):
  `C:\Program Files\WindowsApps\UnityTechnologies.UnityHub_*\app\Unity Hub.exe`. Resolve it with `Get-AppxPackage UnityTechnologies.UnityHub` + `\app\Unity Hub.exe`.
- Editors install to `D:\MobileDeveloper\Unity\Editors\<version>` (check with `install-path --get`).
- Preferred version: Unity 6.3 LTS `6000.3.26f1`. Ask before uninstalling any editor.

## Hub CLI

`ELECTRON_RUN_AS_NODE=1` is inherited from VS Code and makes Hub run as plain Node ("Cannot find module '--headless'"). Always remove it first, and use `Start-Process` with redirected output because Hub doesn't write to the console otherwise:

```powershell
Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
$hub = (Get-AppxPackage UnityTechnologies.UnityHub).InstallLocation + '\app\Unity Hub.exe'
$out = '<scratchpad>\hub.out'
$p = Start-Process $hub -ArgumentList @('--','--headless','editors','--installed') -RedirectStandardOutput $out -RedirectStandardError "$out.err" -NoNewWindow -Wait -PassThru
Get-Content $out
```

Useful argument lists:

| Task | Arguments after `--`,`--headless` |
|---|---|
| Installed editors | `editors --installed` |
| Available releases | `editors --releases` |
| Install editor + Android | `install --version 6000.3.26f1 --module android android-sdk-ndk-tools android-open-jdk --childModules` |
| Add Android to an existing editor | `install-modules --version 6000.3.26f1 --module android android-sdk-ndk-tools android-open-jdk --childModules` |
| Uninstall editor | `uninstall --version <v>` (only when the user asks) |

Installs are several GB: run them in the background and verify afterwards that `Editor\Data\PlaybackEngines\AndroidPlayer\{SDK,NDK,OpenJDK}` exist. Don't trust the exit code alone.

The first launch needs a Unity account sign-in and Personal license activation in the Hub GUI. Only the user can do that.

## Batchmode build

```powershell
$unity = 'D:\MobileDeveloper\Unity\Editors\6000.3.26f1\Editor\Unity.exe'
& $unity -batchmode -quit -nographics -projectPath <project> -buildTarget Android `
  -executeMethod BuildScript.BuildAndroid -logFile <scratchpad>\unity_build.log
```

- `BuildScript.BuildAndroid` must exist in `Assets/Editor/`. Set `PlayerSettings.Android.targetArchitectures = AndroidArchitecture.ARM64` and IL2CPP scripting backend there.
- Unity returns before the log is complete when launched from PowerShell. Wait on the process (`Start-Process -Wait`), then read the log tail for `Build succeeded`/`error CS`. Report errors from the log, not just the exit code.
- Close any open Editor on the same project first, or batchmode fails with a project lock.
