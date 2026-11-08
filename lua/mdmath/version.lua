--- Single source of truth for the plugin version.
--
-- `mdmath-js/package.json` and `package-lock.json` must match (enforced by
-- tests/js/version.test.mjs), and a release tag must match after dropping the
-- `v` prefix and any prerelease suffix (enforced by .github/workflows/release.yml).
---@type string
return '0.3.0'
