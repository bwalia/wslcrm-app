# Test fixtures

Two kinds of fixture live here:

* `*.json` (this folder) — response bodies written from the OpsAPI Lua response shapers
  (`lapis/queries/*`, `lapis/routes/*`) with the serialisation quirks the live server has:
  NULL columns omitted, empty objects encoded as `[]`, JSON-in-TEXT columns as strings,
  microsecond timestamps, per-module envelopes. `error_catalogued_validation.json` was
  captured verbatim from `int-opsapi.workstation.co.uk`.
* `live/live_*.json` — anonymised responses captured from the int API by
  `scripts/capture-fixtures.py`. `LiveFixtureDecodingTests` decodes every file present,
  so re-running the script re-validates the models against the real server.
