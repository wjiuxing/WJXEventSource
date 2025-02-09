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
    [_source addListener:^(WJXEvent * _Nonnull event) {
        NSLog(@"sse message: %@", event);
    } forEvent:WJXEventNameMessage queue:NSOperationQueue.mainQueue];
    
    [_source addListener:^(WJXEvent * _Nonnull event) {
        NSLog(@"sse open: %@", event);
    } forEvent:WJXEventNameOpen queue:nil];
    
    [_source addListener:^(WJXEvent * _Nonnull event) {
        NSLog(@"sse readyState: %@", event);
    } forEvent:WJXEventNameReadyState queue:nil];
    
    [_source addListener:^(WJXEvent * _Nonnull event) {
        NSLog(@"sse error: %@", event.error);
    } forEvent:WJXEventNameError queue:nil];
    
    [_source open];
}

- (void)dealloc
{
    [_source close];
}

@end
