//
//  WJXEventSourceTests.m
//  WJXEventSourceTests
//
//  Unit tests for SSE event parsing (_parseEventData:).
//  Add this file and WJXEventSource+TestHelpers.{h,m} to the test target.
//

#import <XCTest/XCTest.h>
#import "WJXEventSource+TestHelpers.h"
#import "WJXEventSource-Private.h"

/// Captures events dispatched during parsing
@interface WJXTestEventCapture : NSObject
@property (nonatomic, strong) NSMutableArray<WJXEvent *> *capturedEvents;
- (void)handleEvent:(WJXEvent *)event;
@end

@implementation WJXTestEventCapture

- (instancetype)init
{
    if (self = [super init]) {
        self.capturedEvents = [NSMutableArray array];
    }
    return self;
}

- (void)handleEvent:(WJXEvent *)event
{
    [self.capturedEvents addObject:event];
}

@end

/// 统计 buffer 头部压缩次数,用于防止多事件解析退化成逐事件 memmove
@interface WJXCountingMutableData : NSMutableData
@property (nonatomic, strong) NSMutableData *backingData;
@property (nonatomic, assign) NSUInteger replaceCount;
@end

@implementation WJXCountingMutableData

- (instancetype)init
{
    if (self = [super init]) {
        self.backingData = [NSMutableData data];
    }
    return self;
}

- (NSUInteger)length
{
    return self.backingData.length;
}

- (const void *)bytes
{
    return self.backingData.bytes;
}

- (void)appendBytes:(const void *)bytes length:(NSUInteger)length
{
    [self.backingData appendBytes:bytes length:length];
}

- (void)setLength:(NSUInteger)length
{
    [self.backingData setLength:length];
}

- (void)replaceBytesInRange:(NSRange)range withBytes:(const void *)bytes length:(NSUInteger)length
{
    self.replaceCount += 1;
    [self.backingData replaceBytesInRange:range withBytes:bytes length:length];
}

- (NSData *)subdataWithRange:(NSRange)range
{
    return [self.backingData subdataWithRange:range];
}

- (NSRange)rangeOfData:(NSData *)dataToFind options:(NSDataSearchOptions)mask range:(NSRange)rangeOfSearch
{
    return [self.backingData rangeOfData:dataToFind options:mask range:rangeOfSearch];
}

@end

/// 立即执行 block operation，用于在事件派发点同步触发 open/close，复现锁外窗口
@interface WJXImmediateOperationQueue : NSOperationQueue
@end

@implementation WJXImmediateOperationQueue

- (void)addOperationWithBlock:(void (^)(void))block
{
    if (nil != block) {
        block();
    }
}

@end

/// 读取状态时触发重开，用于插入 didReceiveResponse 首次校验与状态写入之间的窗口
@interface WJXTestOpenOnStatusResponse : NSHTTPURLResponse
@property (nonatomic, copy) void (^openBlock)(void);
@end

@implementation WJXTestOpenOnStatusResponse

- (NSInteger)statusCode
{
    if (nil != self.openBlock) {
        self.openBlock();
        self.openBlock = nil;
    }
    return [super statusCode];
}

@end

/// drain 阶段包装事件数据，真正进入 UTF-8 解析读取 bytes 时才触发重开
@interface WJXTestOpenWhenParsedData : NSData
@property (nonatomic, strong) NSData *backingData;
@property (nonatomic, copy) void (^openBlock)(void);
@property (nonatomic, assign) BOOL opened;
- (instancetype)initWithBackingData:(NSData *)backingData openBlock:(void (^)(void))openBlock;
@end

@implementation WJXTestOpenWhenParsedData

- (instancetype)initWithBackingData:(NSData *)backingData openBlock:(void (^)(void))openBlock
{
    if (self = [super init]) {
        self.backingData = backingData;
        self.openBlock = openBlock;
    }
    return self;
}

- (NSUInteger)length
{
    return self.backingData.length;
}

- (const void *)bytes
{
    if (!self.opened && nil != self.openBlock) {
        self.opened = YES;
        self.openBlock();
        self.openBlock = nil;
    }
    return self.backingData.bytes;
}

@end

/// 用自定义 subdata 把“锁内 drain”和“锁外 parse”的边界接到测试钩子上
@interface WJXTestOpenWhenParsedMutableData : WJXCountingMutableData
@property (nonatomic, copy) void (^openBlock)(void);
@end

@implementation WJXTestOpenWhenParsedMutableData

- (NSData *)subdataWithRange:(NSRange)range
{
    NSData *backingData = [super subdataWithRange:range];
    if (nil == self.openBlock) {
        return backingData;
    }
    return [[WJXTestOpenWhenParsedData alloc] initWithBackingData:backingData openBlock:self.openBlock];
}

@end

#pragma mark -

@interface WJXEventParseTests : XCTestCase
@property (nonatomic, strong) WJXEventSource *eventSource;
@property (nonatomic, strong) WJXTestEventCapture *eventCapture;
@property (nonatomic, strong) NSOperationQueue *testQueue;
@end

