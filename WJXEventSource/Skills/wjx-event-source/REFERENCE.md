# WJXEventSource — Reference & Troubleshooting

Gotchas, common mistakes, and SSE protocol details for WJXEventSource.

## Common Mistakes

| Mistake | Fix |
|---|---|
| Not calling `close` in `dealloc` | Always call `[_source close]` to prevent reconnection after owner is deallocated |
| Using `nil` request | `initWithRequest:` requires a valid NSURLRequest |
| Listening only to `message` for a named SSE event | Register the exact `event:` value with `forEvent:` |
| Forgetting `NSURLRequestReloadIgnoringCacheData` | SSE requires no caching — use this cache policy |
| Blocking main thread in handler | Use a custom `NSOperationQueue` for heavy processing |

## Gotchas

1. **Named event dispatch**: The `event:` field selects the listener event name. Events without an `event:` field use `WJXEventNameMessage`:
   ```objc
   [source addListener:^(WJXEvent *event) {
       // Handle `event: update`
   } forEvent:@"update" queue:nil];
   ```

2. **Content-Type validation**: Responses without `text/event-stream` Content-Type are rejected with `NSURLSessionResponseCancel` and an error event is dispatched.

3. **Callback queues**: NSURLSession delegate callbacks run on WJXEventSource's private serial operation queue. Handler queues default to `mainQueue` if nil. Use explicit background queues for heavy work.

4. **Lifecycle races**: `open` and `close` increment an internal state generation. Delegate events revalidate that generation before listener callbacks run, so superseded tasks cannot emit into a newer connection.

5. **Thread-safe listeners**: Listener dictionary uses a concurrent GCD queue with barrier writes. Snapshot is taken synchronously before enumeration — safe to add/remove listeners during event dispatch.

6. **`WJX_EXTERN` macro**: Public symbols use `extern "C"` with visibility attribute for C++ compatibility. Import the header in `.mm` files without issues.

7. **Import style**: Use framework-style import: `#import <WJXEventSource/WJXEventSource.h>`

## SSE Protocol Fields Supported

| Field | Example | Behavior |
|---|---|---|
| `id:` | `id: 123` | Stored as `event.eventId`, sent as `Last-Event-ID` on reconnect |
| `event:` | `event: update` | Stored as `event.event` and used as the listener event name |
| `data:` | `data: hello` | Stored as `event.data`. Multiple `data:` lines joined with `\n` |
| `retry:` | `retry: 5000` | Sets base retry interval in milliseconds (converted to seconds) |

Events separated by blank line (`\n\n`). Buffer parsing uses binary `NSData rangeOfData:` matching.
