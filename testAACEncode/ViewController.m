//
//  ViewController.m
//  testAACEncode
//
//  Created by 彭依汉 on 2019/11/1.
//  Copyright © 2019 彭依汉. All rights reserved.
//

#import "ViewController.h"
#import <AudioToolbox/AudioToolbox.h>
#import <VideoToolbox/VideoToolbox.h>
#import <AVFoundation/AVFoundation.h>

@interface ViewController ()<AVCaptureAudioDataOutputSampleBufferDelegate>

//存储PCM裸数据
@property (assign, nonatomic) char* pcmBuffer;
@property (assign, nonatomic) unsigned long pcmBufferSize;

//存储AAC数据
@property (assign, nonatomic) char* aacBuffer;
@property (assign, nonatomic) unsigned long aacBufferSize;

@property (strong, nonatomic) AVCaptureSession *captureSession;

@property (strong, nonatomic) AVCaptureDevice *audioCaptureDevice;

@property (strong, nonatomic) AVCaptureAudioDataOutput *audioDataOutput;

@property (strong, nonatomic) AVCaptureDeviceInput *captureDeviceInput;

//视频、捕捉队列
@property (strong, nonatomic) dispatch_queue_t captureQueue;

@property (strong, nonatomic) dispatch_queue_t aacEncoderQueue;

@property (strong ,nonatomic) dispatch_queue_t dispatchQueue;

@property (assign, nonatomic) AudioConverterRef audioConverter;

@property (strong, nonatomic) NSFileHandle *fileHandle;

@end

@implementation ViewController

#pragma mark ----------
#pragma mark ---------- life cycle ------------
- (void)viewDidLoad {
    [super viewDidLoad];
    
    //音频编码器为NULL
    _audioConverter = NULL;
    
    //PCM buffer为0，空间大小为0
    _pcmBufferSize = 0;
    _pcmBuffer = NULL;
    //AAC buffer先申请1024个
    _aacBufferSize = 1024;
    _aacBuffer = malloc(_aacBufferSize * sizeof(uint8_t));
    //然后将aacbuffer全部memset为0
    memset(_aacBuffer, 0, _aacBufferSize);
    
    self.view.backgroundColor = [UIColor yellowColor];
    
    //取得音频输入的设备
    self.audioCaptureDevice = [[AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio] lastObject];
    self.captureDeviceInput = [[AVCaptureDeviceInput alloc]initWithDevice:self.audioCaptureDevice error:nil];
    
    //设置输入和输出
    if(self.captureDeviceInput && [self.captureSession canAddInput:self.captureDeviceInput]){
        [self.captureSession addInput:self.captureDeviceInput];
    }
    self.audioDataOutput = [[AVCaptureAudioDataOutput alloc]init];
    if (self.audioDataOutput && [self.captureSession canAddOutput:self.audioDataOutput]) {
        [self.captureSession addOutput:self.audioDataOutput];
    }
    
    //设置输出的代理和执行队列
    [self.audioDataOutput setSampleBufferDelegate:self queue:self.captureQueue];
}

#pragma mark ----------
#pragma mark ---------- event && response ------------
- (IBAction)startAction:(id)sender {
    [self.captureSession startRunning];
}

- (IBAction)stopAction:(id)sender {
    [self.captureSession stopRunning];
}

#pragma mark ----------
#pragma mark ---------- AVCaptureAudioDataOutputSampleBufferDelegate ------------
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection{
    dispatch_sync(self.dispatchQueue, ^{
        [self processAudioSampleBuffer:sampleBuffer];
    });
 
    NSLog(@"ACC output Success");
}

- (void)processAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer{
    CFRetain(sampleBuffer);
    dispatch_async(self.aacEncoderQueue, ^{
        
        if(!_audioConverter){
            //创建编码器
            [self setupEncoderFromSampleBuffer:sampleBuffer];
        }
        
        CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
        CFRetain(blockBuffer);
        
        //这里拿到pcm的裸数据， Buffer指针和pcmBufferSize大小
        OSStatus status = CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, &_pcmBufferSize, &_pcmBuffer);
        if(status == kCMBlockBufferNoErr){
            
            memset(_aacBuffer, 0, _aacBufferSize);
            
            AudioBufferList outAudioBufferList = {0};
            outAudioBufferList.mNumberBuffers = 1;
            outAudioBufferList.mBuffers[0].mNumberChannels = 1;
            outAudioBufferList.mBuffers[0].mDataByteSize = (int)_aacBufferSize;
            outAudioBufferList.mBuffers[0].mData = _aacBuffer;
            
            AudioStreamPacketDescription *outPacketDescription = NULL;
            
            UInt32 ioOutputDataPacketSize = 1;
            
            status = AudioConverterFillComplexBuffer(_audioConverter,  //转码器
                                                     inInputDataProc,  //回调函数，用于将PCM数据喂给编码器
                                                     (__bridge void *)(self), //回调对象
                                                     &ioOutputDataPacketSize,   //输出包大小
                                                     &outAudioBufferList,
                                                     outPacketDescription);
            NSData *rawAAC;
            if(status == 0){
                rawAAC = [NSData dataWithBytes:outAudioBufferList.mBuffers[0].mData length:outAudioBufferList.mBuffers[0].mDataByteSize];
                NSData *adtsHeader = [self adtsDataForPacketLength:rawAAC.length];
                NSMutableData *fullData = [NSMutableData dataWithData:adtsHeader];
                [fullData appendData:rawAAC];
                rawAAC = fullData;
                
                [self.fileHandle writeData:rawAAC];
                NSLog(@"AAC encode Success");
            }
            
            CFRelease(blockBuffer);
            CFRelease(sampleBuffer);
            
        }
    });
}