@implementation WJXEventParseTests

- (void)setUp
{
    [super setUp];
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:@"http://localhost/"]];
    self.eventSource = [[WJXEventSource alloc] initWithRequest:request];
    self.eventCapture = [[WJXTestEventCapture alloc] init];
    
    self.testQueue = [[NSOperationQueue alloc] init];
    self.testQueue.maxConcurrentOperationCount = 1;
    
    __weak typeof(_eventCapture) weakCapture = _eventCapture;
    [self.eventSource addListener:^(WJXEvent *event) {
        [weakCapture handleEvent:event];
    } forEvent:WJXEventNameMessage queue:self.testQueue];
}

- (void)tearDown
{
    [self.eventSource close];
    self.eventSource = nil;
    self.eventCapture = nil;
    self.testQueue = nil;
    [super tearDown];
}

/// 调用 parseEventData 后等待 testQueue 完成事件派发
- (void)parseAndWait:(NSData *)sseData
{
    [self.eventSource parseEventData:sseData];
    [self.testQueue waitUntilAllOperationsAreFinished];
}

#pragma mark - Basic Field Parsing

/// 测试解析 data 字段
- (void)testParseDataField
{
    NSData *sseData = [@"data: hello world" dataUsingEncoding:NSUTF8StringEncoding];
    [self parseAndWait:sseData];
    
    XCTAssertEqual(self.eventCapture.capturedEvents.count, 1);
    WJXEvent *event = self.eventCapture.capturedEvents.firstObject;
    XCTAssertEqualObjects(event.data, @"hello world");
    XCTAssertNil(event.event);
    XCTAssertNil(event.eventId);
}

/// 测试解析 event 字段
- (void)testParseEventField
{
    NSMutableArray<WJXEvent *> *namedEvents = [NSMutableArray array];
    [self.eventSource addListener:^(WJXEvent *event) {
        @synchronized (namedEvents) {
            [namedEvents addObject:event];
        }
    } forEvent:@"custom" queue:self.testQueue];

    NSData *sseData = [@"event: custom\ndata: payload" dataUsingEncoding:NSUTF8StringEncoding];
    [self parseAndWait:sseData];
    
    WJXEvent *event = namedEvents.firstObject;
    XCTAssertEqualObjects(event.event, @"custom");
    XCTAssertEqualObjects(event.data, @"payload");
}

/// 规范:event 字段应按事件名定向派发,未指定 event 时才派发 message
- (void)testNamedEventDispatchesToMatchingListener
{
    NSMutableArray<WJXEvent *> *namedEvents = [NSMutableArray array];
    [self.eventSource addListener:^(WJXEvent *event) {
        @synchronized (namedEvents) {
            [namedEvents addObject:event];
        }
    } forEvent:@"update" queue:self.testQueue];

    [self parseAndWait:[@"event: update\ndata: payload" dataUsingEncoding:NSUTF8StringEncoding]];

    XCTAssertEqual(namedEvents.count, 1u);
    XCTAssertEqual(self.eventCapture.capturedEvents.count, 0u);
}

/// 测试解析 id 字段
- (void)testParseIdField
{
    NSData *sseData = [@"id: 42\ndata: test" dataUsingEncoding:NSUTF8StringEncoding];
    [self parseAndWait:sseData];
    
    WJXEvent *event = self.eventCapture.capturedEvents.firstObject;
    XCTAssertEqualObjects(event.eventId, @"42");
    XCTAssertEqualObjects(event.data, @"test");
}

/// 测试解析 retry 字段
- (void)testParseRetryField
{
    NSData *sseData = [@"retry: 5000\ndata: test" dataUsingEncoding:NSUTF8StringEncoding];
    [self parseAndWait:sseData];
    
    // retry: 5000 (ms) → retryInterval = 5.0 (s)
    XCTAssertEqualWithAccuracy(self.eventSource.retryInterval, 5.0, 0.001);
}

#pragma mark - Multi-line Data

/// 测试多行 data 字段用 \n 连接（符合 SSE 规范）
- (void)testMultiLineData
{
    NSData *sseData = [@"data: line1\ndata: line2\ndata: line3" dataUsingEncoding:NSUTF8StringEncoding];
    [self parseAndWait:sseData];
    
    WJXEvent *event = self.eventCapture.capturedEvents.firstObject;
    XCTAssertEqualObjects(event.data, @"line1\nline2\nline3");
}

/// U+2028/U+2029/U+0085 不是 SSE 行终止符(规范只认 CR/LF/CRLF),出现在 data 载荷中必须原样保留
- (void)testUnicodeLineSeparatorInDataPreserved
{
    NSData *sseData = [@"data: {\"a\":\"x\u2028y\u2029z\"}" dataUsingEncoding:NSUTF8StringEncoding];
    [self parseAndWait:sseData];

    WJXEvent *event = self.eventCapture.capturedEvents.firstObject;
    XCTAssertEqualObjects(event.data, @"{\"a\":\"x\u2028y\u2029z\"}");
}

#pragma mark - Edge Cases

