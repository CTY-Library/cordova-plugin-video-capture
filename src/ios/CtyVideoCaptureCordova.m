/*
 Licensed to the Apache Software Foundation (ASF) under one
 or more contributor license agreements.  See the NOTICE file
 distributed with this work for additional information
 regarding copyright ownership.  The ASF licenses this file
 to you under the Apache License, Version 2.0 (the
 "License"); you may not use this file except in compliance
 with the License.  You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied.  See the License for the
 specific language governing permissions and limitations
 under the License.
 */

#import "CtyVideoCaptureCordova.h"
#import "CDVFile.h"
#import <Cordova/CDVAvailability.h>
#import <Photos/Photos.h>


#define kW3CMediaFormatHeight @"height"
#define kW3CMediaFormatWidth @"width"
#define kW3CMediaFormatCodecs @"codecs"
#define kW3CMediaFormatBitrate @"bitrate"
#define kW3CMediaFormatDuration @"duration"
#define kW3CMediaModeType @"type"

static NSString * const CtyVideoCaptureErrorPermissionDeniedFirstTime = @"PERMISSION_DENIED_FIRST_TIME";
static NSString * const CtyVideoCaptureErrorPermissionDeniedNeedSettings = @"PERMISSION_DENIED_NEED_SETTINGS";
static NSString * const CtyVideoCaptureErrorPermissionRestricted = @"PERMISSION_RESTRICTED";
static NSString * const CtyVideoCaptureErrorPermissionStateUnresolved = @"PERMISSION_STATE_UNRESOLVED";
static NSString * const CtyVideoCaptureErrorOpenSettingsFailed = @"OPEN_SETTINGS_FAILED";
static const NSTimeInterval CtyVideoCaptureStopFallbackTimeoutSeconds = 8.0;

static BOOL CtyVideoCapturePhotoAccessGranted(PHAuthorizationStatus status)
{
    if (status == PHAuthorizationStatusAuthorized) {
        return YES;
    }

#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 140000
    if (@available(iOS 14.0, *)) {
        if (status == PHAuthorizationStatusLimited) {
            return YES;
        }
    }
#endif

    return NO;
}

@implementation NSBundle (PluginExtensions)

+ (NSBundle*) pluginBundle:(CDVPlugin*)plugin {
    NSBundle* bundle = [NSBundle bundleWithPath: [[NSBundle mainBundle] pathForResource:NSStringFromClass([plugin class]) ofType: @"bundle"]];
    return bundle;
}
@end

#define PluginLocalizedString(plugin, key, comment) [[NSBundle pluginBundle:(plugin)] localizedStringForKey:(key) value:nil table:nil]

@implementation CDVImagePicker



@synthesize quality;
@synthesize callbackId;
@synthesize mimeType;

- (uint64_t)accessibilityTraits
{
    NSString* systemVersion = [[UIDevice currentDevice] systemVersion];

    if (([systemVersion compare:@"4.0" options:NSNumericSearch] != NSOrderedAscending)) { // this means system version is not less than 4.0
        return UIAccessibilityTraitStartsMediaSession;
    }

    return UIAccessibilityTraitNone;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (UIViewController*)childViewControllerForStatusBarHidden {
    return nil;
}

- (void)viewWillAppear:(BOOL)animated {
    SEL sel = NSSelectorFromString(@"setNeedsStatusBarAppearanceUpdate");
    if ([self respondsToSelector:sel]) {
        [self performSelector:sel withObject:nil afterDelay:0];
    }

    [super viewWillAppear:animated];
}

@end

@interface CtyVideoCaptureCordova ()
@property (atomic, assign) NSInteger stopVideoFallbackToken;
@property (atomic, assign) BOOL awaitingVideoStopResult;
@property (atomic, copy) NSString* awaitingVideoCallbackId;
@property (atomic, assign) BOOL isVideoRecording;
@end

@implementation CtyVideoCaptureCordova
@synthesize inUse;

- (void)cleanupPickerControllerUI:(UIImagePickerController*)picker
{
    if (!picker) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController* presentingViewController = [picker presentingViewController];
        if (presentingViewController) {
            [presentingViewController dismissViewControllerAnimated:YES completion:nil];
        }

        if (picker.parentViewController) {
            [picker willMoveToParentViewController:nil];
            [picker.view removeFromSuperview];
            [picker removeFromParentViewController];
        }

        self.webView.opaque = YES;
        self.webView.backgroundColor = [UIColor whiteColor];
    });
}

- (void)pluginInitialize
{
    self.inUse = NO;
    self.stopVideoFallbackToken = 0;
    self.awaitingVideoStopResult = NO;
    self.awaitingVideoCallbackId = nil;
    self.isVideoRecording = NO;
}

- (void)armStopVideoFallbackWithCallbackId:(NSString*)callbackId
{
    self.awaitingVideoStopResult = YES;
    self.awaitingVideoCallbackId = callbackId;
    self.stopVideoFallbackToken += 1;

    NSInteger token = self.stopVideoFallbackToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(CtyVideoCaptureStopFallbackTimeoutSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self.awaitingVideoStopResult || token != self.stopVideoFallbackToken) {
            return;
        }

        NSLog(@"stopVideoCapture fallback triggered: didFinish/didCancel not received");
        self.awaitingVideoStopResult = NO;

        NSString* pendingCallbackId = self.awaitingVideoCallbackId;
        self.awaitingVideoCallbackId = nil;

        if (pendingCallbackId != nil && pendingCallbackId.length > 0) {
            CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageToErrorObject:CAPTURE_INTERNAL_ERR];
            [self.commandDelegate sendPluginResult:result callbackId:pendingCallbackId];
        }

        if (pickerController != nil) {
            [self cleanupPickerControllerUI:pickerController];
            pickerController = nil;
        }
        self.isVideoRecording = NO;
        self.inUse = NO;
    });
}

- (void)disarmStopVideoFallback
{
    self.awaitingVideoStopResult = NO;
    self.awaitingVideoCallbackId = nil;
    self.stopVideoFallbackToken += 1;
}

- (void)captureAudio:(CDVInvokedUrlCommand*)command
{
    NSString* callbackId = command.callbackId;
    NSDictionary* options = [command argumentAtIndex:0];

    if ([options isKindOfClass:[NSNull class]]) {
        options = [NSDictionary dictionary];
    }
    self->cfgoptions = options;
    NSNumber* duration = [options objectForKey:@"duration"];
    // the default value of duration is 0 so use nil (no duration) if default value
    if (duration) {
        duration = [duration doubleValue] == 0 ? nil : duration;
    }
    CDVPluginResult* result = nil;

    if (NSClassFromString(@"AVAudioRecorder") == nil) {
        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageToErrorObject:CAPTURE_NOT_SUPPORTED];
    } else if (self.inUse == YES) {
        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageToErrorObject:CAPTURE_APPLICATION_BUSY];
    } else {
        // all the work occurs here
        CDVAudioRecorderViewController* audioViewController = [[CDVAudioRecorderViewController alloc] initWithCommand:self duration:duration callbackId:callbackId];

        // Now create a nav controller and display the view...
        CDVAudioNavigationController* navController = [[CDVAudioNavigationController alloc] initWithRootViewController:audioViewController];

        self.inUse = YES;

        [self.viewController presentViewController:navController animated:YES completion:nil];
    }

    if (result) {
        [self.commandDelegate sendPluginResult:result callbackId:callbackId];
    }
}

