package com.cty.CtyVideoCapture;

import org.apache.cordova.CordovaPlugin;
import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaWebView;
import org.apache.cordova.PluginManager;
import org.apache.cordova.PluginResult;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.ContextWrapper;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.app.FragmentManager;
import android.app.FragmentTransaction;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.os.Handler;
import android.hardware.Camera;
import android.hardware.camera2.CameraAccessException;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraManager;
import android.util.DisplayMetrics;
import android.util.Log;
import android.util.Size;
import android.util.SizeF;
import android.util.TypedValue;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewParent;
import android.widget.FrameLayout;

import org.apache.cordova.file.FileUtils;
import org.apache.cordova.file.LocalFilesystemURL;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.List;
import java.util.Arrays;

/**
 * This class echoes a string called from JavaScript.
 */
public class CtyVideoCaptureCordova extends CordovaPlugin {

  private static CallbackContext execingCallbackContext;
  private static int previewFragmentId = 1231231;
  private static CordovaWebView mCordovaWebView;

  private CtyVideoConfigOption configOption;
  private CtyVideoCaptureFragment mCtyVideoCaptureFragment;
  private int containerViewId = 12312321;
  private ViewParent mViewParent;

  public CtyVideoCaptureCordova() {
    super();
  }

  @Override
  public boolean execute(String action, JSONArray args, CallbackContext callbackContext) throws JSONException {

    if (action.equals("captureVideo")) {
      Log.d("CtyVideoCapture", "execute: captureVideo 被调用");
      execingCallbackContext = callbackContext;
      JSONObject options = args.optJSONObject(0);
      if (options == null) {
        options = new JSONObject();
      }

      final JSONObject finalOptions = options;
      PluginResult pendingResult = new PluginResult(PluginResult.Status.NO_RESULT);
      pendingResult.setKeepCallback(true);
      callbackContext.sendPluginResult(pendingResult);

      cordova.getThreadPool().execute(new Runnable() {
        @Override
        public void run() {
          try {
            Log.d("CtyVideoCapture", "线程池: 开始初始化配置");
            configOption = new CtyVideoConfigOption(finalOptions, callbackContext);
            Log.d("CtyVideoCapture", "线程池: 配置初始化完成，检查权限");
            if (allPermissionsGranted()) {
              Log.d("CtyVideoCapture", "所有权限已授予，开始初始化 Fragment");
              initFragment(configOption, callbackContext);
            } else {
              Log.d("CtyVideoCapture", "权限未授予，请求权限");
              cordova.getActivity().runOnUiThread(new Runnable() {
                @Override
                public void run() {
                  Log.d("CtyVideoCapture", "UI线程: 请求权限");
                  cordova.requestPermissions(CtyVideoCaptureCordova.this, Configuration.REQUEST_CODE_PERMISSIONS,
                    Configuration.REQUIRED_PERMISSIONS);
                }
              });
            }
          } catch (Exception e) {
            Log.e("CtyVideoCapture", "execute 异常: " + e.getMessage(), e);
            callbackContext.error("captureVideo 参数解析失败: " + e.getMessage());
          }
        }
      });

      return true;
    } else if (action.equals("stopVideoCapture")) {
      cordova.getThreadPool().execute(new Runnable() {
        @Override
        public void run() {
          try {
            endVideoCapture(callbackContext);
          } catch (JSONException e) {
            callbackContext.error("stopVideoCapture 执行失败: " + e.getMessage());
          }
        }
      });
      return true;
    } else if (action.equals("startVideoCapture")) {
      cordova.getThreadPool().execute(new Runnable() {
        @Override
        public void run() {
          recordVideo(callbackContext);
        }
      });
      return true;
    } else if (action.equals("selectCamera")) {
      selectCamera(callbackContext);
      return true;
    }
    return false;
  }



