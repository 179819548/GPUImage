#import "GPUImageVideoCamera.h"
#import "GPUImageMovieWriter.h"
#import "GPUImageFilter.h"

void setColorConversion601( GLfloat conversionMatrix[9] )
{
    kColorConversion601 = conversionMatrix;
}

void setColorConversion601FullRange( GLfloat conversionMatrix[9] )
{
    kColorConversion601FullRange = conversionMatrix;
}

void setColorConversion709( GLfloat conversionMatrix[9] )
{
    kColorConversion709 = conversionMatrix;
}

#pragma mark -
#pragma mark Private methods and instance variables

@interface GPUImageVideoCamera () 
{
    NSDate *startingCaptureTime;
    
    GLProgram *yuvConversionProgram;
    GLint yuvConversionPositionAttribute, yuvConversionTextureCoordinateAttribute;
    GLint yuvConversionLuminanceTextureUniform, yuvConversionChrominanceTextureUniform;
    GLint yuvConversionMatrixUniform;
    const GLfloat *_preferredConversion;
    
    BOOL isFullYUVRange;
    
    int imageBufferWidth, imageBufferHeight;
    
    BOOL addedAudioInputsDueToEncodingTarget;
}

- (void)updateOrientationSendToTargets;
- (void)convertYUVToRGBOutput;

@end

@implementation GPUImageVideoCamera
@synthesize captureSessionPreset = _captureSessionPreset;
@synthesize captureSession = _captureSession;
@synthesize audioSession = _audioSession;
@synthesize backFacingCamera = _backFacingCamera;
@synthesize frontFacingCamera = _frontFacingCamera;
@synthesize inputCamera = _inputCamera;
@synthesize runBenchmark = _runBenchmark;
@synthesize outputImageOrientation = _outputImageOrientation;
@synthesize delegate = _delegate;
@synthesize horizontallyMirrorFrontFacingCamera = _horizontallyMirrorFrontFacingCamera, horizontallyMirrorRearFacingCamera = _horizontallyMirrorRearFacingCamera;
@synthesize frameRate = _frameRate;
@synthesize ultraWideCamera = _ultraWideCamera;

#pragma mark -
#pragma mark Initialization and teardown

- (id)init;
{
    if (!(self = [self initWithSessionPreset:AVCaptureSessionPreset640x480 cameraPosition:AVCaptureDevicePositionBack]))
    {
		return nil;
    }
    
    return self;
}

- (id)initWithSessionPreset:(NSString *)sessionPreset cameraPosition:(AVCaptureDevicePosition)cameraPosition; 
{
	if (!(self = [super init]))
    {
		return nil;
    }
    frameRenderingSemaphore = dispatch_semaphore_create(1);

	_frameRate = 0; // This will not set frame rate unless this value gets set to 1 or above
    _runBenchmark = NO;
    capturePaused = NO;
    outputRotation = kGPUImageNoRotation;
    internalRotation = kGPUImageNoRotation;
    captureAsYUV = YES;
    _preferredConversion = kColorConversion709;
    _captureSessionPreset = sessionPreset;

	// Grab the back-facing or front-facing camera
    [self createCaptureDeviceCameraPosition:cameraPosition];
    
	return self;
}

//初始化视频设备
-(void) createCaptureDeviceCameraPosition:(AVCaptureDevicePosition)cameraPosition {
    [self createCaptureDevice:cameraPosition];
    [self createOutput];
    [self createCaptureSession];
}

//初始化视频设备
-(void) createCaptureDevice:(AVCaptureDevicePosition)cameraPosition{
    //创建视频设备
    [self cameraPositionInit];
    _inputCamera = nil;
    if (cameraPosition == AVCaptureDevicePositionBack){
        _inputCamera = _backFacingCamera;
    }else if (cameraPosition == AVCaptureDevicePositionFront){
        _inputCamera = _frontFacingCamera;
    }
    if (!_inputCamera) {
        return;
    }
    videoInput = nil;
    if (cameraPosition == AVCaptureDevicePositionBack){
        videoInput = backVideoInput;
    }else if (cameraPosition == AVCaptureDevicePositionFront){
        videoInput = frontVideoInput;
    }
//    _microphone = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
//    audioInput = [AVCaptureDeviceInput deviceInputWithDevice:_microphone error:nil];
}