- (void)captureImage:(CDVInvokedUrlCommand*)command
{
    NSString* callbackId = command.callbackId;
    NSDictionary* options = [command argumentAtIndex:0];

    if ([options isKindOfClass:[NSNull class]]) {
        options = [NSDictionary dictionary];
    }

    // options could contain limit and mode neither of which are supported at this time
    // taking more than one picture (limit) is only supported if provide own controls via cameraOverlayView property
    // can support mode in OS

    if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) {
        NSLog(@"Capture.imageCapture: camera not available.");
        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageToErrorObject:CAPTURE_NOT_SUPPORTED];
        [self.commandDelegate sendPluginResult:result callbackId:callbackId];
    } else {
        if (pickerController == nil) {
            pickerController = [[CDVImagePicker alloc] init];
        }

        pickerController.delegate = self;
        pickerController.sourceType = UIImagePickerControllerSourceTypeCamera;
        pickerController.allowsEditing = NO;
        if ([pickerController respondsToSelector:@selector(mediaTypes)]) {
            // iOS 3.0
            pickerController.mediaTypes = [NSArray arrayWithObjects:(NSString*)kUTTypeImage, nil];
        }

        /*if ([pickerController respondsToSelector:@selector(cameraCaptureMode)]){
            // iOS 4.0
            pickerController.cameraCaptureMode = UIImagePickerControllerCameraCaptureModePhoto;
            pickerController.cameraDevice = UIImagePickerControllerCameraDeviceRear;
            pickerController.cameraFlashMode = UIImagePickerControllerCameraFlashModeAuto;
        }*/
        // CDVImagePicker specific property
        pickerController.callbackId = callbackId;
        pickerController.modalPresentationStyle = UIModalPresentationCurrentContext;

        __weak CtyVideoCaptureCordova* weakSelf = self;
        [self ensureCameraPermissionForCallbackId:callbackId completion:^(BOOL granted) {
            __strong CtyVideoCaptureCordova* strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            if (!granted) {
                strongSelf->pickerController = nil;
                strongSelf.inUse = NO;
                return;
            }
            [strongSelf ensurePhotoLibraryPermissionForCallbackId:callbackId saveToPhotoAlbum:YES completion:^(BOOL photoGranted) {
                __strong CtyVideoCaptureCordova* innerStrongSelf = weakSelf;
                if (!innerStrongSelf) {
                    return;
                }
                if (!photoGranted) {
                    innerStrongSelf->pickerController = nil;
                    innerStrongSelf.inUse = NO;
                    return;
                }

                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong CtyVideoCaptureCordova* mainStrongSelf = weakSelf;
                    if (!mainStrongSelf) {
                        return;
                    }
                    [mainStrongSelf.viewController presentViewController:mainStrongSelf->pickerController animated:YES completion:nil];
                });
            }];
        }];
    }
}

/* Process a still image from the camera.
 * IN:
 *  UIImage* image - the UIImage data returned from the camera
 *  NSString* callbackId
 */
- (CDVPluginResult*)processImage:(UIImage*)image type:(NSString*)mimeType forCallbackId:(NSString*)callbackId
{
    CDVPluginResult* result = nil;

    // save the image to photo album
    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil);

    NSData* data = nil;
    if (mimeType && [mimeType isEqualToString:@"image/png"]) {
        data = UIImagePNGRepresentation(image);
    } else {
        data = UIImageJPEGRepresentation(image, 0.5);
    }

    // write to temp directory and return URI
    NSString* docsPath = [NSTemporaryDirectory()stringByStandardizingPath];   // use file system temporary directory
    NSError* err = nil;
    NSFileManager* fileMgr = [[NSFileManager alloc] init];

    // generate unique file name
    NSString* filePath;
    int i = 1;
    do {
        filePath = [NSString stringWithFormat:@"%@/photo_%03d.jpg", docsPath, i++];
    } while ([fileMgr fileExistsAtPath:filePath]);

    if (![data writeToFile:filePath options:NSAtomicWrite error:&err]) {
        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageToErrorObject:CAPTURE_INTERNAL_ERR];
        if (err) {
            NSLog(@"Error saving image: %@", [err localizedDescription]);
        }
    } else {
        // create MediaFile object

        NSDictionary* fileDict = [self getMediaDictionaryFromPath:filePath ofType:mimeType];
        NSArray* fileArray = [NSArray arrayWithObject:fileDict];

        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:fileArray];
    }

    return result;
}

- (void)startVideoCapture:(CDVInvokedUrlCommand*)command
{
    NSLog(@"===== iOS startVideoCapture START =====");

    if (self.awaitingVideoStopResult) {
        NSLog(@"startVideoCapture: 上一次 stop 尚未完成，忽略本次启动");
        CDVPluginResult* busyResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"0"];
        [self.commandDelegate sendPluginResult:busyResult callbackId:command.callbackId];
        NSLog(@"===== iOS startVideoCapture END (stop进行中) =====");
        return;
    }
    
    if (pickerController == nil) {
        NSLog(@"startVideoCapture: pickerController 为空");
        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"0"];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        NSLog(@"===== iOS startVideoCapture END (pickerController为空) =====");
        return;
    }

    if (self.isVideoRecording) {
        NSLog(@"startVideoCapture: 已处于录制中，忽略重复 start");
        CDVPluginResult* startedResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"1"];
        [self.commandDelegate sendPluginResult:startedResult callbackId:command.callbackId];
        NSLog(@"===== iOS startVideoCapture END (已在录制) =====");
        return;
    }
    
    NSLog(@"startVideoCapture: 开始启动视频录制");
    
    Boolean is_start = NO;
    
    // 调用startVideoCapture如果存在
    if ([pickerController respondsToSelector:@selector(startVideoCapture)]) {
        NSLog(@"startVideoCapture: 调用 pickerController.startVideoCapture()");
        @try {
            is_start = [pickerController startVideoCapture];
        } @catch (NSException *exception) {
            NSLog(@"startVideoCapture: 捕获异常=%@", exception.reason);
            is_start = NO;
        }
        NSLog(@"startVideoCapture: pickerController.startVideoCapture() 返回=%d", is_start);
    } else {
        NSLog(@"startVideoCapture: pickerController 不支持 startVideoCapture 方法");
        is_start = NO;
    }
    
    self.inUse = YES;
    self.isVideoRecording = is_start;
    
    CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:[NSString stringWithFormat:@"%d", is_start]];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    
    NSLog(@"===== iOS startVideoCapture END =====");
}

- (void)stopVideoCapture:(CDVInvokedUrlCommand*)command
{
    NSLog(@"===== iOS stopVideoCapture START =====");

    if (self.awaitingVideoStopResult) {
        NSLog(@"stopVideoCapture: 已在停止流程中，忽略重复 stop");
        CDVPluginResult* duplicateResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"true"];
        [self.commandDelegate sendPluginResult:duplicateResult callbackId:command.callbackId];
        NSLog(@"===== iOS stopVideoCapture END (重复调用) =====");
        return;
    }
    
    if (pickerController == nil) {
        NSLog(@"stopVideoCapture: pickerController 为空");
        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"false"];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        NSLog(@"===== iOS stopVideoCapture END (pickerController为空) =====");
        return;
    }

    if (!self.isVideoRecording) {
        NSLog(@"stopVideoCapture: 当前不在录制中，忽略 stop 调用");
        CDVPluginResult* idleResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"true"];
        [self.commandDelegate sendPluginResult:idleResult callbackId:command.callbackId];
        NSLog(@"===== iOS stopVideoCapture END (非录制态) =====");
        return;
    }
    
    NSLog(@"stopVideoCapture: 开始停止录制");

    NSString* callbackId = [(CDVImagePicker*)pickerController callbackId];
    [self armStopVideoFallbackWithCallbackId:callbackId];
    self.isVideoRecording = NO;
    
    // Stop recording on main thread. Do not cleanup picker here; wait for
    // didFinishPickingMediaWithInfo to process video and close UI.
    if ([pickerController respondsToSelector:@selector(stopVideoCapture)]) {
        NSLog(@"stopVideoCapture: 调用 pickerController.stopVideoCapture()");
        if ([NSThread isMainThread]) {
            @try {
                [pickerController stopVideoCapture];
                NSLog(@"stopVideoCapture: pickerController.stopVideoCapture() 完成 (main thread)");
            } @catch (NSException *exception) {
                // iOS 26+/new hardware occasionally throws "This task has already been stopped".
                // Treat as idempotent stop and continue waiting for didFinish/didCancel callback.
                NSLog(@"stopVideoCapture: ignored exception on main thread: %@", exception.reason);
            }
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    [pickerController stopVideoCapture];
                    NSLog(@"stopVideoCapture: pickerController.stopVideoCapture() 完成 (dispatched)");
                } @catch (NSException *exception) {
                    NSLog(@"stopVideoCapture: ignored exception on dispatched main thread: %@", exception.reason);
                }
            });
        }
    } else {
        NSLog(@"stopVideoCapture: pickerController 不支持 stopVideoCapture 方法");
    }

    CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"true"];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    
    NSLog(@"===== iOS stopVideoCapture END =====");
}