/// 测试 data 字段不带空格（SSE 规范允许 data:value 和 data: value 等价）
- (void)testDataFieldWithoutSpace
{
    NSData *sseData = [@"data:nospace" dataUsingEncoding:NSUTF8StringEncoding];
    [self parseAndWait:sseData];
    
    WJXEvent *event = self.eventCapture.capturedEvents.firstObject;
    XCTAssertEqualObjects(event.data, @"nospace");
}

/// 规范:字段冒号可省略,无冒号 data 表示空数据且仍需派发 message
- (void)testDataFieldWithoutColonDispatchesEmptyMessage
{
    NSData *sseData = [@"data\n\n" dataUsingEncoding:NSUTF8StringEncoding];
    [self parseAndWait:sseData];

    XCTAssertEqual(self.eventCapture.capturedEvents.count, 1);
    XCTAssertEqualObjects(self.eventCapture.capturedEvents.firstObject.data, @"");
}

/// 测试空 data 字段
- (void)testEmptyDataField
{
    NSData *sseData = [@"data:" dataUsingEncoding:NSUTF8StringEncoding];
    [self parseAndWait:sseData];
    
    WJXEvent *event = self.eventCapture.capturedEvents.firstObject;
    XCTAssertEqualObjects(event.data, @"");
}

/// 测试注释行（以冒号开头）被忽略
- (void)testCommentLinesIgnored
{
    NSData *sseData = [@"data: hello\n: this is a comment\ndata: world" dataUsingEncoding:NSUTF8StringEncoding];
    [self parseAndWait:sseData];
    
    WJXEvent *event = self.eventCapture.capturedEvents.firstObject;
    XCTAssertEqualObjects(event.data, @"hello\nworld");
}

/// 测试完整 SSE 事件（所有字段）
- (void)testCompleteEvent
{
    NSMutableArray<WJXEvent *> *namedEvents = [NSMutableArray array];
    [self.eventSource addListener:^(WJXEvent *event) {
        @synchronized (namedEvents) {
            [namedEvents addObject:event];
        }
    } forEvent:@"update" queue:self.testQueue];

    NSData *sseData = [@"id: abc123\nevent: update\ndata: first\ndata: second\nretry: 2000" dataUsingEncoding:NSUTF8StringEncoding];
    [self parseAndWait:sseData];
    
    WJXEvent *event = namedEvents.firstObject;
    XCTAssertEqualObjects(event.eventId, @"abc123");
    XCTAssertEqualObjects(event.event, @"update");
    XCTAssertEqualObjects(event.data, @"first\nsecond");
    XCTAssertEqualWithAccuracy(self.eventSource.retryInterval, 2.0, 0.001);
}

/// 测试只有未知字段的行被忽略
- (void)testUnknownFieldsIgnored
{
    NSData *sseData = [@"unknown: foo\ndata: bar" dataUsingEncoding:NSUTF8StringEncoding];
    [self parseAndWait:sseData];

    WJXEvent *event = self.eventCapture.capturedEvents.firstObject;
    XCTAssertEqualObjects(event.data, @"bar");
}

#pragma mark - Buffer Race Regression (Bugly #11242650)

/// 回归:解析线程扫描/消费 buffer 期间,另一线程 close 清空 buffer,不得抛 NSRangeException。
/// 复现原 bug:close 里 `_buffer = [NSMutableData data]` 换指针,解析线程拿旧 range 撞新空对象。
- (void)testCloseRacingBufferDrainDoesNotCrash
{
    NSMutableData *chunk = [NSMutableData data];
    for (NSUInteger i = 0; i < 50; i++) {
        [chunk appendData:[@"data: hello world\n\n" dataUsingEncoding:NSUTF8StringEncoding]];
    }
    NSURLSessionDataTask *raceTask = [[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:@"http://localhost/"]];

    dispatch_queue_t drainQueue = dispatch_queue_create("test.buffer.drain", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_t closeQueue = dispatch_queue_create("test.buffer.close", DISPATCH_QUEUE_SERIAL);
    dispatch_group_t group = dispatch_group_create();

    for (NSUInteger round = 0; round < 300; round++) {
        @autoreleasepool {
            // 每轮使用独立 source 并等待结束,避免测试用 KVC 在锁外重置 closedByUser
            WJXEventSource *raceSource = [[WJXEventSource alloc] initWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"http://localhost/"]]];
            raceSource.dataTask = raceTask;

            dispatch_group_async(group, drainQueue, ^{
                [(id<NSURLSessionDataDelegate>)raceSource URLSession:[NSURLSession sharedSession] dataTask:raceTask didReceiveData:chunk];
            });
            dispatch_group_async(group, closeQueue, ^{
                [raceSource close];
            });
            dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        }
    }

    // 未捕获的 NSRangeException 会直接终止测试进程;能走到这里即通过
    [self.testQueue waitUntilAllOperationsAreFinished];
    XCTAssertNotNil(self.eventSource);
}

#pragma mark - Spec Compliance

