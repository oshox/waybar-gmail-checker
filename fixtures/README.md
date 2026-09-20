# Fixtures

Canned Gmail API responses for `WAYBAR_GMAIL_FIXTURE=<this directory>`. Every
file is the small envelope `http.zig`'s fixture mode expects:

```json
{"status": 200, "body": { ...the real Gmail API response shape... }}
```

`status` other than 200 lets error paths (401, 403, 500, ...) be tested
exactly like success paths -- see `messages/msg-unauthorized.json` and
`trash/msg-unauthorized.json`.

Try it:

```sh
WAYBAR_GMAIL_FIXTURE=$PWD/fixtures ./zig-out/bin/waybar-gmail status
```

## What's deliberately nasty in here

Per the M2 plan, this set exists to stress the RFC 2047 decoder
(`src/mime.zig`) and the rest of the pipeline with real-world-shaped ugly
data, not just clean happy-path JSON:

| id | what it tests |
|---|---|
| `msg-plain` | the ordinary case: plain ASCII headers |
| `msg-rfc2047-b` | RFC 2047 base64-encoded UTF-8 subject (café, ☕) |
| `msg-rfc2047-q` | RFC 2047 quoted-printable subject, with `_` as space |
| `msg-emoji` | raw (un-encoded) UTF-8 emoji directly in the header, as real modern mail clients send it |
| `msg-rtl` | right-to-left script (Arabic) in From and Subject |
| `msg-long-subject` | a ~1.9 KB subject line, to make sure nothing truncates mid-codepoint or assumes headers are short |
| `msg-empty-snippet` | an empty snippet string |
| `msg-bad-utf8` | an RFC 2047 word claiming `UTF-8` whose base64-decoded bytes (`0xFF 0xFE`) are **not** valid UTF-8 -- exercises `mime.zig`'s U+FFFD replacement, since a real spammer's mis-declared charset is exactly this shape |
| `msg-unauthorized` | `messages/` and `trash/` fixtures returning HTTP 401, for testing the "unauthenticated" error path |

`messages_list.json` lists all of the above except `msg-unauthorized` (which
represents a message that existed at list time but whose per-message call
later fails -- e.g. a permissions change mid-session).