/// 生成ADTS header
/// @param packetLength <#packetLength description#>
- (NSData*) adtsDataForPacketLength:(NSUInteger)packetLength {
    int adtsLength = 7;
    char *packet = malloc(sizeof(char) * adtsLength);
    // Variables Recycled by addADTStoPacket
    int profile = 2;  //AAC LC
    //39=MediaCodecInfo.CodecProfileLevel.AACObjectELD;
    int freqIdx = 4;  //44.1KHz
    int chanCfg = 1;  //MPEG-4 Audio Channel Configuration. 1 Channel front-center
    NSUInteger fullLength = adtsLength + packetLength;
    // fill in ADTS data
    packet[0] = (char)0xFF; // 11111111     = syncword
    packet[1] = (char)0xF9; // 1111 1 00 1  = syncword MPEG-2 Layer CRC
    packet[2] = (char)(((profile-1)<<6) + (freqIdx<<2) +(chanCfg>>2));
    packet[3] = (char)(((chanCfg&3)<<6) + (fullLength>>11));
    packet[4] = (char)((fullLength&0x7FF) >> 3);
    packet[5] = (char)(((fullLength&7)<<5) + 0x1F);
    packet[6] = (char)0xFC;
    NSData *data = [NSData dataWithBytesNoCopy:packet length:adtsLength freeWhenDone:YES];
    return data;
}

OSStatus inInputDataProc(AudioConverterRef inAudioConverter, UInt32 *ioNumberDataPackets, AudioBufferList *ioData, AudioStreamPacketDescription **outDataPacketDescription, void *inUserData)
{
    ViewController *encoder = (__bridge ViewController *)(inUserData);
    UInt32 requestedPackets = *ioNumberDataPackets;
    
    size_t copiedSamples = [encoder copyPCMSamplesIntoBuffer:ioData];
    if (copiedSamples < requestedPackets) {
        //PCM 缓冲区还没满
        *ioNumberDataPackets = 0;
        return -1;
    }
    *ioNumberDataPackets = 1;
    return noErr;
}


- (size_t) copyPCMSamplesIntoBuffer:(AudioBufferList*)ioData {
    size_t originalBufferSize = _pcmBufferSize;
    if (!originalBufferSize) {
        return 0;
    }
    ioData->mBuffers[0].mData = _pcmBuffer;
    ioData->mBuffers[0].mDataByteSize = (int)_pcmBufferSize;
    _pcmBuffer = NULL;
    _pcmBufferSize = 0;
    return originalBufferSize;
}

