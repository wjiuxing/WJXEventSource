//
//  WJXEventSource.m
//  WJXEventSource
//
//  Created by JiuxingWang on 2025/2/9.
//

#import "WJXEventSource.h"

/// 消息事件
WJXEventName const WJXEventNameMessage = @"message";

/// readyState 变化事件
WJXEventName const WJXEventNameReadyState = @"readyState";

/// open 事件
WJXEventName const WJXEventNameOpen = @"open";

/// error 事件
WJXEventName const WJXEventNameError = @"error";

#pragma mark -
#pragma mark WJXEvent

@implementation WJXEvent

- (instancetype)initWithReadyState:(WJXEventState)readyState;
{
    if (self = [super init]) {
        self.readyState = readyState;
    }
    return self;
}

- (NSString *)description
{
    NSString *state = nil;
    switch (_readyState) {
        case WJXEventStateConnecting: {
            state = @"CONNECTING";
        } break;
            
        case WJXEventStateOpen: {
            state = @"OPEN";
        } break;
            
        case WJXEventStateClosed: {
            state = @"CLOSED";
        } break;
    }
    
    return [NSString stringWithFormat:@"<%@: readyState: %@, id: %@; event: %@; data: %@>", [self class], state, _eventId, _event, _data];
}

@end


#pragma mark -
#pragma mark WJXEventHandler

@interface WJXEventHandler : NSObject

@property (nonatomic, copy, nonnull) WJXEventSourceEventHandler handler;
@property (nonatomic, strong, nullable) NSOperationQueue *queue;

@end

@implementation WJXEventHandler

- (instancetype)initWithHandler:(WJXEventSourceEventHandler)handler queue:(NSOperationQueue *)queue
{
    if (self = [super init]) {
        self.handler = handler;
        self.queue = queue;
    }
    return self;
}

@end


#pragma mark -
#pragma mark WJXEventSource

@interface WJXEventSource () <NSURLSessionDataDelegate>

@property (nonatomic, strong) NSMutableURLRequest *request;
@property (nonatomic, strong) NSMutableDictionary<WJXEventName, NSMutableArray<WJXEventHandler *> *> *listeners;

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDataTask *dataTask;
@property (nonatomic, copy) NSString *lastEventId;
@property (nonatomic, assign) NSTimeInterval retryInterval;

@property (nonatomic, assign) BOOL closedByUser;
@property (nonatomic, strong) NSMutableData *buffer;

@end

@implementation WJXEventSource

- (instancetype)initWithRquest:(NSURLRequest *)request;
{
    if (self = [super init]) {
        self.request = [request mutableCopy];
        self.listeners = [NSMutableDictionary dictionary];
        self.session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration] delegate:self delegateQueue:NSOperationQueue.mainQueue];
        self.buffer = [NSMutableData data];
    }
    return self;
}

- (void)dealloc
{
    [_session finishTasksAndInvalidate];
}

- (void)addListener:(WJXEventSourceEventHandler)listener
           forEvent:(WJXEventName)eventName
              queue:(nullable NSOperationQueue *)queue;
{
    if (nil == listener) {
        return;
    }
    
    NSMutableArray *listeners = self.listeners[eventName];
    if (nil == listeners) {
        self.listeners[eventName] = listeners = [NSMutableArray array];
    }
    [listeners addObject:[[WJXEventHandler alloc] initWithHandler:listener queue:queue]];
}

- (void)open;
{
    if (_lastEventId.length) {
        [_request setValue:_lastEventId forHTTPHeaderField:@"Last-Event-ID"];
    }
    
    self.dataTask = [_session dataTaskWithRequest:_request];
    [_dataTask resume];
    
    WJXEvent *event = [[WJXEvent alloc] initWithReadyState:WJXEventStateConnecting];
    [self _dispatchEvent:event forName:WJXEventNameReadyState];
}

- (void)close;
{
    self.closedByUser = YES;
    [_dataTask cancel];
    [_session finishTasksAndInvalidate];
    _buffer = [NSMutableData data];
}


