# Throttler

Call with:

```
$ cabal run throttler "http://<your-domain>"
```

Runs on `localhost:8888` by default.

All requests made to this server will be throttled configurable via the TUI and forwarded to the given URL. Also works for TUS uploads and WebSockets.