- (void)captureVideo:(CDVInvokedUrlCommand*)command
{
    NSLog(@"===== iOS captureVideo START =====");

    if (self.inUse || pickerController != nil || self.awaitingVideoStopResult) {
        NSLog(@"captureVideo: 插件忙，拒绝并发录制请求");
        CDVPluginResult* busyResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageToErrorObject:CAPTURE_APPLICATION_BUSY];
        [self.commandDelegate sendPluginResult:busyResult callbackId:command.callbackId];
        NSLog(@"===== iOS captureVideo END (busy) =====");
        return;
    }
    
    NSString* callbackId = command.callbackId;
    NSDictionary* options = [command argumentAtIndex:0];

    if ([options isKindOfClass:[NSNull class]]) {
        options = [NSDictionary dictionary];
    }
    self->cfgoptions = options;
    // options could contain limit, duration and mode
    // taking more than one video (limit) is only supported if provide own controls via cameraOverlayView property
    NSNumber* duration = [options objectForKey:@"duration"];
    NSString* is_front = [options objectForKey:@"is_front"]; // "1" or "true"  前置摄像头
    NSString* mediaType = nil;
    float width = [[options objectForKey:@"width"] floatValue];
    float height =  [[options objectForKey:@"height"] floatValue];
    
    NSLog(@"captureVideo: duration=%@, is_front=%@, width=%.0f, height=%.0f", duration, is_front, width, height);

    if ([UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) {
        // there is a camera, it is available, make sure it can do movies
        NSLog(@"captureVideo: 相机可用，创建 pickerController");
        pickerController = [[CDVImagePicker alloc] init];
        
        

        NSArray* types = nil;
        if ([UIImagePickerController respondsToSelector:@selector(availableMediaTypesForSourceType:)]) {
            types = [UIImagePickerController availableMediaTypesForSourceType:UIImagePickerControllerSourceTypeCamera];
            
            NSLog(@"MediaTypes: %@", [types description]);

            if ([types containsObject:(NSString*)kUTTypeMovie]) {
                mediaType = (NSString*)kUTTypeMovie;
            } else if ([types containsObject:(NSString*)kUTTypeVideo]) {
                mediaType = (NSString*)kUTTypeVideo;
            }
            
            //mediaType = (NSString*)kUTTypeMPEG4;
            //mediaType = (NSString*)kUTTypeAppleProtectedMPEG4Video;
        }
    }
    if (!mediaType) {
        // don't have video camera return error
        NSLog(@"Capture.captureVideo: video mode not available.");
        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageToErrorObject:CAPTURE_NOT_SUPPORTED];
        [self.commandDelegate sendPluginResult:result callbackId:callbackId];
        NSLog(@"captureVideo: 清空 pickerController");
        pickerController = nil;
        NSLog(@"===== iOS captureVideo END (video mode 不可用) =====");
    } else {
        pickerController.delegate = self;
        pickerController.sourceType = UIImagePickerControllerSourceTypeCamera;
        pickerController.allowsEditing = NO;
    
        // add 2023-02-05
        pickerController.showsCameraControls = NO;
        if([is_front  isEqual: @"1"] || [is_front  isEqual: @"true"]){
            pickerController.cameraDevice = UIImagePickerControllerCameraDeviceFront;//前置摄像头
        }
        
        // iOS 3.0
        pickerController.mediaTypes = [NSArray arrayWithObjects:mediaType, nil];

        if ([mediaType isEqualToString:(NSString*)kUTTypeMovie]){
            if (duration) {
                pickerController.videoMaximumDuration = [duration doubleValue];
            }
            //NSLog(@"pickerController.videoMaximumDuration = %f", pickerController.videoMaximumDuration);
        }

        // iOS 4.0
        if ([pickerController respondsToSelector:@selector(cameraCaptureMode)]) {
            pickerController.cameraCaptureMode = UIImagePickerControllerCameraCaptureModeVideo;
            //pickerController.videoQuality = UIImagePickerControllerQualityTypeIFrame1280x720;// UIImagePickerControllerQualityTypeHigh;
            // pickerController.cameraDevice = UIImagePickerControllerCameraDeviceRear;
            // pickerController.cameraFlashMode = UIImagePickerControllerCameraFlashModeAuto;
            
            
//            UIImagePickerControllerQualityTypeHigh = 0,       // highest quality
//            UIImagePickerControllerQualityTypeMedium = 1,     // medium quality, suitable for transmission via Wi-Fi
//            UIImagePickerControllerQualityTypeLow = 2,         // lowest quality, suitable for transmission via cellular network
//            UIImagePickerControllerQualityType640x480 API_AVAILABLE(ios(4.0)) = 3,    // VGA quality
//            UIImagePickerControllerQualityTypeIFrame1280x720 API_AVAILABLE(ios(5.0)) = 4,
//            UIImagePickerControllerQualityTypeIFrame960x540 API_AVAILABLE(ios(5.0)) = 5,
            if(width>0) {
                if(width<=192){
                    pickerController.videoQuality =UIImagePickerControllerQualityTypeLow;
                }
                else if(width<=480){
                    pickerController.videoQuality =UIImagePickerControllerQualityTypeMedium;
                }
                //虽然分辨率低（下面注释的3种），但是生成的文件比UIImagePickerControllerQualityTypeHigh更大
//                else if(width<=640){
//                    pickerController.videoQuality =UIImagePickerControllerQualityType640x480;
//                }
//                else if(width<=960){
//                    pickerController.videoQuality = UIImagePickerControllerQualityTypeIFrame960x540;
//                }
//                else if(width<=1280){
//                    pickerController.videoQuality = UIImagePickerControllerQualityTypeIFrame1280x720;
//                }
                else{
                    pickerController.videoQuality = UIImagePickerControllerQualityTypeHigh;
                }
            }
            else if (height > 0){
                if(height<=144){
                    pickerController.videoQuality = UIImagePickerControllerQualityTypeLow;
                }
                else  if(height<=360){
                    pickerController.videoQuality = UIImagePickerControllerQualityTypeMedium;
                }
                //虽然分辨率低（下面注释的3种），但是生成的文件比UIImagePickerControllerQualityTypeHigh更大
//                else  if(height<=480){
//                    pickerController.videoQuality = UIImagePickerControllerQualityType640x480;
//                }
//                else  if(height<=540){
//                    pickerController.videoQuality = UIImagePickerControllerQualityTypeIFrame960x540;
//                }
//                else  if(height<=720){
//                    pickerController.videoQuality = UIImagePickerControllerQualityTypeIFrame1280x720;
//                }
                else {
                    pickerController.videoQuality = UIImagePickerControllerQualityTypeHigh;
                }
                
            }
            else {
                pickerController.videoQuality =  UIImagePickerControllerQualityTypeHigh;
            }
            
        }
        // CDVImagePicker specific property
        pickerController.callbackId = callbackId;
        pickerController.modalPresentationStyle = UIModalPresentationCurrentContext;
        BOOL saveToPhotoAlbum = YES;
        if ([self->cfgoptions objectForKey:@"saveToPhotoAlbum"]) {
            saveToPhotoAlbum = [[self->cfgoptions objectForKey:@"saveToPhotoAlbum"] boolValue];
        }

        __weak CtyVideoCaptureCordova* weakSelf = self;
        [self ensureCameraAndMicrophonePermissionForCallbackId:callbackId completion:^(BOOL granted) {
            __strong CtyVideoCaptureCordova* strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            if (!granted) {
                strongSelf->pickerController = nil;
                strongSelf.inUse = NO;
                return;
            }

            [strongSelf ensurePhotoLibraryPermissionForCallbackId:callbackId saveToPhotoAlbum:saveToPhotoAlbum completion:^(BOOL photoGranted) {
                __strong CtyVideoCaptureCordova* innerStrongSelf = weakSelf;
                if (!innerStrongSelf) {
                    return;
                }
                if (!photoGranted) {
                    innerStrongSelf->pickerController = nil;
                    innerStrongSelf.inUse = NO;
                    return;
                }

                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong CtyVideoCaptureCordova* mainStrongSelf = weakSelf;
                    if (!mainStrongSelf) {
                        return;
                    }
                    NSLog(@"captureVideo: 将 pickerController 添加到 view hierarchy");
                    [mainStrongSelf.viewController addChildViewController:mainStrongSelf->pickerController];
                    mainStrongSelf->pickerController.view.frame = mainStrongSelf.webView.superview.bounds;
                    mainStrongSelf->pickerController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                    mainStrongSelf.webView.opaque = NO;
                    mainStrongSelf.webView.backgroundColor = [UIColor clearColor];
                    [mainStrongSelf.webView.superview addSubview:mainStrongSelf->pickerController.view];
                    [mainStrongSelf.webView.superview bringSubviewToFront:mainStrongSelf.webView];
                    [mainStrongSelf->pickerController didMoveToParentViewController:mainStrongSelf.viewController];

                    // Auto-start recording so captureVideo works as a one-call flow on iOS.
                    if ([mainStrongSelf->pickerController respondsToSelector:@selector(startVideoCapture)]) {
                        BOOL didStart = NO;
                        @try {
                            didStart = [mainStrongSelf->pickerController startVideoCapture];
                        } @catch (NSException *exception) {
                            NSLog(@"captureVideo: auto startVideoCapture exception=%@", exception.reason);
                            didStart = NO;
                        }
                        mainStrongSelf.isVideoRecording = didStart;
                        NSLog(@"captureVideo: auto startVideoCapture result=%d", didStart);
                    }

                    NSLog(@"captureVideo: pickerController 显示完成");
                    mainStrongSelf.inUse = YES;
                    NSLog(@"===== iOS captureVideo END (成功) =====");
                });
            }];
        }];
        
    }
}

