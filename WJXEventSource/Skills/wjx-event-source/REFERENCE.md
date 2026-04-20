# WJXEventSource — Reference & Troubleshooting

Gotchas, common mistakes, and SSE protocol details for WJXEventSource.

## Common Mistakes

| Mistake | Fix |
|---|---|
| Not calling `close` in `dealloc` | Always call `[_source close]` to prevent reconnection after owner is deallocated |
| Using `nil` request | `initWithRequest:` requires a valid NSURLRequest |
| Expecting custom event dispatch | All SSE events dispatch to `WJXEventNameMessage` only — check `event.event` property inside the handler to filter |
| Forgetting `NSURLRequestReloadIgnoringCacheData` | SSE requires no caching — use this cache policy |
| Blocking main thread in handler | Use a custom `NSOperationQueue` for heavy processing |

## Gotchas

1. **No custom event dispatch**: The `event:` field from SSE is parsed and stored on `WJXEvent.event`, but `_dispatchEvent:` always uses `WJXEventNameMessage`. To handle different event types, check `event.event` inside your message handler:
   ```objc
   [source addListener:^(WJXEvent *event) {
       if ([event.event isEqualToString:@"update"]) {
           // handle update event
       } else if ([event.event isEqualToString:@"notification"]) {
           // handle notification event
       }
   } forEvent:WJXEventNameMessage queue:nil];
   ```

2. **Content-Type validation**: Responses without `text/event-stream` Content-Type are rejected with `NSURLSessionResponseCancel` and an error event is dispatched.

3. **Main thread callbacks**: NSURLSession delegate queue is `mainQueue` — all delegate methods fire on main thread. Handler queue also defaults to `mainQueue` if nil. Use explicit background queues for heavy work.

4. **`setDataTask:` side effects**: The setter cancels the previous task and toggles `closedByUser` to prevent spurious reconnection. This is intentional.

5. **Thread-safe listeners**: Listener dictionary uses a concurrent GCD queue with barrier writes. Snapshot is taken synchronously before enumeration — safe to add/remove listeners during event dispatch.

6. **`WJX_EXTERN` macro**: Public symbols use `extern "C"` with visibility attribute for C++ compatibility. Import the header in `.mm` files without issues.

7. **Import style**: Use framework-style import: `#import <WJXEventSource/WJXEventSource.h>`

## SSE Protocol Fields Supported

| Field | Example | Behavior |
|---|---|---|
| `id:` | `id: 123` | Stored as `event.eventId`, sent as `Last-Event-ID` on reconnect |
| `event:` | `event: update` | Stored as `event.event` (parsed, NOT used for targeted dispatch) |
| `data:` | `data: hello` | Stored as `event.data`. Multiple `data:` lines joined with `\n` |
| `retry:` | `retry: 5000` | Sets base retry interval in milliseconds (converted to seconds) |

Events separated by blank line (`\n\n`). Buffer parsing uses binary `NSData rangeOfData:` matching.