/// 规范:纯注释块(`: ping` 心跳/空块)不派发 message
- (void)testCommentOnlyEventNotDispatched
{
    [self parseAndWait:[@": ping" dataUsingEncoding:NSUTF8StringEncoding]];
    XCTAssertEqual(self.eventCapture.capturedEvents.count, 0);
}

/// 规范:retry 非纯 ASCII 数字被忽略,间隔不变(否则会置 0 紧贴重连)
- (void)testRetryNonDigitIgnored
{
    [self parseAndWait:[@"retry: abc\ndata: x" dataUsingEncoding:NSUTF8StringEncoding]];
    XCTAssertEqualWithAccuracy(self.eventSource.retryInterval, 3.0, 0.001);
}

/// 规范:科学计数法等非纯数字 retry 同样忽略
- (void)testRetryScientificNotationIgnored
{
    [self parseAndWait:[@"retry: 1e3\ndata: x" dataUsingEncoding:NSUTF8StringEncoding]];
    XCTAssertEqualWithAccuracy(self.eventSource.retryInterval, 3.0, 0.001);
}

/// 规范:冒号后仅剥一个空格,前导多余空格与尾部空白保留
- (void)testFieldValueWhitespacePreserved
{
    [self parseAndWait:[@"data:   x  " dataUsingEncoding:NSUTF8StringEncoding]];
    XCTAssertEqualObjects(self.eventCapture.capturedEvents.firstObject.data, @"  x  ");
}

