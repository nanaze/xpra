# This file is part of Xpra.
# Copyright (C) 2017-2021 Antoine Martin <antoine@xpra.org>
# Xpra is released under the terms of the GNU GPL v2, or, at your option, any
# later version. See the file COPYING for details.

#cython: wraparound=False

import time

from xpra.util import envbool, typedict
from xpra.log import Logger
log = Logger("encoder", "jpeg")

from libc.stdint cimport uintptr_t
from xpra.buffers.membuf cimport makebuf, MemBuf, buffer_context    #pylint: disable=syntax-error

from xpra.codecs.codec_constants import get_subsampling_divs
from xpra.net.compression import Compressed
from xpra.util import csv
from xpra.os_util import bytestostr

cdef int SAVE_TO_FILE = envbool("XPRA_SAVE_TO_FILE")


ctypedef int TJSAMP
ctypedef int TJPF

cdef extern from "turbojpeg.h":
    TJSAMP  TJSAMP_444
    TJSAMP  TJSAMP_422
    TJSAMP  TJSAMP_420
    TJSAMP  TJSAMP_GRAY
    TJSAMP  TJSAMP_440
    TJSAMP  TJSAMP_411

    TJPF    TJPF_RGB
    TJPF    TJPF_BGR
    TJPF    TJPF_RGBX
    TJPF    TJPF_BGRX
    TJPF    TJPF_XBGR
    TJPF    TJPF_XRGB
    TJPF    TJPF_GRAY
    TJPF    TJPF_RGBA
    TJPF    TJPF_BGRA
    TJPF    TJPF_ABGR
    TJPF    TJPF_ARGB
    TJPF    TJPF_CMYK

    int TJFLAG_BOTTOMUP
    int TJFLAG_FASTUPSAMPLE
    int TJFLAG_FASTDCT
    int TJFLAG_ACCURATEDCT

    ctypedef void* tjhandle
    tjhandle tjInitCompress()
    int tjDestroy(tjhandle handle)
    char* tjGetErrorStr()
    #unsigned long tjBufSize(int width, int height, int jpegSubsamp)
    int tjCompress2(tjhandle handle, const unsigned char *srcBuf,
                    int width, int pitch, int height, int pixelFormat, unsigned char **jpegBuf,
                    unsigned long *jpegSize, int jpegSubsamp, int jpegQual, int flags) nogil

    int tjCompressFromYUVPlanes(tjhandle handle,
                    const unsigned char **srcPlanes,
                    int width, const int *strides,
                    int height, int subsamp,
                    unsigned char **jpegBuf,
                    unsigned long *jpegSize, int jpegQual,
                    int flags) nogil

TJPF_VAL = {
    "RGB"   : TJPF_RGB,
    "BGR"   : TJPF_BGR,
    "RGBX"  : TJPF_RGBX,
    "BGRX"  : TJPF_BGRX,
    "XBGR"  : TJPF_XBGR,
    "XRGB"  : TJPF_XRGB,
    "GRAY"  : TJPF_GRAY,
    "RGBA"  : TJPF_RGBA,
    "BGRA"  : TJPF_BGRA,
    "ABGR"  : TJPF_ABGR,
    "ARGB"  : TJPF_ARGB,
    "CMYK"  : TJPF_CMYK,
    }
TJSAMP_STR = {
    TJSAMP_444  : "444",
    TJSAMP_422  : "422",
    TJSAMP_420  : "420",
    TJSAMP_GRAY : "GRAY",
    TJSAMP_440  : "440",
    TJSAMP_411  : "411",
    }


def get_version():
    return 2

def get_type():
    return "jpeg"

def get_info():
    return {"version"   : get_version()}

def get_encodings():
    return ("jpeg",)

def init_module():
    log("jpeg.init_module()")

def cleanup_module():
    log("jpeg.cleanup_module()")

def get_input_colorspaces(encoding):
    assert encoding=="jpeg"
    return ("BGRX", "RGBX", "XBGR", "XRGB", "RGB", "BGR", "YUV420P", "YUV422P", "YUV444P")

def get_output_colorspaces(encoding, input_colorspace):
    assert encoding in get_encodings()
    assert input_colorspace in get_input_colorspaces(encoding)
    return (input_colorspace, )

