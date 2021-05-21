//
//  MRDecoder.h
//  MRVTPKit
//
//  Created by Matt Reach on 2020/6/2.
//
// 自定义解码器类
// 通过代理衔接输入输出

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef enum : NSUInteger {
    MRDecoderVideoRotateNone = 0,
    MRDecoderVideoRotate90 = 90,
    MRDecoderVideoRotate180 = 180,
    MRDecoderVideoRotate270 = 270,
} MRDecoderVideoRotate;

typedef struct AVStream AVStream;
typedef struct AVFormatContext AVFormatContext;
typedef struct AVPacket AVPacket;
typedef struct AVFrame AVFrame;

@class MRDecoder;
@protocol MRDecoderDelegate <NSObject>

@required
///解码器向 delegater 要一个 AVPacket
- (int)decoder:(MRDecoder *)decoder wantAPacket:(AVPacket *)packet;
///将解码后的 AVFrame 给 delegater
- (void)decoder:(MRDecoder *)decoder reveivedAFrame:(AVFrame *)frame;
///是否还有更多的包需要解码
- (BOOL)decoderHasMorePacket:(MRDecoder *)decoder;
///解码结束
- (void)decoderEOF:(MRDecoder *)decoder;

@end

@interface MRDecoder : NSObject

@property (assign) AVFormatContext *ic;
@property (assign) int streamIdx;
@property (copy) NSString * name;
@property (weak) id <MRDecoderDelegate> delegate;
@property (assign, readonly) AVStream * stream;
//for video
@property (assign) enum AVPixelFormat pix_fmt;
@property (assign, readonly) int picWidth;
@property (assign, readonly) int picHeight;
@property (copy, readonly) NSString * codecName;
@property (assign) MRDecoderVideoRotate rotate;

- (void)dumpStreamFormat;
/**
 打开解码器，创建解码线程;
 return 0;（没有错误）
 */
- (BOOL)open;
//开始解码
- (void)start;
//取消解码
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
