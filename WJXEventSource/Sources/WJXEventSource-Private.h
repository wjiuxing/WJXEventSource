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
@property (nonatomic, strong) NSMutableData *buffer;
@property (nonatomic, strong) NSURLSessionDataTask *dataTask;
@property (nonatomic, assign) BOOL bufferOverflow;

- (void)_appendNormalizedData:(NSData *)data;
- (NSMutableArray<NSData *> *)_drainBuffer;
- (void)_parseEventData:(NSData *)data;
- (void)_handleBufferOverflowForStateGeneration:(NSUInteger)stateGeneration;

@end

NS_ASSUME_NONNULL_END
