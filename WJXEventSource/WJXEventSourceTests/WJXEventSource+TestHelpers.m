//
//  WJXEventSource+TestHelpers.m
//  WJXEventSourceTests
//
//  Exposes private methods for unit testing.
//

#import "WJXEventSource+TestHelpers.h"
#import "WJXEventSource-Private.h"

@implementation WJXEventSource (TestHelpers)

- (void)parseEventData:(NSData *)data
{
    [self _parseEventData:data];
}

@end
