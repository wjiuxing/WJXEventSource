//
//  WJXEventSource+TestHelpers.h
//  WJXEventSourceTests
//
//  Exposes private methods for unit testing.
//

#import "WJXEventSource.h"

NS_ASSUME_NONNULL_BEGIN

@interface WJXEventSource (TestHelpers)

/// Parse SSE event data from raw bytes. Exposed for unit testing.
- (void)parseEventData:(NSData *)data;

@end

NS_ASSUME_NONNULL_END
