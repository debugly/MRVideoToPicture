//
//  MRVideoCoverExtracter.h
//  MRVTPKit
//
//  Created by qianlongxu on 2021/4/25.
//

/*
 抽取视频封面图，图片将等比缩放
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MRVideoCoverExtracter : NSObject

- (instancetype _Nullable)initWithPath:(NSString *)path;
+ (instancetype _Nullable)videoCoverExtracterWithPath:(NSString *)path;

@property (readonly, copy) NSString *videoPath;
///最大尺寸，默认 320
@property (assign) int maxPicDimension;
@property (copy) NSString *videoCoverPath;

- (void)startProber:(void(^)(NSError * _Nullable,NSString * _Nullable))completion;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