- (void)setupEncoderFromSampleBuffer:(CMSampleBufferRef)sampleBuffer{
    
    //获取输入的samplebuffer设置输出的格式
    AudioStreamBasicDescription inAudioSteamBasicDescription = *CMAudioFormatDescriptionGetStreamBasicDescription((CMAudioFormatDescriptionRef)CMSampleBufferGetFormatDescription(sampleBuffer));
    
    //初始化输出流的结构体描述为0，很重要
    AudioStreamBasicDescription outAudioSteamBasicDescription = {0};
    //音频流，在正常播放情况下的帧率。如果是压缩的格式，这个属性表示解压缩后的帧率。帧率不能为0
    outAudioSteamBasicDescription.mSampleRate = inAudioSteamBasicDescription.mSampleRate;
    //设置编码格式
    outAudioSteamBasicDescription.mFormatID = kAudioFormatMPEG4AAC;
    //无损编码，0表示没有
    outAudioSteamBasicDescription.mFormatFlags = kMPEG4Object_AAC_LC;
    //每一个packet的音视频数据大小。如果设置动态大小则设置为0，动态大小的格式，需要用AudioStreamPacketDesription来确定每个packet的大小
    outAudioSteamBasicDescription.mBytesPerPacket = 0;
    //每个packet的帧数。如果是未压缩的音频数据，值是1。动态帧率格式，这个值是较大的固定数字，比如说AAC的1024。如果是动态大小帧数（比如Ogg格式）设置为0.
    outAudioSteamBasicDescription.mFramesPerPacket = 1024;
    //每帧的大小。每一帧的起始点到下一帧的起始点。如果是压缩格式，设置为0.
    outAudioSteamBasicDescription.mBytesPerFrame = 0;
    //声道数
    outAudioSteamBasicDescription.mChannelsPerFrame = 1;
    //压缩格式设置为0
    outAudioSteamBasicDescription.mBitsPerChannel = 0;
    //8字节对齐，填0，相等于不对齐
    outAudioSteamBasicDescription.mReserved = 0;
    //获得音频描述符，创建AudioConverterRef
    AudioClassDescription *description = [self getAudioClassDescriptionWithType:kAudioFormatMPEG4AAC fromManufacturer:kAppleSoftwareAudioCodecManufacturer];
    OSStatus status = AudioConverterNewSpecific(&inAudioSteamBasicDescription, &outAudioSteamBasicDescription, 1, description, &_audioConverter);
    if (status != 0) {
        NSLog(@"setup converter: %d",(int)status);
    }
    
    //修改编码率的码率
    UInt32 outputBitrate = 64000;
    UInt32 propSize =  sizeof(outputBitrate);
    status = AudioConverterSetProperty(_audioConverter, kAudioConverterEncodeBitRate, propSize, &outputBitrate);
    
    //AudioConverterGetProperty方法查询一下是否设置成功
    UInt32 value = 0;
    UInt32 size = sizeof(value);
    AudioConverterGetProperty(_audioConverter,kAudioConverterPropertyMaximumOutputPacketSize, &size, &value);
    
}


/// 音频描述符
/// @param type 编解码类型
/// @param manufacturer 指明是软编还是硬编码
- (AudioClassDescription *)getAudioClassDescriptionWithType:(UInt32)type fromManufacturer:(UInt32)manufacturer{
    
    static AudioClassDescription desc;
    UInt32 encoderSpecifier = type;
    OSStatus st;
    
    UInt32 size;
    //拿到输出格式的size大小
    st = AudioFormatGetPropertyInfo(kAudioFormatProperty_Encoders, sizeof(encoderSpecifier), &encoderSpecifier, &size);
    
    if(st){
        NSLog(@"error getting audio format propery info: %d", (int)(st));
        return nil;
    }
    
    //一共有count这么多个编码的格式
    unsigned int count = size / sizeof(AudioClassDescription);
    
    //定义一个count容量的数组，将指定编码器的类型全部取出来放到一个数组里
    AudioClassDescription descriptions[count];
    st = AudioFormatGetProperty(kAudioFormatProperty_Encoders, sizeof(encoderSpecifier), &encoderSpecifier, &size, descriptions);
    if(st){
        NSLog(@"error getting audio format propery: %d", (int)(st));
        return nil;
    }
    //判断mSubType和mManufacturer，两者都相等则表示找到这个对应的编码器
    for (unsigned int i = 0; i < count; i++) {
        if((type == descriptions[i].mSubType) && (manufacturer == descriptions[i].mManufacturer)){
            memcpy(&desc, &(descriptions[i]), sizeof(desc));
            return &desc;
        }
    }
    return nil;
}

#pragma mark ----------
#pragma mark ---------- setter && getter ------------
- (AVCaptureSession *)captureSession{
    if(!_captureSession){
        _captureSession = [AVCaptureSession new];
    }
    return _captureSession;
}

- (dispatch_queue_t)captureQueue{
    if (!_captureQueue) {
        _captureQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    }
    return _captureQueue;
}

- (dispatch_queue_t)dispatchQueue{
    if(!_dispatchQueue){
        _dispatchQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    }
    return _dispatchQueue;
    
}

- (dispatch_queue_t)aacEncoderQueue{
    if (!_aacEncoderQueue) {
        _aacEncoderQueue = dispatch_queue_create("AAC Encoder Queue", DISPATCH_QUEUE_SERIAL);
    }
    return _aacEncoderQueue;
}

- (NSFileHandle*)fileHandle{
    if(!_fileHandle){
        NSArray *paths= NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *documentDirectory = [paths firstObject];
        NSString *filePath = [documentDirectory stringByAppendingPathComponent:@"aac.data"];
        
        [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
        [[NSFileManager defaultManager] createFileAtPath:filePath contents:nil attributes:nil];
        
        _fileHandle = [NSFileHandle fileHandleForWritingAtPath:filePath];
    }
    return _fileHandle;
}


@end
