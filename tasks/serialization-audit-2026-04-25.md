# CaseState serialization audit

- Run: 2026-04-25T08:29:30.704591+00:00
- Fixtures: `tests/fixtures/serialization_edge_cases`
- Serializer: `langgraph.checkpoint.serde.jsonplus.JsonPlusSerializer`
- Total: **5** | Passed: **5** | Failed: **0**

## Per-fixture

| Fixture | Status | Encoded bytes |
| --- | --- | --- |
| `01_tz_aware_datetimes` | ✅ pass | 1034 |
| `02_custom_pydantic_models` | ✅ pass | 1210 |
| `03_enum_values` | ✅ pass | 647 |
| `04_deeply_nested_dict` | ✅ pass | 889 |
| `05_unicode_and_escapes` | ✅ pass | 1227 |

All fixtures round-trip with no field loss. Safe to proceed with
PostgresSaver cutover (Sprint 2 2.A2 chain).

