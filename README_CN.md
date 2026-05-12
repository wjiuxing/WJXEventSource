# WJXEventSource

[English](README.md)

![Platform](https://img.shields.io/badge/platform-iOS%2010.0%2B-lightgrey)
![License](https://img.shields.io/badge/license-MIT-blue)
![Language](https://img.shields.io/badge/language-Objective--C-orange)
![CocoaPods](https://img.shields.io/badge/CocoaPods-%E5%85%BC%E5%AE%B9-4BC51D)
![Swift Package Manager](https://img.shields.io/badge/SPM-%E5%85%BC%E5%AE%B9-orange)

iOS 平台上的 HTML5 Server-Sent Events (SSE) 客户端，使用 Objective-C 实现。灵感来自 [EventSource](https://github.com/neilco/EventSource)。

## 特性

- 完整遵循 HTML5 SSE 协议（解析 `id`、`event`、`data`、`retry` 字段）
- 基于 `addListener:forEvent:queue:` 的事件监听模式
- 断线自动重连，支持指数退避策略
- 可配置最大重试次数
- 线程安全的监听器管理（并发 GCD 队列 + barrier 写入）
- Content-Type 校验（拒绝非 `text/event-stream` 响应）
- 重连时自动携带 `Last-Event-ID` 请求头
- 可指定回调队列（默认为主队列）
- 零外部依赖
- 支持 CocoaPods 集成
- 支持 Swift Package Manager (SPM) 集成

## 环境要求

- iOS 10.0+
- ARC 已启用
- Objective-C

## 安装

### CocoaPods

在 Podfile 中添加：

```ruby
pod 'WJXEventSource'
```

然后执行：

```bash
pod install
```

### Swift Package Manager

在 `Package.swift` 中添加依赖：

```swift
dependencies: [
    .package(url: "https://github.com/wjiuxing/WJXEventSource.git", from: "0.0.1")
]
```

或在 Xcode 中添加：**File → Add Package Dependencies** → 粘贴仓库地址。

## 使用

### 快速开始

```objc
#import <WJXEventSource/WJXEventSource.h>

NSURL *URL = [NSURL URLWithString:@"http://example.com/sse"];
NSURLRequest *request = [NSURLRequest requestWithURL:URL
                                         cachePolicy:NSURLRequestReloadIgnoringCacheData
                                     timeoutInterval:60];

WJXEventSource *source = [[WJXEventSource alloc] initWithRequest:request];

[source addListener:^(WJXEvent *event) {
    NSLog(@"message: %@", event.data);
} forEvent:WJXEventNameMessage queue:[NSOperationQueue mainQueue]];

[source addListener:^(WJXEvent *event) {
    NSLog(@"connected");
} forEvent:WJXEventNameOpen queue:nil];

[source addListener:^(WJXEvent *event) {
    NSLog(@"error: %@", event.error);
} forEvent:WJXEventNameError queue:nil];

[source open];
```

使用完毕后记得调用 `close`：

```objc
[source close];
```

### 内置事件名

| 常量 | 值 | 说明 |
|---|---|---|
| `WJXEventNameMessage` | `@"message"` | SSE 消息事件 |
| `WJXEventNameOpen` | `@"open"` | 连接已建立 |
| `WJXEventNameReadyState` | `@"readyState"` | 连接状态变化 |
| `WJXEventNameError` | `@"error"` | 发生错误 |

### 重连行为

WJXEventSource 在连接断开时会自动重连，并使用指数退避策略：

- **基础重试间隔**：3.0 秒（默认值）
- **服务端覆盖**：服务端可通过 `retry:` 字段（单位：毫秒）修改重试间隔
- **延迟计算公式**：`retryInterval × 2^min(retryCount, 6)` — 最大倍数限制为 64 倍
- **重置**：每次成功连接后 `retryCount` 重置为 0
- **禁用**：设置 `ignoreRetryAction = YES` 可禁用自动重连
- **次数限制**：设置 `maxRetryCount` 可限制最大重试次数（默认：无限制）

```objc
source.ignoreRetryAction = NO;     // 默认值 — 自动重连已启用
source.maxRetryCount = 10;          // 最多重试 10 次
```

## API 参考

### WJXEventSource

| 方法 / 属性 | 说明 |
|---|---|
| `initWithRequest:` | 使用 `NSURLRequest` 初始化 |
| `addListener:forEvent:queue:` | 注册事件处理回调。`queue` 参数指定回调执行的 `NSOperationQueue`，传 `nil` 时默认为主队列。 |
| `open` | 打开 SSE 连接 |
| `close` | 关闭连接。调用后不会再自动重连。 |
| `ignoreRetryAction` | `BOOL` — 设为 `YES` 禁用自动重连（默认 `NO`） |
| `maxRetryCount` | `NSUInteger` — 最大重试次数（默认 `NSUIntegerMax`，即无限制） |

### WJXEvent

| 属性 | 类型 | 说明 |
|---|---|---|
| `eventId` | `id`（可空） | SSE 事件 ID |
| `event` | `NSString *`（可空） | 事件类型名称 |
| `data` | `NSString *`（可空） | 事件数据。多行 `data:` 字段按 SSE 规范以 `\n` 拼接。 |
| `readyState` | `WJXEventState` | 当前连接状态 |
| `error` | `NSError *`（可空） | 错误信息 |

### WJXEventState

| 值 | 说明 |
|---|---|
| `WJXEventStateConnecting` (0) | 正在连接 |
| `WJXEventStateOpen` (1) | 连接已建立 |
| `WJXEventStateClosed` (2) | 连接已关闭 |

## 许可证

WJXEventSource 基于 MIT 许可证发布。详情请查看 [LICENSE](LICENSE) 文件。

## 致谢

灵感来自 Neil Cowburn 的 [EventSource](https://github.com/neilco/EventSource) 项目。