- (CDVPluginResult*)processVideo:(NSString*)moviePath forCallbackId:(NSString*)callbackId
{
    // save the movie to photo album (only avail as of iOS 3.1)

    /* don't need, it should automatically get saved
     NSLog(@"can save %@: %d ?", moviePath, UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(moviePath));
    if (&UIVideoAtPathIsCompatibleWithSavedPhotosAlbum != NULL && UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(moviePath) == YES) {
        NSLog(@"try to save movie");
        UISaveVideoAtPathToSavedPhotosAlbum(moviePath, nil, nil, nil);
        NSLog(@"finished saving movie");
    }*/
    // create MediaFile object
    
    
    //moviePath
     CtyVideoTranscode *transcode = [CtyVideoTranscode alloc];
    
    transcode.outputFileType = MPEG4;
    
    CFUUIDRef uuidObj = CFUUIDCreate(nil);//create a new UUID
    //get the string representation of the UUID
    NSString* uuidString = (NSString*)CFBridgingRelease(CFUUIDCreateString(nil, uuidObj));
    CFRelease(uuidObj);
    
     
    //压缩
    if([self->cfgoptions objectForKey:@"optimizeForNetworkUse"]){
        transcode.optimizeForNetworkUse =  [[self->cfgoptions objectForKey:@"optimizeForNetworkUse"] boolValue];
    }
    else{
        transcode.optimizeForNetworkUse =  NO;
    }
    //保存相册
    if([self->cfgoptions objectForKey:@"saveToPhotoAlbum"]){
        transcode.saveToPhotoAlbum =  [[self->cfgoptions objectForKey:@"saveToPhotoAlbum"] boolValue];
    }
    else{
        transcode.saveToPhotoAlbum = YES;
    }
    //保持长宽比不变
    if([self->cfgoptions objectForKey:@"maintainAspectRatio"]){
        transcode.maintainAspectRatio =  [[self->cfgoptions objectForKey:@"maintainAspectRatio"] boolValue];
    }else{
        transcode.maintainAspectRatio = YES;
    }

    transcode.width = [[self->cfgoptions objectForKey:@"width"] floatValue];
    transcode.height =  [[self->cfgoptions objectForKey:@"height"] floatValue];
    transcode.videoBitrate =  [[self->cfgoptions objectForKey:@"videoBitrate"] intValue];
    transcode.audioChannels =  [[self->cfgoptions objectForKey:@"audioChannels"] intValue];
    transcode.audioSampleRate =  [[self->cfgoptions objectForKey:@"audioSampleRate"] intValue];
    transcode.audioBitrate =  [[self->cfgoptions objectForKey:@"audioBitrate"] intValue];

    
    NSString* outputPath = [transcode transcodeVideo:moviePath videoFileName: uuidString ];
    
    NSLog(@"[CtyVideoCaptureCordova] processVideo: inputPath=%@, outputPath=%@, outputPathLength=%lu", moviePath, outputPath, (unsigned long)[outputPath length]);
    
    if (!outputPath || [outputPath length] == 0) {
        NSLog(@"[CtyVideoCaptureCordova] ERROR: Transcode returned empty path. Possible causes: encoding failure, permission issue, or codec incompatibility on this device.");
        return [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageToErrorObject:CAPTURE_INTERNAL_ERR];
    }
    
    NSDictionary* fileDict = [self getMediaDictionaryFromPath:outputPath ofType:nil];
    NSArray* fileArray = [NSArray arrayWithObject:fileDict];

    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:moviePath error:NULL];
    } @catch (NSException *exception) {
        
    } @finally {
        
    }

    return [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:fileArray];
}

- (CDVPluginResult*)permissionErrorResultWithCode:(NSString*)code message:(NSString*)message
{
    NSDictionary* payload = @{ @"code": code, @"message": message };
    return [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:payload];
}

- (BOOL)isGrantedAuthorizationStatus:(AVAuthorizationStatus)status
{
    return status == AVAuthorizationStatusAuthorized;
}

- (void)requestPhotoLibraryAuthorizationIfNeededWithCompletion:(void (^)(PHAuthorizationStatus status))completion
{
    if (@available(iOS 14.0, *)) {
        PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];
        if (status == PHAuthorizationStatusNotDetermined) {
            [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus resolvedStatus) {
                completion(resolvedStatus);
            }];
            return;
        }

        completion(status);
        return;
    }

    PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];
    if (status == PHAuthorizationStatusNotDetermined) {
        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus resolvedStatus) {
            completion(resolvedStatus);
        }];
        return;
    }

    completion(status);
}

- (void)ensurePhotoLibraryPermissionForCallbackId:(NSString*)callbackId saveToPhotoAlbum:(BOOL)saveToPhotoAlbum completion:(void (^)(BOOL granted))completion
{
    if (!saveToPhotoAlbum) {
        completion(YES);
        return;
    }

    PHAuthorizationStatus initialStatus;
    if (@available(iOS 14.0, *)) {
        initialStatus = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];
    } else {
        initialStatus = [PHPhotoLibrary authorizationStatus];
    }

    [self requestPhotoLibraryAuthorizationIfNeededWithCompletion:^(PHAuthorizationStatus status) {
        if (CtyVideoCapturePhotoAccessGranted(status)) {
            completion(YES);
            return;
        }

        if (status == PHAuthorizationStatusRestricted) {
            [self sendPermissionErrorForCode:CtyVideoCaptureErrorPermissionRestricted callbackId:callbackId];
        } else if (status == PHAuthorizationStatusDenied) {
            [self sendPermissionErrorForCode:(initialStatus == PHAuthorizationStatusNotDetermined
                ? CtyVideoCaptureErrorPermissionDeniedFirstTime
                : CtyVideoCaptureErrorPermissionDeniedNeedSettings)
                callbackId:callbackId];
        } else {
            [self sendPermissionErrorForCode:CtyVideoCaptureErrorPermissionStateUnresolved callbackId:callbackId];
        }

        completion(NO);
    }];
}

- (void)sendPermissionErrorForCode:(NSString*)code callbackId:(NSString*)callbackId
{
    NSString* message = @"Permission denied.";
    if ([code isEqualToString:CtyVideoCaptureErrorPermissionDeniedNeedSettings]) {
        message = @"Permission denied. Please open app settings and enable the required permissions.";
    } else if ([code isEqualToString:CtyVideoCaptureErrorPermissionRestricted]) {
        message = @"Permission is restricted by system policy.";
    } else if ([code isEqualToString:CtyVideoCaptureErrorPermissionStateUnresolved]) {
        message = @"Permission request did not resolve to an authorized state.";
    }

    CDVPluginResult* result = [self permissionErrorResultWithCode:code message:message];
    [self.commandDelegate sendPluginResult:result callbackId:callbackId];
}

