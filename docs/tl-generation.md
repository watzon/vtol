# TL Generation

## Source of truth

VTOL snapshots Telegram TL definitions from Telethon's `telethon_generator/data` directory.

- `tl/schema/raw/mtproto.tl`
- `tl/schema/raw/api.tl`
- `tl/schema/snapshot.json`
- `tl/schema/normalized.tl`

The snapshot metadata records:

- the Telegram layer
- the Telethon source URLs
- the upstream blob SHAs
- the normalized schema path

## Workflow

Refresh the pinned schema inputs:

```bash
v run scripts/fetch_schemas.vsh
```

Regenerate the `tl` module:

```bash
v run scripts/gen_tl.vsh
```

Validate the result:

```bash
v run scripts/check_tl_schema.vsh
v fmt -w .
v test .
```

## Generated output

The generator emits:

- `tl/generated_schema_types.v` with constructor and request structs plus object codecs
- `tl/generated_schema_dispatch.v` with decode dispatch, typed union decoders, layer metadata, and a generated `current_function_registry()`

Generated union-like result families use V interfaces such as `InputPeerType`, `UserType`, and `UpdatesType`.

`current_function_registry()` is the checked-in inventory of every generated TL request for the pinned layer. The test suite compares it against `tl/schema/normalized.tl`, so method coverage is enforced rather than inferred from code generation counts alone.

## Compatibility process

When Telegram bumps layers:

1. Run `v run scripts/fetch_schemas.vsh` to snapshot the new Telethon inputs.
2. Review `tl/schema/snapshot.json`, `tl/schema/normalized.tl`, and the raw TL files for the expected layer and upstream blob-sha changes.
3. Run `v run scripts/gen_tl.vsh`.
4. Run `v run scripts/check_tl_schema.vsh` to confirm the checked-in generated files exactly match the pinned snapshot.
5. Run `v fmt -w .` and `v test .`.
6. Run the credential-gated integration suite when the layer bump affects auth, session recovery, updates, or request/response decoding behavior.
7. Keep purely generated schema refreshes separate from follow-up runtime compatibility fixes when a layer bump needs code changes outside `tl/`.

`scripts/check_tl_schema.vsh` is also part of CI. If it fails, the repository contains a stale `tl/generated_schema_types.v` or `tl/generated_schema_dispatch.v` relative to `tl/schema/snapshot.json` and `tl/schema/normalized.tl`.

## Unknown constructors

Top-level unknown constructors decode into `tl.UnknownObject` and preserve the constructor ID plus raw payload bytes for round-tripping.

Typed union decoders also preserve unknown constructors by wrapping them in generated fallback types such as `tl.UnknownInputPeerType` or `tl.UnknownUserStatusType`, so result decoding and tail-position nested fields can survive a layer bump without an immediate regeneration.

Unknown constructors still cannot be losslessly skipped in the middle of a larger object, because boxed TL objects do not carry a byte length on the wire. When that happens, regenerate against the newer layer before relying on fields that follow the unknown value.
