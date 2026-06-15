# FormalInception-ATP

244 Lean 4 proofs for [miniF2F](https://github.com/google-deepmind/miniF2F),
packaged as an encrypted archive: `solutions.7z`, password `rkNE8nBuZyy2Nix7JED9JoUjvehPenS3`.

## Verifying

Needs elan, git, curl, jq, go, 7z, ~6 GB disk, network on first run.

```sh
git submodule update --init vendor/miniF2F
./verify_proofs.sh --7z solutions.7z   # prompts for the password: 123
```

Each proof is built against the verbatim upstream statement and checked
with [leanprover/comparator](https://github.com/leanprover/comparator).
