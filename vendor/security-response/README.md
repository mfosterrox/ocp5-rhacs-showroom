# Security response upstream snapshot

Filtered copy of the OpenShift security response workshop from [jmhbnz/workshops](https://github.com/jmhbnz/workshops).

Refresh this directory with:

```bash
updates/sync-security-response.sh
```

The script updates the GitHub fork from `jmhbnz/workshops` when `gh` can see that fork, then copies an allowlist. It does not change pages under `content/modules/security-response`. After a refresh, review this snapshot and edit those pages by hand.

This snapshot omits `exercise4.mdx` and `setup/exercise4/exploit/` (the live exploit walkthrough and payload). See `UPSTREAM` for the fetched commit.

The files in this directory are GPL-3.0. See `LICENSE`. The rest of the roadshow repository stays under the Apache-2.0 license at the repository root.