- (void)requestAuthorizationIfNeededForMediaType:(AVMediaType)mediaType completion:(void (^)(AVAuthorizationStatus status))completion
{
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:mediaType];
    if (status == AVAuthorizationStatusNotDetermined) {
        [AVCaptureDevice requestAccessForMediaType:mediaType completionHandler:^(BOOL granted) {
            AVAuthorizationStatus resolved = granted ? AVAuthorizationStatusAuthorized : AVAuthorizationStatusDenied;
            completion(resolved);
        }];
        return;
    }
    completion(status);
}

- (void)ensureCameraPermissionForCallbackId:(NSString*)callbackId completion:(void (^)(BOOL granted))completion
{
    AVAuthorizationStatus initialStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    [self requestAuthorizationIfNeededForMediaType:AVMediaTypeVideo completion:^(AVAuthorizationStatus status) {
        if ([self isGrantedAuthorizationStatus:status]) {
            completion(YES);
        } else if (status == AVAuthorizationStatusRestricted) {
            [self sendPermissionErrorForCode:CtyVideoCaptureErrorPermissionRestricted callbackId:callbackId];
            completion(NO);
        } else if (status == AVAuthorizationStatusDenied) {
            [self sendPermissionErrorForCode:(initialStatus == AVAuthorizationStatusNotDetermined
                ? CtyVideoCaptureErrorPermissionDeniedFirstTime
                : CtyVideoCaptureErrorPermissionDeniedNeedSettings)
                callbackId:callbackId];
            completion(NO);
        } else {
            [self sendPermissionErrorForCode:CtyVideoCaptureErrorPermissionStateUnresolved callbackId:callbackId];
            completion(NO);
        }
    }];
}

- (void)ensureCameraAndMicrophonePermissionForCallbackId:(NSString*)callbackId completion:(void (^)(BOOL granted))completion
{
    AVAuthorizationStatus cameraInitialStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    AVAuthorizationStatus micInitialStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    __block AVAuthorizationStatus cameraFinalStatus = cameraInitialStatus;
    __block AVAuthorizationStatus micFinalStatus = micInitialStatus;

    dispatch_group_t group = dispatch_group_create();

    dispatch_group_enter(group);
    [self requestAuthorizationIfNeededForMediaType:AVMediaTypeVideo completion:^(AVAuthorizationStatus status) {
        cameraFinalStatus = status;
        dispatch_group_leave(group);
    }];

    dispatch_group_enter(group);
    [self requestAuthorizationIfNeededForMediaType:AVMediaTypeAudio completion:^(AVAuthorizationStatus status) {
        micFinalStatus = status;
        dispatch_group_leave(group);
    }];

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        if ([self isGrantedAuthorizationStatus:cameraFinalStatus] && [self isGrantedAuthorizationStatus:micFinalStatus]) {
            completion(YES);
            return;
        }

        if (cameraFinalStatus == AVAuthorizationStatusRestricted || micFinalStatus == AVAuthorizationStatusRestricted) {
            [self sendPermissionErrorForCode:CtyVideoCaptureErrorPermissionRestricted callbackId:callbackId];
            completion(NO);
            return;
        }

        if (cameraFinalStatus == AVAuthorizationStatusDenied || micFinalStatus == AVAuthorizationStatusDenied) {
            BOOL wasNotDetermined = (cameraInitialStatus == AVAuthorizationStatusNotDetermined)
                || (micInitialStatus == AVAuthorizationStatusNotDetermined);
            [self sendPermissionErrorForCode:(wasNotDetermined
                ? CtyVideoCaptureErrorPermissionDeniedFirstTime
                : CtyVideoCaptureErrorPermissionDeniedNeedSettings)
                callbackId:callbackId];
            completion(NO);
            return;
        }

        [self sendPermissionErrorForCode:CtyVideoCaptureErrorPermissionStateUnresolved callbackId:callbackId];
        completion(NO);
    });
}

- (void)hasCapturePermission:(CDVInvokedUrlCommand*)command
{
    AVAuthorizationStatus cameraStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    AVAuthorizationStatus micStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    BOOL granted = [self isGrantedAuthorizationStatus:cameraStatus] && [self isGrantedAuthorizationStatus:micStatus];

    CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:granted];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)requestCapturePermission:(CDVInvokedUrlCommand*)command
{
    [self ensureCameraAndMicrophonePermissionForCallbackId:command.callbackId completion:^(BOOL granted) {
        if (!granted) {
            return;
        }
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    }];
}

- (void)openAppSettings:(CDVInvokedUrlCommand*)command
{
    NSURL* url = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
    if (url == nil) {
        CDVPluginResult* pluginResult = [self permissionErrorResultWithCode:CtyVideoCaptureErrorOpenSettingsFailed message:@"Could not build app settings URL."];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        return;
    }

    if (@available(iOS 10.0, *)) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
            CDVPluginResult* pluginResult = success
                ? [CDVPluginResult resultWithStatus:CDVCommandStatus_OK]
                : [self permissionErrorResultWithCode:CtyVideoCaptureErrorOpenSettingsFailed message:@"Could not open app settings."];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
        }];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        BOOL success = [[UIApplication sharedApplication] openURL:url];
#pragma clang diagnostic pop
        CDVPluginResult* pluginResult = success
            ? [CDVPluginResult resultWithStatus:CDVCommandStatus_OK]
            : [self permissionErrorResultWithCode:CtyVideoCaptureErrorOpenSettingsFailed message:@"Could not open app settings."];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    }
}

- (void)getMediaModes:(CDVInvokedUrlCommand*)command
{
    // NSString* callbackId = [command argumentAtIndex:0];
    // NSMutableDictionary* imageModes = nil;
    NSArray* imageArray = nil;
    NSArray* movieArray = nil;
    NSArray* audioArray = nil;

    if ([UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) {
        // there is a camera, find the modes
        // can get image/jpeg or image/png from camera

        /* can't find a way to get the default height and width and other info
         * for images/movies taken with UIImagePickerController
         */
        NSDictionary* jpg = [NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithInt:0], kW3CMediaFormatHeight,
            [NSNumber numberWithInt:0], kW3CMediaFormatWidth,
            @"image/jpeg", kW3CMediaModeType,
            nil];
        NSDictionary* png = [NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithInt:0], kW3CMediaFormatHeight,
            [NSNumber numberWithInt:0], kW3CMediaFormatWidth,
            @"image/png", kW3CMediaModeType,
            nil];
        imageArray = [NSArray arrayWithObjects:jpg, png, nil];

        if ([UIImagePickerController respondsToSelector:@selector(availableMediaTypesForSourceType:)]) {
            NSArray* types = [UIImagePickerController availableMediaTypesForSourceType:UIImagePickerControllerSourceTypeCamera];

            if ([types containsObject:(NSString*)kUTTypeMovie]) {
                NSDictionary* mov = [NSDictionary dictionaryWithObjectsAndKeys:
                    [NSNumber numberWithInt:0], kW3CMediaFormatHeight,
                    [NSNumber numberWithInt:0], kW3CMediaFormatWidth,
                    @"video/quicktime", kW3CMediaModeType,
                    nil];
                movieArray = [NSArray arrayWithObject:mov];
            }
        }
    }
    NSDictionary* modes = [NSDictionary dictionaryWithObjectsAndKeys:
        imageArray ? (NSObject*)                          imageArray:[NSNull null], @"image",
        movieArray ? (NSObject*)                          movieArray:[NSNull null], @"video",
        audioArray ? (NSObject*)                          audioArray:[NSNull null], @"audio",
        nil];

    NSData* jsonData = [NSJSONSerialization dataWithJSONObject:modes options:0 error:nil];
    NSString* jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];

    NSString* jsString = [NSString stringWithFormat:@"navigator.device.capture.setSupportedModes(%@);", jsonStr];
    [self.commandDelegate evalJs:jsString];
}

