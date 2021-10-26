//
//  MRVideoToPicture.m
//  MRVTPKit
//
//  Created by qianlongxu on 2020/6/2.
//

#import "MRVideoToPicture.h"
#import "MRThread.h"
#import "FFPlayerInternalHeader.h"
#import "FFPlayerPacketHeader.h"
#import "FFPlayerFrameHeader.h"
#import "MRDecoder.h"
#import "MRVideoScale.h"
#import "MRConvertUtil.h"
#import <ImageIO/ImageIO.h>

#if TARGET_OS_IOS
#import <MobileCoreServices/MobileCoreServices.h>
#endif

#define USE_WRITE_THREAD 1
#define USE_READ_THREAD  1

//视频时长；单位s
kMRMovieInfoKey kMRMovieDuration = @"kMRMovieDuration";
//视频格式
kMRMovieInfoKey kMRMovieContainerFmt = @"kMRMovieContainerFmt";
//视频宽；单位像素
kMRMovieInfoKey kMRMovieWidth = @"kMRMovieWidth";
//视频高；单位像素
kMRMovieInfoKey kMRMovieHeight = @"kMRMovieHeight";
//视频编码格式
kMRMovieInfoKey kMRMovieVideoFmt = @"kMRMovieVideoFmt";
//音频编码格式
kMRMovieInfoKey kMRMovieAudioFmt = @"kMRMovieAudioFmt";
//视频旋转角度
kMRMovieInfoKey kMRMovieRotate = @"kMRMovieRotate";

NS_INLINE
void dispatch_sync_to_main_queue(dispatch_block_t block)
{
    if (!block) {
        return;
    }
    if (0 == strcmp(dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL), dispatch_queue_get_label(dispatch_get_main_queue()))) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

@interface MRVideoToPicture ()<MRDecoderDelegate>
{
    //解码前的视频包缓存队列
    PacketQueue videoq;
#if USE_WRITE_THREAD
    //解码后的视频包缓存队列
    FrameQueue videof;
#endif
    int64_t lastPkts;
    int lastSeekPos;
    int lastFramePts;//单位s
}

@property (readwrite) NSDictionary <kMRMovieInfoKey,id> * movieInfo;
//读包线程
@property (strong) MRThread *workThread;
#if USE_WRITE_THREAD
//写入磁盘线程
@property (strong) MRThread *ioThread;
#endif

#if USE_READ_THREAD
//读包线程
@property (strong) MRThread *readThread;
#endif
//视频解码器
@property (strong) MRDecoder *videoDecoder;
//图像格式转换/缩放器
@property (strong) MRVideoScale *videoScale;
//读包完毕？
@property (atomic, assign) BOOL readEOF;
@property (assign) int frameCount;
@property (assign) int pktCount;
@property (assign) int duration;
//1:Cancel,2:Stop
@property (atomic, assign) int abort;
@property (atomic, assign) int deInited;
@property (atomic, strong) NSError *lastError;

@end

@implementation  MRVideoToPicture

static int decode_interrupt_cb(void *ctx)
{
    MRVideoToPicture *player = (__bridge MRVideoToPicture *)ctx;
    return player.abort > 0;
}

- (void)_stop:(BOOL)isCancel
{
    self.abort = isCancel ? 1 : 2;
    //仅仅标记为取消
    [self.videoDecoder cancel];
    videoq.abort_request = 1;
#if USE_WRITE_THREAD
    videof.abort_request = 1;
#endif
    if (self.workThread) {
        [self.workThread cancel];
    }
#if USE_WRITE_THREAD
    if (self.ioThread) {
        [self.ioThread cancel];
    }
#endif
#if USE_READ_THREAD
    if (self.readThread) {
        [self.readThread cancel];
    }
#endif
}

- (void)dealloc
{
    self.videoDecoder = nil;
    self.workThread = nil;
#if USE_READ_THREAD
    self.readThread = nil;
#endif
    
#if USE_WRITE_THREAD
    self.ioThread = nil;
    frame_queue_destory(&self->videof);
#endif
    packet_queue_destroy(&self->videoq);
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        self.perferMaxCount = INT_MAX;
        self.maxPicDimension = INT_MAX;
        self.picSaveDir = NSTemporaryDirectory();
    }
    return self;
}

