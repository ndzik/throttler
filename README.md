# Throttler

Call with:

```
Usage: throttler [-p|--port PORT] UPSTREAM_URLS...
```

or straight with `cabal`:

```
$ cabal run throttler -p 8888 "http://127.0.0.1:54321" "http://127.0.0.1:8000"
```

Runs on `localhost:8888` by default.

All requests made to this server will be throttled configurable via the TUI and forwarded to the given URL. Also works for TUS uploads and WebSockets.

## Commands

- Use `<TAB>` to switch between input fields.
- **Rate (KBit/s)** - The upload rate targeted. This limits the rate at which the proxy will
  accept chunks of data from the client in a request. E.g. uppy uploads in multiple PATCH requests.
  Each PATCH would then be limited with the rate set here.
- **Drop (%)** - The percentage of requests to drop. The proxy will simply drop the request.
- **Disconnect (%)** - The probability of disconnecting an accepted request which is currently being
  processed.

**Everything can be changed at runtime and every request will immediately be affected by the new settings.**

![img](https://github.com/user-attachments/assets/05f313d2-4646-4d2a-85f8-5abb4108d0fd)
