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

/// 单个事件(分隔符之间)的缓冲上限,超过视为坏流,防恶意服务端撑爆内存
static const NSUInteger kWJXEventSourceMaxBufferSize = 1024 * 1024;

/// 重连延迟上限(秒),防服务端超大 retry 值导致 NSTimeInterval→int64 转换溢出(UB)
static const NSTimeInterval kWJXEventSourceMaxRetryDelay = 300.0;

@interface WJXEvent ()

@property (nonatomic, assign, readwrite) BOOL cleanClose;

@end


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
@property (nonatomic, strong) dispatch_queue_t listenersQueue;

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionConfiguration *sessionConfiguration;
@property (nonatomic, strong) NSOperationQueue *delegateQueue;
@property (nonatomic, strong) NSURLSessionDataTask *dataTask;
@property (nonatomic, copy) NSString *lastEventId;
@property (nonatomic, assign) NSTimeInterval retryInterval;

@property (nonatomic, assign) BOOL closedByUser;
@property (nonatomic, strong) NSMutableData *buffer;
/// 跨 chunk 的 \r 携带位:上一 chunk 以 \r 结尾时置 YES,避免归一化在 chunk 边界拼出假分隔符
@property (nonatomic, assign) BOOL pendingCR;
/// 流首 BOM 是否已处理(只剥一次)
@property (nonatomic, assign) BOOL bomStripped;
/// 半包超过上限标志,由 _drainBuffer 置位,didReceiveData 锁外处理
@property (nonatomic, assign) BOOL bufferOverflow;
/// 响应阶段已判失败(非 200/非法 Content-Type)标记:该任务的取消型 completion 不再重复派发 error
@property (nonatomic, assign) BOOL responseFailed;

@property (nonatomic, assign) NSUInteger retryCount;
/// 状态代次:close 与 open 都递增。排期重连时快照,触发时对不上即作废
@property (nonatomic, assign) NSUInteger stateGeneration;

@end

@implementation WJXEventSource

- (instancetype)initWithRequest:(NSURLRequest *)request;
{
    if (self = [super init]) {
        self.request = [request mutableCopy];
        self.listeners = [NSMutableDictionary dictionary];
        self.listenersQueue = dispatch_queue_create("com.wjx.eventsource.listeners", DISPATCH_QUEUE_CONCURRENT);
        // 自建串行 delegate 队列:回调线程固定,不占用主队列,也不受第三方 APM SDK 转发线程影响
        NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
        delegateQueue.maxConcurrentOperationCount = 1;
        self.delegateQueue = delegateQueue;
        self.sessionConfiguration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        self.session = [NSURLSession sessionWithConfiguration:self.sessionConfiguration delegate:self delegateQueue:delegateQueue];
        self.buffer = [NSMutableData data];
        self.retryInterval = 3.0;
        // 浏览器 SSE 都带 Accept 头,部分网关按它路由;调用方显式设置过则不覆盖
        if (nil == [self.request valueForHTTPHeaderField:@"Accept"]) {
            [self.request setValue:@"text/event-stream" forHTTPHeaderField:@"Accept"];
        }
        self.maxRetryCount = NSUIntegerMax;
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
    
    dispatch_barrier_async(self.listenersQueue, ^{
        NSMutableArray *listeners = self.listeners[eventName];
        if (nil == listeners) {
            self.listeners[eventName] = listeners = [NSMutableArray array];
        }
        [listeners addObject:[[WJXEventHandler alloc] initWithHandler:listener queue:queue]];
    });
}

- (void)removeListener:(WJXEventSourceEventHandler)listener
              forEvent:(WJXEventName)eventName;
{
    if (nil == listener) {
        return;
    }

    dispatch_barrier_async(self.listenersQueue, ^{
        NSMutableArray *listeners = self.listeners[eventName];
        // 按 block 指针匹配移除;同一个 block 注册多次则全部移除
        [listeners filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WJXEventHandler *evaluatedHandler, NSDictionary * _Nullable bindings) {
            return evaluatedHandler.handler != listener;
        }]];
    });
}

