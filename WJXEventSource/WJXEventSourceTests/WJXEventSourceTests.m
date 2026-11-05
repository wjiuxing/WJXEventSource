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
    NSData *sseData = [@"event: custom\ndata: payload" dataUsingEncoding:NSUTF8StringEncoding];
    [self parseAndWait:sseData];
    
    WJXEvent *event = self.eventCapture.capturedEvents.firstObject;
    XCTAssertEqualObjects(event.event, @"custom");
    XCTAssertEqualObjects(event.data, @"payload");
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

#pragma mark - Edge Cases

/// 测试 data 字段不带空格（SSE 规范允许 data:value 和 data: value 等价）
- (void)testDataFieldWithoutSpace
{
    NSData *sseData = [@"data:nospace" dataUsingEncoding:NSUTF8StringEncoding];
    [self parseAndWait:sseData];
    
    WJXEvent *event = self.eventCapture.capturedEvents.firstObject;
    XCTAssertEqualObjects(event.data, @"nospace");
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
    NSData *sseData = [@"id: abc123\nevent: update\ndata: first\ndata: second\nretry: 2000" dataUsingEncoding:NSUTF8StringEncoding];
    [self parseAndWait:sseData];
    
    WJXEvent *event = self.eventCapture.capturedEvents.firstObject;
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

    dispatch_queue_t drainQueue = dispatch_queue_create("test.buffer.drain", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_t closeQueue = dispatch_queue_create("test.buffer.close", DISPATCH_QUEUE_SERIAL);
    dispatch_group_t group = dispatch_group_create();

    for (NSUInteger round = 0; round < 300; round++) {
        // 每轮重置关闭标记,模拟活跃连接下反复 close(如 SNSSEClient 后台 dealloc)
        [self.eventSource setValue:@NO forKey:@"closedByUser"];

        dispatch_group_async(group, drainQueue, ^{
            [(id<NSURLSessionDataDelegate>)self.eventSource URLSession:nil dataTask:nil didReceiveData:chunk];
        });
        dispatch_group_async(group, closeQueue, ^{
            [self.eventSource close];
        });
    }
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

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
    [(id<NSURLSessionDataDelegate>)source URLSession:nil dataTask:source.dataTask didReceiveResponse:[self testResponseWithStatusCode:404 contentType:@"text/html"]
        completionHandler:^(NSURLSessionResponseDisposition d) {
            disposition = d;
        }];
    [(id<NSURLSessionDataDelegate>)source URLSession:nil task:source.dataTask didCompleteWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]];
    [self.testQueue waitUntilAllOperationsAreFinished];

    XCTAssertEqual(disposition, NSURLSessionResponseCancel);
    XCTAssertEqual(errors.count, 1);
    XCTAssertEqual(errors.firstObject.error.code, 404);

    [source close];
}

/// MIME 精确匹配:text/event-streamevil 拒绝,大小写与参数不敏感的合法值接受
- (void)testContentTypeExactMatch
{
    NSMutableArray<WJXEvent *> *errors = [NSMutableArray array];
    WJXEventSource *source = [self testUnroutableSourceWithErrors:errors];

    [(id<NSURLSessionDataDelegate>)source URLSession:nil dataTask:source.dataTask didReceiveResponse:[self testResponseWithStatusCode:200 contentType:@"Text/Event-Stream; charset=utf-8"]
        completionHandler:^(NSURLSessionResponseDisposition d) {}];
    [(id<NSURLSessionDataDelegate>)source URLSession:nil dataTask:source.dataTask didReceiveResponse:[self testResponseWithStatusCode:200 contentType:@"text/event-streamevil"]
        completionHandler:^(NSURLSessionResponseDisposition d) {}];
    [(id<NSURLSessionDataDelegate>)source URLSession:nil task:source.dataTask didCompleteWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]];
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

    [(id<NSURLSessionTaskDelegate>)source URLSession:nil task:source.dataTask didCompleteWithError:nil];
    [self.testQueue waitUntilAllOperationsAreFinished];

    XCTAssertTrue(states.lastObject.cleanClose);

    [source close];
}

/// 被顶替任务(open 重开后的旧任务)的数据被丢弃,当前任务数据正常派发
- (void)testSupersededTaskDataDropped
{
    [self.eventSource open];
    NSData *chunk = [@"data: hello\n\n" dataUsingEncoding:NSUTF8StringEncoding];

    // 当前任务的数据正常派发
    [(id<NSURLSessionDataDelegate>)self.eventSource URLSession:nil dataTask:self.eventSource.dataTask didReceiveData:chunk];
    [self.testQueue waitUntilAllOperationsAreFinished];
    XCTAssertEqual(self.eventCapture.capturedEvents.count, 1);

    // 另一实例的任务引用,模拟被顶替的旧任务:数据整体丢弃
    WJXEventSource *other = [[WJXEventSource alloc] initWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"http://localhost/"]]];
    [other open];
    [(id<NSURLSessionDataDelegate>)self.eventSource URLSession:nil dataTask:other.dataTask didReceiveData:chunk];
    [self.testQueue waitUntilAllOperationsAreFinished];
    XCTAssertEqual(self.eventCapture.capturedEvents.count, 1);

    [other close];
}

@end
