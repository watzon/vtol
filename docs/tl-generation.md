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
v fmt -w .
v test .
```

## Generated output

The generator emits:

- `tl/generated_schema_types.v` with constructor and request structs plus object codecs
- `tl/generated_schema_dispatch.v` with decode dispatch, typed union decoders, and layer metadata

Generated union-like result families use V interfaces such as `InputPeerType`, `UserType`, and `UpdatesType`.

## Compatibility process

When Telegram bumps layers:

1. Run `v run scripts/fetch_schemas.vsh` to snapshot the new Telethon inputs.
2. Review `tl/schema/snapshot.json` for layer and blob-sha changes.
3. Run `v run scripts/gen_tl.vsh`.
4. Run `v test .`.
5. If request/session behavior changed, keep runtime compatibility work in later phases separate from the generated schema commit.

## Unknown constructors

Top-level unknown constructors decode into `tl.UnknownObject` and preserve the constructor ID plus raw payload bytes for round-tripping. Nested unknown constructor recovery still depends on regenerating against the newer layer.
