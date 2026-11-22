# Vendored appflowy_editor

Copied from https://github.com/AppFlowy-IO/appflowy-editor at commit
01eccc6ee36bd07698bd80915289fe7070478cd2 (2026-10-17), license MPL-2.0 / AGPL-3.0 (see LICENSE).

Local patches are marked with `// PATCH(notes #NNN)` and listed in ../../ISSUES.md.
To find them: `rg "PATCH\(notes" lib`

## Other vendored packages (notes #063)

- `packages/super_native_extensions` (0.9.1), `packages/irondash_engine_context` (0.5.5): copied from pub.dev for one fix. Their Android build script (`cargokit/gradle/plugin.gradle`) used `Project.exec`, removed in Gradle 9; it now runs the build tool with `ProcessBuilder`. Used through `dependency_overrides` in `app/pubspec.yaml`.