/// CRLF 行尾归一化后按 \n\n 正常分隔
- (void)testCRLFLineEndings
{
    [self.eventSource _appendNormalizedData:[@"data: hello\r\n\r\ndata: world\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    NSMutableArray<NSData *> *events = [self.eventSource _drainBuffer];
    XCTAssertEqual(events.count, 2);
}

/// 流首 BOM 剥除一次,不影响分隔
- (void)testBOMStripped
{
    NSMutableData *chunk = [NSMutableData data];
    [chunk appendBytes:"\xEF\xBB\xBF" length:3];
    [chunk appendData:[@"data: bom\n\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [self.eventSource _appendNormalizedData:chunk];
    XCTAssertEqual([self.eventSource _drainBuffer].count, 1);
}

/// BOM 被拆在多个 chunk(如首 chunk 仅 1 字节)仍正确剥除,不污染首条事件
- (void)testBOMSplitAcrossChunks
{
    [self.eventSource _appendNormalizedData:[NSData dataWithBytes:"\xEF" length:1]];
    NSMutableData *rest = [NSMutableData data];
    [rest appendBytes:"\xBB\xBF" length:2];
    [rest appendData:[@"data: bom\n\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [self.eventSource _appendNormalizedData:rest];
    XCTAssertEqual([self.eventSource _drainBuffer].count, 1);
}

/// 超大未完成事件按分片判坏流,处理中的半包缓冲不超过单事件上限
- (void)testOversizedEventRejectedWithBoundedBuffer
{
    NSMutableArray<WJXEvent *> *errors = [NSMutableArray array];
    WJXEventSource *source = [[WJXEventSource alloc] initWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"http://192.0.2.1:81/"]]];
    [source addListener:^(WJXEvent *event) {
        @synchronized (errors) {
            [errors addObject:event];
        }
    } forEvent:WJXEventNameError queue:self.testQueue];
    source.dataTask = [[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:@"http://192.0.2.1:81/"]];

    NSMutableData *huge = [NSMutableData dataWithData:[@"data: " dataUsingEncoding:NSUTF8StringEncoding]];
    [huge increaseLengthBy:1200 * 1024];
    [(id<NSURLSessionDataDelegate>)source URLSession:[NSURLSession sharedSession] dataTask:source.dataTask didReceiveData:huge];
    [self.testQueue waitUntilAllOperationsAreFinished];

    // 判坏流并关闭:error 恰好一次,buffer 从未装入超大 chunk(一直为空)
    XCTAssertEqual(errors.count, 1u);
    XCTAssertEqual(source.buffer.length, 0u);
}

/// 真实 didReceiveData 路径:单个 chunk 内多个完整事件总量超上限仍合法,不得按 chunk 总量误拒
- (void)testManyCompleteEventsOverLimitDeliveredThroughDataCallback
{
    NSMutableArray<WJXEvent *> *messages = [NSMutableArray array];
    NSMutableArray<WJXEvent *> *errors = [NSMutableArray array];
    WJXEventSource *source = [[WJXEventSource alloc] initWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"http://192.0.2.1:81/"]]];
    [source addListener:^(WJXEvent *event) {
        @synchronized (messages) {
            [messages addObject:event];
        }
    } forEvent:WJXEventNameMessage queue:self.testQueue];
    [source addListener:^(WJXEvent *event) {
        @synchronized (errors) {
            [errors addObject:event];
        }
    } forEvent:WJXEventNameError queue:self.testQueue];
    source.dataTask = [[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:@"http://192.0.2.1:81/"]];

    NSMutableData *payload = [NSMutableData data];
    for (NSUInteger i = 0; i < 2; i++) {
        [payload appendData:[@"data: " dataUsingEncoding:NSUTF8StringEncoding]];
        [payload increaseLengthBy:600 * 1024];
        [payload appendData:[@"\n\n" dataUsingEncoding:NSUTF8StringEncoding]];
    }
    [(id<NSURLSessionDataDelegate>)source URLSession:[NSURLSession sharedSession] dataTask:source.dataTask didReceiveData:payload];
    [self.testQueue waitUntilAllOperationsAreFinished];

    XCTAssertEqual(messages.count, 2u);
    XCTAssertEqual(errors.count, 0u);
    XCTAssertFalse(source.bufferOverflow);

    [source close];
}

/// \r 落在 chunk 边界不得拼出假 \n\n 分隔符
- (void)testCRSplitAcrossChunks
{
    [self.eventSource _appendNormalizedData:[@"data: x\r" dataUsingEncoding:NSUTF8StringEncoding]];
    [self.eventSource _appendNormalizedData:[@"\ndata: y\n\n" dataUsingEncoding:NSUTF8StringEncoding]];
    XCTAssertEqual([self.eventSource _drainBuffer].count, 1);
}

/// 剩余半包超过上限置溢出标志
- (void)testBufferOverflowFlagged
{
    NSMutableData *big = [NSMutableData dataWithData:[@"data: " dataUsingEncoding:NSUTF8StringEncoding]];
    [big increaseLengthBy:1200 * 1024];
    [self.eventSource _appendNormalizedData:big];
    // 上限在 drain 后按剩余半包计,须先 drain 再断言
    XCTAssertEqual([self.eventSource _drainBuffer].count, 0);
    XCTAssertTrue(self.eventSource.bufferOverflow);
}

/// 多个完整事件总量超上限不是坏流:上限只针对单个事件与剩余半包
- (void)testManyCompleteEventsOverLimitStillDelivered
{
    NSMutableData *payload = [NSMutableData data];
    for (NSUInteger i = 0; i < 2; i++) {
        [payload appendData:[@"data: " dataUsingEncoding:NSUTF8StringEncoding]];
        [payload increaseLengthBy:600 * 1024];
        [payload appendData:[@"\n\n" dataUsingEncoding:NSUTF8StringEncoding]];
    }
    [self.eventSource _appendNormalizedData:payload];
    NSMutableArray<NSData *> *events = [self.eventSource _drainBuffer];
    XCTAssertEqual(events.count, 2);
    XCTAssertFalse(self.eventSource.bufferOverflow);
}

/// 多个完整事件解析后只压缩一次 buffer,避免逐事件移动剩余数据
- (void)testDrainBufferCompactsOnceForMultipleCompleteEvents
{
    WJXCountingMutableData *buffer = [[WJXCountingMutableData alloc] init];
    self.eventSource.buffer = buffer;

    NSMutableData *payload = [NSMutableData data];
    for (NSUInteger i = 0; i < 3; i++) {
        [payload appendData:[[NSString stringWithFormat:@"data:%lu\n\n", (unsigned long)i]
                             dataUsingEncoding:NSUTF8StringEncoding]];
    }
    [payload appendData:[@"data:partial" dataUsingEncoding:NSUTF8StringEncoding]];
    [self.eventSource _appendNormalizedData:payload];

    NSMutableArray<NSData *> *events = [self.eventSource _drainBuffer];

    XCTAssertEqual(events.count, 3u);
    XCTAssertEqualObjects(self.eventSource.buffer,
                          [@"data:partial" dataUsingEncoding:NSUTF8StringEncoding]);
    XCTAssertEqual(buffer.replaceCount, 1u);
}

/// 超大坏事件不能吞掉同一 buffer 中位于其前面的已完成合法事件
- (void)testCompleteEventsBeforeOversizedEventStillDelivered
{
    NSMutableData *payload = [NSMutableData data];
    [payload appendData:[@"data: valid\n\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [payload appendData:[@"data: " dataUsingEncoding:NSUTF8StringEncoding]];
    [payload increaseLengthBy:1200 * 1024];
    [payload appendData:[@"\n\n" dataUsingEncoding:NSUTF8StringEncoding]];

    [self.eventSource _appendNormalizedData:payload];
    NSMutableArray<NSData *> *events = [self.eventSource _drainBuffer];

    XCTAssertEqual(events.count, 1);
    XCTAssertTrue(self.eventSource.bufferOverflow);
}

- (NSHTTPURLResponse *)testResponseWithStatusCode:(NSInteger)statusCode contentType:(NSString *)contentType
{
    return [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"http://localhost/"]
                                       statusCode:statusCode
                                      HTTPVersion:@"HTTP/1.1"
                                     headerFields:(nil == contentType ? @{} : @{@"Content-Type": contentType})];
}

/// 独立不可路由源:排除真实连接错误混入 error 计数
- (WJXEventSource *)testUnroutableSourceWithErrors:(NSMutableArray<WJXEvent *> *)errors
{
    WJXEventSource *source = [[WJXEventSource alloc] initWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"http://192.0.2.1:81/"]]];
    [source addListener:^(WJXEvent *event) {
        @synchronized (errors) {
            [errors addObject:event];
        }
    } forEvent:WJXEventNameError queue:self.testQueue];
    [source open];
    return source;
}

/// 非 200 只派发一次 error:响应阶段一次,取消型 completion 不再重复
- (void)testNon200DispatchesSingleError
{
    NSMutableArray<WJXEvent *> *errors = [NSMutableArray array];
    WJXEventSource *source = [self testUnroutableSourceWithErrors:errors];

    __block NSURLSessionResponseDisposition disposition = NSURLSessionResponseAllow;
    [(id<NSURLSessionDataDelegate>)source URLSession:[NSURLSession sharedSession] dataTask:source.dataTask didReceiveResponse:[self testResponseWithStatusCode:404 contentType:@"text/html"]
        completionHandler:^(NSURLSessionResponseDisposition d) {
            disposition = d;
        }];
    [(id<NSURLSessionDataDelegate>)source URLSession:[NSURLSession sharedSession] task:source.dataTask didCompleteWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]];
    [self.testQueue waitUntilAllOperationsAreFinished];

    XCTAssertEqual(disposition, NSURLSessionResponseCancel);
    XCTAssertEqual(errors.count, 1);
    XCTAssertEqual(errors.firstObject.error.code, 404);

    [source close];
}

