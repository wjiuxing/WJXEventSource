//
//  WJXEventSource-Private.h
//  WJXEventSource
//
//  Private header for testing. DO NOT include in production code.
//

#import "WJXEventSource.h"

NS_ASSUME_NONNULL_BEGIN

@interface WJXEventSource ()

@property (nonatomic, assign) NSTimeInterval retryInterval;

- (void)_parseEventData:(NSData *)data;

@end

NS_ASSUME_NONNULL_END
