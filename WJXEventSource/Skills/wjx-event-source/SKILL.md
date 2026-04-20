---
name: wjx-event-source
description: Use when building iOS apps that need Server-Sent Events (SSE) real-time streaming in Objective-C. Covers WJXEventSource CocoaPods library for HTML5 SSE client connections, event listening, automatic reconnection, and connection lifecycle management. Triggers: SSE, EventSource, server-sent events, real-time streaming, NSURLSession streaming, event listener pattern, iOS push notifications alternative.
---

# WJXEventSource

HTML5 Server-Sent Events (SSE) client for iOS in Objective-C. Event-listener pattern with automatic reconnection and exponential backoff. Distributed via CocoaPods.

## When to Use

- iOS app needs real-time server push via SSE protocol
- Replacing polling with persistent streaming connection
- Server sends `Content-Type: text/event-stream` responses
- Need auto-reconnect with backoff on disconnect

**Do NOT use for:** WebSocket (SSE is server→client only), iOS 9.x (requires 10.0+), Swift-only without Obj-C interop.

## Installation

```ruby
pod 'WJXEventSource'
```

```objc
#import <WJXEventSource/WJXEventSource.h>
```

## API

### WJXEventSource

| Method / Property | Description |
|---|---|
| `initWithRequest:` | Create SSE client with NSURLRequest |
| `addListener:forEvent:queue:` | Register handler block. Queue defaults to mainQueue if nil. |
| `open` | Start connection. `readyState` → connecting → open |
| `close` | Close connection. No auto-retry after this. |
| `ignoreRetryAction` | `BOOL` (default NO) — disable auto-reconnection |
| `maxRetryCount` | `NSUInteger` (default max) — cap retry attempts |

### Event Name Constants

| Constant | Value | When Fired |
|---|---|---|
| `WJXEventNameMessage` | `@"message"` | Every SSE event received |
| `WJXEventNameOpen` | `@"open"` | Connection established |
| `WJXEventNameReadyState` | `@"readyState"` | State changed |
| `WJXEventNameError` | `@"error"` | Error occurred |

### WJXEvent Properties

| Property | Type | Description |
|---|---|---|
| `eventId` | `id` | SSE `id:` field |
| `event` | `NSString *` | SSE `event:` field (parsed, not used for dispatch) |
| `data` | `NSString *` | SSE `data:` field. Multi-line joined with `\n`. |
| `readyState` | `WJXEventState` | Connecting(0) / Open(1) / Closed(2) |
| `error` | `NSError *` | Error object on error events |

## More

- **Code examples & reconnection details** → see `ADVANCED.md` in this directory
- **Gotchas, common mistakes & SSE protocol** → see `REFERENCE.md` in this directory
