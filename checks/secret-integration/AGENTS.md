# Secret Integration Test

Integration tests for the `mcl secret` CLI command, exercising the full
encrypt / decrypt / re-encrypt flow against a real NixOS configuration.

## Running

```bash
nix run .#checks.x86_64-linux.secret-integration
```

## Architecture

Three components work together:

| Component                                | Role                                                                                                                                                                                                         |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `modules/host-info.nix`                  | NixOS option module — defines `mcl.host-info.configPath` (must be a valid relative subpath, validated via `lib.path.subpath.isValid`). Changed from `types.path` to `types.str` to avoid Nix store coercion. |
| `modules/secrets.nix`                    | NixOS option module — defines `mcl.secrets.services.<name>.recipients` and derives the on-disk secrets directory from `configPath + "/secrets"`.                                                             |
| `packages/mcl/src/mcl/commands/secret.d` | D CLI implementation — `mcl secret edit`, `re-encrypt`, and `re-encrypt-all` subcommands. Resolves `configPath` and `recipients` via `nix eval`, then invokes `age` for encryption/decryption.               |

### Key invariant

`configPath` is a **relative subpath** (e.g. `machines/desktop/my-host`).
The CLI uses it directly as a filesystem path from CWD, so it must point to
a writable directory in the repo checkout. It must **not** be a Nix store
path (`/nix/store/...`), which would be read-only.

## Test structure

`default.nix` sets up:

1. A minimal `nixosConfigurations.test-secret-machine` with `mcl-host-info`
   and `mcl-secrets` modules, using test SSH keys from `test-keys/`.
2. A `writeShellApplication` check that runs `test-mcl-secret.sh` with
   `mcl`, `age`, `git`, and `nix` on `PATH`.

`test-mcl-secret.sh` covers four scenarios:

| Test | Subcommand                  | What it verifies                                          |
| ---- | --------------------------- | --------------------------------------------------------- |
| 1    | `mcl secret edit`           | Creates a new `.age` secret and decrypts it back          |
| 2    | `mcl secret edit`           | Edits an existing secret (overwrites ciphertext)          |
| 3    | `mcl secret re-encrypt`     | Re-encrypts a service folder; content is preserved        |
| 4    | `mcl secret re-encrypt-all` | Re-encrypts all services using `configPath`-derived paths |

### Test environment setup

- The test runs from the repo root so that `nix eval .#...` resolves
  the flake naturally. A temp directory is used only for secrets output.
- A fake `$EDITOR` script copies a prepared cleartext file into the
  target, simulating user input without interactive editing.

## Files

```
checks/secret-integration/
├── default.nix            # NixOS config + Nix check derivation
├── test-mcl-secret.sh     # Bash test script (uses @-substitution vars)
├── test-keys/             # Test HOME directory
│   └── .ssh/              # Keys laid out for $HOME/.ssh auto-discovery
│       ├── id_ed25519
│       ├── id_ed25519.pub
│       └── extra_id_ed25519.pub
└── AGENTS.md              # This file
```