//准备
- (void)prepareToPlay
{
    if (self.workThread) {
        NSAssert(NO, @"不允许重复创建");
    }
    
    lastPkts = -1;
    lastSeekPos = -1;
    lastFramePts = -1;
    
    //初始化视频包队列
    packet_queue_init(&videoq);
#if USE_WRITE_THREAD
    frame_queue_init(&videof, 10, "pictq", 0);
#endif
    //初始化ffmpeg相关函数
    init_ffmpeg_once();

    self.workThread = [[MRThread alloc] initWithTarget:self selector:@selector(workFunc) object:nil];
    self.workThread.name = @"readPackets";
    __weak typeof(self)weakSelf = self;
    [self.workThread onFinish:^(id info) {
        __strong typeof(weakSelf)self = weakSelf;
        [self tryJoin:info];
    }];
}

#pragma mark - 打开解码器创建解码线程

- (MRDecoder *)dumpStreamComponent:(AVFormatContext *)ic streamIdx:(int)idx
{
    MRDecoder *decoder = [MRDecoder new];
    decoder.ic = ic;
    decoder.streamIdx = idx;
    [decoder dumpStreamFormat];
    return decoder;
}

#pragma -mark 读包逻辑

- (int)seekTo:(AVFormatContext *)formatCtx sec:(int)sec
{
    if (sec < self.duration) {
        int64_t seek_pos = sec * AV_TIME_BASE;
        int64_t seek_target = seek_pos;
        int64_t seek_min    = INT64_MIN;
        int64_t seek_max    = INT64_MAX;
        av_log(NULL, AV_LOG_INFO,
               "seek to %d\n",sec);
        
        int ret = avformat_seek_file(formatCtx, -1, seek_min, seek_target, seek_max, AVSEEK_FLAG_ANY);
        if (ret < 0) {
            av_log(NULL, AV_LOG_ERROR,
                   "error while seek to %d\n",sec);
            return 1;
        } else {
            return 0;
        }
    } else {
        av_log(NULL, AV_LOG_ERROR,
               "ignore error seek to %d/%d\n",sec,self.duration);
        return -1;
    }
}

//循环读包，读满了就停止
- (void)readPacketLoop:(AVFormatContext *)formatCtx
{
    AVPacket pkt1, *pkt = &pkt1;
    
    //调用了stop方法，则不再读包
    while (self.abort <= 0) {
        
        //已经读完了
        if (self.readEOF) {
            break;
        }
#if USE_READ_THREAD
        //单独使用读包线程
        if (packet_queue_nb_remaining(&videoq) >= 10) {
            mr_msleep(3);
            continue;
        }
#else
        if (packet_queue_nb_remaining(&videoq) >= 1) {
            break;
        }
#endif
//        if (videoq.size > 1 * 1024 * 1024
//            || (stream_has_enough_packets(self.videoDecoder.stream, self.videoDecoder.streamIdx, &videoq))) {
//            break;
//        }
        
        //开始读
        int ret = av_read_frame(formatCtx, pkt);
        //读包出错
        if (ret < 0) {
            //读到最后结束了
            if ((ret == AVERROR_EOF || avio_feof(formatCtx->pb)) && !self.readEOF) {
                //最后放一个空包进去
                if (self.videoDecoder.streamIdx >= 0) {
                    packet_queue_put_nullpacket(&videoq, self.videoDecoder.streamIdx);
                }
                //标志为读包结束
                av_log(NULL, AV_LOG_INFO,"real read eof\n");
                self.readEOF = YES;
                break;
            }
            
            if (formatCtx->pb && formatCtx->pb->error) {
                break;
            }
            break;
        } else {
            //视频包入视频队列
            if (pkt->stream_index == self.videoDecoder.streamIdx) {
                
                //gif 不能按关键帧处理
                if (![self.videoDecoder.codecName isEqualToString:@"gif"]) {
                    // 忽略非关键帧
                    if (!(pkt->flags & AV_PKT_FLAG_KEY)) {
                        av_packet_unref(pkt);
                        continue;
                    }
                }
                
                //没有pts，则使用dts当做pts
                if (AV_NOPTS_VALUE == pkt->pts && AV_NOPTS_VALUE != pkt->dts) {
                    pkt->pts = pkt->dts;
                }
                
                //lastPkts记录上一个关键帧的时间戳，避免seek后出现回退，解码出一样的图片！
                if (AV_NOPTS_VALUE != pkt->pts) {

                    AVRational tb = self.videoDecoder.stream->time_base;
                    int64_t pts = lround(pkt->pts * av_q2d(tb));
                    
                    if (lastPkts < pts) {
                        lastPkts = pts;

                        packet_queue_put(&videoq, pkt);
                        self.pktCount ++;
                        if (!self.perferUseSeek) {
                            lastPkts += self.perferInterval;
                        }
                    } else {
                        av_packet_unref(pkt);
                    }
                } else {
                    packet_queue_put(&videoq, pkt);
                    self.pktCount ++;
                }
                
                //当帧间隔大于10s时，时长大于 1min 才采用seek方案
                if (self.perferUseSeek && self.perferInterval > 10 && self.duration > 60) {
                    int sec = self.perferInterval * self.pktCount;
                    //对于seek间隔很小的视频，seek后很可能回退，因此要想办法避免回退，避免ABAB循环导致的seek死循环
                    if (sec <= lastSeekPos) {
                        sec = lastSeekPos + self.perferInterval;
                    }
                    lastSeekPos = sec;
                    if (-1 == [self seekTo:formatCtx sec:sec]) {
                        //标志为读包结束
                        av_log(NULL, AV_LOG_INFO,"logic read eof\n");
                        self.readEOF = YES;
                    }
                }
            } else {
                //其他包释放内存忽略掉
                av_packet_unref(pkt);
            }
        }
    }
}

