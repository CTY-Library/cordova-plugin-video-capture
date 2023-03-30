/*
 *
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 *
 */

var exec = require('cordova/exec');


var CtyVideoCaptureCordova = {
    //悬浮播放视频  
    captureVideo: function(
        success,
        error,
        cfgOptions
    ) {
         
        if(!cfgOptions){      
            cfgOptions =  {   
                 // Upper limit of videos user can record. Value must be equal or greater than 1.  
                limit : 1,
                // Maximum duration of a single video clip in seconds.
                duration : 0,             
                is_front : "0", // 默认后置摄像头 
                outputFileType : 1,  // 1 : mp4 , 2 : mov
                optimizeForNetworkUse : true, //only ios 压缩
                saveToPhotoAlbum : true, //only ios 保存到相册, 安卓还未实现   //todo android
                maintainAspectRatio : true, //  保持长宽比不变  //todo android
                width : 0,
                height : 0,
                videoBitrate : 0, //码率
                audioChannels : 2,//通道
                audioSampleRate : 44100, //样本率
                audioBitrate : 64*1024, //比特率
                videoFrameRate : 24, //only android,帧数
            };
        }

        cordova.require('cordova/channel').onCordovaReady.subscribe(function(){
            exec(success, error, 'CtyVideoCaptureCordova', 'captureVideo', [cfgOptions]);
        });
    }, 
    startVideoCapture: function(
        success,
        error
    ) {
        exec(success, error, 'CtyVideoCaptureCordova', 'startVideoCapture', ['']);
    },
    stopVideoCapture: function(
        success,
        error        
    ) {
        exec(success, error, 'CtyVideoCaptureCordova', 'stopVideoCapture', ['']);
    } 
}

module.exports = CtyVideoCaptureCordova

 