- (void)open;
{
    NSURLSessionDataTask *task = nil;
    @synchronized (self) {
        // 错误后排期的重连,期间发生任何 open/close(手动重连、关闭)都作废
        _stateGeneration++;
        // close 已 invalidate 旧 session,重开必须重建,否则 dataTaskWithRequest: 会抛异常
        if (nil == _session) {
            _session = [NSURLSession sessionWithConfiguration:_sessionConfiguration delegate:self delegateQueue:_delegateQueue];
        }
        _closedByUser = NO;
        if (_lastEventId.length) {
            [_request setValue:_lastEventId forHTTPHeaderField:@"Last-Event-ID"];
        }
        // 重开丢弃上一连接残留半包与归一化状态,防止跨流拼接出脏事件
        [_buffer setLength:0];
        _pendingCR = NO;
        _bomStripped = NO;
        _bufferOverflow = NO;
        _responseFailed = NO;
        [_dataTask cancel];
        task = _dataTask = [_session dataTaskWithRequest:_request];
    }
    // 先派发 Connecting 再 resume:响应极快时避免 Open 事件先于 Connecting 入队
    WJXEvent *connectingEvent = [[WJXEvent alloc] initWithReadyState:WJXEventStateConnecting];
    [self _dispatchEvent:connectingEvent forName:WJXEventNameReadyState];
    [task resume];
}

- (void)close;
{
    @synchronized (self) {
        if (_closedByUser) {
            return;
        }
        _closedByUser = YES;
        // 递增代次,作废 close 之前已排队、尚未触发的重连
        _stateGeneration++;

        [_dataTask cancel];
        _dataTask = nil;
        [_session finishTasksAndInvalidate];
        _session = nil;
        // 只清长度不换对象:换指针会让正在解析的线程拿旧 range 撞新空 buffer,抛 NSRangeException
        [_buffer setLength:0];
        _pendingCR = NO;
        _bomStripped = NO;
        _bufferOverflow = NO;
        _responseFailed = NO;
    }
}