#pragma mark - 查找最优的音视频流
- (void)findBestStreams:(AVFormatContext *)formatCtx result:(int (*) [AVMEDIA_TYPE_NB])st_index
{
    int first_video_stream = -1;
    int first_h264_stream = -1;
    //查找H264格式的视频流
    for (int i = 0; i < formatCtx->nb_streams; i++) {
        AVStream *st = formatCtx->streams[i];
        enum AVMediaType type = st->codecpar->codec_type;
        //这里设置为了丢弃所有帧，解码器里会进行修改！
        st->discard = AVDISCARD_ALL;

        if (type == AVMEDIA_TYPE_VIDEO) {
            enum AVCodecID codec_id = st->codecpar->codec_id;
            if (codec_id == AV_CODEC_ID_H264) {
                if (first_h264_stream < 0) {
                    first_h264_stream = i;
                    break;
                }
                if (first_video_stream < 0) {
                    first_video_stream = i;
                }
            }
        }
    }
    //h264优先
    (*st_index)[AVMEDIA_TYPE_VIDEO] = first_h264_stream != -1 ? first_h264_stream : first_video_stream;
    //根据上一步确定的视频流查找最优的视频流
    (*st_index)[AVMEDIA_TYPE_VIDEO] = av_find_best_stream(formatCtx, AVMEDIA_TYPE_VIDEO, (*st_index)[AVMEDIA_TYPE_VIDEO], -1, NULL, 0);
    //参照视频流查找最优的音频流
    (*st_index)[AVMEDIA_TYPE_AUDIO] = av_find_best_stream(formatCtx, AVMEDIA_TYPE_AUDIO, (*st_index)[AVMEDIA_TYPE_AUDIO], (*st_index)[AVMEDIA_TYPE_VIDEO], NULL, 0);
}

#pragma mark - 视频像素格式转换

- (void)createVideoScaleIfNeed
{
    if (self.videoScale) {
        return;
    }
    //未指定期望像素格式
    if (self.supportedPixelFormats == MR_PIX_FMT_MASK_NONE) {
        NSAssert(NO, @"supportedPixelFormats can't be none!");
        return;
    }
    
    //当前视频的像素格式
    const enum AVPixelFormat format = self.videoDecoder.pix_fmt;
    
    //测试过程中有的视频没有获取到像素格式，单视频实际上有，等到解码出来后再次走下这个逻辑
    if (format == AV_PIX_FMT_NONE) {
        return;
    }
    
    bool matched = false;
    MRPixelFormat firstSupportedFmt = MR_PIX_FMT_NONE;
    for (int i = MR_PIX_FMT_BEGIN; i <= MR_PIX_FMT_END; i ++) {
        const MRPixelFormat fmt = i;
        const MRPixelFormatMask mask = 1 << fmt;
        if (self.supportedPixelFormats & mask) {
            if (firstSupportedFmt == MR_PIX_FMT_NONE) {
                firstSupportedFmt = fmt;
            }
            
            if (format == MRPixelFormat2AV(fmt)) {
                matched = true;
                break;
            }
        }
    }
    
    if (matched) {
        //期望像素格式包含了当前视频像素格式，则直接使用当前格式，不再转换。
        return;
    }
    
    if (firstSupportedFmt == MR_PIX_FMT_NONE) {
        NSAssert(NO, @"supportedPixelFormats is invalid!");
        return;
    }
    
    //拿到了视频宽高，再缩放；否则除数为0引发 SIGFPE 崩溃
    if (self.videoDecoder.picWidth > 0 && self.videoDecoder.picHeight > 0) {
        int dstWidth = 0;
        int dstHeight = 0;
        //宽屏视频
        if (self.videoDecoder.picWidth > self.videoDecoder.picHeight) {
            dstWidth = MIN(self.videoDecoder.picWidth, self.maxPicDimension);
            dstHeight = dstWidth * self.videoDecoder.picHeight / self.videoDecoder.picWidth;
        } else {
            //竖屏视频
            dstHeight = MIN(self.videoDecoder.picHeight, self.maxPicDimension);
            dstWidth = dstHeight * self.videoDecoder.picWidth / self.videoDecoder.picHeight;
        }
        
        //创建像素格式转换上下文
        self.videoScale = [[MRVideoScale alloc] initWithSrcPixFmt:format
                                                        dstPixFmt:MRPixelFormat2AV(firstSupportedFmt)
                                                         srcWidth:self.videoDecoder.picWidth
                                                        srcHeight:self.videoDecoder.picHeight
                                                         dstWidth:dstWidth
                                                        dstHeight:dstHeight];
    }
}