- (void)getFormatData:(CDVInvokedUrlCommand*)command
{
    NSString* callbackId = command.callbackId;
    // existence of fullPath checked on JS side
    NSString* fullPath = [command argumentAtIndex:0];
    // mimeType could be null
    NSString* mimeType = nil;

    if ([command.arguments count] > 1) {
        mimeType = [command argumentAtIndex:1];
    }
    BOOL bError = NO;
    CDVCaptureError errorCode = CAPTURE_INTERNAL_ERR;
    CDVPluginResult* result = nil;

    if (!mimeType || [mimeType isKindOfClass:[NSNull class]]) {
        // try to determine mime type if not provided
        id command = [self.commandDelegate getCommandInstance:@"File"];
        bError = !([command isKindOfClass:[CDVFile class]]);
        if (!bError) {
            CDVFile* cdvFile = (CDVFile*)command;
            mimeType = [cdvFile getMimeTypeFromPath:fullPath];
            if (!mimeType) {
                // can't do much without mimeType, return error
                bError = YES;
                errorCode = CAPTURE_INVALID_ARGUMENT;
            }
        }
    }
    if (!bError) {
        // create and initialize return dictionary
        NSMutableDictionary* formatData = [NSMutableDictionary dictionaryWithCapacity:5];
        [formatData setObject:[NSNull null] forKey:kW3CMediaFormatCodecs];
        [formatData setObject:[NSNumber numberWithInt:0] forKey:kW3CMediaFormatBitrate];
        [formatData setObject:[NSNumber numberWithInt:0] forKey:kW3CMediaFormatHeight];
        [formatData setObject:[NSNumber numberWithInt:0] forKey:kW3CMediaFormatWidth];
        [formatData setObject:[NSNumber numberWithInt:0] forKey:kW3CMediaFormatDuration];

        if ([mimeType rangeOfString:@"image/"].location != NSNotFound) {
            UIImage* image = [UIImage imageWithContentsOfFile:fullPath];
            if (image) {
                CGSize imgSize = [image size];
                [formatData setObject:[NSNumber numberWithInteger:imgSize.width] forKey:kW3CMediaFormatWidth];
                [formatData setObject:[NSNumber numberWithInteger:imgSize.height] forKey:kW3CMediaFormatHeight];
            }
        } else if (([mimeType rangeOfString:@"video/"].location != NSNotFound) && (NSClassFromString(@"AVURLAsset") != nil)) {
            NSURL* movieURL = [NSURL fileURLWithPath:fullPath];
            AVURLAsset* movieAsset = [[AVURLAsset alloc] initWithURL:movieURL options:nil];
            CMTime duration = [movieAsset duration];
            [formatData setObject:[NSNumber numberWithFloat:CMTimeGetSeconds(duration)]  forKey:kW3CMediaFormatDuration];

            NSArray* allVideoTracks = [movieAsset tracksWithMediaType:AVMediaTypeVideo];
            if ([allVideoTracks count] > 0) {
                AVAssetTrack* track = [[movieAsset tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0];
                CGSize size = [track naturalSize];

                [formatData setObject:[NSNumber numberWithFloat:size.height] forKey:kW3CMediaFormatHeight];
                [formatData setObject:[NSNumber numberWithFloat:size.width] forKey:kW3CMediaFormatWidth];
                // not sure how to get codecs or bitrate???
                // AVMetadataItem
                // AudioFile
            } else {
                NSLog(@"No video tracks found for %@", fullPath);
            }
        } else if ([mimeType rangeOfString:@"audio/"].location != NSNotFound) {
            if (NSClassFromString(@"AVAudioPlayer") != nil) {
                NSURL* fileURL = [NSURL fileURLWithPath:fullPath];
                NSError* err = nil;

                AVAudioPlayer* avPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:fileURL error:&err];
                if (!err) {
                    // get the data
                    [formatData setObject:[NSNumber numberWithDouble:[avPlayer duration]] forKey:kW3CMediaFormatDuration];
                    if ([avPlayer respondsToSelector:@selector(settings)]) {
                        NSDictionary* info = [avPlayer settings];
                        NSNumber* bitRate = [info objectForKey:AVEncoderBitRateKey];
                        if (bitRate) {
                            [formatData setObject:bitRate forKey:kW3CMediaFormatBitrate];
                        }
                    }
                } // else leave data init'ed to 0
            }
        }
        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:formatData];
        // NSLog(@"getFormatData: %@", [formatData description]);
    }
    if (bError) {
        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageToErrorObject:(int)errorCode];
    }
    if (result) {
        [self.commandDelegate sendPluginResult:result callbackId:callbackId];
    }
}

- (NSDictionary*)getMediaDictionaryFromPath:(NSString*)fullPath ofType:(NSString*)type
{
    NSFileManager* fileMgr = [[NSFileManager alloc] init];
    NSMutableDictionary* fileDict = [NSMutableDictionary dictionaryWithCapacity:5];

    CDVFile *fs = [self.commandDelegate getCommandInstance:@"File"];

    // Get canonical version of localPath
    NSURL *fileURL = [NSURL URLWithString:[NSString stringWithFormat:@"file://%@", fullPath]];
    NSURL *resolvedFileURL = [fileURL URLByResolvingSymlinksInPath];
    NSString *path = [resolvedFileURL path];

    CDVFilesystemURL *url = [fs fileSystemURLforLocalPath:path];

    [fileDict setObject:[fullPath lastPathComponent] forKey:@"name"];
    [fileDict setObject:fullPath forKey:@"fullPath"];
    if (url) {
        [fileDict setObject:[url absoluteURL] forKey:@"localURL"];
    }
    // determine type
    if (!type) {
        id command = [self.commandDelegate getCommandInstance:@"File"];
        if ([command isKindOfClass:[CDVFile class]]) {
            CDVFile* cdvFile = (CDVFile*)command;
            NSString* mimeType = [cdvFile getMimeTypeFromPath:fullPath];
            [fileDict setObject:(mimeType != nil ? (NSObject*)mimeType : [NSNull null]) forKey:@"type"];
        }
    }
    NSDictionary* fileAttrs = [fileMgr attributesOfItemAtPath:fullPath error:nil];
    [fileDict setObject:[NSNumber numberWithUnsignedLongLong:[fileAttrs fileSize]] forKey:@"size"];
    NSDate* modDate = [fileAttrs fileModificationDate];
    NSNumber* msDate = [NSNumber numberWithDouble:[modDate timeIntervalSince1970] * 1000];
    [fileDict setObject:msDate forKey:@"lastModifiedDate"];

    return fileDict;
}

- (void)imagePickerController:(UIImagePickerController*)picker didFinishPickingImage:(UIImage*)image editingInfo:(NSDictionary*)editingInfo
{
    // older api calls new one
    [self imagePickerController:picker didFinishPickingMediaWithInfo:editingInfo];
}

/* Called when image/movie is finished recording.
 * Calls success or error code as appropriate
 * if successful, result  contains an array (with just one entry since can only get one image unless build own camera UI) of MediaFile object representing the image
 *      name
 *      fullPath
 *      type
 *      lastModifiedDate
 *      size
 */
