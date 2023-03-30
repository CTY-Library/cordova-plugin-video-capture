package huayu.cordova.plugin.videocapture;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.LOG;
import org.apache.cordova.PluginResult;

import android.os.Bundle;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

public class CtyVideoConfigOption {

    public String is_front = "0" ;// 0默认后置摄像头
    public int duration=15;
    public int outputFileType = 1;  // 1 : mp4 , 2 : mov
    public boolean optimizeForNetworkUse = true; //only ios 压缩
    public boolean saveToPhotoAlbum = true; //only ios 保存到相册, 安卓还未实现   //todo android
    public boolean maintainAspectRatio = true; //  保持长宽比不变  //todo android
    public int width = 0;
    public int height = 0;
    public int videoBitrate = 0; //码率
    public int audioChannels =2 ;//通道
    public int audioSampleRate = 44100; //样本率
    public int audioBitrate = 64*1024; //比特率
    public int videoFrameRate = 24; //only android,帧数



    public CallbackContext callbackContext;

    public CtyVideoConfigOption(JSONObject options, CallbackContext callbackContext)throws JSONException {
        this.callbackContext= callbackContext;

    }


    public  CtyVideoConfigOption(int height,int width,int duration, CallbackContext callbackContext){

      this.callbackContext= callbackContext;
    }
}

