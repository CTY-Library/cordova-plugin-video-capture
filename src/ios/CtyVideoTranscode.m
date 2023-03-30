//
//  VideoEditor.m
//
//  Created by Josh Bavari on 01-14-2014
//  Modified by Ross Martin on 01-29-2015
//

#import <Cordova/CDV.h>
#import "CtyVideoTranscode.h"
#import "CtyAVAssetExportSession.h"

@interface CtyVideoTranscode ()

@end

@implementation CtyVideoTranscode

 
/**
 * transcodeVideo
 *
 * Transcodes a video
 *
 * ARGUMENTS
 * =========
 *
 * fileUri              - path to input video
 * outputFileName       - output file name
 * quality              - transcode quality
 * outputFileType       - output file type
 * saveToLibrary        - save to gallery
 * maintainAspectRatio  - make the output aspect ratio match the input video
 * width                - width for the output video
 * height               - height for the output video
 * videoBitrate         - video bitrate for the output video in bits
 * audioChannels        - number of audio channels for the output video
 * audioSampleRate      - sample rate for the audio (samples per second)
 * audioBitrate         - audio bitrate for the output video in bits
 *
 * RESPONSE
 * ========
 *
 * outputFilePath - path to output file
 *
 * @param CDVInvokedUrlCommand command
 * @return void
 */
