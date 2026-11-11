## What this changes

<!-- What and why, in a few sentences. Link the issue if there is one. -->

## How it was checked

<!-- Tests added or changed, and what you ran. For a hot path, the benchmark numbers before and after. -->

## Checklist

- [ ] Every commit is signed off (`git commit -s`, see CONTRIBUTING.md)
- [ ] `cargo fmt --check` and `cargo clippy --workspace --all-targets -- -D warnings` pass
- [ ] `cargo test --workspace` passes; Swift changes pass `scripts/test-app.sh`
- [ ] New strings went through `scripts/l10n.sh` and are translated (docs/LOCALIZATION.md)
- [ ] A new dependency: `scripts/licenses.sh` run and `THIRD_PARTY_LICENSES.md` committed
- [ ] No personal paths, names, real photos or secrets in code, fixtures or docs