-(void) createOutput{
    dispatch_queue_t captureQueue = dispatch_queue_create("frog.capture.queue", DISPATCH_QUEUE_SERIAL);
    // Add the video frame output
    videoOutput = [[AVCaptureVideoDataOutput alloc] init];
    [videoOutput setSampleBufferDelegate:self queue:captureQueue];
    [videoOutput setAlwaysDiscardsLateVideoFrames:NO];
    
    if (captureAsYUV && [GPUImageContext supportsFastTextureUpload])
    {
        BOOL supportsFullYUVRange = NO;
        NSArray *supportedPixelFormats = videoOutput.availableVideoCVPixelFormatTypes;
        for (NSNumber *currentPixelFormat in supportedPixelFormats)
        {
            if ([currentPixelFormat intValue] == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            {
                supportsFullYUVRange = YES;
            }
        }
        
        if (supportsFullYUVRange)
        {
            [videoOutput setVideoSettings:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
            isFullYUVRange = YES;
        }
        else
        {
            [videoOutput setVideoSettings:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
            isFullYUVRange = NO;
        }
    }
    else
    {
        [videoOutput setVideoSettings:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCVPixelFormatType_32BGRA] forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
    }
    
    runSynchronouslyOnVideoProcessingQueue(^{

        if (self->captureAsYUV)
        {
            [GPUImageContext useImageProcessingContext];
            if (self->isFullYUVRange)
            {
                self->yuvConversionProgram = [[GPUImageContext sharedImageProcessingContext] programForVertexShaderString:kGPUImageVertexShaderString fragmentShaderString:kGPUImageYUVFullRangeConversionForLAFragmentShaderString];
            }
            else
            {
                self->yuvConversionProgram = [[GPUImageContext sharedImageProcessingContext] programForVertexShaderString:kGPUImageVertexShaderString fragmentShaderString:kGPUImageYUVVideoRangeConversionForLAFragmentShaderString];
            }

            //            }
            
            if (!self->yuvConversionProgram.initialized)
            {
                [self->yuvConversionProgram addAttribute:@"position"];
                [self->yuvConversionProgram addAttribute:@"inputTextureCoordinate"];
                
                if (![self->yuvConversionProgram link])
                {
                    NSString *progLog = [self->yuvConversionProgram programLog];
                    NSLog(@"Program link log: %@", progLog);
                    NSString *fragLog = [self->yuvConversionProgram fragmentShaderLog];
                    NSLog(@"Fragment shader compile log: %@", fragLog);
                    NSString *vertLog = [self->yuvConversionProgram vertexShaderLog];
                    NSLog(@"Vertex shader compile log: %@", vertLog);
                    self->yuvConversionProgram = nil;
                    NSAssert(NO, @"Filter shader link failed");
                }
            }
            
            self->yuvConversionPositionAttribute = [self->yuvConversionProgram attributeIndex:@"position"];
            self->yuvConversionTextureCoordinateAttribute = [self->yuvConversionProgram attributeIndex:@"inputTextureCoordinate"];
            self->yuvConversionLuminanceTextureUniform = [self->yuvConversionProgram uniformIndex:@"luminanceTexture"];
            self->yuvConversionChrominanceTextureUniform = [self->yuvConversionProgram uniformIndex:@"chrominanceTexture"];
            self->yuvConversionMatrixUniform = [self->yuvConversionProgram uniformIndex:@"colorConversionMatrix"];
            
            [GPUImageContext setActiveShaderProgram:self->yuvConversionProgram];
            
            glEnableVertexAttribArray(self->yuvConversionPositionAttribute);
            glEnableVertexAttribArray(self->yuvConversionTextureCoordinateAttribute);
        }
    });
    
//    audioOutput = [[AVCaptureAudioDataOutput alloc] init];
//    [audioOutput setSampleBufferDelegate:self queue:captureQueue];
}

//创建会话
-(void) createCaptureSession{
    
    _captureSession = [[AVCaptureSession alloc] init];
    _audioSession = [[AVCaptureSession alloc] init];

    [_captureSession beginConfiguration];

    if ([_captureSession canAddInput:videoInput])
    {
        [_captureSession addInput:videoInput];
    }
    
    if ([_captureSession canAddOutput:videoOutput])
    {
        [_captureSession addOutput:videoOutput];
    }
    
//    if ([_captureSession canAddInput:audioInput])
//    {
//        [_captureSession addInput:audioInput];
//    }
    
//    if ([_captureSession canAddOutput:audioOutput])
//    {
//        [_captureSession addOutput:audioOutput];
//    }
    
    if (![self.captureSession canSetSessionPreset:self.captureSessionPreset]) {
        @throw [NSException exceptionWithName:@"Not supported captureSessionPreset" reason:[NSString stringWithFormat:@"captureSessionPreset is [%@]", self.captureSessionPreset] userInfo:nil];
    }
    
    self.captureSession.sessionPreset = self.captureSessionPreset;
    
    [self.captureSession commitConfiguration];
}

- (void)cameraPositionInit{
    _ultraWideCamera = NO;
    _backFacingCamera = nil;
    _frontFacingCamera = nil;

    // 创建Camera镜头组，实现镜头自动变焦
    NSArray<AVCaptureDeviceType> * deviceTypeArr = @[AVCaptureDeviceTypeBuiltInWideAngleCamera,AVCaptureDeviceTypeBuiltInTripleCamera,AVCaptureDeviceTypeBuiltInDualWideCamera,AVCaptureDeviceTypeBuiltInTrueDepthCamera,AVCaptureDeviceTypeBuiltInUltraWideCamera,AVCaptureDeviceTypeBuiltInTelephotoCamera,AVCaptureDeviceTypeBuiltInDualCamera,AVCaptureDeviceTypeBuiltInMicrophone];
    
    AVCaptureDeviceDiscoverySession * myDiscoverySesion = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:deviceTypeArr mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionBack];
    AVCaptureDevice *tempBackFacingCamera = nil;
    for (AVCaptureDevice *device in myDiscoverySesion.devices) {
        // 找到对应的摄像头
        if ([device position] == AVCaptureDevicePositionBack)
        {
            tempBackFacingCamera = device;
        }
        if ([device position] == AVCaptureDevicePositionBack && (device.deviceType == AVCaptureDeviceTypeBuiltInTripleCamera || device.deviceType == AVCaptureDeviceTypeBuiltInDualWideCamera)) {
            _backFacingCamera = device;
            _ultraWideCamera = YES;
            break;
        }
    }
    if(_backFacingCamera == nil){
        if(tempBackFacingCamera){
            _backFacingCamera = tempBackFacingCamera;
        }else{
            NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
            for (AVCaptureDevice *device in devices)
            {
                if ([device position] == AVCaptureDevicePositionBack)
                {
                    _backFacingCamera = device;
                }
            }
        }
    }
    
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    for (AVCaptureDevice *device in devices)
    {
        if ([device position] == AVCaptureDevicePositionFront)
        {
            _frontFacingCamera = device;
        }
    }
    
    NSError *error1 = nil;
    if(_backFacingCamera) {
        backVideoInput = [[AVCaptureDeviceInput alloc] initWithDevice:_backFacingCamera error:&error1];
    }
    NSError *error2 = nil;
    if(_frontFacingCamera) {
        frontVideoInput = [[AVCaptureDeviceInput alloc] initWithDevice:_frontFacingCamera error:&error2];
    }
}

- (GPUImageFramebuffer *)framebufferForOutput;
{
    return outputFramebuffer;
}

- (void)dealloc 
{
    [self stopCameraCapture];
    [videoOutput setSampleBufferDelegate:nil queue:dispatch_get_main_queue()];
    [audioOutput setSampleBufferDelegate:nil queue:dispatch_get_main_queue()];
    
    [self removeInputsAndOutputs];
    
// ARC forbids explicit message send of 'release'; since iOS 6 even for dispatch_release() calls: stripping it out in that case is required.
#if !OS_OBJECT_USE_OBJC
    if (frameRenderingSemaphore != NULL)
    {
        dispatch_release(frameRenderingSemaphore);
    }
#endif
}

- (BOOL)addAudioInputsAndOutputs
{
    if (audioOutput || self.isPhoneCall)
        return NO;
    
//    if (self.isPhoneCall)
//        return NO;
    dispatch_queue_t captureQueue = dispatch_queue_create("frog.capture.audioqueue", DISPATCH_QUEUE_SERIAL);

    [_audioSession beginConfiguration];
    
    _microphone = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    audioInput = [AVCaptureDeviceInput deviceInputWithDevice:_microphone error:nil];
    if ([_audioSession canAddInput:audioInput])
    {
        [_audioSession addInput:audioInput];
    }
    audioOutput = [[AVCaptureAudioDataOutput alloc] init];
    
    if ([_audioSession canAddOutput:audioOutput])
    {
        [_audioSession addOutput:audioOutput];
    }
    else
    {
        NSLog(@"Couldn't add audio output");
    }
    [audioOutput setSampleBufferDelegate:self queue:captureQueue];
    
    [_audioSession commitConfiguration];
    return YES;
}

- (BOOL)removeAudioInputsAndOutputs
{
    if (!audioOutput)
        return NO;
    
    [_audioSession beginConfiguration];
    [_audioSession removeInput:audioInput];
    [_audioSession removeOutput:audioOutput];
    audioInput = nil;
    audioOutput = nil;
    _microphone = nil;
    [_audioSession commitConfiguration];
    _audioSession = [[AVCaptureSession alloc] init];
    return YES;
}

- (void)removeInputsAndOutputs;
{
    [_captureSession beginConfiguration];
    if (videoInput) {
        [_captureSession removeInput:videoInput];
        [_captureSession removeOutput:videoOutput];
        videoInput = nil;
        videoOutput = nil;
    }
    if (_microphone != nil)
    {
        [_audioSession beginConfiguration];
        [_audioSession removeInput:audioInput];
        [_audioSession removeOutput:audioOutput];
        audioInput = nil;
        audioOutput = nil;
        _microphone = nil;
        [_audioSession commitConfiguration];
        _audioSession = [[AVCaptureSession alloc] init];
    }
    [_captureSession commitConfiguration];
}

#pragma mark -
#pragma mark Managing targets

- (void)addTarget:(id<GPUImageInput>)newTarget atTextureLocation:(NSInteger)textureLocation;
{
    [super addTarget:newTarget atTextureLocation:textureLocation];
    
    [newTarget setInputRotation:outputRotation atIndex:textureLocation];
}

#pragma mark -
#pragma mark Manage the camera video stream

- (BOOL)isRunning;
{
    return [_captureSession isRunning];
}

- (void)startCameraCapture;
{
    if (![_captureSession isRunning])
	{
        startingCaptureTime = [NSDate date];
		[_captureSession startRunning];
	};
    
    if (![_audioSession isRunning])
    {
        [_audioSession startRunning];
    };
}

- (void)stopCameraCapture;
{
    if ([_captureSession isRunning])
    {
        [_captureSession stopRunning];
    }
    if ([_audioSession isRunning])
    {
        [_audioSession stopRunning];
    }
}

- (void)pauseCameraCapture;
{
    capturePaused = YES;
}

- (void)resumeCameraCapture;
{
    capturePaused = NO;
}

- (void)rotateCamera
{
    if (self.frontFacingCameraPresent == NO)
        return;

    AVCaptureDeviceInput *newVideoInput;
    AVCaptureDevicePosition currentCameraPosition = [[videoInput device] position];

    if (currentCameraPosition == AVCaptureDevicePositionBack) {
        _inputCamera = _frontFacingCamera;
        newVideoInput = frontVideoInput;
    }else {
        _inputCamera = _backFacingCamera;
        newVideoInput = backVideoInput;
    }
    
    if (newVideoInput != nil)
    {
        [_captureSession beginConfiguration];
        [_captureSession removeInput:videoInput];
        if ([_captureSession canAddInput:newVideoInput]) {
            [_captureSession addInput:newVideoInput];
            videoInput = newVideoInput;
        } else {
            [_captureSession addInput:videoInput];
        }
        [_captureSession commitConfiguration];
    }
    [self setOutputImageOrientation:_outputImageOrientation];
}

//- (void)rotateCamera
//{
//	if (self.frontFacingCameraPresent == NO)
//		return;
//
//    NSError *error;
//    AVCaptureDeviceInput *newVideoInput;
//    AVCaptureDevicePosition currentCameraPosition = [[videoInput device] position];
//
//    if (currentCameraPosition == AVCaptureDevicePositionBack)
//    {
//        currentCameraPosition = AVCaptureDevicePositionFront;
//    }
//    else
//    {
//        currentCameraPosition = AVCaptureDevicePositionBack;
//    }
//    _ultraWideCamera = NO;
//    AVCaptureDevice *backFacingCamera = nil;
//    if(currentCameraPosition == AVCaptureDevicePositionBack){
//        // 创建Camera镜头组，实现镜头自动变焦
//        NSArray<AVCaptureDeviceType> * deviceTypeArr = @[AVCaptureDeviceTypeBuiltInWideAngleCamera,AVCaptureDeviceTypeBuiltInTripleCamera,AVCaptureDeviceTypeBuiltInDualWideCamera,AVCaptureDeviceTypeBuiltInTrueDepthCamera,AVCaptureDeviceTypeBuiltInUltraWideCamera,AVCaptureDeviceTypeBuiltInTelephotoCamera,AVCaptureDeviceTypeBuiltInDualCamera,AVCaptureDeviceTypeBuiltInMicrophone];
//
//        AVCaptureDeviceDiscoverySession * myDiscoverySesion = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:deviceTypeArr mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionBack];
//        AVCaptureDevice *tempBackFacingCamera = nil;
//        for (AVCaptureDevice *device in myDiscoverySesion.devices) {
//            // 找到对应的摄像头
//            if ([device position] == currentCameraPosition)
//            {
//                tempBackFacingCamera = device;
//            }
//            if ([device position] == AVCaptureDevicePositionBack && (device.deviceType == AVCaptureDeviceTypeBuiltInTripleCamera || device.deviceType == AVCaptureDeviceTypeBuiltInDualWideCamera)) {
//                backFacingCamera = device;
//                _ultraWideCamera = YES;
//                break;
//            }
//        }
//        if(backFacingCamera == nil){
//            if(tempBackFacingCamera){
//                backFacingCamera = tempBackFacingCamera;
//            }else{
//                NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
//                for (AVCaptureDevice *device in devices)
//                {
//                    if ([device position] == AVCaptureDevicePositionBack)
//                    {
//                        backFacingCamera = device;
//                    }
//                }
//            }
//        }
//        //        NSArray *arrFactors = backFacingCamera.virtualDeviceSwitchOverVideoZoomFactors;
//        //        if(arrFactors && arrFactors.count){
//        //
//        //        }
//    }else{
//        NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
//        for (AVCaptureDevice *device in devices)
//        {
//            if ([device position] == currentCameraPosition)
//            {
//                backFacingCamera = device;
//            }
//        }
//    }
//
//    newVideoInput = [[AVCaptureDeviceInput alloc] initWithDevice:backFacingCamera error:&error];
//
//    if (newVideoInput != nil)
//    {
//        [_captureSession beginConfiguration];
//
//        [_captureSession removeInput:videoInput];
//        if ([_captureSession canAddInput:newVideoInput])
//        {
//            [_captureSession addInput:newVideoInput];
//            videoInput = newVideoInput;
//        }
//        else
//        {
//            [_captureSession addInput:videoInput];
//        }
//
//        NSKeyValueObservingOptions options = NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld | NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionPrior;
//        [_captureSession commitConfiguration];
//    }
//
//    _inputCamera = backFacingCamera;
//    [self setOutputImageOrientation:_outputImageOrientation];
//}

- (AVCaptureDevicePosition)cameraPosition 
{
    return [[videoInput device] position];
}

+ (BOOL)isBackFacingCameraPresent;
{
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    
    for (AVCaptureDevice *device in devices)
    {
        if ([device position] == AVCaptureDevicePositionBack)
            return YES;
    }
    
    return NO;
}

- (BOOL)isBackFacingCameraPresent
{
    return [GPUImageVideoCamera isBackFacingCameraPresent];
}

+ (BOOL)isFrontFacingCameraPresent;
{
	NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
	
	for (AVCaptureDevice *device in devices)
	{
		if ([device position] == AVCaptureDevicePositionFront)
			return YES;
	}
	
	return NO;
}

- (BOOL)isFrontFacingCameraPresent
{
    return [GPUImageVideoCamera isFrontFacingCameraPresent];
}

- (void)setCaptureSessionPreset:(NSString *)captureSessionPreset;
{
	[_captureSession beginConfiguration];
	
	_captureSessionPreset = captureSessionPreset;
	[_captureSession setSessionPreset:_captureSessionPreset];
	
	[_captureSession commitConfiguration];
}

- (void)setFrameRate:(int32_t)frameRate;
{
	_frameRate = frameRate;
	
	if (_frameRate > 0)
	{
		if ([_inputCamera respondsToSelector:@selector(setActiveVideoMinFrameDuration:)] &&
            [_inputCamera respondsToSelector:@selector(setActiveVideoMaxFrameDuration:)]) {
            
            NSError *error;
            [_inputCamera lockForConfiguration:&error];
            if (error == nil) {
#if defined(__IPHONE_7_0)
                [_inputCamera setActiveVideoMinFrameDuration:CMTimeMake(1, _frameRate)];
                [_inputCamera setActiveVideoMaxFrameDuration:CMTimeMake(1, _frameRate)];
#endif
            }
            [_inputCamera unlockForConfiguration];
            
        } else {
            
            for (AVCaptureConnection *connection in videoOutput.connections)
            {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                if ([connection respondsToSelector:@selector(setVideoMinFrameDuration:)])
                    connection.videoMinFrameDuration = CMTimeMake(1, _frameRate);
                
                if ([connection respondsToSelector:@selector(setVideoMaxFrameDuration:)])
                    connection.videoMaxFrameDuration = CMTimeMake(1, _frameRate);
#pragma clang diagnostic pop
            }
        }
        
	}
	else
	{
		if ([_inputCamera respondsToSelector:@selector(setActiveVideoMinFrameDuration:)] &&
            [_inputCamera respondsToSelector:@selector(setActiveVideoMaxFrameDuration:)]) {
            
            NSError *error;
            [_inputCamera lockForConfiguration:&error];
            if (error == nil) {
#if defined(__IPHONE_7_0)
                [_inputCamera setActiveVideoMinFrameDuration:kCMTimeInvalid];
                [_inputCamera setActiveVideoMaxFrameDuration:kCMTimeInvalid];
#endif
            }
            [_inputCamera unlockForConfiguration];
            
        } else {
            
            for (AVCaptureConnection *connection in videoOutput.connections)
            {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                if ([connection respondsToSelector:@selector(setVideoMinFrameDuration:)])
                    connection.videoMinFrameDuration = kCMTimeInvalid; // This sets videoMinFrameDuration back to default
                
                if ([connection respondsToSelector:@selector(setVideoMaxFrameDuration:)])
                    connection.videoMaxFrameDuration = kCMTimeInvalid; // This sets videoMaxFrameDuration back to default
#pragma clang diagnostic pop
            }
        }
        
	}
}

- (int32_t)frameRate;
{
	return _frameRate;
}

- (AVCaptureConnection *)videoCaptureConnection {
    for (AVCaptureConnection *connection in [videoOutput connections] ) {
		for ( AVCaptureInputPort *port in [connection inputPorts] ) {
			if ( [[port mediaType] isEqual:AVMediaTypeVideo] ) {
				return connection;
			}
		}
	}
    
    return nil;
}

#define INITIALFRAMESTOIGNOREFORBENCHMARK 5

- (void)updateTargetsForVideoCameraUsingCacheTextureAtWidth:(int)bufferWidth height:(int)bufferHeight time:(CMTime)currentTime;
{
    // First, update all the framebuffers in the targets
    for (id<GPUImageInput> currentTarget in targets)
    {
        if ([currentTarget enabled])
        {
            NSInteger indexOfObject = [targets indexOfObject:currentTarget];
            NSInteger textureIndexOfTarget = [[targetTextureIndices objectAtIndex:indexOfObject] integerValue];
            
            if (currentTarget != self.targetToIgnoreForUpdates)
            {
                [currentTarget setInputRotation:outputRotation atIndex:textureIndexOfTarget];
                [currentTarget setInputSize:CGSizeMake(bufferWidth, bufferHeight) atIndex:textureIndexOfTarget];
                
                if ([currentTarget wantsMonochromeInput] && captureAsYUV)
                {
                    [currentTarget setCurrentlyReceivingMonochromeInput:YES];
                    // TODO: Replace optimization for monochrome output
                    [currentTarget setInputFramebuffer:outputFramebuffer atIndex:textureIndexOfTarget];
                }
                else
                {
                    [currentTarget setCurrentlyReceivingMonochromeInput:NO];
                    [currentTarget setInputFramebuffer:outputFramebuffer atIndex:textureIndexOfTarget];
                }
            }
            else
            {
                [currentTarget setInputRotation:outputRotation atIndex:textureIndexOfTarget];
                [currentTarget setInputFramebuffer:outputFramebuffer atIndex:textureIndexOfTarget];
            }
        }
    }
    
    // Then release our hold on the local framebuffer to send it back to the cache as soon as it's no longer needed
    [outputFramebuffer unlock];
    outputFramebuffer = nil;
    
    // Finally, trigger rendering as needed
    for (id<GPUImageInput> currentTarget in targets)
    {
        if ([currentTarget enabled])
        {
            NSInteger indexOfObject = [targets indexOfObject:currentTarget];
            NSInteger textureIndexOfTarget = [[targetTextureIndices objectAtIndex:indexOfObject] integerValue];
            
            if (currentTarget != self.targetToIgnoreForUpdates)
            {
                [currentTarget newFrameReadyAtTime:currentTime atIndex:textureIndexOfTarget];
            }
        }
    }
}

- (void)processVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer;
{
    if (capturePaused)
    {
        return;
    }
    
    CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
    CVImageBufferRef cameraFrame = CMSampleBufferGetImageBuffer(sampleBuffer);
    
    int bufferWidth = (int) CVPixelBufferGetWidth(cameraFrame);
    int bufferHeight = (int) CVPixelBufferGetHeight(cameraFrame);
    CFTypeRef colorAttachments = CVBufferGetAttachment(cameraFrame, kCVImageBufferYCbCrMatrixKey, NULL);
    if (colorAttachments != NULL)
    {
        if(CFStringCompare(colorAttachments, kCVImageBufferYCbCrMatrix_ITU_R_601_4, 0) == kCFCompareEqualTo)
        {
            if (isFullYUVRange)
            {
                _preferredConversion = kColorConversion601FullRange;
            }
            else
            {
                _preferredConversion = kColorConversion601;
            }
        }
        else
        {
            _preferredConversion = kColorConversion709;
        }
    }
    else
    {
        if (isFullYUVRange)
        {
            _preferredConversion = kColorConversion601FullRange;
        }
        else
        {
            _preferredConversion = kColorConversion601;
        }
    }

	CMTime currentTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);

    [GPUImageContext useImageProcessingContext];

    if ([GPUImageContext supportsFastTextureUpload] && captureAsYUV)
    {
        CVOpenGLESTextureRef luminanceTextureRef = NULL;
        CVOpenGLESTextureRef chrominanceTextureRef = NULL;

//        if (captureAsYUV && [GPUImageContext deviceSupportsRedTextures])
        if (CVPixelBufferGetPlaneCount(cameraFrame) > 0) // Check for YUV planar inputs to do RGB conversion
        {
            CVPixelBufferLockBaseAddress(cameraFrame, 0);
            
            if ( (imageBufferWidth != bufferWidth) && (imageBufferHeight != bufferHeight) )
            {
                imageBufferWidth = bufferWidth;
                imageBufferHeight = bufferHeight;
            }
            
            CVReturn err;
            // Y-plane
            glActiveTexture(GL_TEXTURE4);
            if ([GPUImageContext deviceSupportsRedTextures])
            {
//                err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, coreVideoTextureCache, cameraFrame, NULL, GL_TEXTURE_2D, GL_RED_EXT, bufferWidth, bufferHeight, GL_RED_EXT, GL_UNSIGNED_BYTE, 0, &luminanceTextureRef);
                err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, [[GPUImageContext sharedImageProcessingContext] coreVideoTextureCache], cameraFrame, NULL, GL_TEXTURE_2D, GL_LUMINANCE, bufferWidth, bufferHeight, GL_LUMINANCE, GL_UNSIGNED_BYTE, 0, &luminanceTextureRef);
            }
            else
            {
                err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, [[GPUImageContext sharedImageProcessingContext] coreVideoTextureCache], cameraFrame, NULL, GL_TEXTURE_2D, GL_LUMINANCE, bufferWidth, bufferHeight, GL_LUMINANCE, GL_UNSIGNED_BYTE, 0, &luminanceTextureRef);
            }
            if (err)
            {
                NSLog(@"Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err);
            }
            
            luminanceTexture = CVOpenGLESTextureGetName(luminanceTextureRef);
            glBindTexture(GL_TEXTURE_2D, luminanceTexture);
            glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            
            // UV-plane
            glActiveTexture(GL_TEXTURE5);
            if ([GPUImageContext deviceSupportsRedTextures])
            {
//                err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, coreVideoTextureCache, cameraFrame, NULL, GL_TEXTURE_2D, GL_RG_EXT, bufferWidth/2, bufferHeight/2, GL_RG_EXT, GL_UNSIGNED_BYTE, 1, &chrominanceTextureRef);
                err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, [[GPUImageContext sharedImageProcessingContext] coreVideoTextureCache], cameraFrame, NULL, GL_TEXTURE_2D, GL_LUMINANCE_ALPHA, bufferWidth/2, bufferHeight/2, GL_LUMINANCE_ALPHA, GL_UNSIGNED_BYTE, 1, &chrominanceTextureRef);
            }
            else
            {
                err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, [[GPUImageContext sharedImageProcessingContext] coreVideoTextureCache], cameraFrame, NULL, GL_TEXTURE_2D, GL_LUMINANCE_ALPHA, bufferWidth/2, bufferHeight/2, GL_LUMINANCE_ALPHA, GL_UNSIGNED_BYTE, 1, &chrominanceTextureRef);
            }
            if (err)
            {
                NSLog(@"Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err);
            }
            
            chrominanceTexture = CVOpenGLESTextureGetName(chrominanceTextureRef);
            glBindTexture(GL_TEXTURE_2D, chrominanceTexture);
            glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            
//            if (!allTargetsWantMonochromeData)
//            {
                [self convertYUVToRGBOutput];
//            }

            int rotatedImageBufferWidth = bufferWidth, rotatedImageBufferHeight = bufferHeight;
            
            if (GPUImageRotationSwapsWidthAndHeight(internalRotation))
            {
                rotatedImageBufferWidth = bufferHeight;
                rotatedImageBufferHeight = bufferWidth;
            }
            
            [self updateTargetsForVideoCameraUsingCacheTextureAtWidth:rotatedImageBufferWidth height:rotatedImageBufferHeight time:currentTime];
            
            CVPixelBufferUnlockBaseAddress(cameraFrame, 0);
            CFRelease(luminanceTextureRef);
            CFRelease(chrominanceTextureRef);
        }
        else
        {
            // TODO: Mesh this with the output framebuffer structure
            
//            CVPixelBufferLockBaseAddress(cameraFrame, 0);
//            
//            CVReturn err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, [[GPUImageContext sharedImageProcessingContext] coreVideoTextureCache], cameraFrame, NULL, GL_TEXTURE_2D, GL_RGBA, bufferWidth, bufferHeight, GL_BGRA, GL_UNSIGNED_BYTE, 0, &texture);
//            
//            if (!texture || err) {
//                NSLog(@"Camera CVOpenGLESTextureCacheCreateTextureFromImage failed (error: %d)", err);
//                NSAssert(NO, @"Camera failure");
//                return;
//            }
//            
//            outputTexture = CVOpenGLESTextureGetName(texture);
//            //        glBindTexture(CVOpenGLESTextureGetTarget(texture), outputTexture);
//            glBindTexture(GL_TEXTURE_2D, outputTexture);
//            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
//            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
//            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
//            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
//            
//            [self updateTargetsForVideoCameraUsingCacheTextureAtWidth:bufferWidth height:bufferHeight time:currentTime];
//
//            CVPixelBufferUnlockBaseAddress(cameraFrame, 0);
//            CFRelease(texture);
//
//            outputTexture = 0;
        }
        
        
        if (_runBenchmark)
        {
            numberOfFramesCaptured++;
            if (numberOfFramesCaptured > INITIALFRAMESTOIGNOREFORBENCHMARK)
            {
                CFAbsoluteTime currentFrameTime = (CFAbsoluteTimeGetCurrent() - startTime);
                totalFrameTimeDuringCapture += currentFrameTime;
                NSLog(@"Average frame time : %f ms", [self averageFrameDurationDuringCapture]);
                NSLog(@"Current frame time : %f ms", 1000.0 * currentFrameTime);
            }
        }
    }
    else
    {
        CVPixelBufferLockBaseAddress(cameraFrame, 0);
        
        int bytesPerRow = (int) CVPixelBufferGetBytesPerRow(cameraFrame);
        outputFramebuffer = [[GPUImageContext sharedFramebufferCache] fetchFramebufferForSize:CGSizeMake(bytesPerRow / 4, bufferHeight) onlyTexture:YES];
        [outputFramebuffer activateFramebuffer];

        glBindTexture(GL_TEXTURE_2D, [outputFramebuffer texture]);
        
        //        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, bufferWidth, bufferHeight, 0, GL_BGRA, GL_UNSIGNED_BYTE, CVPixelBufferGetBaseAddress(cameraFrame));
        
        // Using BGRA extension to pull in video frame data directly
        // The use of bytesPerRow / 4 accounts for a display glitch present in preview video frames when using the photo preset on the camera
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, bytesPerRow / 4, bufferHeight, 0, GL_BGRA, GL_UNSIGNED_BYTE, CVPixelBufferGetBaseAddress(cameraFrame));
        
        [self updateTargetsForVideoCameraUsingCacheTextureAtWidth:bytesPerRow / 4 height:bufferHeight time:currentTime];
        
        CVPixelBufferUnlockBaseAddress(cameraFrame, 0);
        
        if (_runBenchmark)
        {
            numberOfFramesCaptured++;
            if (numberOfFramesCaptured > INITIALFRAMESTOIGNOREFORBENCHMARK)
            {
                CFAbsoluteTime currentFrameTime = (CFAbsoluteTimeGetCurrent() - startTime);
                totalFrameTimeDuringCapture += currentFrameTime;
            }
        }
    }  
}

