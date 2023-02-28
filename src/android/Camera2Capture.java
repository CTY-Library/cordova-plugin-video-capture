package huayu.cordova.plugin.camera2capture;

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
public class Camera2Capture extends CordovaPlugin {

  private static CallbackContext execingCallbackContext;
  private static int previewFragmentId = 1231231;
  private static CordovaWebView mCordovaWebView;

  private Camera2ConfigOption configOption;
  private Camera2CaptureFragment mCamera2CaptureFragment;
  private int containerViewId = 12312321;
  private ViewParent mViewParent;

  public Camera2Capture() {
    super();
  }

  @Override
  public boolean execute(String action, JSONArray args, CallbackContext callbackContext) throws JSONException {

    if (action.equals("captureVideo")) {
      execingCallbackContext = callbackContext;
      // JSONObject options = args.optJSONObject(0);
      // configOption = new Camera2ConfigOption(options, callbackContext);
      //configOption = new Camera2ConfigOption(args.getInt(0),args.getInt(1),args.getInt(2), callbackContext);
      if (allPermissionsGranted()) {
        this.initFragment(configOption, callbackContext);
      } else {
        cordova.requestPermissions(this, Configuration.REQUEST_CODE_PERMISSIONS,
          Configuration.REQUIRED_PERMISSIONS);
      }
      return true;
    } else if (action.equals("stopVideoCapture")) {
      endVideoCapture(callbackContext);
      return true;
    } else if (action.equals("startVideoCapture")) {
      recordVideo(callbackContext);
      return true;
    } else if (action.equals("selectCamera")) {
      selectCamera(callbackContext);
      return true;
    }
    return false;
  }



  private void initFragment(Camera2ConfigOption configOption, CallbackContext callbackContext) {
    mCamera2CaptureFragment.Durantion = 0;//configOption.Duration;
    mCamera2CaptureFragment.mAppContext = cordova.getContext();

    mCamera2CaptureFragment = null;
    if (mCamera2CaptureFragment == null) {
      mCamera2CaptureFragment = new Camera2CaptureFragment();
      Bundle fragmentArguments= new Bundle();
      // fragmentArguments.putInt("Camera2ConfigOption.Height",configOption.Height);
      // fragmentArguments.putInt("Camera2ConfigOption.Width",configOption.Width);
      // fragmentArguments.putInt("Camera2ConfigOption.Duration",configOption.Duration);
      mCamera2CaptureFragment.setArguments(fragmentArguments);
      cordova.getActivity().runOnUiThread(new Runnable() {

        @Override
        public void run() {
          // create or update the layout params for the container view
          FrameLayout containerView = (FrameLayout) cordova.getActivity().findViewById(containerViewId);
          if (containerView == null) {
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
          fragmentTransaction.add(containerView.getId(), mCamera2CaptureFragment);
          fragmentTransaction.commit();
        }
      });
    }
    //callbackContext.success("success");
  }


  private void recordVideo(CallbackContext callbackContext) {
    // execingCallbackContext=callbackContext;
    mCordovaWebView=this.webView;
    if (mCamera2CaptureFragment.camera2VideoCaptureHelper == null) {
      callbackContext.error("请先执行init进行初始化");
    }
    mCamera2CaptureFragment.camera2VideoCaptureHelper.startRecorder();
   // CallJS(new Camera2CaptureChannelMessage("start", true,"success"));
  }

  private void endVideoCapture(CallbackContext callbackContext) throws JSONException {
    //execingCallbackContext=callbackContext;
    if (mCamera2CaptureFragment.camera2VideoCaptureHelper == null) {
      callbackContext.error("请先执行init进行初始化");
    }
   mCamera2CaptureFragment.camera2VideoCaptureHelper.stopRecorder();

  }


  private void selectCamera(CallbackContext callbackContext) {
    if (mCamera2CaptureFragment.camera2VideoCaptureHelper == null) {
      callbackContext.error("请先执行init进行初始化");
    }
    mCamera2CaptureFragment.camera2VideoCaptureHelper.exchangeCamera();
    callbackContext.success("success");
  }

  @Override
  public void onRequestPermissionResult(int requestCode, String[] permissions, int[] grantResults)
    throws JSONException {
    for (int r : grantResults) {
      if (r == PackageManager.PERMISSION_DENIED) {
        execingCallbackContext.sendPluginResult(new PluginResult(PluginResult.Status.ILLEGAL_ACCESS_EXCEPTION));
        return;
      }
    }

    if (requestCode == Configuration.REQUEST_CODE_PERMISSIONS) {
      this.initFragment(configOption, execingCallbackContext);
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
      ? new String[] { Manifest.permission.CAMERA,
      Manifest.permission.RECORD_AUDIO,
      Manifest.permission.WRITE_EXTERNAL_STORAGE
    }
      : new String[] { Manifest.permission.CAMERA,
      Manifest.permission.RECORD_AUDIO };

    public static File CreateFile(Context context, String extension) {
      String timeStamp = new SimpleDateFormat(Configuration.FILENAME_FORMAT).format(new Date());
      String tempFileName = timeStamp + extension;
      String filePath = context.getExternalCacheDir().getAbsolutePath() + File.separator + tempFileName;
      File targetFile = new File(filePath);
      return targetFile;
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
