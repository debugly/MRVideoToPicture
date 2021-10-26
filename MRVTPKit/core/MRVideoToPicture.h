//
//  MRVideoToPicture.h
//  MRVTPKit
//
//  Created by qianlongxu on 2020/6/2.
//

/*
 关键帧的位置大多是不固定的，除非是 mpeg-dash 的视频；
 因此根据设定的 frameInterval 去快进视频流，查找下一个关键帧时，可能出现回退，程序需要处理这个问题；
 因此不同的视频，导出图片的速度是不一样的！
 */

#import <Foundation/Foundation.h>
#import "FFPlayerHeader.h"
#import <CoreGraphics/CGImage.h>

NS_ASSUME_NONNULL_BEGIN

//videoOpened info's key
typedef NSString * const kMRMovieInfoKey;
//视频时长；单位s
FOUNDATION_EXPORT kMRMovieInfoKey kMRMovieDuration;
//视频封装格式；可能有多个，使用 ”,“ 分割
FOUNDATION_EXPORT kMRMovieInfoKey kMRMovieContainerFmt;
//视频宽；单位像素
FOUNDATION_EXPORT kMRMovieInfoKey kMRMovieWidth;
//视频高；单位像素
FOUNDATION_EXPORT kMRMovieInfoKey kMRMovieHeight;
//视频编码格式
FOUNDATION_EXPORT kMRMovieInfoKey kMRMovieVideoFmt;
//音频编码格式
FOUNDATION_EXPORT kMRMovieInfoKey kMRMovieAudioFmt;
//视频旋转角度
FOUNDATION_EXPORT kMRMovieInfoKey kMRMovieRotate;

typedef enum : NSUInteger {
    MRVTPImageJPG,
    MRVTPImagePNG,
    MRVTPImageBMP,
    MRVTPImageTIFF,
    MRVTPImagePDF,
    MRVTPImageGIF
//    MRVTPImageICO,
//    MRVTPImageICNS,
//    MRVTPImageRAW,
//    MRVTPImageSVG
} MRVTPImageType;

@class MRVideoToPicture;

typedef void (^MROnVideoOpenedBlock)(MRVideoToPicture*, NSDictionary <kMRMovieInfoKey,id> *);
typedef void (^MROnConvertAnImageBlock)(MRVideoToPicture*, NSString *, int);
typedef void (^MROnConvertFinishedBlock)(MRVideoToPicture*, NSError * _Nullable);

@protocol MRVideoToPictureDelegate <NSObject>

//代理方法均在主线程里回调
@optional
- (void)vtp:(MRVideoToPicture*)vtp videoOpened:(NSDictionary <kMRMovieInfoKey,id> *)info;
//pst is picture position(unit:s),when pst is -1 means the video hasn't pts!
- (void)vtp:(MRVideoToPicture*)vtp convertAnImage:(NSString *)imgPath pst:(int)pst;
- (void)vtp:(MRVideoToPicture*)vtp convertFinished:(NSError *)err;

@end

@interface MRVideoToPicture : NSObject

///播放地址
@property (copy) NSString *contentPath;
///期望的像素格式
@property (assign) MRPixelFormatMask supportedPixelFormats;
///保存图片格式
@property (assign) MRVTPImageType imageType;
///通过代理接收回调
@property (weak) id<MRVideoToPictureDelegate> delegate;
///通过block接收回调
@property (copy, nullable) MROnVideoOpenedBlock onVideoOpenedBlock;
@property (copy, nullable) MROnConvertAnImageBlock onConvertAnImageBlock;
@property (copy, nullable) MROnConvertFinishedBlock onConvertFinishedBlock;
@property (readonly) NSDictionary <kMRMovieInfoKey,id> * movieInfo;

///期望帧间隔时长
@property (assign) int perferInterval;
///期望总张数，当获取不到pts时，会超出期望值
@property (assign) int perferMaxCount;
@property (assign, readonly) int frameCount;
@property (copy) NSString *picSaveDir;
///期望使用seek代替逐帧读取
@property (assign) BOOL perferUseSeek;
///图片最大尺寸
@property (assign) int maxPicDimension;
///准备抽帧
- (void)prepareToPlay;
///开始抽帧
- (void)startConvert;
///取消抽帧
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