- (void)processAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer;
{
    [self.audioEncodingTarget processAudioBuffer:sampleBuffer]; 
}

- (void)convertYUVToRGBOutput;
{
    [GPUImageContext setActiveShaderProgram:yuvConversionProgram];

    int rotatedImageBufferWidth = imageBufferWidth, rotatedImageBufferHeight = imageBufferHeight;

    if (GPUImageRotationSwapsWidthAndHeight(internalRotation))
    {
        rotatedImageBufferWidth = imageBufferHeight;
        rotatedImageBufferHeight = imageBufferWidth;
    }

    outputFramebuffer = [[GPUImageContext sharedFramebufferCache] fetchFramebufferForSize:CGSizeMake(rotatedImageBufferWidth, rotatedImageBufferHeight) textureOptions:self.outputTextureOptions onlyTexture:NO];
    [outputFramebuffer activateFramebuffer];

    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    
    static const GLfloat squareVertices[] = {
        -1.0f, -1.0f,
        1.0f, -1.0f,
        -1.0f,  1.0f,
        1.0f,  1.0f,
    };
    
	glActiveTexture(GL_TEXTURE4);
	glBindTexture(GL_TEXTURE_2D, luminanceTexture);
	glUniform1i(yuvConversionLuminanceTextureUniform, 4);

    glActiveTexture(GL_TEXTURE5);
	glBindTexture(GL_TEXTURE_2D, chrominanceTexture);
	glUniform1i(yuvConversionChrominanceTextureUniform, 5);

    glUniformMatrix3fv(yuvConversionMatrixUniform, 1, GL_FALSE, _preferredConversion);

    glVertexAttribPointer(yuvConversionPositionAttribute, 2, GL_FLOAT, 0, 0, squareVertices);
	glVertexAttribPointer(yuvConversionTextureCoordinateAttribute, 2, GL_FLOAT, 0, 0, [GPUImageFilter textureCoordinatesForRotation:internalRotation]);
    
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

#pragma mark -
#pragma mark Benchmarking

- (CGFloat)averageFrameDurationDuringCapture;
{
    return (totalFrameTimeDuringCapture / (CGFloat)(numberOfFramesCaptured - INITIALFRAMESTOIGNOREFORBENCHMARK)) * 1000.0;
}

- (void)resetBenchmarkAverage;
{
    numberOfFramesCaptured = 0;
    totalFrameTimeDuringCapture = 0.0;
}

#pragma mark -
#pragma mark AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    if (!self.captureSession.isRunning)
    {
        return;
    }
    else if (captureOutput == audioOutput)
    {
        [self processAudioSampleBuffer:sampleBuffer];
    }
    else
    {
        if (dispatch_semaphore_wait(frameRenderingSemaphore, DISPATCH_TIME_NOW) != 0)
        {
            return;
        }
        
        if ([self.delegate respondsToSelector:@selector(willOutputImageBufferRef:)])
        {
            [self.delegate willOutputImageBufferRef:sampleBuffer];
        }
        
        CFRetain(sampleBuffer);
        
        runAsynchronouslyOnVideoProcessingQueue(^{
            //Feature Detection Hook.
            if (self.delegate)
            {
                [self.delegate willOutputSampleBuffer:sampleBuffer];
            }
            
            [self processVideoSampleBuffer:sampleBuffer];
            
            CFRelease(sampleBuffer);
            dispatch_semaphore_signal(frameRenderingSemaphore);
        });
    }
}

