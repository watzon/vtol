# MTProto Notes

## Scope for the initial implementation

- Build toward a user-client MTProto library, not the HTTP Bot API.
- Start with MTProto 2.0 transport and authorization flows.
- Treat TL schema generation as mandatory for complete API coverage.

## Protocol priorities

1. Binary TL codec correctness
2. Transport framing and reconnect behavior
3. Auth key exchange and session persistence
4. RPC orchestration, retries, and DC migration
5. Updates, media flows, and ergonomic client APIs

## Crypto direction

- Start with C-backed crypto wrappers behind V module boundaries.
- Keep the wrapper surface narrow so pure V replacements remain possible later.
- Add vectors early because MTProto correctness depends on exact byte behavior.

## Telethon-like target

“Telethon-like” here means:

- user-account login flows
- generated Telegram API coverage
- long-lived sessions
- update subscription support
- media transfer support
- ergonomic wrappers that remain thin over generated TL methods

## Known implementation constraints

- Telegram layer evolution requires a repeatable schema ingestion and generation pipeline.
- MTProto session correctness depends on persisted auth keys, salts, session IDs, and sequence handling.
- Update processing must tolerate reconnects, gaps, and duplicate delivery.
