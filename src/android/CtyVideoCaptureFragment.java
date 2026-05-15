package com.cty.CtyVideoCapture;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.Fragment;
import android.content.Context;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;

import android.view.LayoutInflater;
import android.view.TextureView;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.ImageView;

import androidx.annotation.RequiresApi;

/**
 * A simple {@link Fragment} subclass.
 * Use the {@link CtyVideoCaptureFragment#newInstance} factory method to
 * create an instance of this fragment.
 */
public class CtyVideoCaptureFragment extends Fragment {

  private static final String Key_Height = "CtyVideoConfigOption.Height";
  private static final String Key_Width = "CtyVideoConfigOption.Width";
  private static final String Key_Duration = "CtyVideoConfigOption.Duration";
  public  static int Durantion=15;
  public  static Context mAppContext;

  private String mHeightKey;
  private String mWidthKey;
  private String mDurationKey;

  private  CtyVideoConfigOption cfgOption;

  private View mPageView;
  private String appResourcesPackage;

  public static CtyVideoCaptureHelper CtyVideoCaptureHelper;
  private TextureView mTextureView;
  private ImageView image;
  private int mHeight;
  private int mWidth;
  private int mDuration = 0;
  private Activity mActivity;

  public CtyVideoCaptureFragment() {
    // Required empty public constructor

  }

  public  void setInputParams(CtyVideoConfigOption configOption){
    cfgOption = configOption;
  }


  /**
   * Use this factory method to create a new instance of
   * this fragment using the provided parameters.
   *
   * @param height Parameter 1.
   * @param width Parameter 2.
   * @param duration Parameter 2.
   * @return A new instance of fragment CtyVideoCaptureFragment.
   */
  public static CtyVideoCaptureFragment newInstance(int height, int width ,int duration) {
    CtyVideoCaptureFragment fragment = new CtyVideoCaptureFragment();
    Bundle args = new Bundle();
    args.putInt(Key_Height, height);
    args.putInt(Key_Width, width);
    args.putInt(Key_Duration, duration);
    fragment.setArguments(args);
    return fragment;
  }

  @Override
  public void onCreate(Bundle savedInstanceState) {
    super.onCreate(savedInstanceState);


  }

  @RequiresApi(api = Build.VERSION_CODES.M)
  @Override
  public void onActivityCreated(Bundle savedInstanceState) {
    super.onActivityCreated(savedInstanceState);
  }

  @Override
  public View onCreateView(LayoutInflater inflater, ViewGroup container,
                           Bundle savedInstanceState) {
    Log.d("CtyVideoCapture", "===== CtyVideoCaptureFragment.onCreateView START =====");
    try {
      appResourcesPackage = getActivity().getPackageName();
      // Inflate the layout for this fragment
      int pageViewId = getResources().getIdentifier("camera2_capture_activity", "layout", appResourcesPackage);
      mPageView = inflater.inflate(pageViewId, container, false);
      // mPageView = inflater.inflate(R.layout.camera2_capture_fragment, container, false);
      mActivity = getActivity();
      if (mActivity != null) {
        mActivity.getWindow().setFlags(
          WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
          WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED);//硬件加速
        mActivity.getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);//保持常亮
        mActivity.getWindow().addFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN);//全屏，包含系统状态栏
      }

      int textureViewId = getResources().getIdentifier("camera2_capture_container", "id", appResourcesPackage);
      mTextureView = mPageView.findViewById(textureViewId);
      Log.d("CtyVideoCapture", "onCreateView: 开始创建 CtyVideoCaptureHelper");
      CtyVideoCaptureHelper = new CtyVideoCaptureHelper(getActivity(), mTextureView, getResources().getDisplayMetrics(), cfgOption);
      Log.d("CtyVideoCapture", "onCreateView: CtyVideoCaptureHelper 创建成功");
      initBrightness();
      Log.d("CtyVideoCapture", "===== CtyVideoCaptureFragment.onCreateView END =====");
    } catch (SecurityException e) {
      Log.e("CtyVideoCaptureFragment", "SecurityException: " + e.getMessage(), e);
      e.printStackTrace();
    } catch (Exception e) {
      Log.e("CtyVideoCaptureFragment", "初始化异常: " + e.getMessage(), e);
      e.printStackTrace();
    }
    return mPageView;
  }


  /**
   * 初始化屏幕亮度，不到200自动调整到200
   */
  private void initBrightness() {
    if (mActivity == null) {
      mActivity = getActivity();
    }
    try {
      int brightness = BrightnessTools.getScreenBrightness(mActivity);
      if (brightness < 200) {
        BrightnessTools.setBrightness(mActivity, 200);
      }
    } catch (Exception e) {
      // 处理权限或系统限制导致的异常
      android.util.Log.w("BrightnessTools", "亮度设置失败: " + e.getMessage());
    }
  }

  @Override
  public void onDestroy() {
    super.onDestroy();
    Log.d("CtyVideoCapture", "===== CtyVideoCaptureFragment.onDestroy START =====");
    Log.d("CtyVideoCapture", "onDestroy: 释放 HandlerThread");
    CtyVideoCaptureHelper.releaseThread();
    Log.d("CtyVideoCapture", "===== CtyVideoCaptureFragment.onDestroy END =====");
  }
}