#if USE_READ_THREAD
- (void)readFunc
{
    [self readPacketLoop:self.videoDecoder.ic];
    [self tryJoin:nil];
}
#endif

#if USE_WRITE_THREAD
- (void)ioFunc
{
    while (![[NSThread currentThread] isCancelled]) {
        
        if (self.readEOF && packet_queue_nb_remaining(&videoq) == 0 && frame_queue_nb_remaining(&videof) == 0) {
            NSLog(@"frame is eof");
            break;
        }
        //队列里缓存帧大于0，则取出
        if (frame_queue_nb_remaining(&videof) > 0) {
            Frame *ap = frame_queue_peek(&videof);
            [self convertToPic:ap->frame];
            //释放该节点存储的frame的内存
            frame_queue_pop(&videof);
        }
    }
}
#endif

- (void)tryJoin:(NSError *)error
{
    if (error) {
        av_log(NULL, AV_LOG_ERROR, "%s\n",[[error localizedDescription] UTF8String]);
        self.lastError = error;
    }
    BOOL finished = [self.workThread isFinished];
    NSLog(@"[self.workThread isFinished]:%d,%p",finished,self);
    
    if (!finished) {
        return;
    }
    
#if USE_WRITE_THREAD
    BOOL ioFinished = [self.ioThread isFinished];
    NSLog(@"[self.ioThread isFinished]:%d,%p",ioFinished,self);
    
    if (!ioFinished) {
        return;
    }
#endif
    
#if USE_READ_THREAD
    BOOL readFinished = [self.readThread isFinished];
    NSLog(@"[self.readThread isFinished]:%d,%p",readFinished,self);
    
    if (!readFinished) {
        return;
    }
#endif
    
    //回到主线程销毁资源
    dispatch_sync_to_main_queue(^{
        //避免多个线程同时进来这里！
        if (self.deInited) {
            return;
        }
        self.deInited = YES;
        
        if (self.abort != 1) {
            if ([self.delegate respondsToSelector:@selector(vtp:convertFinished:)]) {
                [self.delegate vtp:self convertFinished:self.lastError];
            }
            
            if (self.onConvertFinishedBlock) {
                self.onConvertFinishedBlock(self, self.lastError);
            }
        }
    });
}