- ( NSString * ) transcodeVideo:( NSString *) inputFilePath
         videoFileName : (NSString *) videoFileName
{

    
    if(self.videoBitrate==0){
        self.videoBitrate= 2000000;
    }
    if(self.audioChannels==0){
        self.audioChannels=2;
    }
    if(self.audioSampleRate==0){
        self.audioSampleRate=44100;
    }
    if(self.audioBitrate==0){
        self.audioBitrate=128000;
    } 
    NSURL *inputFileURL = [self getURLFromFilePath:inputFilePath];
    
  
    NSString *stringOutputFileType = Nil;
    NSString *outputExtension = Nil;

    switch (self.outputFileType) {
        case QUICK_TIME:
            stringOutputFileType = AVFileTypeQuickTimeMovie;
            outputExtension = @".mov";
            break;
        case M4A:
            stringOutputFileType = AVFileTypeAppleM4A;
            outputExtension = @".m4a";
            break;
        case M4V:
            stringOutputFileType = AVFileTypeAppleM4V;
            outputExtension = @".m4v";
            break;
        case MPEG4:
        default:
            stringOutputFileType = AVFileTypeMPEG4;
            outputExtension = @".mp4";
            break;
    }

    // check if the video can be saved to photo album before going further
    if (self.saveToPhotoAlbum && !UIVideoAtPathIsCompatibleWithSavedPhotosAlbum([inputFileURL path]))
    {
        NSString *error = @"Video cannot be saved to photo album";
//        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error ] callbackId:command.callbackId];
        return @"";
    }

    AVURLAsset *avAsset = [AVURLAsset URLAssetWithURL:inputFileURL options:nil];

    NSString *cacheDir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    NSString *outputPath = [NSString stringWithFormat:@"%@/%@%@", cacheDir, videoFileName, outputExtension];
    NSURL *outputURL = [NSURL fileURLWithPath:outputPath];

    NSArray *tracks = [avAsset tracksWithMediaType:AVMediaTypeVideo];
    AVAssetTrack *track = [tracks objectAtIndex:0];
    CGSize mediaSize = track.naturalSize;

    float videoWidth = mediaSize.width;
    float videoHeight = mediaSize.height;
    int newWidth;
    int newHeight;

    if (self.maintainAspectRatio) {
        float aspectRatio = videoWidth / videoHeight;

        // for some portrait videos ios gives the wrong width and height, this fixes that
        NSString *videoOrientation = [self getOrientationForTrack:avAsset];
        if ([videoOrientation isEqual: @"portrait"]) {
            if (videoWidth > videoHeight) {
                videoWidth = mediaSize.height;
                videoHeight = mediaSize.width;
                aspectRatio = videoWidth / videoHeight;
            }
        }

        newWidth = (self.width && self.height) ? self.height * aspectRatio : videoWidth;
        newHeight = (self.width && self.height) ? newWidth / aspectRatio : videoHeight;
    } else {
        newWidth = (self.width && self.height) ? self.width : videoWidth;
        newHeight = (self.width && self.height) ? self.height : videoHeight;
    }

    NSLog(@"input videoWidth: %f", videoWidth);
    NSLog(@"input videoHeight: %f", videoHeight);
    NSLog(@"output newWidth: %d", newWidth);
    NSLog(@"output newHeight: %d", newHeight);

    CtyAVAssetExportSession *encoder = [CtyAVAssetExportSession.alloc initWithAsset:avAsset];
    encoder.outputFileType = stringOutputFileType;
    encoder.outputURL = outputURL;
    encoder.shouldOptimizeForNetworkUse = self.optimizeForNetworkUse;
    encoder.videoSettings = @
    {
        AVVideoCodecKey: AVVideoCodecH264,
        AVVideoWidthKey: [NSNumber numberWithInt: newWidth],
        AVVideoHeightKey: [NSNumber numberWithInt: newHeight],
        AVVideoCompressionPropertiesKey: @
        {
            AVVideoAverageBitRateKey: [NSNumber numberWithInt: self.videoBitrate],
            AVVideoProfileLevelKey: AVVideoProfileLevelH264High40
        }
    };
    encoder.audioSettings = @
    {
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVNumberOfChannelsKey: [NSNumber numberWithInt: self.audioChannels],
        AVSampleRateKey: [NSNumber numberWithInt: self.audioSampleRate],
        AVEncoderBitRateKey: [NSNumber numberWithInt: self.audioBitrate]
    };

    /* // setting timeRange is not possible due to a bug with CtyAVAssetExportSession (https://github.com/rs/CtyAVAssetExportSession/issues/28)
     if (videoDuration) {
     int32_t preferredTimeScale = 600;
     CMTime startTime = CMTimeMakeWithSeconds(0, preferredTimeScale);
     CMTime stopTime = CMTimeMakeWithSeconds(videoDuration, preferredTimeScale);
     CMTimeRange exportTimeRange = CMTimeRangeFromTimeToTime(startTime, stopTime);
     encoder.timeRange = exportTimeRange;
     }
     */

    //  Set up a semaphore for the completion handler and progress timer
    dispatch_semaphore_t sessionWaitSemaphore = dispatch_semaphore_create(0);

    void (^completionHandler)(void) = ^(void)
    {
        dispatch_semaphore_signal(sessionWaitSemaphore);
    };

    // do it

    //[self.commandDelegate runInBackground:^{
        [encoder exportAsynchronouslyWithCompletionHandler:completionHandler];

        do {
            dispatch_time_t dispatchTime = DISPATCH_TIME_FOREVER;  // if we dont want progress, we will wait until it finishes.
            dispatchTime = getDispatchTimeFromSeconds((float)1.0);
            double progress = [encoder progress] * 100;

            NSMutableDictionary *dictionary = [[NSMutableDictionary alloc] init];
            [dictionary setValue: [NSNumber numberWithDouble: progress] forKey: @"progress"];

            CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary: dictionary];

            [result setKeepCallbackAsBool:YES];
           // [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            dispatch_semaphore_wait(sessionWaitSemaphore, dispatchTime);
        } while( [encoder status] < AVAssetExportSessionStatusCompleted );

        // this is kinda odd but must be done
        if ([encoder status] == AVAssetExportSessionStatusCompleted) {
            NSMutableDictionary *dictionary = [[NSMutableDictionary alloc] init];
            // AVAssetExportSessionStatusCompleted will not always mean progress is 100 so hard code it below
            double progress = 100.00;
            [dictionary setValue: [NSNumber numberWithDouble: progress] forKey: @"progress"];

            CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary: dictionary];

            [result setKeepCallbackAsBool:YES];
           // [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        }

        if (encoder.status == AVAssetExportSessionStatusCompleted)
        {
            NSLog(@"Video export succeeded");
            if (self.saveToPhotoAlbum) {
                UISaveVideoAtPathToSavedPhotosAlbum(outputPath, self, nil, nil);
            }
           // [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:outputPath] callbackId:command.callbackId];
            return outputPath;
        }
        else if (encoder.status == AVAssetExportSessionStatusCancelled)
        {
            NSLog(@"Video export cancelled");
           // [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Video export cancelled"] callbackId:command.callbackId];
        }
        else
        {
            NSString *error = [NSString stringWithFormat:@"Video export failed with error: %@ (%ld)", encoder.error.localizedDescription, (long)encoder.error.code];
           // [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error] callbackId:command.callbackId];
        }
    //}];
    return @"";
}
 

// inspired by http://stackoverflow.com/a/6046421/1673842
- (NSString*)getOrientationForTrack:(AVAsset *)asset
{
    AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0];
    CGSize size = [videoTrack naturalSize];
    CGAffineTransform txf = [videoTrack preferredTransform];

    if (size.width == txf.tx && size.height == txf.ty)
        return @"landscape";
    else if (txf.tx == 0 && txf.ty == 0)
        return @"landscape";
    else if (txf.tx == 0 && txf.ty == size.width)
        return @"portrait";
    else
        return @"portrait";
}

- (NSURL*)getURLFromFilePath:(NSString*)filePath
{
    if ([filePath containsString:@"assets-library://"]) {
        return [NSURL URLWithString:[filePath stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
    } else if ([filePath containsString:@"file://"]) {
        return [NSURL URLWithString:[filePath stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
    }

    return [NSURL fileURLWithPath:[filePath stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
}

static dispatch_time_t getDispatchTimeFromSeconds(float seconds) {
    long long milliseconds = seconds * 1000.0;
    dispatch_time_t waitTime = dispatch_time( DISPATCH_TIME_NOW, 1000000LL * milliseconds );
    return waitTime;
}

@end