#pragma mark -
#pragma mark NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler;
{
    @synchronized (self) {
        // 被顶替(open 重开)/已关闭任务的响应直接取消,不得触发 readyState 或重置重连计数
        if (_closedByUser || dataTask != _dataTask) {
            if (nil != completionHandler) {
                completionHandler(NSURLSessionResponseCancel);
            }
            return;
        }
    }

    NSHTTPURLResponse *HTTPResponse = (NSHTTPURLResponse *)response;
    if (200 != HTTPResponse.statusCode) {
        // 规范:非 200 必须失败,不能把错误页 body 当流解析
        @synchronized (self) {
            // 标记响应阶段已失败:该任务随后的取消型 completion 不再重复派发 error
            _responseFailed = YES;
        }
        if (nil != completionHandler) {
            completionHandler(NSURLSessionResponseCancel);
        }
        WJXEvent *errorEvent = [[WJXEvent alloc] initWithReadyState:WJXEventStateClosed];
        errorEvent.error = [NSError errorWithDomain:@"WJXEventSource" code:HTTPResponse.statusCode userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Unexpected HTTP status code: %ld", (long)HTTPResponse.statusCode],
        }];
        [self _dispatchEvent:errorEvent forName:WJXEventNameError];
        return;
    }

    // MIMEType 由系统解析(兼容 HTTP/2 小写头名场景);精确匹配,
    // 前缀匹配会误收 text/event-streamevil,字典直取会漏小写头名
    NSString *mimeType = [HTTPResponse.MIMEType lowercaseString];
    if (![mimeType isEqualToString:@"text/event-stream"]) {
        @synchronized (self) {
            // 标记响应阶段已失败:该任务随后的取消型 completion 不再重复派发 error
            _responseFailed = YES;
        }
        if (nil != completionHandler) {
            completionHandler(NSURLSessionResponseCancel);
        }
        WJXEvent *errorEvent = [[WJXEvent alloc] initWithReadyState:WJXEventStateClosed];
        errorEvent.error = [NSError errorWithDomain:@"WJXEventSource" code:-1 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Invalid Content-Type: expected 'text/event-stream', got '%@'", HTTPResponse.MIMEType ?: @"(null)"],
        }];
        [self _dispatchEvent:errorEvent forName:WJXEventNameError];
        return;
    }

    @synchronized (self) {
        // 连接成功重置重连计数与响应失败标记;与 didCompleteWithError 的读写互斥
        self.retryCount = 0;
        _responseFailed = NO;
    }
    WJXEvent *event = [[WJXEvent alloc] initWithReadyState:WJXEventStateOpen];
    [self _dispatchEvent:event forName:WJXEventNameReadyState];
    [self _dispatchEvent:event forName:WJXEventNameOpen];

    if (nil != completionHandler) {
        completionHandler(NSURLSessionResponseAllow);
    }
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data;
{
    NSMutableArray<NSData *> *completedEvents = nil;
    BOOL bufferOverflow = NO;

    // 追加、扫描、消费三步必须原子:与 close 的清空互斥,否则旧 range 撞空 buffer 崩溃
    @synchronized (self) {
        if (_closedByUser) {
            return;
        }
        // open() 重开已顶替旧任务:旧任务在途回调的残留数据不得混入新流 buffer
        if (dataTask != _dataTask) {
            return;
        }
        [self _appendNormalizedData:data];
        completedEvents = [self _drainBuffer];
        bufferOverflow = _bufferOverflow;
    }

    // 锁外派发:handler 里可能回调 close/open,持锁派发会放大锁粒度;
    // 先派发本批已完整事件,坏流也不吞掉已收好的数据
    for (NSData *eventData in completedEvents) {
        [self _parseEventData:eventData];
    }

    if (bufferOverflow) {
        // 坏流:单个完整事件或剩余半包超过缓冲上限,报错并关闭,防恶意服务端撑爆内存
        WJXEvent *errorEvent = [[WJXEvent alloc] initWithReadyState:WJXEventStateClosed];
        errorEvent.error = [NSError errorWithDomain:@"WJXEventSource" code:-1 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Event exceeds maximum buffer size (%lu bytes)", (unsigned long)kWJXEventSourceMaxBufferSize],
        }];
        [self _dispatchEvent:errorEvent forName:WJXEventNameError];
        [self close];
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(nullable NSError *)error;
{
    BOOL closedByUser = NO;
    BOOL shouldRetry = NO;
    BOOL responseFailed = NO;
    NSUInteger stateGeneration = 0;
    NSTimeInterval retryDelay = 0;
    @synchronized (self) {
        closedByUser = _closedByUser;
        responseFailed = _responseFailed;
        // open() 重开会取消被顶替的旧任务:其完成回调(含 NSURLErrorCancelled)整体作废,
        // 否则派发假 error 并排期重连,与新一轮连接互相取消成重连风暴
        if (!closedByUser && (NSURLSessionDataTask *)task != _dataTask) {
            return;
        }
        if (!closedByUser && nil != error && !_ignoreRetryAction && _retryCount < _maxRetryCount) {
            shouldRetry = YES;
            stateGeneration = _stateGeneration;
            // 先自增再调度:原顺序在窗口内重复进入会多重调度重连
            _retryCount++;
            // 上限封顶:防服务端超大 retry 值导致 double→int64 转换溢出(UB)
            retryDelay = MIN(_retryInterval * (1 << MIN(_retryCount, 6)), kWJXEventSourceMaxRetryDelay);
        }
    }

    if (closedByUser) {
        return;
    }

    WJXEvent *event = [[WJXEvent alloc] initWithReadyState:WJXEventStateClosed];
    if (nil == (event.error = error)) {
        event.error = [NSError errorWithDomain:@"WJXEventSource" code:event.readyState userInfo:@{
            NSLocalizedDescriptionKey: @"Connection with the event source was closed without error",
        }];
        event.cleanClose = YES;
    }

    // 响应阶段(非 200/非法 Content-Type)已派发过 error:随后的取消型 completion
    // 不再重复派发 readyState/error,JS 端只收一次;重连仍按规范继续
    BOOL suppressDuplicateError = responseFailed
        && NSURLErrorDomain == error.domain
        && NSURLErrorCancelled == error.code;
    if (!suppressDuplicateError) {
        [self _dispatchEvent:event forName:WJXEventNameReadyState];

        if (nil != error) {
            [self _dispatchEvent:event forName:WJXEventNameError];
        }
    }

    if (nil != error && shouldRetry) {
        // delegate 回调已不在主线程:performSelector:afterDelay: 依赖当前线程的 runloop,
        // NSOperationQueue 工作线程无 runloop,timer 会永不触发,改用 dispatch_after 派发主队列
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(retryDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (nil == strongSelf) {
                return;
            }
            @synchronized (strongSelf) {
                // 期间发生过 open/close(手动重连、关闭):本次排队的重连作废;
                // open 一并持锁调用(@synchronized 可重入),消除检查与重连之间的窗口
                if (strongSelf->_stateGeneration != stateGeneration) {
                    return;
                }
                [strongSelf open];
            }
        });
    }

    if (!shouldRetry) {
        // 终态完成(正常结束/不可重试):释放 session,断开 delegate 强引用,避免空闲连接持有本实例
        @synchronized (self) {
            [_session finishTasksAndInvalidate];
            _session = nil;
            _dataTask = nil;
        }
    }
}