/// HTTP 响应失败也必须通知 readyState Closed,避免只监听状态的调用方停在非终态
- (void)testNon200DispatchesClosedReadyState
{
    NSMutableArray<WJXEvent *> *states = [NSMutableArray array];
    WJXEventSource *source = [[WJXEventSource alloc] initWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"http://192.0.2.1:81/"]]];
    [source addListener:^(WJXEvent *event) {
        @synchronized (states) {
            [states addObject:event];
        }
    } forEvent:WJXEventNameReadyState queue:self.testQueue];
    source.dataTask = [[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:@"http://localhost/"]];

    NSHTTPURLResponse *response = [self testResponseWithStatusCode:404 contentType:@"text/html"];
    [(id<NSURLSessionDataDelegate>)source URLSession:[NSURLSession sharedSession] dataTask:source.dataTask didReceiveResponse:response
        completionHandler:^(NSURLSessionResponseDisposition disposition) {}];
    [self.testQueue waitUntilAllOperationsAreFinished];

    NSUInteger closedIndex = [states indexOfObjectPassingTest:^BOOL(WJXEvent *event, NSUInteger idx, BOOL *stop) {
        *stop = YES;
        return WJXEventStateClosed == event.readyState;
    }];
    XCTAssertNotEqual(NSNotFound, closedIndex);

    [source close];
}

/// MIME 精确匹配:text/event-streamevil 拒绝,大小写与参数不敏感的合法值接受
- (void)testContentTypeExactMatch
{
    NSMutableArray<WJXEvent *> *errors = [NSMutableArray array];
    WJXEventSource *source = [self testUnroutableSourceWithErrors:errors];

    [(id<NSURLSessionDataDelegate>)source URLSession:[NSURLSession sharedSession] dataTask:source.dataTask didReceiveResponse:[self testResponseWithStatusCode:200 contentType:@"Text/Event-Stream; charset=utf-8"]
        completionHandler:^(NSURLSessionResponseDisposition d) {}];
    [(id<NSURLSessionDataDelegate>)source URLSession:[NSURLSession sharedSession] dataTask:source.dataTask didReceiveResponse:[self testResponseWithStatusCode:200 contentType:@"text/event-streamevil"]
        completionHandler:^(NSURLSessionResponseDisposition d) {}];
    [(id<NSURLSessionDataDelegate>)source URLSession:[NSURLSession sharedSession] task:source.dataTask didCompleteWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]];
    [self.testQueue waitUntilAllOperationsAreFinished];

    // 第二次(非法 MIME)才失败:恰好 1 次 error,取消型 completion 不重复
    XCTAssertEqual(errors.count, 1);
    XCTAssertEqual(errors.firstObject.error.code, -1);

    [source close];
}

/// 服务端无错误断开时,readyState 事件应显式标记 cleanClose,调用方不得依赖内部 NSError 约定
- (void)testCleanCloseFlaggedOnReadyStateEvent
{
    NSMutableArray<WJXEvent *> *states = [NSMutableArray array];
    WJXEventSource *source = [[WJXEventSource alloc] initWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"http://localhost/"]]];
    [source addListener:^(WJXEvent *event) {
        @synchronized (states) {
            [states addObject:event];
        }
    } forEvent:WJXEventNameReadyState queue:self.testQueue];
    [source open];

    [(id<NSURLSessionTaskDelegate>)source URLSession:[NSURLSession sharedSession] task:source.dataTask didCompleteWithError:nil];
    [self.testQueue waitUntilAllOperationsAreFinished];

    XCTAssertTrue(states.lastObject.cleanClose);

    [source close];
}