- (void)workFunc
{
    if (![self.contentPath hasPrefix:@"/"]) {
        _init_net_work_once();
    }
    
    AVFormatContext *formatCtx = avformat_alloc_context();
    
    if (!formatCtx) {
        self.workThread.info = _make_nserror_desc(FFPlayerErrorCode_AllocFmtCtxFailed, @"创建 AVFormatContext 失败！");
        return;
    }
    
    formatCtx->interrupt_callback.callback = decode_interrupt_cb;
    formatCtx->interrupt_callback.opaque = (__bridge void *)self;
    
    /*
     打开输入流，读取文件头信息，不会打开解码器；
     */
    //低版本是 av_open_input_file 方法
    const char *moviePath = [self.contentPath cStringUsingEncoding:NSUTF8StringEncoding];
    
    //打开文件流，读取头信息；
    if (0 != avformat_open_input(&formatCtx, moviePath , NULL, NULL)) {
        //释放内存
        avformat_free_context(formatCtx);
        //当取消掉时，不给上层回调
        if (self.abort == 1) {
            return;
        }
        self.workThread.info = _make_nserror_desc(FFPlayerErrorCode_OpenFileFailed, @"文件打开失败！");
        return;
    }
    
    /* 刚才只是打开了文件，检测了下文件头而已，并不知道流信息；因此开始读包以获取流信息
     设置读包探测大小和最大时长，避免读太多的包！
    */
    formatCtx->probesize = 1024 * 1024;
    formatCtx->max_analyze_duration = 10 * AV_TIME_BASE;
#if DEBUG
    NSTimeInterval begin = [[NSDate date] timeIntervalSinceReferenceDate];
#endif
    if (0 != avformat_find_stream_info(formatCtx, NULL)) {
        //出错了，销毁下相关结构体
        avformat_close_input(&formatCtx);
        self.workThread.info = _make_nserror_desc(FFPlayerErrorCode_StreamNotFound, @"不能找到流！");
        return;
    }
    
#if DEBUG
    NSTimeInterval end = [[NSDate date] timeIntervalSinceReferenceDate];
    //用于查看详细信息，调试的时候打出来看下很有必要
    av_dump_format(formatCtx, 0, moviePath, false);
    NSLog(@"avformat_find_stream_info coast time:%g",end-begin);
#endif

    //确定最优的音视频流
    int st_index[AVMEDIA_TYPE_NB];
    memset(st_index, -1, sizeof(st_index));
    [self findBestStreams:formatCtx result:&st_index];
    
    NSMutableDictionary *dumpDic = [NSMutableDictionary dictionary];
    const char *name = formatCtx->iformat->name;
    if (NULL != name) {
        NSString *format = [NSString stringWithCString:name encoding:NSUTF8StringEncoding];
        if (format) {
            [dumpDic setObject:format forKey:kMRMovieContainerFmt];
        }
    }
    if (formatCtx->duration > 0) {
        self.duration = (int)(formatCtx->duration / 1000000);
    }
    [dumpDic setObject:@(self.duration) forKey:kMRMovieDuration];
    
    //创建解码器
    if (st_index[AVMEDIA_TYPE_VIDEO] >= 0) {
        MRDecoder *videoDecoder = [self dumpStreamComponent:formatCtx streamIdx:st_index[AVMEDIA_TYPE_VIDEO]];
        
        [dumpDic setObject:@(videoDecoder.picWidth) forKey:kMRMovieWidth];
        [dumpDic setObject:@(videoDecoder.picHeight) forKey:kMRMovieHeight];
        
        if (videoDecoder.codecName) {
            [dumpDic setObject:videoDecoder.codecName forKey:kMRMovieVideoFmt];
        }
        
        if ([videoDecoder open]) {
            self.videoDecoder = videoDecoder;
            self.videoDecoder.delegate = self;
            self.videoDecoder.name = @"videoDecoder";
            [self createVideoScaleIfNeed];
            
            [dumpDic setObject:@(videoDecoder.rotate) forKey:kMRMovieRotate];
        }
    }
    
    //创建解码器
    if (st_index[AVMEDIA_TYPE_AUDIO] >= 0) {
        MRDecoder *audioDecoder = [self dumpStreamComponent:formatCtx streamIdx:st_index[AVMEDIA_TYPE_AUDIO]];
        
        if (audioDecoder.codecName) {
            [dumpDic setObject:audioDecoder.codecName forKey:kMRMovieAudioFmt];
        }
        
        //目前抽帧没必要打开音频流解码器
//        if ([audioDecoder open]) {
//            self.audioDecoder = audioDecoder;
//            self.audioDecoder.delegate = self;
//            self.audioDecoder.name = @"audioDecoder";
//        } else {
//            av_log(NULL, AV_LOG_ERROR, "can't open audio stream.");
//        }
    }
    
    self.movieInfo = [dumpDic copy];
    //这里采用同步目的是为了，让代理能够修改 vtp 的属性，比如根据视频时长修改perferInterval等
    dispatch_sync_to_main_queue(^{
        if (self.delegate && [self.delegate respondsToSelector:@selector(vtp:videoOpened:)]) {
            [self.delegate vtp:self videoOpened:dumpDic];
        }
        if (self.onVideoOpenedBlock) {
            self.onVideoOpenedBlock(self, dumpDic);
        }
    });
        
    if (self.videoDecoder) {
    #if USE_WRITE_THREAD
        //创建IO线程，将 frame buffer 里的 frame 转成图片
        self.ioThread = [[MRThread alloc] initWithTarget:self selector:@selector(ioFunc) object:nil];
        self.ioThread.name = @"saveImg";
        __weak typeof(self)weakSelf = self;
        [self.ioThread onFinish:^(id info) {
            __strong typeof(weakSelf)self = weakSelf;
            [self tryJoin:info];
        }];
        [self.ioThread start];
    #endif
        
    #if USE_READ_THREAD
        //创建 Read 线程
        self.readThread = [[MRThread alloc] initWithTarget:self selector:@selector(readFunc) object:nil];
        self.readThread.name = @"readFrame";
        __weak typeof(self)_weakSelf = self;
        [self.readThread onFinish:^(id info) {
            __strong typeof(_weakSelf)self = _weakSelf;
            [self tryJoin:info];
        }];
        [self.readThread start];
    #endif
            
        //开始视频解码，读包完全由解码器控制，解码后放到 frame buffer 里
        [self.videoDecoder start];
        //解码结束
    } else {
        //出错了
        //有的视频只有一个头，没有包也不能打开解码器；有的是编码格式不支持
        NSString *videoFmt = dumpDic[kMRMovieVideoFmt];
        NSString *msg = [NSString stringWithFormat:@"can't open [%@] video stream",videoFmt];
        self.workThread.info = _make_nserror_desc(FFPlayerErrorCode_StreamOpenFailed, msg);
    }
    
    //销毁下相关结构体
    avformat_close_input(&formatCtx);
}