def get_spec(encoding, colorspace):
    assert encoding=="jpeg"
    assert colorspace in get_input_colorspaces(encoding)
    from xpra.codecs.codec_constants import video_spec
    return video_spec("jpeg", input_colorspace=colorspace, output_colorspaces=(colorspace, ), has_lossless_mode=False,
                      codec_class=Encoder, codec_type="jpeg",
                      setup_cost=0, cpu_cost=100, gpu_cost=0,
                      min_w=16, min_h=16, max_w=16*1024, max_h=16*1024,
                      can_scale=False,
                      score_boost=-50)


cdef class Encoder:
    cdef tjhandle compressor
    cdef int width
    cdef int height
    cdef object scaling
    cdef object src_format
    cdef int quality
    cdef int speed
    cdef long frames
    cdef object __weakref__

    def __init__(self):
        self.width = self.height = self.quality = self.speed = self.frames = 0
        self.compressor = tjInitCompress()
        if self.compressor==NULL:
            raise Exception("Error: failed to instantiate a JPEG compressor")

    def init_context(self, device_context, width : int, height : int,
                     src_format, dst_formats, encoding, quality : int, speed : int, scaling, options : typedict):
        assert encoding=="jpeg"
        assert src_format in get_input_colorspaces(encoding)
        assert scaling==(1, 1)
        self.width = width
        self.height = height
        self.src_format = src_format
        self.scaling = scaling

    def is_ready(self):
        return self.compressor!=NULL

    def is_closed(self):
        return self.compressor==NULL

    def clean(self):
        self.width = self.height = self.quality = self.speed = 0
        r = tjDestroy(self.compressor)
        self.compressor = NULL
        if r:
            log.error("Error: failed to destroy the JPEG compressor, code %i:", r)
            log.error(" %s", get_error_str())

    def get_encoding(self):
        return "jpeg"

    def get_width(self):
        return self.width

    def get_height(self):
        return self.height

    def get_type(self):
        return "jpeg"

    def get_src_format(self):
        return self.src_format

    def get_info(self) -> dict:
        info = get_info()
        info.update({
            "frames"        : int(self.frames),
            "width"         : self.width,
            "height"        : self.height,
            "speed"         : self.speed,
            "quality"       : self.quality,
            })
        return info

    def compress_image(self, device_context, image, int quality=-1, int speed=-1, options=None):
        pfstr = bytestostr(image.get_pixel_format())
        if pfstr in ("YUV420P", "YUV422P", "YUV444P"):
            cdata = encode_yuv(self.compressor, image, quality, speed)
        else:
            cdata = encode_rgb(self.compressor, image, quality, speed)
        if not cdata:
            return None
        self.frames += 1
        return memoryview(cdata), {}


def get_error_str():
    cdef char *err = tjGetErrorStr()
    return bytestostr(err)

def encode(image, int quality=50, int speed=50):
    #100 would mean lossless, so cap it at 99:
    client_options = {
        "quality"   : min(99, quality),
        }
    cdef tjhandle compressor = tjInitCompress()
    if compressor==NULL:
        log.error("Error: failed to instantiate a JPEG compressor")
        return None
    cdef int r
    try:
        cdata = encode_rgb(compressor, image, quality, speed)
        if not cdata:
            return None
        if SAVE_TO_FILE:    # pragma: no cover
            filename = "./%s.jpeg" % time.time()
            with open(filename, "wb") as f:
                f.write(cdata)
            log.info("saved %i bytes to %s", len(cdata), filename)
        return "jpeg", Compressed("jpeg", memoryview(cdata), False), client_options, image.get_width(), image.get_height(), 0, 24
    finally:
        r = tjDestroy(compressor)
        if r:
            log.error("Error: failed to destroy the JPEG compressor, code %i:", r)
            log.error(" %s", get_error_str())