  private void initFragment(CtyVideoConfigOption configOption, CallbackContext callbackContext) {
    Log.d("CtyVideoCapture", "initFragment: 开始初始化");
    CtyVideoCaptureFragment.Durantion = 0;//configOption.Duration;
    CtyVideoCaptureFragment.mAppContext = cordova.getContext();

    mCtyVideoCaptureFragment = null;
    if (mCtyVideoCaptureFragment == null) {
      Log.d("CtyVideoCapture", "initFragment: 创建新的 Fragment");
      mCtyVideoCaptureFragment = new CtyVideoCaptureFragment();
      mCtyVideoCaptureFragment.setInputParams(configOption);
      cordova.getActivity().runOnUiThread(new Runnable() {

        @Override
        public void run() {
          Log.d("CtyVideoCapture", "initFragment UI线程: 开始添加 Fragment 到容器");
          // create or update the layout params for the container view
          FrameLayout containerView = (FrameLayout) cordova.getActivity().findViewById(containerViewId);
          if (containerView == null) {
            Log.d("CtyVideoCapture", "initFragment: 创建容器 FrameLayout");
            containerView = new FrameLayout(cordova.getActivity().getApplicationContext());
            containerView.setId(containerViewId);

            FrameLayout.LayoutParams containerLayoutParams = new FrameLayout.LayoutParams(
              FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT);
            cordova.getActivity().addContentView(containerView, containerLayoutParams);
          }

          View view = webView.getView();
          ViewParent rootParent = containerView.getParent();
          ViewParent curParent = view.getParent();
          view.setBackgroundColor(0x00000000);

          if (curParent.getParent() != rootParent) {
            while (curParent != null && curParent.getParent() != rootParent) {
              curParent = curParent.getParent();
            }

            if (curParent != null) {
              ((ViewGroup) curParent).setBackgroundColor(0x00000000);
              ((ViewGroup) curParent).bringToFront();
            } else {
              // Do default...
              curParent = view.getParent();
              mViewParent = curParent;
              ((ViewGroup) view).bringToFront();
            }
          } else {
            // Default
            mViewParent = curParent;
            ((ViewGroup) curParent).bringToFront();
          }

          FragmentManager fragmentManager = cordova.getActivity().getFragmentManager();
          FragmentTransaction fragmentTransaction = fragmentManager.beginTransaction();
          Log.d("CtyVideoCapture", "initFragment: 执行 Fragment 事务");
          fragmentTransaction.add(containerView.getId(), mCtyVideoCaptureFragment);
          fragmentTransaction.commit();
          Log.d("CtyVideoCapture", "initFragment: Fragment 初始化完成");
        }
      });
    }
    //callbackContext.success("success");
  }


  private void recordVideo(CallbackContext callbackContext) {
    // execingCallbackContext=callbackContext;
    mCordovaWebView=this.webView;
    if (mCtyVideoCaptureFragment.CtyVideoCaptureHelper == null) {
      callbackContext.error("请先执行init进行初始化");
      return;
    }
    mCtyVideoCaptureFragment.CtyVideoCaptureHelper.startRecorder();
    callbackContext.success("success");
   // CallJS(new CtyVideoCaptureChannelMessage("start", true,"success"));
  }

  private void endVideoCapture(CallbackContext callbackContext) throws JSONException {
    //execingCallbackContext=callbackContext;
    if (mCtyVideoCaptureFragment.CtyVideoCaptureHelper == null) {
      callbackContext.error("请先执行init进行初始化");
      return;
    }
   mCtyVideoCaptureFragment.CtyVideoCaptureHelper.stopRecorder();
   callbackContext.success("success");

  }


  private void selectCamera(CallbackContext callbackContext) {
    if (mCtyVideoCaptureFragment.CtyVideoCaptureHelper == null) {
      callbackContext.error("请先执行init进行初始化");
    }
    mCtyVideoCaptureFragment.CtyVideoCaptureHelper.exchangeCamera();
    callbackContext.success("success");
  }

  @Override
  public void onRequestPermissionResult(int requestCode, String[] permissions, int[] grantResults)
    throws JSONException {
    Log.d("CtyVideoCapture", "onRequestPermissionResult: requestCode=" + requestCode + ", permissions=" + Arrays.toString(permissions));
    for (int i = 0; i < grantResults.length; i++) {
      if (grantResults[i] == PackageManager.PERMISSION_DENIED) {
        String deniedPermission = (permissions != null && i < permissions.length) ? permissions[i] : "unknown";

        // Android 10+ 对应用私有目录写入不再需要 WRITE_EXTERNAL_STORAGE，拒绝后继续初始化
        if (Manifest.permission.WRITE_EXTERNAL_STORAGE.equals(deniedPermission)
          && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
          Log.w("CtyVideoCapture", "WRITE_EXTERNAL_STORAGE 被拒绝，但在 Android 10+ 可忽略");
          continue;
        }

        Log.e("CtyVideoCapture", "权限被拒绝: " + deniedPermission);
        execingCallbackContext.sendPluginResult(new PluginResult(PluginResult.Status.ILLEGAL_ACCESS_EXCEPTION));
        return;
      }
    }

    if (requestCode == Configuration.REQUEST_CODE_PERMISSIONS) {
      Log.d("CtyVideoCapture", "所有权限已授予，初始化 Fragment");
      this.initFragment(configOption, execingCallbackContext);
    } else {
      Log.w("CtyVideoCapture", "未知的请求代码: " + requestCode);
    }
  }

  private boolean allPermissionsGranted() {
    for (String permission : Configuration.REQUIRED_PERMISSIONS) {
      if (!cordova.hasPermission(permission)) {
        return false;
      }
    }
    return true;
  }

