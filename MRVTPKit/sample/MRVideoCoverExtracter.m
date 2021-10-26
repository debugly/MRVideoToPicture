//
//  MRVideoCoverExtracter.m
//  MRVTPKit
//
//  Created by qianlongxu on 2020/6/2.
//

#import "MRVideoCoverExtracter.h"
#import "MRVideoToPicture.h"

@interface MRVideoCoverExtracter ()

@property (strong) MRVideoToPicture *vtp;
@property (readwrite, copy) NSString *videoPath;

@end

@implementation MRVideoCoverExtracter

- (void)dealloc
{
    if (self.vtp)
    {
        self.vtp.delegate = nil;
        [self.vtp cancel];
        self.vtp = nil;
    }
}

+ (instancetype)videoCoverExtracterWithPath:(NSString *)path
{
    return [[self alloc] initWithPath:path];
}

- (instancetype)initWithPath:(NSString *)path
{
    if (path.length == 0) {
        return nil;
    }
    self = [super init];
    if (self) {
        self.videoPath = path;
        self.maxPicDimension = 320;
    }
    return self;
}

- (void)startProber:(void(^)(NSError *,NSString *))completion
{
    if (!self.vtp) {
        MRVideoToPicture *vtp = [[MRVideoToPicture alloc] init];
        if (self.videoPath) {
            vtp.contentPath = self.videoPath;
        }
        
        __weak typeof(self)weakSelf = self;
        [vtp setOnConvertAnImageBlock:^(MRVideoToPicture * _Nonnull vtp, NSString * _Nonnull imgPath, int pts) {
            __strong typeof(weakSelf)self = weakSelf;
            
            if (self.vtp == vtp)
            {
                if (self.videoCoverPath) {
                    [[NSFileManager defaultManager] removeItemAtPath:self.videoCoverPath error:nil];
                }
                self.videoCoverPath = imgPath;
            }
        }];
        
        [vtp setOnConvertFinishedBlock:^(MRVideoToPicture * _Nonnull vtp, NSError * _Nullable err) {
            __strong typeof(weakSelf)self = weakSelf;
            if (self.vtp == vtp)
            {
                [self.vtp cancel];
                self.vtp = nil;
                
                if (completion) {
                    completion(err, self.videoCoverPath);
                }
            }
        }];
        
        vtp.perferMaxCount = 2;
        vtp.supportedPixelFormats = MR_PIX_FMT_MASK_0RGB;
        vtp.maxPicDimension = self.maxPicDimension;
        vtp.perferInterval = 1;
        [vtp prepareToPlay];
        [vtp startConvert];
        self.vtp = vtp;
    }
}

- (void)stop
{
    if (self.vtp)
    {
        [self.vtp cancel];
        self.vtp = nil;
    }
}

@end