- (void)imagePickerController:(UIImagePickerController*)picker didFinishPickingMediaWithInfo:(NSDictionary*)info
{
    NSLog(@"===== imagePickerController didFinishPickingMediaWithInfo START =====");
    [self disarmStopVideoFallback];
    self.isVideoRecording = NO;
    
    CDVImagePicker* cameraPicker = (CDVImagePicker*)picker;
    NSString* callbackId = cameraPicker.callbackId;
    // NOTE: Do NOT cleanup picker UI before processVideo. On ProRes-capable devices (iPhone 15 Pro+),
    // removing the child VC tears down the underlying AV hardware session before the export
    // completes, causing AVAssetExportSessionStatusCancelled. Cleanup happens after processing.

    CDVPluginResult* result = nil;

    UIImage* image = nil;
    NSString* mediaType = [info objectForKey:UIImagePickerControllerMediaType];
    if (!mediaType || [mediaType isEqualToString:(NSString*)kUTTypeImage]) {
        // mediaType is nil then only option is UIImagePickerControllerOriginalImage
        if ([UIImagePickerController respondsToSelector:@selector(allowsEditing)] &&
            (cameraPicker.allowsEditing && [info objectForKey:UIImagePickerControllerEditedImage])) {
            image = [info objectForKey:UIImagePickerControllerEditedImage];
        } else {
            image = [info objectForKey:UIImagePickerControllerOriginalImage];
        }
    }
    if (image != nil) {
        // mediaType was image — cleanup UI first (no AV session dependency)
        [self cleanupPickerControllerUI:picker];
        NSLog(@"didFinishPickingMediaWithInfo: 处理图像");
        result = [self processImage:image type:cameraPicker.mimeType forCallbackId:callbackId];
    } else if ([mediaType isEqualToString:(NSString*)kUTTypeMovie]
               || [mediaType isEqualToString:(NSString*)kUTTypeVideo]
               || [mediaType hasPrefix:@"public.movie"]
               || [mediaType hasPrefix:@"public.mpeg"]
               || [mediaType hasPrefix:@"com.apple.quicktime"]) {
        // process video — match both legacy kUTTypeMovie ("com.apple.quicktime-movie") and
        // newer UTType identifiers ("public.movie", "public.mpeg-4") returned on iOS 14+/26+.
        NSLog(@"didFinishPickingMediaWithInfo: mediaType=%@", mediaType);
        NSURL* mediaURL = [info objectForKey:UIImagePickerControllerMediaURL];
        NSString* moviePath = [mediaURL path];
        NSLog(@"didFinishPickingMediaWithInfo: 处理视频，路径=%@", moviePath);
        if (moviePath) {
            // Process video BEFORE cleaning up picker UI so ProRes hardware session stays alive
            result = [self processVideo:moviePath forCallbackId:callbackId];
        }
        // Now safe to cleanup picker UI — export session has completed (or failed)
        [self cleanupPickerControllerUI:picker];
    } else {
        [self cleanupPickerControllerUI:picker];
    }
    if (!result) {
        NSLog(@"didFinishPickingMediaWithInfo: 结果为空，返回错误");
        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageToErrorObject:CAPTURE_INTERNAL_ERR];
    }
    [self.commandDelegate sendPluginResult:result callbackId:callbackId];
    
    NSLog(@"didFinishPickingMediaWithInfo: 释放 pickerController");
    pickerController = nil;
    self.isVideoRecording = NO;
    self.inUse = NO;
    
    NSLog(@"===== imagePickerController didFinishPickingMediaWithInfo END =====");
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController*)picker
{
    NSLog(@"===== imagePickerControllerDidCancel START =====");
    [self disarmStopVideoFallback];
    self.isVideoRecording = NO;
    
    CDVImagePicker* cameraPicker = (CDVImagePicker*)picker;
    NSString* callbackId = cameraPicker.callbackId;
    [self cleanupPickerControllerUI:picker];

    CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageToErrorObject:CAPTURE_NO_MEDIA_FILES];
    [self.commandDelegate sendPluginResult:result callbackId:callbackId];
    
    NSLog(@"imagePickerControllerDidCancel: 释放 pickerController");
    pickerController = nil;
    self.isVideoRecording = NO;
    self.inUse = NO;
    
    NSLog(@"===== imagePickerControllerDidCancel END =====");
}

@end

@implementation CDVAudioNavigationController

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    // delegate to CVDAudioRecorderViewController
    return [self.topViewController supportedInterfaceOrientations];
}

@end

@interface CDVAudioRecorderViewController ()
@end

@implementation CDVAudioRecorderViewController
@synthesize errorCode, callbackId, duration, captureCommand, doneButton, recordingView, recordButton, recordImage, stopRecordImage, timerLabel, avRecorder, avSession, pluginResult, timer, isTimed;

- (NSString*)resolveImageResource:(NSString*)resource
{
    NSString* systemVersion = [[UIDevice currentDevice] systemVersion];
    BOOL isLessThaniOS4 = ([systemVersion compare:@"4.0" options:NSNumericSearch] == NSOrderedAscending);

    // the iPad image (nor retina) differentiation code was not in 3.x, and we have to explicitly set the path
    // if user wants iPhone only app to run on iPad they must remove *~ipad.* images from CtyVideoCaptureCordova.bundle
    if (isLessThaniOS4) {
        NSString* iPadResource = [NSString stringWithFormat:@"%@~ipad.png", resource];
        if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad && [UIImage imageNamed:iPadResource]) {
            return iPadResource;
        } else {
            return [NSString stringWithFormat:@"%@.png", resource];
        }
    }

    return resource;
}

- (id)initWithCommand:(CtyVideoCaptureCordova*)theCommand duration:(NSNumber*)theDuration callbackId:(NSString*)theCallbackId
{
    if ((self = [super init])) {
        self.captureCommand = theCommand;
        self.duration = theDuration;
        self.callbackId = theCallbackId;
        self.errorCode = CAPTURE_NO_MEDIA_FILES;
        self.isTimed = self.duration != nil;

        return self;
    }

    return nil;
}

- (void)loadView
{
	if ([self respondsToSelector:@selector(edgesForExtendedLayout)]) {
        self.edgesForExtendedLayout = UIRectEdgeNone;
    }

    // create view and display
    CGRect viewRect = [[UIScreen mainScreen] bounds];
    UIView* tmp = [[UIView alloc] initWithFrame:viewRect];

    // make backgrounds
    NSString* microphoneResource = @"CtyVideoCaptureCordova.bundle/microphone";

    BOOL isIphone5 = ([[UIScreen mainScreen] bounds].size.width == 568 && [[UIScreen mainScreen] bounds].size.height == 320) || ([[UIScreen mainScreen] bounds].size.height == 568 && [[UIScreen mainScreen] bounds].size.width == 320);
    if (isIphone5) {
        microphoneResource = @"CtyVideoCaptureCordova.bundle/microphone-568h";
    }

    NSBundle* cdvBundle = [NSBundle bundleForClass:[CtyVideoCaptureCordova class]];
    UIImage* microphone = [UIImage imageNamed:[self resolveImageResource:microphoneResource] inBundle:cdvBundle compatibleWithTraitCollection:nil];
    UIView* microphoneView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, viewRect.size.width, microphone.size.height)];
    [microphoneView setBackgroundColor:[UIColor colorWithPatternImage:microphone]];
    [microphoneView setUserInteractionEnabled:NO];
    [microphoneView setIsAccessibilityElement:NO];
    [tmp addSubview:microphoneView];

    // add bottom bar view
    UIImage* grayBkg = [UIImage imageNamed:[self resolveImageResource:@"CtyVideoCaptureCordova.bundle/controls_bg"] inBundle:cdvBundle compatibleWithTraitCollection:nil];
    UIView* controls = [[UIView alloc] initWithFrame:CGRectMake(0, microphone.size.height, viewRect.size.width, grayBkg.size.height)];
    [controls setBackgroundColor:[UIColor colorWithPatternImage:grayBkg]];
    [controls setUserInteractionEnabled:NO];
    [controls setIsAccessibilityElement:NO];
    [tmp addSubview:controls];

    // make red recording background view
    UIImage* recordingBkg = [UIImage imageNamed:[self resolveImageResource:@"CtyVideoCaptureCordova.bundle/recording_bg"] inBundle:cdvBundle compatibleWithTraitCollection:nil];
    UIColor* background = [UIColor colorWithPatternImage:recordingBkg];
    self.recordingView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, viewRect.size.width, recordingBkg.size.height)];
    [self.recordingView setBackgroundColor:background];
    [self.recordingView setHidden:YES];
    [self.recordingView setUserInteractionEnabled:NO];
    [self.recordingView setIsAccessibilityElement:NO];
    [tmp addSubview:self.recordingView];

    // add label
    self.timerLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, viewRect.size.width, recordingBkg.size.height)];
    // timerLabel.autoresizingMask = reSizeMask;
    [self.timerLabel setBackgroundColor:[UIColor clearColor]];
    [self.timerLabel setTextColor:[UIColor whiteColor]];
    [self.timerLabel setTextAlignment:NSTextAlignmentCenter];
    [self.timerLabel setText:@"0:00"];
    [self.timerLabel setAccessibilityHint:PluginLocalizedString(captureCommand, @"recorded time in minutes and seconds", nil)];
    self.timerLabel.accessibilityTraits |= UIAccessibilityTraitUpdatesFrequently;
    self.timerLabel.accessibilityTraits &= ~UIAccessibilityTraitStaticText;
    [tmp addSubview:self.timerLabel];

    // Add record button

    self.recordImage = [UIImage imageNamed:[self resolveImageResource:@"CtyVideoCaptureCordova.bundle/record_button"] inBundle:cdvBundle compatibleWithTraitCollection:nil];
    self.stopRecordImage = [UIImage imageNamed:[self resolveImageResource:@"CtyVideoCaptureCordova.bundle/stop_button"] inBundle:cdvBundle compatibleWithTraitCollection:nil];
    self.recordButton.accessibilityTraits |= [self accessibilityTraits];
    self.recordButton = [[UIButton alloc] initWithFrame:CGRectMake((viewRect.size.width - recordImage.size.width) / 2, (microphone.size.height + (grayBkg.size.height - recordImage.size.height) / 2), recordImage.size.width, recordImage.size.height)];
    [self.recordButton setAccessibilityLabel:PluginLocalizedString(captureCommand, @"toggle audio recording", nil)];
    [self.recordButton setImage:recordImage forState:UIControlStateNormal];
    [self.recordButton addTarget:self action:@selector(processButton:) forControlEvents:UIControlEventTouchUpInside];
    [tmp addSubview:recordButton];

    // make and add done button to navigation bar
    self.doneButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(dismissAudioView:)];
    [self.doneButton setStyle:UIBarButtonItemStyleDone];
    self.navigationItem.rightBarButtonItem = self.doneButton;

    [self setView:tmp];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil);
    NSError* error = nil;

    if (self.avSession == nil) {
        // create audio session
        self.avSession = [AVAudioSession sharedInstance];
        if (error) {
            // return error if can't create recording audio session
            NSLog(@"error creating audio session: %@", [[error userInfo] description]);
            self.errorCode = CAPTURE_INTERNAL_ERR;
            [self dismissAudioView:nil];
        }
    }

    // create file to record to in temporary dir

    NSString* docsPath = [NSTemporaryDirectory()stringByStandardizingPath];   // use file system temporary directory
    NSError* err = nil;
    NSFileManager* fileMgr = [[NSFileManager alloc] init];

    // generate unique file name
    NSString* filePath;
    int i = 1;
    do {
        filePath = [NSString stringWithFormat:@"%@/audio_%03d.wav", docsPath, i++];
    } while ([fileMgr fileExistsAtPath:filePath]);

    NSURL* fileURL = [NSURL fileURLWithPath:filePath isDirectory:NO];

    // create AVAudioPlayer
    NSDictionary *recordSetting = [[NSMutableDictionary alloc] init];
    self.avRecorder = [[AVAudioRecorder alloc] initWithURL:fileURL settings:recordSetting error:&err];
    if (err) {
        NSLog(@"Failed to initialize AVAudioRecorder: %@\n", [err localizedDescription]);
        self.avRecorder = nil;
        // return error
        self.errorCode = CAPTURE_INTERNAL_ERR;
        [self dismissAudioView:nil];
    } else {
        self.avRecorder.delegate = self;
        [self.avRecorder prepareToRecord];
        self.recordButton.enabled = YES;
        self.doneButton.enabled = YES;
    }
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    UIInterfaceOrientationMask orientation = UIInterfaceOrientationMaskPortrait;
    UIInterfaceOrientationMask supported = [captureCommand.viewController supportedInterfaceOrientations];

    orientation = orientation | (supported & UIInterfaceOrientationMaskPortraitUpsideDown);
    return orientation;
}

