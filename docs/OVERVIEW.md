# Overview

```yaml
Overview:
  description: >
    Personal devtools setup repository: scripts that configure a development
    machine's toolchain (package managers, shells, editors) consistently
    across Linux, macOS, and Windows (Git Bash/MSYS2).
  subsystems:
    scripts: Standalone bash scripts, one concern per script, run directly by the user.
    docs: This overview plus per-feature docs under docs/features/.
  data_flow: >
    Each script detects the host OS and installed tools, then writes
    user/global-level configuration files in the locations each tool expects
    on that OS. Scripts are idempotent: re-running updates values in place.

Features Index:
  cooldowns:
    description: >
      Set a minimum release age (supply-chain cooldown) for every installed
      package manager that supports it natively (npm, pnpm, yarn, bun, deno,
      uv, pip, poetry, cargo, bundler, composer, hex, mise), warning where the
      installed version is too old and noting managers it leaves alone.
    entry_points: [scripts/cooldowns.sh]
    depends_on: []
    doc: docs/features/cooldowns.md
```