/// 规范:服务端正常 EOF 属于需要自动重连的断流,不是终态
- (void)testCleanEOFSchedulesReconnect
{
    NSMutableArray<WJXEvent *> *states = [NSMutableArray array];
    XCTestExpectation *reconnected = [self expectationWithDescription:@"Event source reconnects after clean EOF"];
    WJXEventSource *source = [[WJXEventSource alloc] initWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"http://192.0.2.1:81/"]]];
    source.retryInterval = 0.05;
    [source addListener:^(WJXEvent *event) {
        @synchronized (states) {
            [states addObject:event];
        }
        if (WJXEventStateConnecting == event.readyState) {
            [reconnected fulfill];
        }
    } forEvent:WJXEventNameReadyState queue:self.testQueue];
    source.dataTask = [[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:@"http://localhost/"]];

    [(id<NSURLSessionTaskDelegate>)source URLSession:[NSURLSession sharedSession] task:source.dataTask didCompleteWithError:nil];
    [self.testQueue waitUntilAllOperationsAreFinished];
    [self waitForExpectations:@[reconnected] timeout:1.0];
    [self.testQueue waitUntilAllOperationsAreFinished];

    NSUInteger closedIndex = [states indexOfObjectPassingTest:^BOOL(WJXEvent *event, NSUInteger idx, BOOL *stop) {
        *stop = YES;
        return WJXEventStateClosed == event.readyState;
    }];
    XCTAssertNotEqual(NSNotFound, closedIndex);
    XCTAssertLessThan(closedIndex, states.count - 1);
    XCTAssertEqual(states.lastObject.readyState, WJXEventStateConnecting);

    [source close];
}

/// 被顶替任务(open 重开后的旧任务)的数据被丢弃,当前任务数据正常派发
- (void)testSupersededTaskDataDropped
{
    [self.eventSource open];
    NSData *chunk = [@"data: hello\n\n" dataUsingEncoding:NSUTF8StringEncoding];

    // 当前任务的数据正常派发
    [(id<NSURLSessionDataDelegate>)self.eventSource URLSession:[NSURLSession sharedSession] dataTask:self.eventSource.dataTask didReceiveData:chunk];
    [self.testQueue waitUntilAllOperationsAreFinished];
    XCTAssertEqual(self.eventCapture.capturedEvents.count, 1);

    // 另一实例的任务引用,模拟被顶替的旧任务:数据整体丢弃
    WJXEventSource *other = [[WJXEventSource alloc] initWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"http://localhost/"]]];
    [other open];
    [(id<NSURLSessionDataDelegate>)self.eventSource URLSession:[NSURLSession sharedSession] dataTask:other.dataTask didReceiveData:chunk];
    [self.testQueue waitUntilAllOperationsAreFinished];
    XCTAssertEqual(self.eventCapture.capturedEvents.count, 1);

    [other close];
}

/// 响应首次校验后、状态写入前发生 open,旧响应不得污染新连接的响应失败标记
- (void)testOpenDuringResponseParsingDoesNotPoisonNewConnection
{
    WJXEventSource *source = [[WJXEventSource alloc] initWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"http://localhost/"]]];
    [source open];
    NSURLSessionDataTask *oldTask = source.dataTask;

    WJXTestOpenOnStatusResponse *response = [[WJXTestOpenOnStatusResponse alloc] initWithURL:[NSURL URLWithString:@"http://localhost/"]
                                                                                    statusCode:404
                                                                                   HTTPVersion:@"HTTP/1.1"
                                                                                  headerFields:@{@"Content-Type": @"text/html"}];
    __weak typeof(source) weakSource = source;
    response.openBlock = ^{
        [weakSource open];
    };
    [(id<NSURLSessionDataDelegate>)source URLSession:[NSURLSession sharedSession] dataTask:oldTask didReceiveResponse:response
        completionHandler:^(NSURLSessionResponseDisposition disposition) {}];

    XCTAssertNotEqualObjects(oldTask, source.dataTask);
    XCTAssertFalse([[source valueForKey:@"responseFailed"] boolValue]);

    [source close];
}

/// 事件在锁内 drain、锁外解析之间被 open 顶替时,不得提交旧 lastEventId 或派发旧消息
- (void)testOpenDuringParsedEventReadingDropsSupersededEvent
{
    WJXEventSource *source = [[WJXEventSource alloc] initWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"http://localhost/"]]];
    NSMutableArray<WJXEvent *> *messages = [NSMutableArray array];
    [source open];
    NSURLSessionDataTask *oldTask = source.dataTask;
    [source addListener:^(WJXEvent *event) {
        @synchronized (messages) {
            [messages addObject:event];
        }
    } forEvent:WJXEventNameMessage queue:self.testQueue];

    WJXTestOpenWhenParsedMutableData *buffer = [[WJXTestOpenWhenParsedMutableData alloc] init];
    __weak typeof(source) weakSource = source;
    buffer.openBlock = ^{
        [weakSource open];
    };
    source.buffer = buffer;

    NSData *chunk = [@"id: stale\ndata: old stream\n\n" dataUsingEncoding:NSUTF8StringEncoding];
    [(id<NSURLSessionDataDelegate>)source URLSession:[NSURLSession sharedSession] dataTask:oldTask didReceiveData:chunk];
    [self.testQueue waitUntilAllOperationsAreFinished];

    XCTAssertNotEqualObjects(oldTask, source.dataTask);
    XCTAssertNil([source valueForKey:@"lastEventId"]);
    XCTAssertEqual(messages.count, 0u);

    [source close];
}

