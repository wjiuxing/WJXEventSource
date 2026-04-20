# WJXEventSource

[中文版](README_CN.md)

![Platform](https://img.shields.io/badge/platform-iOS%2010.0%2B-lightgrey)
![License](https://img.shields.io/badge/license-MIT-blue)
![Language](https://img.shields.io/badge/language-Objective--C-orange)
![CocoaPods](https://img.shields.io/badge/CocoaPods-compatible-4BC51D)

HTML5 Server-Sent Events (SSE) client for iOS, implemented in Objective-C. Inspired by [EventSource](https://github.com/neilco/EventSource).

## Features

- HTML5 SSE protocol compliance (parsing `id`, `event`, `data`, `retry` fields)
- Event-listener pattern with `addListener:forEvent:queue:`
- Automatic reconnection with exponential backoff
- Configurable max retry count
- Thread-safe listener management (concurrent GCD queue with barrier writes)
- Content-Type validation (rejects non-`text/event-stream` responses)
- `Last-Event-ID` header sent on reconnection
- Optional callback queue targeting (defaults to main queue)
- Zero external dependencies
- CocoaPods integration

## Requirements

- iOS 10.0+
- ARC enabled
- Objective-C

## Installation

### CocoaPods

Add to your Podfile:

```ruby
pod 'WJXEventSource'
```

Then run:

```bash
pod install
```

## Usage

### Quick Start

```objc
#import <WJXEventSource/WJXEventSource.h>

NSURL *URL = [NSURL URLWithString:@"http://example.com/sse"];
NSURLRequest *request = [NSURLRequest requestWithURL:URL
                                         cachePolicy:NSURLRequestReloadIgnoringCacheData
                                     timeoutInterval:60];

WJXEventSource *source = [[WJXEventSource alloc] initWithRequest:request];

[source addListener:^(WJXEvent *event) {
    NSLog(@"message: %@", event.data);
} forEvent:WJXEventNameMessage queue:[NSOperationQueue mainQueue]];

[source addListener:^(WJXEvent *event) {
    NSLog(@"connected");
} forEvent:WJXEventNameOpen queue:nil];

[source addListener:^(WJXEvent *event) {
    NSLog(@"error: %@", event.error);
} forEvent:WJXEventNameError queue:nil];

[source open];
```

Don't forget to call `close` when done:

```objc
[source close];
```

### Built-in Event Names

| Constant | Value | Description |
|---|---|---|
| `WJXEventNameMessage` | `@"message"` | SSE message events |
| `WJXEventNameOpen` | `@"open"` | Connection opened |
| `WJXEventNameReadyState` | `@"readyState"` | Connection state changed |
| `WJXEventNameError` | `@"error"` | Error occurred |

### Reconnection Behavior

WJXEventSource automatically reconnects when the connection drops, with exponential backoff:

- **Base retry interval**: 3.0 seconds (default)
- **Server override**: The server can send a `retry:` field (in milliseconds) to change the interval
- **Delay formula**: `retryInterval × 2^min(retryCount, 6)` — capped at a 64× multiplier
- **Reset**: `retryCount` resets to 0 on each successful connection
- **Disable**: Set `ignoreRetryAction = YES` to disable all automatic retries
- **Limit**: Set `maxRetryCount` to cap the total number of retry attempts (default: unlimited)

```objc
source.ignoreRetryAction = NO;     // default — auto-retry enabled
source.maxRetryCount = 10;          // limit to 10 retry attempts
```

## API Reference

### WJXEventSource

| Method / Property | Description |
|---|---|
| `initWithRequest:` | Initialize with an `NSURLRequest` |
| `addListener:forEvent:queue:` | Register an event handler block for a given event name. The `queue` parameter specifies the `NSOperationQueue` to execute the handler on; defaults to `mainQueue` if `nil`. |
| `open` | Open the SSE connection |
| `close` | Close the connection. No automatic retry will occur after calling this. |
| `ignoreRetryAction` | `BOOL` — Set `YES` to disable automatic reconnection (default `NO`) |
| `maxRetryCount` | `NSUInteger` — Maximum number of retry attempts (default `NSUIntegerMax`, unlimited) |

### WJXEvent

| Property | Type | Description |
|---|---|---|
| `eventId` | `id` (nullable) | The SSE event ID |
| `event` | `NSString *` (nullable) | The event type name |
| `data` | `NSString *` (nullable) | Event data. Multi-line `data:` fields are joined with `\n` per the SSE spec. |
| `readyState` | `WJXEventState` | Current connection state |
| `error` | `NSError *` (nullable) | Error object, if applicable |

### WJXEventState

| Value | Description |
|---|---|
| `WJXEventStateConnecting` (0) | Connection in progress |
| `WJXEventStateOpen` (1) | Connection established |
| `WJXEventStateClosed` (2) | Connection closed |

## License

WJXEventSource is available under the MIT license. See the [LICENSE](LICENSE) file for more info.

## Acknowledgements

Inspired by [EventSource](https://github.com/neilco/EventSource) by Neil Cowburn.
