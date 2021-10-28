//
//  xlVideoToolboxUtils.m
//  xLights


#include "CoreImage/CIImage.h"
#include "CoreImage/CIContext.h"
#include "CoreImage/CIKernel.h"
#include "CoreImage/CIFilter.h"
#include "CoreImage/CISampler.h"

extern "C" {
#include "libavcodec/videotoolbox.h"
#include "libavutil/pixdesc.h"
#include "libavutil/imgutils.h"
}

#include <log4cpp/Category.hh>

static CIContext *ciContext = nullptr;
static CIColorKernel *rbFlipKernel = nullptr;


static AVPixelFormat negotiate_pixel_format(AVCodecContext *s, const AVPixelFormat *fmt) {
    const enum AVPixelFormat *p;
    for (p = fmt; *p != AV_PIX_FMT_NONE; p++) {
        if (*p == AV_PIX_FMT_VIDEOTOOLBOX) {
            if (s->hwaccel_context == NULL) {
                AVVideotoolboxContext * vtctx = av_videotoolbox_alloc_context();
                int result = av_videotoolbox_default_init2(s, vtctx);
                if (result < 0) {
                    return s->pix_fmt;
                }
            }
            return *p;
        }
    }
    return s->pix_fmt;
}


bool SetupVideoToolboxAcceleration(AVCodecContext *s, bool enabled) {
    if (enabled) {
        s->thread_count = 2;
        s->get_format = negotiate_pixel_format;
        return true;
    }
    return false;
}

class VideoToolboxDataCache {
public:
    CVPixelBufferRef scaledBuf = nullptr;
    int width = 0;
    int height = 0;
    
    ~VideoToolboxDataCache() {
        release();
    }
    
    void release() {
        width = 0;
        height = 0;
        if (scaledBuf) {
            CVPixelBufferRelease(scaledBuf);
            scaledBuf = nullptr;
        }
    }
};

void CleanupVideoToolbox(AVCodecContext *s, void *cache) {
    VideoToolboxDataCache *c = (VideoToolboxDataCache*)cache;
    if (c) {
        delete c;
    }
    if (s->hwaccel_context != NULL) {
        av_videotoolbox_default_free(s);
    }
}
void InitVideoToolboxAcceleration() {
    static log4cpp::Category& logger_base = log4cpp::Category::getInstance(std::string("log_base"));
    
    NSMutableDictionary *dict = [[NSMutableDictionary alloc]init];
    [dict setObject:@NO forKey:kCIContextUseSoftwareRenderer];
    [dict setObject:@NO forKey:kCIContextOutputPremultiplied];
    if (__builtin_available(macOS 10.11, *)) {
        [dict setObject:@YES forKey:kCIContextHighQualityDownsample];
    }
    if (__builtin_available(macOS 10.12, *)) {
        [dict setObject:@NO forKey:kCIContextCacheIntermediates];
        [dict setObject:@YES forKey:kCIContextAllowLowPower];
    }

    ciContext = [[CIContext alloc] initWithOptions:dict];

    if (ciContext == nullptr) {
        logger_base.info("Could not create hardware context for scaling.");
        // wasn't able to create the context, let's try
        // with allowing the software renderer
        [dict setObject:@YES forKey:kCIContextUseSoftwareRenderer];
        ciContext = [[CIContext alloc] initWithOptions:dict];
    }
    if (ciContext == nullptr) {
        logger_base.info("Could not create context for scaling.");
    } else {

        rbFlipKernel = [CIColorKernel kernelWithString: @"kernel vec4 swapRedAndGreenAmount(__sample s) { return s.bgra; }" ];
    }

    logger_base.info("Hardware decoder initialized.");
}


bool IsVideoToolboxAcceleratedFrame(AVFrame *frame) {
    for (int x = 0; x < 3; x++) {
        if (frame->data[x]) return false;
    }
    return frame->data[3] != nullptr;
}

@interface CIRBFlipFilter: CIFilter {
    @public CIImage *inputImage;
}
@end

@implementation CIRBFlipFilter


- (CIImage *)outputImage
{
    CIImage *ci = inputImage;
    return [rbFlipKernel applyWithExtent:ci.extent arguments:@[ci] ];
}
@end