  static class Configuration {
    public static final String TAG = "video";
    public static final String FILENAME_FORMAT = "yyyyMMdd_HHmmss_SSS";
    public static final int REQUEST_CODE_PERMISSIONS = 10;
    public static final int REQUEST_AUDIO_CODE_PERMISSIONS = 12;
    public static final String[] REQUIRED_PERMISSIONS = Build.VERSION.SDK_INT >= Build.VERSION_CODES.M
      ? (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
      ? new String[] { Manifest.permission.CAMERA,
      Manifest.permission.RECORD_AUDIO
    }
      : new String[] { Manifest.permission.CAMERA,
      Manifest.permission.RECORD_AUDIO,
      Manifest.permission.WRITE_EXTERNAL_STORAGE
    })
      : new String[] { Manifest.permission.CAMERA,
      Manifest.permission.RECORD_AUDIO };

    public static File CreateFile(boolean saveToPhotoAlbum, Context context, String extension) {
      try {
        String outputFileName = new SimpleDateFormat(Configuration.FILENAME_FORMAT).format(new Date());
        String tempFileName = outputFileName + extension;
        if (saveToPhotoAlbum) {
          final PackageManager pm = context.getPackageManager();
          ApplicationInfo ai;
          try {
            ai = pm.getApplicationInfo(context.getPackageName(), 0);
          } catch (final PackageManager.NameNotFoundException e) {
            ai = null;
          }
          final String appName = (String) (ai != null ? pm.getApplicationLabel(ai) : "Unknown");
          File mediaStorageDir = GetMediaStorageDir("DCIM",appName);
          if(mediaStorageDir==null){
            mediaStorageDir = GetMediaStorageDir("Movies",appName);
          }
          
          if (mediaStorageDir == null) {
            Log.e(Configuration.TAG, "无法获取外部存储目录，尝试使用缓存目录");
            // 降级到缓存目录
            File cacheDir = context.getExternalCacheDir();
            if (cacheDir != null && cacheDir.exists()) {
              return new File(cacheDir, tempFileName);
            }
            return null;
          }
          
          File targetFile = new File(mediaStorageDir.getPath(), tempFileName);
          return targetFile;
        } else {
          File cacheDir = context.getExternalCacheDir();
          if (cacheDir == null) {
            Log.e(Configuration.TAG, "getExternalCacheDir() 返回 null，尝试使用内部缓存目录");
            cacheDir = context.getCacheDir();
          }
          
          if (cacheDir != null) {
            if (!cacheDir.exists()) {
              cacheDir.mkdirs();
            }
            String filePath = cacheDir.getAbsolutePath() + File.separator + tempFileName;
            File targetFile = new File(filePath);
            return targetFile;
          }
          
          Log.e(Configuration.TAG, "无法创建缓存文件");
          return null;
        }
      } catch (Exception e) {
        Log.e(Configuration.TAG, "CreateFile 异常: " + e.getMessage(), e);
        e.printStackTrace();
        return null;
      }
    }

    private static File GetMediaStorageDir(String parent,String child){
      try {
        File mediaStorageDir = new File(Environment.getExternalStorageDirectory() + "/" + parent, child);
        Log.d(Configuration.TAG, "尝试使用目录: " + mediaStorageDir.getAbsolutePath());
        
        if (!mediaStorageDir.exists()) {
          if (!mediaStorageDir.mkdirs()) {
            Log.w(Configuration.TAG, "无法创建目录: " + mediaStorageDir.getAbsolutePath());
            // 尝试使用父目录
            mediaStorageDir = new File(Environment.getExternalStorageDirectory() + "/" + parent);
            if (!mediaStorageDir.exists()) {
              Log.e(Configuration.TAG, "父目录也不存在: " + mediaStorageDir.getAbsolutePath());
              return null;
            }
            Log.d(Configuration.TAG, "使用父目录: " + mediaStorageDir.getAbsolutePath());
          }
        }
        return mediaStorageDir;
      } catch (Exception e) {
        Log.e(Configuration.TAG, "GetMediaStorageDir 异常: " + e.getMessage(), e);
        return null;
      }
    }

  }

  public static void CallJSMsg(JSONArray message) {
    if (execingCallbackContext != null) {
      PluginResult dataResult = new PluginResult(PluginResult.Status.OK, message);
      dataResult.setKeepCallback(true);// 非常重要
      execingCallbackContext.sendPluginResult(dataResult);
    }
  }



  public static JSONArray GetMediaFileInfo(File fileData) throws JSONException {
    JSONObject obj = new JSONObject();
    try {
      // File properties
      obj.put("name", fileData.getName());
      obj.put("fullPath", Uri.fromFile(fileData));
      obj.put("lastModifiedDate", fileData.lastModified());
      obj.put("size", fileData.length());
    } catch (JSONException e) {
      // this will never happen
      e.printStackTrace();
    }
    JSONArray result = new JSONArray();
    result.put(obj);
    return result;
  }
}
