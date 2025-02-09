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

FOUNDATION_STATIC_INLINE NSString *SSEEventKeyId(void)
{
    return @"id";
}

FOUNDATION_STATIC_INLINE NSString *SSEEventKeyEvent(void)
{
    return @"event";
}

FOUNDATION_STATIC_INLINE NSString *SSEEventKeyData(void)
{
    return @"data";
}

FOUNDATION_STATIC_INLINE NSString *SSEEventKeyRetry(void)
{
    return @"retry";
}

FOUNDATION_STATIC_INLINE NSString *SSEKeyValueDelimiter(void)
{
    return @":";
}

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

- (void)addListener:(WJXEventName)eventName
            handler:(WJXEventSourceEventHandler)handler
              queue:(nullable NSOperationQueue *)queue;
{
    if (nil == handler) {
        return;
    }
    
    NSMutableArray *listeners = self.listeners[eventName];
    if (nil == listeners) {
        self.listeners[eventName] = [NSMutableArray array];
    }
    [listeners addObject:[[WJXEventHandler alloc] initWithHandler:handler queue:queue]];
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
    
    NSString *response = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    [self _parseResponse:response];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(nullable NSError *)error;
{
    if (nil == error) {
        NSString *bufferString = [[NSString alloc] initWithData:_buffer encoding:NSUTF8StringEncoding];
        NSArray *components = [bufferString componentsSeparatedByString:@"id:"];
        NSString *response = [NSString stringWithFormat:@"id:%@", components.lastObject];
        [self _parseResponse:response];
        return;
    }
    
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
    [self _dispatchEvent:event forName:WJXEventNameError];
    
    if (!_ignoreRetryAction) {
        [self performSelector:@selector(open) withObject:nil afterDelay:_retryInterval];
    }
}


#pragma mark -
#pragma mark Private

- (void)_parseResponse:(NSString *)response
{
    WJXEvent *event = [[WJXEvent alloc] initWithReadyState:WJXEventStateOpen];
    
    NSArray *lines = [response componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        if ([line hasPrefix:SSEKeyValueDelimiter()]) {
            continue;
        } else if (0 == line.length) {
            if (nil != event.data) {
                [self _dispatchEvent:event forName:WJXEventNameMessage];
                event = [[WJXEvent alloc] initWithReadyState:WJXEventStateOpen];
            }
            continue;
        }
        
        @autoreleasepool {
            NSScanner *scanner = [NSScanner scannerWithString:line];
            scanner.charactersToBeSkipped = [NSCharacterSet whitespaceCharacterSet];
            
            NSString *key;
            [scanner scanUpToString:SSEKeyValueDelimiter() intoString:&key];
            
            [scanner scanString:SSEKeyValueDelimiter() intoString:nil];
            
            NSString *value;
            [scanner scanUpToCharactersFromSet:[NSCharacterSet newlineCharacterSet] intoString:&value];
            
            if (key && value) {
                if ([key isEqualToString:SSEEventKeyEvent()]) {
                    event.event = value;
                } else if ([key isEqualToString:SSEEventKeyData()]) {
                    if (nil != event.data) {
                        event.data = [event.data stringByAppendingFormat:@"\n%@", value];
                    } else {
                        event.data = value;
                    }
                } else if ([key isEqualToString:SSEEventKeyId()]) {
                    self.lastEventId = event.eventId = value;
                } else if ([key isEqualToString:SSEEventKeyRetry()]) {
                    self.retryInterval = [value doubleValue];
                }
            }
        }
    }
}

- (void)_dispatchEvent:(WJXEvent *)event forName:(WJXEventName)name
{
    NSMutableArray<WJXEventHandler *> *listeners = self.listeners[name];
    if (0 == listeners.count) {
        return;
    }
    
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
