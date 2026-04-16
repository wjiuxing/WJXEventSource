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

@end
