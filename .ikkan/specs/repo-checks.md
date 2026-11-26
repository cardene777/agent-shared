# repo-checks

| Criterion | How to check | Origin |
|---|---|---|
| The `Reached checks` field of `.ikkan/checks.md` names `bash tests/test-agent-shared.sh`, and the tests refuse a file without that row or with an empty command | `bash tests/test-agent-shared.sh` check `"the ikkan gates run these tests as the reached checks"` passes | #41 |
| The other tests keep passing | `bash tests/test-agent-shared.sh` ends with 0 | #41 |
