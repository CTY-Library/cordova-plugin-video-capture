//
//  VideoEditor.h
//
//  Created by Josh Bavari on 01-14-2014
//  Modified by Ross Martin on 01-29-2015
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AssetsLibrary/ALAssetsLibrary.h>
#import <MediaPlayer/MediaPlayer.h>

#import <Cordova/CDV.h>

enum CDVOutputFileType {
    M4V = 0,
    MPEG4 = 1,
    M4A = 2,
    QUICK_TIME = 3
};
typedef NSUInteger CDVOutputFileType;

@interface CtyVideoTranscode  : NSObject

@property (nonatomic, copy) NSString *inputFilePath;
@property (nonatomic, copy) NSString *videoFileName;
@property (nonatomic, assign) CDVOutputFileType outputFileType;
@property (nonatomic, assign) BOOL optimizeForNetworkUse;
@property (nonatomic, assign) BOOL saveToPhotoAlbum;
@property (nonatomic, assign) BOOL maintainAspectRatio;
@property (nonatomic, assign) float width;
@property (nonatomic, assign) float height;
@property (nonatomic, assign) int videoBitrate ;
@property (nonatomic, assign) int audioChannels ;
@property (nonatomic, assign) int audioSampleRate;
@property (nonatomic, assign) int audioBitrate;

- (NSString *)transcodeVideo: ( NSString *) inputFilePath
videoFileName : (NSString *) videoFileName;
 
 

@end