#pragma mark - MRDecoderDelegate

- (int)decoder:(MRDecoder *)decoder wantAPacket:(AVPacket *)pkt
{
    if (decoder == self.videoDecoder) {
        int ret = 0;
        do {
            if (self.abort > 0) {
                break;
            }
            
#if USE_READ_THREAD
            //持续等frame
            ret = packet_queue_get(&videoq, pkt, 1);
            break;
#else
            ret = packet_queue_get(&videoq, pkt, 0);
            if (ret == 0 && !self.readEOF) {
                //不能从队列里获取pkt，就去读取
                [self readPacketLoop:decoder.ic];
            } else {
                break;
            }
#endif
        } while (1);
        return ret;
    } else {
        return -1;
    }
}

- (void)decoder:(MRDecoder *)decoder reveivedAFrame:(AVFrame *)frame
{
    if (decoder == self.videoDecoder) {
        AVFrame *outP = nil;
        
        const enum AVPixelFormat format = self.videoDecoder.pix_fmt;
        
        //测试过程中有的视频没有获取到像素格式，单视频实际上有，等到解码出来后再次走下这个逻辑
        if (format == AV_PIX_FMT_NONE && frame->format != AV_PIX_FMT_NONE) {
            self.videoDecoder.pix_fmt = frame->format;
            [self createVideoScaleIfNeed];
        }
        
        if (self.videoScale) {
            if (![self.videoScale rescaleFrame:frame outFrame:&outP]) {
                NSError* error = _make_nserror_desc(FFPlayerErrorCode_RescaleFrameFailed, @"视频帧重转失败！");
                [self performErrorResultOnMainThread:error];
                return;
            }
        } else {
            outP = frame;
        }
        
#if USE_WRITE_THREAD
        frame_queue_push(&videof, outP, 0.0);
#else
        [self convertToPic:outP];
#endif
    }
}

- (BOOL)decoderHasMorePacket:(MRDecoder *)decoder
{
    if (videoq.nb_packets > 0) {
        return YES;
    } else {
        return !self.readEOF;
    }
}