/// completion 事件派发点同步重开时,旧 completion cleanup 不得 invalidate 新 session/task
- (void)testOpenDuringCompletionEventDoesNotInvalidateNewConnection
{
    WJXEventSource *source = [[WJXEventSource alloc] initWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"http://localhost/"]]];
    source.ignoreRetryAction = YES;
    [source open];
    NSURLSessionDataTask *oldTask = source.dataTask;

    WJXImmediateOperationQueue *immediateQueue = [[WJXImmediateOperationQueue alloc] init];
    __weak typeof(source) weakSource = source;
    __block BOOL reopened = NO;
    [source addListener:^(WJXEvent *event) {
        if (WJXEventStateClosed == event.readyState && !reopened) {
            reopened = YES;
            [weakSource open];
        }
    } forEvent:WJXEventNameReadyState queue:immediateQueue];

    [(id<NSURLSessionTaskDelegate>)source URLSession:[NSURLSession sharedSession] task:oldTask didCompleteWithError:nil];

    XCTAssertNotEqualObjects(oldTask, source.dataTask);
    XCTAssertNotNil(source.dataTask);
    XCTAssertNotNil([source valueForKey:@"session"]);

    [source close];
}

/// 第一次 Connecting 回调执行前被第二次 open 顶替,只允许当前连接的事件到达监听方
- (void)testSupersededConnectingEventDropped
{
    NSMutableArray<WJXEvent *> *states = [NSMutableArray array];
    [self.eventSource addListener:^(WJXEvent *event) {
        @synchronized (states) {
            [states addObject:event];
        }
    } forEvent:WJXEventNameReadyState queue:self.testQueue];

    self.testQueue.suspended = YES;
    [self.eventSource open];
    [self.eventSource open];
    self.testQueue.suspended = NO;
    [self.testQueue waitUntilAllOperationsAreFinished];

    XCTAssertEqual(states.count, 1u);
    XCTAssertEqual(states.lastObject.readyState, WJXEventStateConnecting);
}

/// 旧流的 buffer overflow 不能关闭已经重开的新连接
- (void)testOverflowFromSupersededGenerationDoesNotCloseNewConnection
{
    NSMutableArray<WJXEvent *> *errors = [NSMutableArray array];
    WJXEventSource *source = [[WJXEventSource alloc] initWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"http://localhost/"]]];
    [source open];
    NSUInteger supersededGeneration = ((NSNumber *)[source valueForKey:@"stateGeneration"]).unsignedIntegerValue;
    NSURLSessionDataTask *firstTask = source.dataTask;
    [source addListener:^(WJXEvent *event) {
        @synchronized (errors) {
            [errors addObject:event];
        }
    } forEvent:WJXEventNameError queue:self.testQueue];

    [source open];
    NSURLSessionDataTask *currentTask = source.dataTask;
    source.bufferOverflow = YES;
    [source _handleBufferOverflowForStateGeneration:supersededGeneration];
    [self.testQueue waitUntilAllOperationsAreFinished];

    XCTAssertNotEqualObjects(firstTask, currentTask);
    XCTAssertEqualObjects(currentTask, source.dataTask);
    XCTAssertNotNil([source valueForKey:@"session"]);
    XCTAssertEqual(errors.count, 0u);

    [source close];
}

/// overflow error 回调同步重开时,cleanup 不能 invalidate 回调开启的新连接
- (void)testOverflowCallbackReopenDoesNotInvalidateNewConnection
{
    NSMutableArray<WJXEvent *> *errors = [NSMutableArray array];
    WJXEventSource *source = [[WJXEventSource alloc] initWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"http://localhost/"]]];
    [source open];
    NSUInteger stateGeneration = ((NSNumber *)[source valueForKey:@"stateGeneration"]).unsignedIntegerValue;
    NSURLSessionDataTask *overflowTask = source.dataTask;
    WJXImmediateOperationQueue *immediateQueue = [[WJXImmediateOperationQueue alloc] init];
    __weak typeof(source) weakSource = source;
    __block BOOL reopened = NO;
    [source addListener:^(WJXEvent *event) {
        @synchronized (errors) {
            [errors addObject:event];
        }
        if (!reopened) {
            reopened = YES;
            [weakSource open];
        }
    } forEvent:WJXEventNameError queue:immediateQueue];

    source.bufferOverflow = YES;
    [source _handleBufferOverflowForStateGeneration:stateGeneration];

    XCTAssertEqual(errors.count, 1u);
    XCTAssertNotEqualObjects(overflowTask, source.dataTask);
    XCTAssertNotNil(source.dataTask);
    XCTAssertNotNil([source valueForKey:@"session"]);

    [source close];
}

@end
