# Integration Tests

Integration tests are reserved for authenticated Telegram scenarios such as bot login, reconnect, update recovery, and media transfer.

## Required environment

- `VTOL_TEST_API_ID`
- `VTOL_TEST_API_HASH`
- `VTOL_TEST_BOT_TOKEN`

## Optional environment

- `VTOL_TEST_DC_HOST` to override the default production DC host
- `VTOL_TEST_MODE=1` to target Telegram test DC behavior where relevant

The default `v test .` run stays deterministic because these tests return immediately when the required credentials are absent.
