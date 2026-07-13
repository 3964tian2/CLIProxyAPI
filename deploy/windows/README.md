# CPA local optimization protection

This directory is the canonical, versioned source for the Windows maintenance files deployed to
`D:\program\CPA\maintenance`.

The protection workflow keeps three independent recovery layers:

1. the committed customization in the local Git fork;
2. `.protected` inside the CPA installation;
3. a DPAPI-protected mirror under `%USERPROFILE%\.codex\protected-software\CPA`.

`config.yaml` and API credentials must never be committed. The protected copies use Windows DPAPI
for the current user. The startup stub always delegates to `launch_cpa.ps1`, which always supplies
the absolute `-config` path.

Canonical deployment copies live in `D:\program\CPA\maintenance`. `protect_installation.ps1`
refreshes both protected locations only from a clean `main` checkout and a clean executable whose
embedded VCS revision matches `HEAD`. It verifies the Git bundle, executable hash, and an in-memory
DPAPI decrypt/hash check without printing configuration content.

Recovery can be checked without changing the installation:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  D:\program\CPA\maintenance\restore_installation.ps1 -VerifyOnly
```

Supported update and recovery paths never clone the public upstream directly. They use the local
customization fork or the protected Git bundle so the transport reuse change and the opencode-go
account support remain present.