- (void)processButton:(id)sender
{
    if (self.avRecorder.recording) {
        // stop recording
        [self.avRecorder stop];
        self.isTimed = NO;  // recording was stopped via button so reset isTimed
        // view cleanup will occur in audioRecordingDidFinishRecording
    } else {
        // begin recording
        [self.recordButton setImage:stopRecordImage forState:UIControlStateNormal];
        self.recordButton.accessibilityTraits &= ~[self accessibilityTraits];
        [self.recordingView setHidden:NO];
        __block NSError* error = nil;

        __weak CDVAudioRecorderViewController* weakSelf = self;

        void (^startRecording)(void) = ^{
            [weakSelf.avSession setCategory:AVAudioSessionCategoryRecord error:&error];
            [weakSelf.avSession setActive:YES error:&error];
            if (error) {
                // can't continue without active audio session
                weakSelf.errorCode = CAPTURE_INTERNAL_ERR;
                [weakSelf dismissAudioView:nil];
            } else {
                if (weakSelf.duration) {
                    weakSelf.isTimed = true;
                    [weakSelf.avRecorder recordForDuration:[weakSelf.duration doubleValue]];
                } else {
                    [weakSelf.avRecorder record];
                }
                [weakSelf.timerLabel setText:@"0.00"];
                weakSelf.timer = [NSTimer scheduledTimerWithTimeInterval:0.5f target:weakSelf selector:@selector(updateTime) userInfo:nil repeats:YES];
                weakSelf.doneButton.enabled = NO;
            }
            UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, nil);
        };

        SEL rrpSel = NSSelectorFromString(@"requestRecordPermission:");
        if ([self.avSession respondsToSelector:rrpSel])
        {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [self.avSession performSelector:rrpSel withObject:^(BOOL granted){
                if (granted) {
                    startRecording();
                } else {
                    NSLog(@"Error creating audio session, microphone permission denied.");
                    weakSelf.errorCode = CAPTURE_INTERNAL_ERR;
                    [weakSelf dismissAudioView:nil];
                }
            }];
#pragma clang diagnostic pop
        } else {
            startRecording();
        }
    }
}

/*
 * helper method to clean up when stop recording
 */
- (void)stopRecordingCleanup
{
    if (self.avRecorder.recording) {
        [self.avRecorder stop];
    }
    [self.recordButton setImage:recordImage forState:UIControlStateNormal];
    self.recordButton.accessibilityTraits |= [self accessibilityTraits];
    [self.recordingView setHidden:YES];
    self.doneButton.enabled = YES;
    if (self.avSession) {
        // deactivate session so sounds can come through
        [self.avSession setCategory:AVAudioSessionCategoryPlayAndRecord error:nil];
        [self.avSession setActive:NO error:nil];
    }
    if (self.duration && self.isTimed) {
        // VoiceOver announcement so user knows timed recording has finished
        //BOOL isUIAccessibilityAnnouncementNotification = (&UIAccessibilityAnnouncementNotification != NULL);
        if (UIAccessibilityAnnouncementNotification) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500ull * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, PluginLocalizedString(self->captureCommand, @"timed recording complete", nil));
                });
        }
    } else {
        // issue a layout notification change so that VO will reannounce the button label when recording completes
        UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, nil);
    }
}

- (void)dismissAudioView:(id)sender
{
    // called when done button pressed or when error condition to do cleanup and remove view
    [[self.captureCommand.viewController.presentedViewController presentingViewController] dismissViewControllerAnimated:YES completion:nil];

    if (!self.pluginResult) {
        // return error
        self.pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageToErrorObject:(int)self.errorCode];
    }

    self.avRecorder = nil;
    [self.avSession setCategory:AVAudioSessionCategoryPlayAndRecord error:nil];
    [self.avSession setActive:NO error:nil];
    [self.captureCommand setInUse:NO];
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil);
    // return result
    [self.captureCommand.commandDelegate sendPluginResult:pluginResult callbackId:callbackId];
}

- (void)updateTime
{
    // update the label with the elapsed time
    [self.timerLabel setText:[self formatTime:self.avRecorder.currentTime]];
}

- (NSString*)formatTime:(int)interval
{
    // is this format universal?
    int secs = interval % 60;
    int min = interval / 60;

    if (interval < 60) {
        return [NSString stringWithFormat:@"0:%02d", interval];
    } else {
        return [NSString stringWithFormat:@"%d:%02d", min, secs];
    }
}

- (void)audioRecorderDidFinishRecording:(AVAudioRecorder*)recorder successfully:(BOOL)flag
{
    // may be called when timed audio finishes - need to stop time and reset buttons
    [self.timer invalidate];
    [self stopRecordingCleanup];

    // generate success result
    if (flag) {
        NSString* filePath = [avRecorder.url path];
        // NSLog(@"filePath: %@", filePath);
        NSDictionary* fileDict = [captureCommand getMediaDictionaryFromPath:filePath ofType:@"audio/wav"];
        NSArray* fileArray = [NSArray arrayWithObject:fileDict];

        self.pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:fileArray];
    } else {
        self.pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageToErrorObject:CAPTURE_INTERNAL_ERR];
    }
}

- (void)audioRecorderEncodeErrorDidOccur:(AVAudioRecorder*)recorder error:(NSError*)error
{
    [self.timer invalidate];
    [self stopRecordingCleanup];

    NSLog(@"error recording audio");
    self.pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageToErrorObject:CAPTURE_INTERNAL_ERR];
    [self dismissAudioView:nil];
}

@end