#pragma mark -
#pragma mark Private

/// 规范:冒号后仅允许剥一个空格,尾部空白属于值的一部分
- (NSString *)_fieldValueInLine:(NSString *)line prefixLength:(NSUInteger)prefixLength
{
    NSString *value = [line substringFromIndex:prefixLength];
    if ([value hasPrefix:@" "]) {
        value = [value substringFromIndex:1];
    }
    return value;
}

/// 归一化行尾并追加:规范允许 \r\n、\r、\n 三种行尾,统一归成 \n 再扫描;
/// 流首 BOM(U+FEFF)剥一次;_pendingCR 记录 \r 落在上一 chunk 末尾的情况,
/// 避免跨 chunk 拼出假分隔符。调用方必须已持锁。
- (void)_appendNormalizedData:(NSData *)data
{
    if (!_bomStripped) {
        _bomStripped = YES;
        static const uint8_t kBOM[3] = {0xEF, 0xBB, 0xBF};
        if (3 <= data.length && 0 == memcmp(data.bytes, kBOM, 3)) {
            data = [data subdataWithRange:NSMakeRange(3, data.length - 3)];
        }
    }
    if (0 == data.length) {
        return;
    }

    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;
    if (_pendingCR && '\n' == bytes[0]) {
        // 上一 chunk 以 \r 收尾且本 chunk 以 \n 开头:合并为一个行尾
        bytes += 1;
        length -= 1;
    }
    if (0 == length) {
        _pendingCR = NO;
        return;
    }
    NSUInteger runStart = 0;
    for (NSUInteger i = 0; i < length; i++) {
        if ('\r' == bytes[i]) {
            if (i > runStart) {
                [_buffer appendBytes:bytes + runStart length:i - runStart];
            }
            [_buffer appendBytes:"\n" length:1];
            if (i + 1 < length && '\n' == bytes[i + 1]) {
                i++;
            }
            runStart = i + 1;
        }
    }
    _pendingCR = ('\r' == bytes[length - 1]);
    if (length > runStart) {
        [_buffer appendBytes:bytes + runStart length:length - runStart];
    }
}