#pragma mark -
#pragma mark Accessors

- (void)setAudioEncodingTarget:(GPUImageMovieWriter *)newValue;
{
    if (newValue) {
        /* Add audio inputs and outputs, if necessary */
        addedAudioInputsDueToEncodingTarget |= [self addAudioInputsAndOutputs];
    } else if (addedAudioInputsDueToEncodingTarget) {
        /* Remove audio inputs and outputs, if they were added by previously setting the audio encoding target */
        [self removeAudioInputsAndOutputs];
        addedAudioInputsDueToEncodingTarget = NO;
    }
    
    [super setAudioEncodingTarget:newValue];
}

- (void)setAudioEncodingTarget:(GPUImageMovieWriter *)newValue audioSettings:(NSDictionary *)audioOutputSettings;
{
    if (newValue) {
        /* Add audio inputs and outputs, if necessary */
        addedAudioInputsDueToEncodingTarget |= [self addAudioInputsAndOutputs];
    } else if (addedAudioInputsDueToEncodingTarget) {
        /* Remove audio inputs and outputs, if they were added by previously setting the audio encoding target */
        [self removeAudioInputsAndOutputs];
        addedAudioInputsDueToEncodingTarget = NO;
    }
    
    [super setAudioEncodingTarget:newValue audioSettings:audioOutputSettings];
}