- (NSString *)saveAsImage:(CGImageRef _Nonnull)img file:(NSString *)filePath
{
    NSString *extension = nil;
    CFStringRef imageUTType = NULL;
    
    switch (self.imageType) {
        case MRVTPImageJPG:
        {
            extension = @"jpg";
            imageUTType = kUTTypeJPEG;
        }
            break;
        case MRVTPImagePNG:
        {
            extension = @"png";
            imageUTType = kUTTypePNG;
        }
            break;
        case MRVTPImageBMP:
        {
            extension = @"bmp";
            imageUTType = kUTTypeBMP;
        }
            break;
        case MRVTPImageTIFF:
        {
            extension = @"tiff";
            imageUTType = kUTTypeTIFF;
        }
            break;
        case MRVTPImagePDF:
        {
            extension = @"pdf";
            imageUTType = kUTTypePDF;
        }
            break;
        case MRVTPImageGIF:
        {
            extension = @"gif";
            imageUTType = kUTTypeGIF;
        }
            break;
//        case MRVTPImageICO:
//        {
//            //writeAll:105: *** cannot create non-square ICO image (320 x 176)
//            fileName = [NSString stringWithFormat:@"%lld.ico",time];
//            imageUTType = kUTTypeICO;
//        }
//            break;
//        case MRVTPImageICNS:
//        {
//            //writeAll:570: unsupported ICNS image size (320 x 176) - scaling factor: 1  dpi: 72 x 72
//            fileName = [NSString stringWithFormat:@"%lld.icns",time];
//            imageUTType = kUTTypeAppleICNS;
//        }
//            break;
//        case MRVTPImageRAW:
//        {
//            //findWriterForTypeAndAlternateType:119: unsupported file format 'public.camera-raw-image'
//
//            fileName = [NSString stringWithFormat:@"%lld.raw",time];
//            imageUTType = kUTTypeRawImage;
//        }
//            break;
//        case MRVTPImageSVG:
//        {
//            //findWriterForTypeAndAlternateType:119: unsupported file format 'public.svg-image'
//            fileName = [NSString stringWithFormat:@"%lld.svg",time];
//            imageUTType = kUTTypeScalableVectorGraphics;
//        }
//            break;
    }
    
    NSString *imgPath = [filePath stringByAppendingPathExtension:extension];
    NSURL *fileUrl = [NSURL fileURLWithPath:imgPath];
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef) fileUrl, imageUTType, 1, NULL);
    if (destination) {
        CGImageDestinationAddImage(destination, img, NULL);
        CGImageDestinationFinalize(destination);
        CFRelease(destination);
        return imgPath;
    }
    return nil;
}

//逆时针旋转90度
- (CGImageRef)createRotated90AngleImage:(CGImageRef)source
{
    int width  = (int)CGImageGetWidth(source);
    int height = (int)CGImageGetHeight(source);
    
    int bitsPerComponent = (int)CGImageGetBitsPerComponent(source);
    int bitsPerPixel = (int)CGImageGetBitsPerPixel(source);
    int bytesPerRow = bitsPerPixel / 8 * height;
    
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bitmapInfo = CGImageGetBitmapInfo(source);
    
    CGContextRef bitmap = CGBitmapContextCreate(NULL, height, width, bitsPerComponent, bytesPerRow, colorSpace, bitmapInfo);
    
    double radius = 90 * M_PI / 180;
    
    // move to the rotation relative point
    CGContextTranslateCTM(bitmap, height, 0);
    
    // Rotate the image context
    CGContextRotateCTM(bitmap, radius);
    
    // Now, draw the rotated/scaled image into the context
    CGContextDrawImage(bitmap, CGRectMake(0, 0, width, height), source);
    
    CGImageRef result = CGBitmapContextCreateImage(bitmap);
    CGContextRelease(bitmap);
    CGColorSpaceRelease(colorSpace);
    
    return (CGImageRef)CFAutorelease(result);
}

//逆时针旋转180度
- (CGImageRef)createRotated180AngleImage:(CGImageRef)source
{
    int width  = (int)CGImageGetWidth(source);
    int height = (int)CGImageGetHeight(source);
    
    int bitsPerComponent = (int)CGImageGetBitsPerComponent(source);
    int bytesPerRow = (int)CGImageGetBytesPerRow(source);
    
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bitmapInfo = CGImageGetBitmapInfo(source);
    
    CGContextRef bitmap = CGBitmapContextCreate(NULL, width, height, bitsPerComponent, bytesPerRow, colorSpace, bitmapInfo);
    
    double radius = 180 * M_PI / 180;
    
    // move to the rotation relative point
    CGContextTranslateCTM(bitmap, width, height);
    
    // Rotate the image context
    CGContextRotateCTM(bitmap, radius);
    
    // Now, draw the rotated/scaled image into the context
    CGContextDrawImage(bitmap, CGRectMake(0, 0, width, height), source);
    
    CGImageRef result = CGBitmapContextCreateImage(bitmap);
    CGContextRelease(bitmap);
    CGColorSpaceRelease(colorSpace);
    
    return (CGImageRef)CFAutorelease(result);
}

