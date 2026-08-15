# Windows TSF adapter

This in-process COM DLL implements a per-user Text Services Framework text
service and delegates conversion to one resident standalone NeLisp worker.

Build using Visual Studio CMake, then install the per-user profile:

```powershell
cmake -S platform/windows/tsf -B platform/windows/tsf/build
cmake --build platform/windows/tsf/build --config Release
platform\windows\tsf\build\Release\nelisp-ime-tsf-smoke.exe `
  platform\windows\tsf\build\Release\nelisp-ime-tsf.dll
platform\windows\tsf\install.ps1
```

The installer copies the runtime and resources under
`%LOCALAPPDATA%\NeLispIME` and registers the TSF profile per user. Run
`uninstall.ps1` to unregister and remove it. Environment overrides remain
available for development builds.
