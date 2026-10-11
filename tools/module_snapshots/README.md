# Migrated XRobot module snapshots

These Git bundles contain the project modules migrated to xrobot 1.0.1 and
LibXR v2.0.1. The official xrobot source resolver reads `index.yaml`; the BSP's
`Modules/modules.yaml` and `xrobot.lock` pin each snapshot commit.

The bundles contain source, README, tests and repository metadata, not firmware
build products. `provenance.json` records each original repository and commit,
the migrated snapshot commit, and any local changes already present before
migration. No module was pushed or published to its upstream repository.

Use `xrobot setup --frozen` to restore the exact sources. Review source
with `git -C Modules/pldx/<Name> show HEAD`, or clone a bundle into a temporary
folder. The original working repositories remain in `.tooling/module_worktrees/`
on the migration machine, with their user changes intact.

Future module edits should happen in their own checkout and be reviewed and
published upstream before switching this BSP to remote module pins. Do not run
an unqualified update expecting it to migrate between the bundled and remote
sources automatically.