bool VideoToolboxScaleImage(AVCodecContext *codecContext, AVFrame *frame, AVFrame *dstFrame, void *&cache) {
    CVPixelBufferRef pixbuf = (CVPixelBufferRef)frame->data[3];
    bool doScale = (dstFrame->height != frame->height) || (dstFrame->width != frame->width);
    if (pixbuf == nullptr) {
        memset(dstFrame->data[0], 0, dstFrame->height * dstFrame->linesize[0]);
        return false;
    }
    if (ciContext == nullptr) {
        //cannot use a hardware scaler
        return false;
    }

    
    VideoToolboxDataCache *vcache = (VideoToolboxDataCache*)cache;
    if (vcache == nullptr) {
        vcache = new VideoToolboxDataCache();
        cache = vcache;
    }
    if (vcache->scaledBuf && (vcache->height != dstFrame->height || vcache->width != dstFrame->width)) {
        vcache->release();
    }
    CVPixelBufferRef scaledBuf = vcache->scaledBuf;
    if (!scaledBuf) {
        //BGRA is the pixel type that works best for us, there isn't an accelerated RGBA or just RGB
        //so we'll do BGRA and map while copying
        CVPixelBufferCreate(kCFAllocatorDefault,
                          dstFrame->width,
                          dstFrame->height,
                          kCVPixelFormatType_32BGRA,
                          (__bridge CFDictionaryRef) @{(__bridge NSString *) kCVPixelBufferIOSurfacePropertiesKey: @{}},
                          &scaledBuf);
        if (scaledBuf == nullptr) {
            return false;
        }
        vcache->scaledBuf = scaledBuf;
        vcache->width = dstFrame->width;
        vcache->height = dstFrame->height;
    }
    
    @autoreleasepool {
        CIImage *image = [CIImage imageWithCVImageBuffer:pixbuf];
        if (image == nullptr) {
            return false;
        }

        CIImage *scaledimage = image;
        if (doScale) {
            float w = dstFrame->width;
            w /= (float)frame->width;
            float h = dstFrame->height;
            h /= (float)frame->height;

            scaledimage = [image imageByApplyingTransform:CGAffineTransformMakeScale(w, h) highQualityDownsample:TRUE];
            if (scaledimage == nullptr) {
                return false;
            }
        }

        CIImage *swappedImage = scaledimage;
        if (dstFrame->format != AV_PIX_FMT_BGRA && dstFrame->format != AV_PIX_FMT_BGR24) {
            CIRBFlipFilter *filter = [[CIRBFlipFilter alloc] init];
            filter->inputImage = scaledimage;
            swappedImage =  [filter outputImage];
            if (swappedImage == nullptr) {
                return false;
            }
        }

        [ciContext render:swappedImage toCVPixelBuffer:scaledBuf];
        pixbuf = nil;

        CVPixelBufferLockBaseAddress(scaledBuf, kCVPixelBufferLock_ReadOnly);
        uint8_t *data = (uint8_t *)CVPixelBufferGetBaseAddress(scaledBuf);
        int linesize = CVPixelBufferGetBytesPerRow(scaledBuf);
        
        //copy data to dest frame
        if (linesize) {
            if (dstFrame->format == AV_PIX_FMT_RGBA || dstFrame->format == AV_PIX_FMT_BGRA) {
                if (linesize == (dstFrame->width*4)) {
                    memcpy(dstFrame->data[0], data, linesize*dstFrame->height);
                } else {
                    int startPosS = 0;
                    int startPosD = 0;
                    for (int x = 0; x < dstFrame->height; x++) {
                        memcpy(&dstFrame->data[0][startPosD], &data[startPosS], dstFrame->width*4);
                        startPosS += linesize;
                        startPosD += dstFrame->width*4;
                    }
                }
                
            } else {
                int startPosS = 0;
                int startPosD = 0;
                for (int l = 0; l < dstFrame->height; l++) {
                    uint8_t *dst = (uint8_t*)(&dstFrame->data[0][startPosD]);
                    uint8_t *src = (uint8_t*)(&data[startPosS]);
                    for (int w = 0, rgbLoc = 0; w < dstFrame->width*4; w += 4, rgbLoc += 3) {
                        dst[rgbLoc] = src[w];
                        dst[rgbLoc + 1] = src[w + 1];
                        dst[rgbLoc + 2] = src[w + 2];
                    }
                    
                    startPosS += linesize;
                    startPosD += dstFrame->width*3;
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(scaledBuf, kCVPixelBufferLock_ReadOnly);
    }

    av_frame_copy_props(dstFrame, frame);
    return true;
}