#pragma mark -
#pragma mark NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler;
{
    NSHTTPURLResponse *HTTPResponse = (NSHTTPURLResponse *)response;
    if (200 == HTTPResponse.statusCode) {
        WJXEvent *event = [[WJXEvent alloc] initWithReadyState:WJXEventStateOpen];
        [self _dispatchEvent:event forName:WJXEventNameReadyState];
        [self _dispatchEvent:event forName:WJXEventNameOpen];
    }
    
    if (nil != completionHandler) {
        completionHandler(NSURLSessionResponseAllow);
    }
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data;
{
    [_buffer appendData:data];
    [self _processBuffer];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(nullable NSError *)error;
{
    if (_closedByUser) {
        return;
    }
    
    WJXEvent *event = [[WJXEvent alloc] initWithReadyState:WJXEventStateClosed];
    if (nil == (event.error = error)) {
        event.error = [NSError errorWithDomain:@"WJXEventSource" code:event.readyState userInfo:@{
            NSLocalizedDescriptionKey: @"Connection with the event source was closed without error",
        }];
    }
    [self _dispatchEvent:event forName:WJXEventNameReadyState];
    
    if (nil != error) {
        [self _dispatchEvent:event forName:WJXEventNameError];
        if (!_ignoreRetryAction) {
            [self performSelector:@selector(open) withObject:nil afterDelay:_retryInterval];
        }
    }
}


#pragma mark -
#pragma mark Private

- (void)_processBuffer
{
    NSData *separatorLFLFData = [NSData dataWithBytes:"\n\n" length:2];
    
    NSRange range = [_buffer rangeOfData:separatorLFLFData options:kNilOptions range:(NSRange) {
        .length = _buffer.length
    }];
    
    while (NSNotFound != range.location) {
        // Extract event data
        NSData *eventData = [_buffer subdataWithRange:(NSRange) {
            .length = range.location
        }];
        [_buffer replaceBytesInRange:(NSRange) {
            .length = range.location + 2
        } withBytes:NULL length:0];
        
        [self _parseEventData:eventData];
        
        // Look for next event
        range = [_buffer rangeOfData:separatorLFLFData options:kNilOptions range:(NSRange) {
            .length = _buffer.length
        }];
    }
}

- (void)_parseEventData:(NSData *)data
{
    WJXEvent *event = [[WJXEvent alloc] initWithReadyState:WJXEventStateOpen];
    
    NSString *eventString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSArray *lines = [eventString componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    for (NSString *line in lines) {
        if ([line hasPrefix:@"id:"]) {
            event.eventId = [[line substringFromIndex:3] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        } else if ([line hasPrefix:@"event:"]) {
            event.event = [[line substringFromIndex:6] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        } else if ([line hasPrefix:@"data:"]) {
            NSString *data = [[line substringFromIndex:5] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            event.data = event.data ? [event.data stringByAppendingFormat:@"\n%@", data] : data;
        } else if ([line hasPrefix:@"retry:"]) {
            NSString *retryString = [[line substringFromIndex:6] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            self.retryInterval = [retryString doubleValue] / 1000;
        }
    }
    
    if (event.eventId) {
        self.lastEventId = event.eventId;
    }
    
    [self _dispatchEvent:event forName:WJXEventNameMessage];
}

- (void)_dispatchEvent:(WJXEvent *)event forName:(WJXEventName)name
{
    NSMutableArray<WJXEventHandler *> *listeners = self.listeners[name];
    [listeners enumerateObjectsUsingBlock:^(WJXEventHandler * _Nonnull handler, NSUInteger idx, BOOL * _Nonnull stop) {
        NSOperationQueue *queue = handler.queue ?: NSOperationQueue.mainQueue;
        [queue addOperationWithBlock:^{
            handler.handler(event);
        }];
    }];
}


#pragma mark -
#pragma mark Setters

- (void)setDataTask:(NSURLSessionDataTask *)dataTask
{
    self.closedByUser = YES; {
        [_dataTask cancel];
        _dataTask = dataTask;
    } self.closedByUser = NO;
}

@end