/// 扫描并消费 buffer 中已完整的事件(以 \n\n 分隔)。调用方必须已持锁。
- (NSMutableArray<NSData *> *)_drainBuffer
{
    NSData *separatorLFLFData = [NSData dataWithBytes:"\n\n" length:2];
    NSMutableArray<NSData *> *completedEvents = [NSMutableArray array];

    NSRange range = [_buffer rangeOfData:separatorLFLFData options:kNilOptions range:(NSRange) {
        .length = _buffer.length
    }];
    while (NSNotFound != range.location) {
        // 单个完整事件超上限:置位标志并清空,交给 didReceiveData 锁外报错并关闭
        if (range.location > kWJXEventSourceMaxBufferSize) {
            _bufferOverflow = YES;
            [_buffer setLength:0];
            return completedEvents;
        }
        [completedEvents addObject:[_buffer subdataWithRange:(NSRange) {
            .length = range.location
        }]];
        [_buffer replaceBytesInRange:(NSRange) {
            .length = NSMaxRange(range)
        } withBytes:NULL length:0];
        range = [_buffer rangeOfData:separatorLFLFData options:kNilOptions range:(NSRange) {
            .length = _buffer.length
        }];
    }
    // 剩余半包(未收齐分隔符)超上限:置位标志。上限只针对半包,
    // 不按整 buffer 计——一个 chunk 携带多个完整事件总量超限不是坏流
    if (_buffer.length > kWJXEventSourceMaxBufferSize) {
        _bufferOverflow = YES;
    }
    return completedEvents;
}

- (void)_parseEventData:(NSData *)data
{
    WJXEvent *event = [[WJXEvent alloc] initWithReadyState:WJXEventStateOpen];

    NSString *eventString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSArray *lines = [eventString componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSString *retryString = nil;
    for (NSString *line in lines) {
        if ([line hasPrefix:@"id:"]) {
            event.eventId = [self _fieldValueInLine:line prefixLength:3];
        } else if ([line hasPrefix:@"event:"]) {
            event.event = [self _fieldValueInLine:line prefixLength:6];
        } else if ([line hasPrefix:@"data:"]) {
            NSString *dataString = [self _fieldValueInLine:line prefixLength:5];
            event.data = event.data ? [event.data stringByAppendingFormat:@"\n%@", dataString] : dataString;
        } else if ([line hasPrefix:@"retry:"]) {
            retryString = [self _fieldValueInLine:line prefixLength:6];
        }
    }

    // 规范:retry 值必须是纯 ASCII 数字才生效,非数字忽略;
    // 否则 "retry: abc" 会把间隔置 0,重连紧贴锤服务器
    static NSCharacterSet *nonAsciiDigits;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        nonAsciiDigits = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet];
    });
    // 状态写入与 close/open 互斥
    @synchronized (self) {
        if (retryString.length && NSNotFound == [retryString rangeOfCharacterFromSet:nonAsciiDigits].location) {
            self.retryInterval = [retryString doubleValue] / 1000;
        }
        if (event.eventId) {
            self.lastEventId = event.eventId;
        }
    }

    // 规范:仅 data 字段出现过才派发 message;纯注释(`: ping` 心跳)/空块不派发
    if (nil != event.data) {
        [self _dispatchEvent:event forName:WJXEventNameMessage];
    }
}

- (void)_dispatchEvent:(WJXEvent *)event forName:(WJXEventName)name
{
    __block NSMutableArray<WJXEventHandler *> *snapshot = nil;
    dispatch_sync(self.listenersQueue, ^{
        snapshot = [self.listeners[name] copy];
    });
    [snapshot enumerateObjectsUsingBlock:^(WJXEventHandler * _Nonnull handler, NSUInteger idx, BOOL * _Nonnull stop) {
        NSOperationQueue *queue = handler.queue ?: NSOperationQueue.mainQueue;
        [queue addOperationWithBlock:^{
            handler.handler(event);
        }];
    }];
}

@end