- (void)updateOrientationSendToTargets;
{
    runSynchronouslyOnVideoProcessingQueue(^{
        
        //    From the iOS 5.0 release notes:
        //    In previous iOS versions, the front-facing camera would always deliver buffers in AVCaptureVideoOrientationLandscapeLeft and the back-facing camera would always deliver buffers in AVCaptureVideoOrientationLandscapeRight.
        
        if (captureAsYUV && [GPUImageContext supportsFastTextureUpload])
        {
            outputRotation = kGPUImageNoRotation;
            if ([self cameraPosition] == AVCaptureDevicePositionBack)
            {
                if (_horizontallyMirrorRearFacingCamera)
                {
                    switch(_outputImageOrientation)
                    {
                        case UIInterfaceOrientationPortrait:internalRotation = kGPUImageRotateRightFlipVertical; break;
                        case UIInterfaceOrientationPortraitUpsideDown:internalRotation = kGPUImageRotate180; break;
                        case UIInterfaceOrientationLandscapeLeft:internalRotation = kGPUImageFlipHorizonal; break;
                        case UIInterfaceOrientationLandscapeRight:internalRotation = kGPUImageFlipVertical; break;
                        default:internalRotation = kGPUImageNoRotation;
                    }
                }
                else
                {
                    switch(_outputImageOrientation)
                    {
                        case UIInterfaceOrientationPortrait:internalRotation = kGPUImageRotateRight; break;
                        case UIInterfaceOrientationPortraitUpsideDown:internalRotation = kGPUImageRotateLeft; break;
                        case UIInterfaceOrientationLandscapeLeft:internalRotation = kGPUImageRotate180; break;
                        case UIInterfaceOrientationLandscapeRight:internalRotation = kGPUImageNoRotation; break;
                        default:internalRotation = kGPUImageNoRotation;
                    }
                }
            }
            else
            {
                if (_horizontallyMirrorFrontFacingCamera)
                {
                    switch(_outputImageOrientation)
                    {
                        case UIInterfaceOrientationPortrait:internalRotation = kGPUImageRotateRightFlipVertical; break;
                        case UIInterfaceOrientationPortraitUpsideDown:internalRotation = kGPUImageRotateRightFlipHorizontal; break;
                        case UIInterfaceOrientationLandscapeLeft:internalRotation = kGPUImageFlipHorizonal; break;
                        case UIInterfaceOrientationLandscapeRight:internalRotation = kGPUImageFlipVertical; break;
                        default:internalRotation = kGPUImageNoRotation;
                   }
                }
                else
                {
                    switch(_outputImageOrientation)
                    {
                        case UIInterfaceOrientationPortrait:internalRotation = kGPUImageRotateRight; break;
                        case UIInterfaceOrientationPortraitUpsideDown:internalRotation = kGPUImageRotateLeft; break;
                        case UIInterfaceOrientationLandscapeLeft:internalRotation = kGPUImageNoRotation; break;
                        case UIInterfaceOrientationLandscapeRight:internalRotation = kGPUImageRotate180; break;
                        default:internalRotation = kGPUImageNoRotation;
                    }
                }
            }
        }
        else
        {
            if ([self cameraPosition] == AVCaptureDevicePositionBack)
            {
                if (_horizontallyMirrorRearFacingCamera)
                {
                    switch(_outputImageOrientation)
                    {
                        case UIInterfaceOrientationPortrait:outputRotation = kGPUImageRotateRightFlipVertical; break;
                        case UIInterfaceOrientationPortraitUpsideDown:outputRotation = kGPUImageRotate180; break;
                        case UIInterfaceOrientationLandscapeLeft:outputRotation = kGPUImageFlipHorizonal; break;
                        case UIInterfaceOrientationLandscapeRight:outputRotation = kGPUImageFlipVertical; break;
                        default:outputRotation = kGPUImageNoRotation;
                    }
                }
                else
                {
                    switch(_outputImageOrientation)
                    {
                        case UIInterfaceOrientationPortrait:outputRotation = kGPUImageRotateRight; break;
                        case UIInterfaceOrientationPortraitUpsideDown:outputRotation = kGPUImageRotateLeft; break;
                        case UIInterfaceOrientationLandscapeLeft:outputRotation = kGPUImageRotate180; break;
                        case UIInterfaceOrientationLandscapeRight:outputRotation = kGPUImageNoRotation; break;
                        default:outputRotation = kGPUImageNoRotation;
                    }
                }
            }
            else
            {
                if (_horizontallyMirrorFrontFacingCamera)
                {
                    switch(_outputImageOrientation)
                    {
                        case UIInterfaceOrientationPortrait:outputRotation = kGPUImageRotateRightFlipVertical; break;
                        case UIInterfaceOrientationPortraitUpsideDown:outputRotation = kGPUImageRotateRightFlipHorizontal; break;
                        case UIInterfaceOrientationLandscapeLeft:outputRotation = kGPUImageFlipHorizonal; break;
                        case UIInterfaceOrientationLandscapeRight:outputRotation = kGPUImageFlipVertical; break;
                        default:outputRotation = kGPUImageNoRotation;
                    }
                }
                else
                {
                    switch(_outputImageOrientation)
                    {
                        case UIInterfaceOrientationPortrait:outputRotation = kGPUImageRotateRight; break;
                        case UIInterfaceOrientationPortraitUpsideDown:outputRotation = kGPUImageRotateLeft; break;
                        case UIInterfaceOrientationLandscapeLeft:outputRotation = kGPUImageNoRotation; break;
                        case UIInterfaceOrientationLandscapeRight:outputRotation = kGPUImageRotate180; break;
                        default:outputRotation = kGPUImageNoRotation;
                    }
                }
            }
        }
        
        for (id<GPUImageInput> currentTarget in targets)
        {
            NSInteger indexOfObject = [targets indexOfObject:currentTarget];
            [currentTarget setInputRotation:outputRotation atIndex:[[targetTextureIndices objectAtIndex:indexOfObject] integerValue]];
        }
    });
}

- (void)setOutputImageOrientation:(UIInterfaceOrientation)newValue;
{
    _outputImageOrientation = newValue;
    [self updateOrientationSendToTargets];
}

- (void)setHorizontallyMirrorFrontFacingCamera:(BOOL)newValue
{
    _horizontallyMirrorFrontFacingCamera = newValue;
    [self updateOrientationSendToTargets];
}

- (void)setHorizontallyMirrorRearFacingCamera:(BOOL)newValue
{
    _horizontallyMirrorRearFacingCamera = newValue;
    [self updateOrientationSendToTargets];
}

@end