cdef encode_rgb(tjhandle compressor, image, int quality, int speed):
    cdef int width = image.get_width()
    cdef int height = image.get_height()
    cdef int stride = image.get_rowstride()
    pixels = image.get_pixels()
    pfstr = bytestostr(image.get_pixel_format())
    pf = TJPF_VAL.get(pfstr)
    if pf is None:
        raise Exception("invalid pixel format %s" % pfstr)
    cdef TJPF tjpf = pf
    cdef TJSAMP subsamp = TJSAMP_444
    if quality<50:
        subsamp = TJSAMP_420
    elif quality<80:
        subsamp = TJSAMP_422
    cdef int flags = 0
    cdef unsigned char *out = NULL
    cdef unsigned long out_size = 0
    cdef int r = -1
    cdef const unsigned char *src
    log("jpeg.encode_rgb with subsampling=%s for pixel format=%s with quality=%s",
        TJSAMP_STR.get(subsamp, subsamp), pfstr, quality)
    with buffer_context(pixels) as bc:
        assert len(bc)>=stride*height, "%s buffer is too small: %i bytes, %ix%i=%i bytes required" % (
            pfstr, len(bc), stride, height, stride*height)
        src = <const unsigned char *> (<uintptr_t> int(bc))
        if src==NULL:
            raise ValueError("missing pixel buffer address from context %s" % bc)
        with nogil:
            r = tjCompress2(compressor, src,
                            width, stride, height, tjpf,
                            &out, &out_size, subsamp, quality, flags)
    if r!=0:
        log.error("Error: failed to compress jpeg image, code %i:", r)
        log.error(" %s", get_error_str())
        log.error(" width=%i, stride=%i, height=%i", width, stride, height)
        log.error(" quality=%i, flags=%x", quality, flags)
        log.error(" pixel format=%s, quality=%i", pfstr, quality)
        return None
    assert out_size>0 and out!=NULL, "jpeg compression produced no data"
    return makebuf(out, out_size)

cdef encode_yuv(tjhandle compressor, image, int quality, int speed):
    pfstr = bytestostr(image.get_pixel_format())
    assert pfstr in ("YUV420P", "YUV422P"), "invalid yuv pixel format %s" % pfstr
    cdef TJSAMP subsamp
    if pfstr=="YUV420P":
        subsamp = TJSAMP_420
    elif pfstr=="YUV422P":
        subsamp = TJSAMP_422
    elif pfstr=="YUV444P":
        subsamp = TJSAMP_444
    else:
        raise ValueError("invalid yuv pixel format %s" % pfstr)
    cdef int width = image.get_width()
    cdef int height = image.get_height()
    stride = image.get_rowstride()
    planes = image.get_pixels()
    cdef int flags = 0
    cdef unsigned char *out = NULL
    cdef unsigned long out_size = 0
    cdef int r = -1
    cdef int strides[3]
    cdef const unsigned char *src[3]
    divs = get_subsampling_divs(pfstr)
    for i in range(3):
        src[i] = NULL
        xdiv = divs[i][0]
        assert stride[i]>=width//xdiv, "stride %i is too small for width %i of plane %s" % (
            stride[i], width//xdiv, "YUV"[i])
        strides[i] = stride[i]
    contexts = []
    try:
        for i in range(3):
            xdiv, ydiv = divs[i]
            bc = buffer_context(planes[i])
            bc.__enter__()
            contexts.append(bc)
            assert len(bc)>=strides[i]*height//ydiv, "%s buffer is too small: %i bytes, %ix%i=%i bytes required" % (
                pfstr, len(bc), strides[i], height, strides[i]*height//ydiv)
            src[i] = <const unsigned char *> (<uintptr_t> int(bc))
            if src[i]==NULL:
                raise ValueError("missing plane %s from context %s" % ("YUV"[i], bc))
            strides[i] = stride[i]
        log("jpeg.encode_yuv with subsampling=%s for pixel format=%s with quality=%s",
            TJSAMP_STR.get(subsamp, subsamp), pfstr, quality)
        with nogil:
            r = tjCompressFromYUVPlanes(compressor,
                                        src,
                                        width, <const int*> strides,
                                        height, subsamp,
                                        &out, &out_size, quality, flags)
        if r!=0:
            log.error("Error: failed to compress jpeg image, code %i:", r)
            log.error(" %s", get_error_str())
            log.error(" width=%i, strides=%s, height=%i", width, stride, height)
            log.error(" quality=%i, subsampling=%s, flags=%x", quality, TJSAMP_STR.get(subsamp, subsamp), flags)
            log.error(" pixel format=%s, quality=%i", pfstr, quality)
            log.error(" planes: %s", csv(<uintptr_t> src[i] for i in range(3)))
            return None
    finally:
        for bc in contexts:
            bc.__exit__()
    assert out_size>0 and out!=NULL, "jpeg compression produced no data"
    return makebuf(out, out_size)


def selftest(full=False):
    log("jpeg selftest")
    from xpra.codecs.codec_checks import make_test_image
    img = make_test_image("BGRA", 32, 32)
    for q in (0, 50, 100):
        v = encode(img, q, 100)
        assert v, "encode output was empty!"
