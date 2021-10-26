//
//  MRThread.h
//  MRVTPKit
//
//  Created by Matt Reach on 2020/6/2.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MRThread : NSObject

///在任务开始前指定线程的名字
@property (atomic, copy) NSString * _Nullable name;
//可传递一个信息
@property (atomic, strong) id info;

- (instancetype)initWithTarget:(id)target selector:(SEL)selector object:(nullable id)argument;
- (instancetype)initWithBlock:(void(^)(void))block;
- (void)start;
/**
 告知内部线程，外部期望取消
 */
- (void)cancel;
- (BOOL)isCanceled;
/**
 告知调用者工作已经完毕了，id值为当前对象的 info
 */
- (void)onFinish:(void(^)(id))block;
- (BOOL)isFinished;

@end

NS_ASSUME_NONNULL_END
