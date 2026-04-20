# WJXEventSource — Code Examples & Reconnection

Code examples for WJXEventSource usage and reconnection behavior details.

## Basic Connection

```objc
#import <WJXEventSource/WJXEventSource.h>

NSURL *URL = [NSURL URLWithString:@"https://example.com/sse"];
NSURLRequest *request = [NSURLRequest requestWithURL:URL
                                         cachePolicy:NSURLRequestReloadIgnoringCacheData
                                     timeoutInterval:60];

WJXEventSource *source = [[WJXEventSource alloc] initWithRequest:request];

// Listen for messages
[source addListener:^(WJXEvent *event) {
    NSLog(@"data: %@", event.data);
} forEvent:WJXEventNameMessage queue:[NSOperationQueue mainQueue]];

// Listen for connection open
[source addListener:^(WJXEvent *event) {
    NSLog(@"connected");
} forEvent:WJXEventNameOpen queue:nil];

// Listen for errors
[source addListener:^(WJXEvent *event) {
    NSLog(@"error: %@", event.error);
} forEvent:WJXEventNameError queue:nil];

[source open];
```

## Lifecycle Management

```objc
// In UIViewController / lifecycle owner
@property (nonatomic, strong) WJXEventSource *source;

- (void)dealloc {
    [_source close];  // Always close to stop reconnection
}
```

## Custom Retry Configuration

```objc
WJXEventSource *source = [[WJXEventSource alloc] initWithRequest:request];

source.maxRetryCount = 10;          // Limit to 10 retries
source.ignoreRetryAction = NO;       // Default — auto-retry enabled

// To disable auto-retry entirely:
// source.ignoreRetryAction = YES;
```

## Background Queue Handler

```objc
// Process events on background queue (avoid blocking main thread)
NSOperationQueue *bgQueue = [[NSOperationQueue alloc] init];
bgQueue.maxConcurrentOperationCount = 1;

[source addListener:^(WJXEvent *event) {
    // Heavy processing here — parsing JSON, DB writes, etc.
    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:[event.data dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
} forEvent:WJXEventNameMessage queue:bgQueue];
```

## Request Headers (Auth, Custom Headers)

```objc
NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL
                                                       cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                   timeoutInterval:60];
[request setValue:@"Bearer token123" forHTTPHeaderField:@"Authorization"];
[request setValue:@"text/event-stream" forHTTPHeaderField:@"Accept"];

WJXEventSource *source = [[WJXEventSource alloc] initWithRequest:request];
```

## Reconnection Behavior

Automatic reconnection with exponential backoff when connection drops (and `ignoreRetryAction == NO`):

- **Base interval**: 3.0 seconds (default)
- **Server override**: Server can send `retry: 5000` (milliseconds) to change base
- **Delay formula**: `retryInterval × 2^min(retryCount, 6)` — max 64× multiplier
- **Reset**: `retryCount` resets to 0 on successful 200 response
- **Last-Event-ID**: Sent as `Last-Event-ID` HTTP header on reconnect (from last `id:` field)

```
Retry 1: 3.0s × 2^0 = 3.0s
Retry 2: 3.0s × 2^1 = 6.0s
Retry 3: 3.0s × 2^2 = 12.0s
...
Retry 7+: 3.0s × 2^6 = 192.0s (capped)
```