//逆时针旋转270度
- (CGImageRef)createRotated270AngleImage:(CGImageRef)source
{
    int width  = (int)CGImageGetWidth(source);
    int height = (int)CGImageGetHeight(source);
    
    int bitsPerComponent = (int)CGImageGetBitsPerComponent(source);
    int bitsPerPixel = (int)CGImageGetBitsPerPixel(source);
    int bytesPerRow = bitsPerPixel / 8 * height;
    
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bitmapInfo = CGImageGetBitmapInfo(source);
    
    CGContextRef bitmap = CGBitmapContextCreate(NULL, height, width, bitsPerComponent, bytesPerRow, colorSpace, bitmapInfo);
    
    double radius = 270 * M_PI / 180;
    
    // move to the rotation relative point
    CGContextTranslateCTM(bitmap, 0, width);
    
    // Rotate the image context
    CGContextRotateCTM(bitmap, radius);
    
    // Now, draw the rotated/scaled image into the context
    CGContextDrawImage(bitmap, CGRectMake(0, 0, width, height), source);
    
    CGImageRef result = CGBitmapContextCreateImage(bitmap);
    CGContextRelease(bitmap);
    CGColorSpaceRelease(colorSpace);
    
    return (CGImageRef)CFAutorelease(result);
}

- (CGImageRef)rotateIfNeed:(CGImageRef)source angle:(MRDecoderVideoRotate)angle
{
    switch (angle) {
        case MRDecoderVideoRotateNone:
            return source;
        case MRDecoderVideoRotate90:
            return [self createRotated270AngleImage:source];
        case MRDecoderVideoRotate180:
            return [self createRotated180AngleImage:source];
        case MRDecoderVideoRotate270:
            return [self createRotated90AngleImage:source];
    }
}

- (NSString *)convertAndSaveAsImage:(AVFrame *)frame position:(int)position
{
    @autoreleasepool {
        CGImageRef img = [MRConvertUtil cgImageFromRGBFrame:frame];
        img = [self rotateIfNeed:img angle:self.videoDecoder.rotate];
        
        int64_t time = position >= 0 ? position : [[NSDate date] timeIntervalSince1970] * 10000;
        
        NSString *filePath = [self.picSaveDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%lld",time]];
        
        return [self saveAsImage:img file:filePath];
    }
}

- (void)convertToPic:(AVFrame *)frame
{
    if (!self.videoDecoder) {
        return;
    }
    
    NSString * imgPath = nil;
    BOOL hasPts = YES;
    int sec = -1;
    if (frame->pts != AV_NOPTS_VALUE) {
        //mpegts pts not start 0
        sec = (int)((frame->pts - self.videoDecoder.startTime) * av_q2d(self.videoDecoder.stream->time_base));
        if (lastFramePts < sec) {
            //av_log(NULL, AV_LOG_INFO, "frame->pts:%ds\n",sec);
            imgPath = [self convertAndSaveAsImage:frame position:sec];
            lastFramePts = sec + imgPath.length > 0 ? self.perferInterval : 0;
        } else {
            av_log(NULL, AV_LOG_INFO, "ignored frame->pts:%ds\n",sec);
        }
    } else {
        // 没有pts
        av_log(NULL, AV_LOG_INFO, "frame no pts\n");
        hasPts = NO;
        imgPath = [self convertAndSaveAsImage:frame position:-1];
    }
    
    if (!imgPath) {
        return;
    }
    
    if (self.frameCount >= self.perferMaxCount) {
        //提取的图片够了，就提前停止
        [[NSFileManager defaultManager] removeItemAtPath:imgPath error:nil];
        dispatch_sync_to_main_queue(^{
            [self _stop:NO];
        });
    } else {
        self.frameCount++;
        dispatch_sync_to_main_queue(^{
            if ([self.delegate respondsToSelector:@selector(vtp:convertAnImage:pst:)]) {
                [self.delegate vtp:self convertAnImage:imgPath pst:sec];
            }
            
            if (self.onConvertAnImageBlock) {
                self.onConvertAnImageBlock(self, imgPath, sec);
            }
        });
    }
}

- (void)performErrorResultOnMainThread:(NSError*)error
{
    dispatch_sync_to_main_queue(^{
        if ([self.delegate respondsToSelector:@selector(vtp:convertFinished:)]) {
            [self.delegate vtp:self convertFinished:error];
        }
        
        if (self.onConvertFinishedBlock) {
            self.onConvertFinishedBlock(self, error);
        }
    });
}

- (void)startConvert
{
    NSParameterAssert(self.contentPath);
    [self.workThread start];
}

- (void)cancel
{
    //主动stop时，则取消掉后续回调
    self.delegate = nil;
    self.onVideoOpenedBlock = nil;
    self.onConvertAnImageBlock = nil;
    self.onConvertFinishedBlock = nil;
    [self _stop:YES];
}

@end
