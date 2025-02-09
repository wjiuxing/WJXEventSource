//
//  ViewController.m
//  WJXEventSource
//
//  Created by JiuxingWang on 2025/2/9.
//

#import "ViewController.h"
#import "WJXEventSource.h"

@interface ViewController ()

@property (nonatomic, strong) WJXEventSource *source;

@end

@implementation ViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    NSURL *URL = [NSURL URLWithString:@"http://127.0.0.1:8000/"];
    NSURLRequest *request = [NSURLRequest requestWithURL:URL cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:60];
    
    self.source = [[WJXEventSource alloc] initWithRquest:request];
    [_source addListener:WJXEventNameMessage handler:^(WJXEvent * _Nonnull event) {
        NSLog(@"sse message: %@", event);
    } queue:nil];
    
    [_source addListener:WJXEventNameOpen handler:^(WJXEvent * _Nonnull event) {
        NSLog(@"sse open: %@", event);
    } queue:NSOperationQueue.mainQueue];
    
    [_source addListener:WJXEventNameReadyState handler:^(WJXEvent * _Nonnull event) {
        NSLog(@"sse readyState: %@", event);
    } queue:nil];

    [_source addListener:WJXEventNameError handler:^(WJXEvent * _Nonnull event) {
        NSLog(@"sse error: %@", event.error);
    } queue:nil];
    
    [_source open];
}

- (void)dealloc
{
    [_source close];
}

@end
