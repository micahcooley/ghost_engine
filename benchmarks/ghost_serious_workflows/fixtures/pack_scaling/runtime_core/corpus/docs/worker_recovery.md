# Worker Recovery

When sync retries grow, the worker keeps the retry window bounded.
Recovery replays only the last safe checkpoint and avoids runaway routing.
Pack activation should never overrule the local runtime truth path.
