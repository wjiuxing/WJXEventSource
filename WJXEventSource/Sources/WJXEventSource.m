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
static const NSUInteger kWJXEventSourceMaxBufferSize = 1 << 20;

/// 重连延迟上限(秒),防服务端超大 retry 值导致 NSTimeInterval→int64 转换溢出(UB)
static const NSTimeInterval kWJXEventSourceMaxRetryDelay = 300.0;

/// 大块网络数据分片处理长度:既允许一个 chunk 携带多个完整事件,又限制单事件缓冲额外内存
static const NSUInteger kWJXEventSourceProcessSliceSize = 1 << 16;

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
@property (nonatomic, copy, nullable) NSString *lastEventId;
@property (nonatomic, assign) NSTimeInterval retryInterval;

@property (nonatomic, assign) BOOL closedByUser;
@property (nonatomic, strong) NSMutableData *buffer;
/// 跨 chunk 的 \r 携带位:上一 chunk 以 \r 结尾时置 YES,避免归一化在 chunk 边界拼出假分隔符
@property (nonatomic, assign) BOOL pendingCR;
/// 流首 BOM 是否已处理(只剥一次)
@property (nonatomic, assign) BOOL bomStripped;
/// BOM 跨 chunk 拆开时的攒字节缓冲:凑满 3 字节才能判定是否剥除
@property (nonatomic, strong) NSMutableData *bomBuffer;
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
        self.bomBuffer = [NSMutableData data];
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
    NSUInteger stateGeneration = 0;
    @synchronized (self) {
        // 错误后排期的重连,期间发生任何 open/close(手动重连、关闭)都作废
        stateGeneration = ++_stateGeneration;
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
        [_bomBuffer setLength:0];
        _bufferOverflow = NO;
        _responseFailed = NO;
        [_dataTask cancel];
        NSURLSessionDataTask *task = _dataTask = [_session dataTaskWithRequest:_request];
        // Connecting 与 resume 都在生命周期临界区内完成,防止出锁后被 close/open 顶替
        WJXEvent *connectingEvent = [[WJXEvent alloc] initWithReadyState:WJXEventStateConnecting];
        [self _dispatchEvent:connectingEvent
                     forName:WJXEventNameReadyState
             stateGeneration:stateGeneration];
        [task resume];
    }
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
        [_bomBuffer setLength:0];
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
    NSUInteger stateGeneration = 0;
    NSURLSessionResponseDisposition disposition = NSURLSessionResponseCancel;
    WJXEvent *stateEvent = nil;
    WJXEvent *lifecycleEvent = nil;
    NSString *lifecycleEventName = nil;
    BOOL responseIsValid = YES;
    NSHTTPURLResponse *HTTPResponse = (NSHTTPURLResponse *)response;

    if (![response isKindOfClass:NSHTTPURLResponse.class]) {
        responseIsValid = NO;
        HTTPResponse = nil;
    }

    if (responseIsValid && 200 != HTTPResponse.statusCode) {
        // 规范:非 200 必须失败,不能把错误页 body 当流解析
        WJXEvent *errorEvent = [[WJXEvent alloc] initWithReadyState:WJXEventStateClosed];
        errorEvent.error = [NSError errorWithDomain:@"WJXEventSource" code:HTTPResponse.statusCode userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Unexpected HTTP status code: %ld", (long)HTTPResponse.statusCode],
        }];
        stateEvent = errorEvent;
        lifecycleEvent = errorEvent;
        lifecycleEventName = WJXEventNameError;
        responseIsValid = NO;
    } else if (responseIsValid) {
        // MIMEType 由系统解析(兼容 HTTP/2 小写头名场景);精确匹配,
        // 前缀匹配会误收 text/event-streamevil,字典直取会漏小写头名
        NSString *mimeType = HTTPResponse.MIMEType.lowercaseString;
        if (![mimeType isEqualToString:@"text/event-stream"]) {
            WJXEvent *errorEvent = [[WJXEvent alloc] initWithReadyState:WJXEventStateClosed];
            errorEvent.error = [NSError errorWithDomain:@"WJXEventSource" code:-1 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Invalid Content-Type: expected 'text/event-stream', got '%@'", HTTPResponse.MIMEType ?: @"(null)"],
            }];
            stateEvent = errorEvent;
            lifecycleEvent = errorEvent;
            lifecycleEventName = WJXEventNameError;
            responseIsValid = NO;
        }
    }

    if (!responseIsValid && nil == stateEvent) {
        WJXEvent *errorEvent = [[WJXEvent alloc] initWithReadyState:WJXEventStateClosed];
        errorEvent.error = [NSError errorWithDomain:@"WJXEventSource" code:-1 userInfo:@{
            NSLocalizedDescriptionKey: @"Response was not an HTTP response",
        }];
        stateEvent = errorEvent;
        lifecycleEvent = errorEvent;
        lifecycleEventName = WJXEventNameError;
    }

    @synchronized (self) {
        // 解析响应期间被 open/close 顶替的任务只允许取消(close 会置空 _dataTask,统一走引用不等分支)
        if (dataTask != _dataTask) {
            // 被顶替的任务:必须调用 completionHandler,NSURLSession delegate API 不允许跳过
            if (nil != completionHandler) {
                completionHandler(NSURLSessionResponseCancel);
            }
            disposition = NSURLSessionResponseCancel;
            return;
        }

        stateGeneration = _stateGeneration;
        if (!responseIsValid) {
            // 标记响应阶段已失败:该任务随后的取消型 completion 不再重复派发 error
            _responseFailed = YES;
            disposition = NSURLSessionResponseCancel;
        } else {
            // 连接成功重置重连计数与响应失败标记;与 didCompleteWithError 的读写互斥
            _retryCount = 0;
            _responseFailed = NO;
            disposition = NSURLSessionResponseAllow;
            WJXEvent *openEvent = [[WJXEvent alloc] initWithReadyState:WJXEventStateOpen];
            stateEvent = openEvent;
            lifecycleEvent = openEvent;
            lifecycleEventName = WJXEventNameOpen;
        }
    }

    // 响应失败也同步派发终态,只监听 readyState 的调用方不能停留在 Connecting
    [self _dispatchEvent:stateEvent forName:WJXEventNameReadyState stateGeneration:stateGeneration];
    if (nil != lifecycleEvent && nil != lifecycleEventName) {
        [self _dispatchEvent:lifecycleEvent forName:lifecycleEventName stateGeneration:stateGeneration];
    }

    if (nil != completionHandler) {
        completionHandler(disposition);
    }
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data;
{
    NSUInteger offset = 0;
    while (offset < data.length) {
        NSMutableArray<NSData *> *completedEvents = nil;
        BOOL bufferOverflow = NO;
        NSUInteger sliceLength = MIN(kWJXEventSourceProcessSliceSize, data.length - offset);
        NSUInteger stateGeneration = 0;

        // 追加、扫描、消费、解析四步必须原子:与 close/open 的换流互斥,并保持事件顺序
        @synchronized (self) {
            if (_closedByUser || dataTask != _dataTask) {
                return;
            }

            stateGeneration = _stateGeneration;
            NSData *slice = [data subdataWithRange:(NSRange) {
                .location = offset,
                .length = sliceLength
            }];
            [self _appendNormalizedData:slice];
            completedEvents = [self _drainBuffer];
            bufferOverflow = _bufferOverflow;

            // 解析可能构造大的字符串,但仍锁内执行:回调线程一旦乱序,不能让旧事件
            // 在新连接状态提交前后穿插
            for (NSData *eventData in completedEvents) {
                [self _parseEventData:eventData stateGeneration:stateGeneration];
            }
        }

        if (bufferOverflow) {
            [self _handleBufferOverflowForStateGeneration:stateGeneration];
            return;
        }

        offset += sliceLength;
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
        // 服务端正常 EOF 也属于断流,与网络错误一样按规范自动重连;
        // 但响应阶段已判失败(非 200/非法 Content-Type)属规范定义的终态 fail the connection,不重连
        if (!closedByUser && !responseFailed && !_ignoreRetryAction && _retryCount < _maxRetryCount) {
            shouldRetry = YES;
            stateGeneration = _stateGeneration;
            // 先自增再调度:原顺序在窗口内重复进入会多重调度重连
            _retryCount++;
            // 上限封顶:防服务端超大 retry 值导致 double→int64 转换溢出(UB)
            retryDelay = MIN(_retryInterval * (1 << MIN(_retryCount, 6)), kWJXEventSourceMaxRetryDelay);
        } else if (!closedByUser) {
            stateGeneration = _stateGeneration;
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
    // 不再重复派发 readyState/error,JS 端只收一次;该终态也不再自动重连(见上方 shouldRetry 判定)
    BOOL suppressDuplicateError = responseFailed
        && NSURLErrorDomain == error.domain
        && NSURLErrorCancelled == error.code;
    if (!suppressDuplicateError) {
        [self _dispatchEvent:event forName:WJXEventNameReadyState stateGeneration:stateGeneration];

        if (nil != error) {
            [self _dispatchEvent:event forName:WJXEventNameError stateGeneration:stateGeneration];
        }
    }

    if (shouldRetry) {
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
        // 终态完成(正常结束/不可重试):释放 session,断开 delegate 强引用,避免空闲连接持有本实例。
        // 事件派发期间可能已被手动重开,只能清理当前 generation 的 session/task。
        @synchronized (self) {
            if (_stateGeneration != stateGeneration) {
                return;
            }
            [_session finishTasksAndInvalidate];
            _session = nil;
            _dataTask = nil;
        }
    }
}


#pragma mark -
#pragma mark Private

/// 归一化行尾并追加:规范允许 \r\n、\r、\n 三种行尾,统一归成 \n 再扫描;
/// 流首 BOM(U+FEFF)剥一次;_pendingCR 记录 \r 落在上一 chunk 末尾的情况,
/// 避免跨 chunk 拼出假分隔符。调用方必须已持锁。
- (void)_appendNormalizedData:(NSData *)data
{
    if (!_bomStripped) {
        // BOM 可能被拆在多个 chunk:攒满 3 字节再判定,避免首 chunk 不足 3 字节时
        // 提前置位丢失 BOM、把残留字节漏进首条事件
        [_bomBuffer appendData:data];
        if (_bomBuffer.length < 3) {
            return;
        }
        _bomStripped = YES;
        static const uint8_t kBOM[3] = {0xEF, 0xBB, 0xBF};
        NSUInteger bomOffset = (0 == memcmp(_bomBuffer.bytes, kBOM, 3)) ? 3 : 0;
        data = [_bomBuffer subdataWithRange:(NSRange) {
            .location = bomOffset,
            .length = _bomBuffer.length - bomOffset
        }];
        [_bomBuffer setLength:0];
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
    NSUInteger consumedLength = 0;

    NSRange range = [_buffer rangeOfData:separatorLFLFData
                                 options:kNilOptions
                                   range:(NSRange) {
        .location = consumedLength,
        .length = _buffer.length - consumedLength
    }];
    while (NSNotFound != range.location) {
        // 单个完整事件超上限:置位标志并清空,交给 didReceiveData 锁外报错并关闭
        NSUInteger eventLength = range.location - consumedLength;
        if (eventLength > kWJXEventSourceMaxBufferSize) {
            _bufferOverflow = YES;
            [_buffer setLength:0];
            return completedEvents;
        }
        [completedEvents addObject:[_buffer subdataWithRange:(NSRange) {
            .location = consumedLength,
            .length = eventLength
        }]];
        consumedLength = NSMaxRange(range);
        range = [_buffer rangeOfData:separatorLFLFData
                             options:kNilOptions
                               range:(NSRange) {
            .location = consumedLength,
            .length = _buffer.length - consumedLength
        }];
    }
    // 一次删除本轮已消费前缀,避免每个事件都把剩余半包向前 memmove
    if (consumedLength > 0) {
        [_buffer replaceBytesInRange:(NSRange) {
            .length = consumedLength
        } withBytes:NULL length:0];
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
    NSUInteger stateGeneration = 0;
    @synchronized (self) {
        stateGeneration = _stateGeneration;
    }
    [self _parseEventData:data stateGeneration:stateGeneration];
}

- (void)_parseEventData:(NSData *)data stateGeneration:(NSUInteger)stateGeneration
{
    WJXEvent *event = [[WJXEvent alloc] initWithReadyState:WJXEventStateOpen];

    NSString *eventString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    // 数据已归一化为 \n 行尾,必须只按 \n 切行:newlineCharacterSet 还含 U+2028/U+2029/U+0085/VT/FF,
    // 而 SSE 规范行终止符只有 CR/LF/CRLF;这些字符在 data 载荷(JSON 字符串)中合法出现时
    // 会被误当行终止符,导致消息在该字符处静默截断、行剩余部分丢失
    NSArray *lines = [eventString componentsSeparatedByString:@"\n"];
    NSString *retryString = nil;
    for (NSString *line in lines) {
        NSRange colonRange = [line rangeOfString:@":"];
        NSString *fieldName = NSNotFound == colonRange.location ? line : [line substringToIndex:colonRange.location];
        NSString *fieldValue = NSNotFound == colonRange.location ? @"" : [line substringFromIndex:colonRange.location + 1];
        if ([fieldValue hasPrefix:@" "]) {
            fieldValue = [fieldValue substringFromIndex:1];
        }

        // 规范:冒号可省略,第一个冒号前才是字段名,值只剥一个前导空格
        if ([fieldName isEqualToString:@"id"]) {
            event.eventId = fieldValue;
        } else if ([fieldName isEqualToString:@"event"]) {
            event.event = fieldValue;
        } else if ([fieldName isEqualToString:@"data"]) {
            NSString *dataString = fieldValue;
            event.data = event.data ? [event.data stringByAppendingFormat:@"\n%@", dataString] : dataString;
        } else if ([fieldName isEqualToString:@"retry"]) {
            retryString = fieldValue;
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
        if (_stateGeneration != stateGeneration) {
            return;
        }
        if (retryString.length && NSNotFound == [retryString rangeOfCharacterFromSet:nonAsciiDigits].location) {
            self.retryInterval = [retryString doubleValue] / 1000;
        }
        if (event.eventId) {
            self.lastEventId = event.eventId;
        }
    }

    // 规范:仅 data 字段出现过才派发;显式 event 字段按事件名派发,否则派发 message
    if (nil != event.data) {
        WJXEventName eventName = event.event.length > 0 ? event.event : WJXEventNameMessage;
        [self _dispatchEvent:event forName:eventName stateGeneration:stateGeneration];
    }
}

- (void)_handleBufferOverflowForStateGeneration:(NSUInteger)stateGeneration
{
    // 坏流:当前未完成事件超过上限,报错并关闭,防恶意服务端撑爆内存
    WJXEvent *errorEvent = [[WJXEvent alloc] initWithReadyState:WJXEventStateClosed];
    errorEvent.error = [NSError errorWithDomain:@"WJXEventSource" code:-1 userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Event exceeds maximum buffer size (%lu bytes)", (unsigned long)kWJXEventSourceMaxBufferSize],
    }];
    [self _dispatchEvent:errorEvent forName:WJXEventNameError stateGeneration:stateGeneration survivesClose:YES];

    @synchronized (self) {
        // generation 校验和关闭必须在同一临界区,防止错误回调中的 open 或并发 open 顶替后被旧流关闭
        if (_stateGeneration != stateGeneration) {
            return;
        }

        _closedByUser = YES;
        _stateGeneration++;
        [_dataTask cancel];
        _dataTask = nil;
        [_session finishTasksAndInvalidate];
        _session = nil;
        [_buffer setLength:0];
        _pendingCR = NO;
        _bomStripped = NO;
        [_bomBuffer setLength:0];
        _bufferOverflow = NO;
        _responseFailed = NO;
    }
}

- (void)_dispatchEvent:(WJXEvent *)event forName:(WJXEventName)name
{
    NSUInteger stateGeneration = 0;
    @synchronized (self) {
        stateGeneration = _stateGeneration;
    }
    [self _dispatchEvent:event forName:name stateGeneration:stateGeneration];
}

- (void)_dispatchEvent:(WJXEvent *)event
               forName:(WJXEventName)name
       stateGeneration:(NSUInteger)stateGeneration
{
    [self _dispatchEvent:event forName:name stateGeneration:stateGeneration survivesClose:NO];
}

- (void)_dispatchEvent:(WJXEvent *)event
               forName:(WJXEventName)name
       stateGeneration:(NSUInteger)stateGeneration
         survivesClose:(BOOL)survivesClose
{
    __block NSMutableArray<WJXEventHandler *> *snapshot = nil;
    dispatch_sync(self.listenersQueue, ^{
        snapshot = [self.listeners[name] copy];
    });
    [snapshot enumerateObjectsUsingBlock:^(WJXEventHandler * _Nonnull handler, NSUInteger idx, BOOL * _Nonnull stop) {
        NSOperationQueue *queue = handler.queue ?: NSOperationQueue.mainQueue;
        [queue addOperationWithBlock:^{
            @synchronized (self) {
                // 回调真正执行前复核代次,丢弃 close/open 后仍排在队列里的旧连接事件
                if (self->_stateGeneration != stateGeneration) {
                    BOOL closedByThisEvent = survivesClose
                        && self->_closedByUser
                        && self->_stateGeneration == stateGeneration + 1;
                    if (!closedByThisEvent) {
                        return;
                    }
                }
            }
            handler.handler(event);
        }];
    }];
}

@end
