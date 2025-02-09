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

@property (nonatomic, strong, nullable) id eventId;

@property (nonatomic, copy, nullable) NSString *event;
@property (nonatomic, copy, nullable) NSString *data;

@property (nonatomic, assign) WJXEventState readyState;
@property (nonatomic, strong, nullable) NSError *error;

- (instancetype)initWithReadyState:(WJXEventState)readyState;

@end

typedef void(^WJXEventSourceEventHandler)(WJXEvent *event);

@interface WJXEventSource : NSObject

@property (nonatomic, assign) BOOL ignoreRetryAction;

- (instancetype)initWithRquest:(NSURLRequest *)request;

- (void)addListener:(WJXEventSourceEventHandler)listener
           forEvent:(WJXEventName)eventName
              queue:(nullable NSOperationQueue *)queue;

- (void)open;
- (void)close;

@end

NS_ASSUME_NONNULL_END
