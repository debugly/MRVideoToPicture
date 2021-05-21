//
//  MRThread.m
//  MRVTPKit
//
//  Created by Matt Reach on 2020/6/2.
//

#import "MRThread.h"

@interface MRThread ()

@property (weak) id threadTarget;
@property (strong) NSThread *thread;
@property (assign) SEL threadSelector;//实际调度任务
@property (strong) id threadArgs;
@property (copy) void(^workBlock)(void);

@end

@implementation MRThread

- (void)dealloc
{
    //NSLog(@"MR %@ thread dealloc",self.name);
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        self.thread = [[NSThread alloc] initWithTarget:self selector:@selector(workFunc) object:nil];
    }
    return self;
}

- (instancetype)initWithTarget:(id)target selector:(SEL)selector object:(nullable id)argument
{
    self = [self init];
    if (self) {
        self.threadTarget = target;
        self.threadSelector = selector;
        self.threadArgs = argument;
    }
    return self;
}

- (instancetype)initWithBlock:(void (^)(void))block
{
    self = [self init];
    if (self) {
        self.workBlock = block;
    }
    return self;
}

- (void)workFunc
{
    //取消了就直接返回，不再处理
    if ([self isCanceled]) {
        return;
    }
    
    // iOS 子线程需要显式创建 autoreleasepool 以释放 autorelease 对象
    @autoreleasepool {
        
        [[NSThread currentThread] setName:self.name];
        
        //嵌套的这个自动释放池也是必要的！！防止在 threadSelector 里完成任务后，将线程释放，但是却进入了死等的Runloop逻辑中，由于外层的 @autoreleasepool 不能回收相关内存，最终导致整个线程得不到释放。[可以将FFPlayer0x02 _stop 方法中的join注释掉观察]
        @autoreleasepool {
            if ([self.threadTarget respondsToSelector:self.threadSelector]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [self.threadTarget performSelector:self.threadSelector withObject:self.threadArgs];
                #pragma clang diagnostic pop
            }
            
            if (self.workBlock) {
                self.workBlock();
            }
        }
    }
}

- (void)start
{
    [self.thread start];
}

- (void)cancel
{
    if (![self.thread isCancelled]) {
        [self.thread cancel];
    }
}

- (BOOL)isCanceled
{
    return [self.thread isCancelled];
}

- (BOOL)isFinished
{
    return [self.thread isFinished];
}

@end
