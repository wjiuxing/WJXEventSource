//
//  WJXEventSource.h
//  WJXEventSource
//
//  Created by JiuxingWang on 2025/2/9.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
#define WJX_EXTERN        extern "C" __attribute__((visibility ("default")))
#else
#define WJX_EXTERN        extern __attribute__((visibility ("default")))
#endif

/// 消息事件
typedef NSString *WJXEventName NS_TYPED_EXTENSIBLE_ENUM;

/// 消息事件
WJX_EXTERN WJXEventName const WJXEventNameMessage;

/// readyState 变化事件
WJX_EXTERN WJXEventName const WJXEventNameReadyState;

/// open 事件
WJX_EXTERN WJXEventName const WJXEventNameOpen;

/// error 事件
WJX_EXTERN WJXEventName const WJXEventNameError;

typedef NS_ENUM(NSUInteger, WJXEventState) {
    WJXEventStateConnecting = 0,
    WJXEventStateOpen,
    WJXEventStateClosed,
};

@interface WJXEvent : NSObject

@property (nonatomic, copy, nullable) NSString *eventId;
@property (nonatomic, copy, nullable) NSString *event;
@property (nonatomic, copy, nullable) NSString *data;

@property (nonatomic, assign) WJXEventState readyState;
@property (nonatomic, strong, nullable) NSError *error;

/// YES 表示服务端无错误正常断开,此时 error 仅为兼容旧回调形状的合成对象
@property (nonatomic, assign, readonly) BOOL cleanClose;

- (instancetype)initWithReadyState:(WJXEventState)readyState;

@end

typedef void(^WJXEventSourceEventHandler)(WJXEvent *event);

/// HTML5 Server-Sent Events 客户端。
/// 注意:用完必须调用 close 释放连接;否则 session 会强持有实例直至任务结束。
@interface WJXEventSource : NSObject

@property (nonatomic, assign) BOOL ignoreRetryAction;

/// 最大重连次数，默认为 NSUIntegerMax（无限制）
@property (nonatomic, assign) NSUInteger maxRetryCount;

- (instancetype)initWithRequest:(NSURLRequest *)request;

- (void)addListener:(WJXEventSourceEventHandler)listener
           forEvent:(WJXEventName)eventName
              queue:(nullable NSOperationQueue *)queue;

/// 移除监听。按传入 block 的指针匹配移除;同一 block 注册多次会全部移除。
- (void)removeListener:(WJXEventSourceEventHandler)listener
              forEvent:(WJXEventName)eventName;

- (void)open;
- (void)close;

@end

NS_ASSUME_NONNULL_END
