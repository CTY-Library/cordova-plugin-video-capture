package com.cty.CtyVideoCapture;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.Context;
import android.graphics.ImageFormat;
import android.graphics.Point;
import android.graphics.SurfaceTexture;
import android.hardware.camera2.CameraAccessException;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureFailure;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.CaptureResult;
import android.hardware.camera2.TotalCaptureResult;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.media.CamcorderProfile;
import android.media.MediaRecorder;
import android.net.Uri;
import android.os.Environment;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.SystemClock;
import android.util.DisplayMetrics;
import android.util.Log;
import android.util.Size;
import android.view.Display;
import android.view.Surface;
import android.view.TextureView;

import androidx.annotation.NonNull;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.io.IOException;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Date;
import java.util.List;
import java.util.Timer;
import java.util.TimerTask;

public class CtyVideoCaptureHelper {

  private static final String TAG = CtyVideoCaptureHelper.class.getSimpleName();
  private CameraManager mCameraManager;
  private CameraDevice mCameraDevice;
  private CameraCaptureSession mCameraCaptureSession;

  private CameraCharacteristics mCameraCharacteristics;
  private int mCameraSensorOrientation = 0; // 摄像头方向
  private int mCameraFacing = CameraCharacteristics.LENS_FACING_BACK; // 默认使用后置摄像头;
  private int mDisplayRotation; // 手机方向

  private boolean isRecordingVideo = false; // 是否正在录像
  private boolean canExchangeCamera = false; // 是否可以切换摄像头

  private Handler mCameraHandler;
  private HandlerThread handlerThread = new HandlerThread("Camera2Thread");

  private Size mPreviewSize = new Size(PREVIEW_WIDTH, PREVIEW_HEIGHT); // 预览大小
  private Size mSavePicSize = new Size(SAVE_WIDTH, SAVE_HEIGHT); // 保存图片大小

  private static final int PREVIEW_WIDTH = 720; // 预览的宽度
  private static final int PREVIEW_HEIGHT = 1280; // 预览的高度
  private static final int SAVE_WIDTH = 720; // 保存的宽度
  private static final int SAVE_HEIGHT = 1280; // 保存的高度

  private Activity mActivity;
  private TextureView mTextureView;

  private int screenWidth;

  private CtyVideoConfigOption cfgOption;

  private CameraDevice.StateCallback mCameraDeviceStateCallback;
  private CameraCaptureSession.StateCallback mSessionStateCallback;
  private CameraCaptureSession.CaptureCallback mSessionCaptureCallback;
  private CaptureRequest.Builder mRecorderCaptureRequest;
  private MediaRecorder mMediaRecorder;
  private String mCurrentCameraId;
  private Size mCurrentPreviewSize;
  private Size mCurrentRecorderSize;
  private Handler mChildHandler;
  private DisplayMetrics displayMetrics;
  private int mDuration=0; // 设置的持续时长（单位：秒）
  private Timer mTimer; // 定时器
  private int mCurrentDuration; // 定时器当前的持续时长
  private boolean timerOnRunning = false; // 定时器是否正在执行
  private File mCurrentFile;//当前录像保存到的文件信息
  private final Object mCameraStateLock = new Object();
  private boolean mIsOpeningCamera = false;
  private int mReconnectAttempts = 0;
  private static final int MAX_RECONNECT_ATTEMPTS = 1;
  private boolean mPendingRecorderStart = false;
  private boolean mRecorderStarted = false;
  private boolean mUseRecorderOnlySession = false;
  private int mRecorderFallbackIndex = -1;
  private boolean mUseCamcorderProfileMode = false;
  private int mCamcorderProfileFallbackIndex = -1;
  private Surface mRecorderPreviewSurface;
  private Surface mRecorderInputSurface;
  private long mRecorderStartElapsedMs = 0L;
  private static final long MIN_RECORDER_STOP_DURATION_MS = 800L;
  private static final Size[] RECORDER_FALLBACK_SIZES = new Size[] {
    new Size(1280, 720),
    new Size(640, 480)
  };
  private static final int[] CAMCORDER_PROFILE_QUALITIES = new int[] {
    CamcorderProfile.QUALITY_720P,
    CamcorderProfile.QUALITY_480P,
    CamcorderProfile.QUALITY_LOW
  };

  public CtyVideoCaptureHelper(Activity activity, TextureView textureView, DisplayMetrics displayMetrics) {
    this.mActivity = activity;
    this.mTextureView = textureView;
    Display display = mActivity.getWindowManager().getDefaultDisplay();
    mDisplayRotation = display.getRotation();
    Point outSize = new Point();
    display.getSize(outSize);
    screenWidth = outSize.x;// 得到屏幕的宽度
    this.displayMetrics = displayMetrics;
    init();
  }


  public CtyVideoCaptureHelper(Activity activity, TextureView textureView, DisplayMetrics displayMetrics,CtyVideoConfigOption configOption) {
    try {
      this.mActivity = activity;
      this.mTextureView = textureView;
      Display display = mActivity.getWindowManager().getDefaultDisplay();
      mDisplayRotation = display.getRotation();
      Point outSize = new Point();
      display.getSize(outSize);
      screenWidth = outSize.x;// 得到屏幕的宽度
      this.displayMetrics = displayMetrics;
      cfgOption = configOption;
      if(cfgOption.is_front.equals("1") || cfgOption.is_front.equals("true")){
        mCameraFacing = CameraCharacteristics.LENS_FACING_FRONT;
      }
      init();
    } catch (SecurityException e) {
      Log.e(TAG, "SecurityException in constructor: " + e.getMessage(), e);
      e.printStackTrace();
    } catch (Exception e) {
      Log.e(TAG, "Exception in constructor: " + e.getMessage(), e);
      e.printStackTrace();
    }
  }

  private void init() {
    try {
      initChildHandler();
      initTextureViewStateListener();
      initCameraDeviceStateCallback();

      initSessionStateCallback();
      initSessionCaptureCallback();
    } catch (SecurityException e) {
      Log.e(TAG, "SecurityException in init: " + e.getMessage(), e);
      e.printStackTrace();
    } catch (Exception e) {
      Log.e(TAG, "Exception in init: " + e.getMessage(), e);
      e.printStackTrace();
    }
  }

  /**
   * 初始化TextureView的纹理生成监听，只有纹理生成准备好了。我们才能去进行摄像头的初始化工作让TextureView接收摄像头预览画面
   */
  private void initTextureViewStateListener() {
    mTextureView.setSurfaceTextureListener(new TextureView.SurfaceTextureListener() {
      @Override
      public void onSurfaceTextureAvailable(SurfaceTexture surface, int width, int height) {
        // 将相机枚举和打开放到子线程，避免阻塞界面首帧
        mChildHandler.post(new Runnable() {
          @Override
          public void run() {
            initCameraManager();
            selectCamera();
            openCamera();
          }
        });

      }

      @Override
      public void onSurfaceTextureSizeChanged(SurfaceTexture surface, int width, int height) {
        // 纹理尺寸变化

      }

      @Override
      public boolean onSurfaceTextureDestroyed(SurfaceTexture surface) {
        // 纹理销毁时把释放动作放到相机线程，避免和相机回调并发冲突
        if (mChildHandler != null) {
          mChildHandler.post(new Runnable() {
            @Override
            public void run() {
              releaseCamera();
            }
          });
        } else {
          releaseCamera();
        }
        return true;
      }

      @Override
      public void onSurfaceTextureUpdated(SurfaceTexture surface) {
        // 纹理更新

      }
    });
  }

  /**
   * 初始化子线程Handler，操作Camera2需要一个子线程的Handler
   */
  private void initChildHandler() {
    try {
      if (handlerThread != null && !handlerThread.isAlive()) {
        handlerThread.start();
      }
      if (handlerThread != null && handlerThread.getLooper() != null) {
        mChildHandler = new Handler(handlerThread.getLooper());
      }
    } catch (IllegalThreadStateException e) {
      Log.e(TAG, "HandlerThread already started", e);
      if (handlerThread != null && handlerThread.getLooper() != null) {
        mChildHandler = new Handler(handlerThread.getLooper());
      }
    } catch (Exception e) {
      Log.e(TAG, "Error initializing handler: " + e.getMessage(), e);
      e.printStackTrace();
    }
  }

  /**
   * 初始化预览
   */

  private void initMediaRecorder() {
    if (mMediaRecorder != null) {
      mMediaRecorder.release();
      mMediaRecorder = null;
    }
    releaseRecorderSurfaces();
    mMediaRecorder = new MediaRecorder();

    configMediaRecorder();

    try {
      closeCaptureSessionSafely();

      // 录制阶段统一使用录制尺寸作为预览缓冲，避免部分机型因为尺寸切换导致预览卡帧
      Size previewSize = getRecorderOutputSize();
      SurfaceTexture surfaceTexture = mTextureView.getSurfaceTexture();
      surfaceTexture.setDefaultBufferSize(previewSize.getWidth(), previewSize.getHeight());
      mRecorderPreviewSurface = new Surface(surfaceTexture);
      mRecorderInputSurface = mMediaRecorder.getSurface();// 从获取录制视频需要的Surface

      mRecorderCaptureRequest = mCameraDevice.createCaptureRequest(CameraDevice.TEMPLATE_RECORD);

      mRecorderCaptureRequest.set(CaptureRequest.CONTROL_AF_MODE,
        CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE); // 自动对焦
      mRecorderCaptureRequest.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON_AUTO_FLASH); // 闪光灯
      List<Surface> outputs = new ArrayList<>();
      outputs.add(mRecorderInputSurface);
      mRecorderCaptureRequest.addTarget(mRecorderInputSurface);
      outputs.add(mRecorderPreviewSurface);
      mRecorderCaptureRequest.addTarget(mRecorderPreviewSurface);

      // 创建CaptureSession会话。
      // 第一个参数 outputs 是一个 List 数组，相机会把捕捉到的图片数据传递给该参数中的 Surface 。
      // 第二个参数 StateCallback 是创建会话的状态回调。
      // 第三个参数描述了 StateCallback 被调用时所在的线程
      // 请注意这里设置了Arrays.asList(previewSurface,recorderSurface)
      // 2个Surface，很好理解录制视频也需要有画面预览，第一个是预览的Surface，第二个是录制视频使用的Surface
      mCameraDevice.createCaptureSession(outputs,mSessionStateCallback, mChildHandler);

    } catch (CameraAccessException e) {
      e.printStackTrace();
      Log.e(TAG,e.getMessage());
    }
  }

  /**
   * 初始化MediaRecorder
   */
  private void initCameraPreview() {
    try {
      Size previewSize = getPreviewOutputSize();
      SurfaceTexture surfaceTexture = mTextureView.getSurfaceTexture();
      surfaceTexture.setDefaultBufferSize(previewSize.getWidth(), previewSize.getHeight());
      Surface previewSurface = new Surface(surfaceTexture);

      mRecorderCaptureRequest = mCameraDevice.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW);

      mRecorderCaptureRequest.set(CaptureRequest.CONTROL_AF_MODE,CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE); // 自动对焦
      mRecorderCaptureRequest.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON_AUTO_FLASH); // 闪光灯
      mRecorderCaptureRequest.addTarget(previewSurface);

      // 创建CaptureSession会话。
      // 第一个参数 outputs 是一个 List 数组，相机会把捕捉到的图片数据传递给该参数中的 Surface 。
      // 第二个参数 StateCallback 是创建会话的状态回调。
      // 第三个参数描述了 StateCallback 被调用时所在的线程
      // 请注意这里设置了Arrays.asList(previewSurface,recorderSurface)
      // 2个Surface，很好理解录制视频也需要有画面预览，第一个是预览的Surface，第二个是录制视频使用的Surface
      mCameraDevice.createCaptureSession(Arrays.asList(previewSurface), new CameraCaptureSession.StateCallback() {
        @Override
        public void onConfigured(@NonNull CameraCaptureSession session) {
          mCameraCaptureSession = session;
          try {
            // 执行重复获取数据请求，等于一直获取数据呈现预览画面，mSessionCaptureCallback会返回此次操作的信息回调
            mCameraCaptureSession.setRepeatingRequest(mRecorderCaptureRequest.build(), mSessionCaptureCallback,
              mChildHandler);
          } catch (CameraAccessException e) {
            e.printStackTrace();
          }
        }

        @Override
        public void onConfigureFailed(@NonNull CameraCaptureSession session) {

        }
      }, mChildHandler);

    } catch (CameraAccessException e) {
      e.printStackTrace();
      Log.e(TAG,e.getMessage());
    }
  }

  /**
   * 配置录制视频相关数据
   */
  private void configMediaRecorder() {
    try {
      mCurrentFile = CtyVideoCaptureCordova.Configuration.CreateFile(cfgOption.saveToPhotoAlbum, mActivity.getBaseContext(), ".mp4");
      
      if (mCurrentFile == null) {
        Log.e(TAG, "文件创建失败：CreateFile 返回 null");
        throw new RuntimeException("无法创建视频文件");
      }
      
      Log.d(TAG, "视频文件路径: " + mCurrentFile.getAbsolutePath());
      
      // 验证文件所在目录是否存在
      File parentDir = mCurrentFile.getParentFile();
      if (parentDir != null && !parentDir.exists()) {
        if (!parentDir.mkdirs()) {
          Log.e(TAG, "无法创建目录: " + parentDir.getAbsolutePath());
          throw new RuntimeException("无法创建视频保存目录");
        }
      }
    } catch (Exception e) {
      Log.e(TAG, "文件创建异常: " + e.getMessage(), e);
      e.printStackTrace();
      mCurrentFile = null;
    }

    mMediaRecorder.setAudioSource(MediaRecorder.AudioSource.MIC);// 设置音频来源
    mMediaRecorder.setVideoSource(MediaRecorder.VideoSource.SURFACE);// 设置视频来源
    boolean profileApplied = false;
    if (mUseCamcorderProfileMode) {
      CamcorderProfile profile = resolveCamcorderProfile();
      if (profile != null) {
        mMediaRecorder.setOutputFormat(profile.fileFormat);
        mMediaRecorder.setAudioEncoder(profile.audioCodec);
        mMediaRecorder.setVideoEncoder(profile.videoCodec);
        mMediaRecorder.setVideoEncodingBitRate(profile.videoBitRate);
        mMediaRecorder.setAudioEncodingBitRate(profile.audioBitRate);
        mMediaRecorder.setAudioSamplingRate(profile.audioSampleRate);
        mMediaRecorder.setAudioChannels(profile.audioChannels);
        mMediaRecorder.setVideoFrameRate(profile.videoFrameRate);
        mMediaRecorder.setVideoSize(profile.videoFrameWidth, profile.videoFrameHeight);
        profileApplied = true;
        Log.w(TAG, "configMediaRecorder: use CamcorderProfile qualityIndex=" + mCamcorderProfileFallbackIndex
          + " size=" + profile.videoFrameWidth + "x" + profile.videoFrameHeight);
      }
    }

    if (!profileApplied) {
      mMediaRecorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4);// 设置输出格式
      mMediaRecorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC);// 设置音频编码格式，请注意这里使用默认，实际app项目需要考虑兼容问题，应该选择AAC
      mMediaRecorder.setVideoEncoder(MediaRecorder.VideoEncoder.H264);// 设置视频编码格式，请注意这里使用默认，实际app项目需要考虑兼容问题，应该选择H264

      mMediaRecorder.setVideoEncodingBitRate(cfgOption.videoBitrate);// 设置比特率 一般是 1*分辨率 到 10*分辨率 之间波动。比特率越大视频越清晰但是视频文件也越大。

      mMediaRecorder.setAudioEncodingBitRate(cfgOption.audioBitrate);
      mMediaRecorder.setAudioSamplingRate(cfgOption.audioSampleRate);
      mMediaRecorder.setAudioChannels(cfgOption.audioChannels);
      mMediaRecorder.setVideoFrameRate(cfgOption.videoFrameRate);// 设置帧数 选择 30即可， 过大帧数也会让视频文件更大当然也会更流畅，但是没有多少实际提升。人眼极限也就30帧了。
      Size size = getRecorderOutputSize();
      int iwidth =  size.getWidth() ;
      int iheight =  size.getHeight();

      if(iwidth > iheight && iwidth  > 1920){
        iheight = 1920 * iheight /  iwidth  ;
        iwidth =  1920;
      }
      if(iwidth < iheight && iheight  > 1920){
        iwidth = 1920 * iwidth  / iheight   ;
        iheight = 1920;
      }

      if(cfgOption.maintainAspectRatio){
        if(cfgOption.width>0 && cfgOption.height>0 ) {
          if(iwidth > iheight){
            cfgOption.height = 0;
          }
          else {
            cfgOption.width = 0;
          }
        }
      }

      if(cfgOption.width>0 && cfgOption.height>0 ){
        iwidth = cfgOption.width;
        iheight = cfgOption.height;
      }
      else if(cfgOption.width>0){
        cfgOption.width = cfgOption.width > iwidth ? iwidth : cfgOption.width;
        iheight = cfgOption.width * iheight /  iwidth  ;
        iwidth = cfgOption.width;
      }
      else if(cfgOption.height>0){
        cfgOption.height = cfgOption.height > iheight ? iheight : cfgOption.height;
        iwidth = cfgOption.height * iwidth  / iheight   ;
        iheight = cfgOption.height;
      }

      if (mRecorderFallbackIndex >= 0 && mRecorderFallbackIndex < RECORDER_FALLBACK_SIZES.length) {
        Size fallbackSize = RECORDER_FALLBACK_SIZES[mRecorderFallbackIndex];
        iwidth = fallbackSize.getWidth();
        iheight = fallbackSize.getHeight();
        Log.w(TAG, "configMediaRecorder: use fallback size " + iwidth + "x" + iheight);
      }

      iwidth = iwidth + iwidth % 2;
      iheight = iheight + iheight % 2;
      mMediaRecorder.setVideoSize(iwidth,iheight); //760,360
    }
    mMediaRecorder.setOrientationHint(90);
    
    // 验证文件路径是否有效
    if (mCurrentFile == null) {
      Log.e(TAG, "无法设置输出文件：mCurrentFile 为 null");
      throw new RuntimeException("视频输出文件路径无效");
    }
    
    mMediaRecorder.setOutputFile(mCurrentFile.getAbsolutePath());
    try {
      mMediaRecorder.prepare();
    } catch (IOException e) {
      e.printStackTrace();
      Log.e(TAG,"MediaRecorder prepare IOException: " + e.getMessage());
      throw new RuntimeException("MediaRecorder prepare failed", e);
    } catch (RuntimeException e) {
      Log.e(TAG, "MediaRecorder 参数不兼容: " + e.getMessage(), e);
      throw e;
    }

  }


  /**
   * 开始录制视频
   */
  public void startRecorder() {
    if (mChildHandler == null) {
      Log.e(TAG, "startRecorder: 相机线程未初始化");
      return;
    }

    mChildHandler.post(new Runnable() {
      @Override
      public void run() {
        if (isRecordingVideo) {
          Log.w(TAG, "startRecorder: 已在录制中，忽略重复请求");
          return;
        }
        if (mCameraDevice == null || mTextureView == null || !mTextureView.isAvailable()) {
          Log.e(TAG, "startRecorder: 相机未就绪，mCameraDevice=" + (mCameraDevice != null)
            + ", textureAvailable=" + (mTextureView != null && mTextureView.isAvailable()));
          return;
        }

        isRecordingVideo = true;
        mCurrentFile = null;
        try {
          mPendingRecorderStart = true;
          mRecorderStarted = false;
          mRecorderStartElapsedMs = 0L;
          mUseRecorderOnlySession = false;
          mRecorderFallbackIndex = -1;
          mUseCamcorderProfileMode = false;
          mCamcorderProfileFallbackIndex = -1;
          initMediaRecorder();
          Log.d(TAG, "startRecorder: 已发起录制会话初始化");
        } catch (Exception e) {
          mPendingRecorderStart = false;
          mRecorderStarted = false;
          isRecordingVideo = false;
          Log.e(TAG, "开始录制视频时发现异常", e);
        }
      }
    });
  }

  /**
   * 暂停录制视频（暂停后视频文件会自动保存）
   */
  public void stopRecorder() throws JSONException {
    if (mChildHandler == null) {
      Log.e(TAG, "stopRecorder: 相机线程未初始化");
      return;
    }

    mChildHandler.post(new Runnable() {
      @Override
      public void run() {
        if (mTimer != null && timerOnRunning) {
          mTimer.cancel();
          mTimer = null;
          mCurrentDuration = 0;
          timerOnRunning = false;
        }
        isRecordingVideo = false;
        mPendingRecorderStart = false;
        File videoFile = mCurrentFile;
        mCurrentFile = null;
        boolean stopSucceeded = false;
        boolean shouldDiscardFile = false;
        try {
          if (mMediaRecorder != null && mRecorderStarted) {
            long recordDurationMs = SystemClock.elapsedRealtime() - mRecorderStartElapsedMs;
            if (recordDurationMs < MIN_RECORDER_STOP_DURATION_MS) {
              shouldDiscardFile = true;
              Log.w(TAG, "录制时长过短，跳过 stop。durationMs=" + recordDurationMs);
            } else {
              mMediaRecorder.stop();
              stopSucceeded = true;
            }
          }
        } catch (Exception e) {
          shouldDiscardFile = true;
          Log.e(TAG, "停止视频时发生异常", e);
          if (mMediaRecorder != null) {
            mMediaRecorder.reset();
          }
        }
        mRecorderStarted = false;
        mRecorderStartElapsedMs = 0L;
        if (mMediaRecorder != null) {
          mMediaRecorder.reset();
        }
        releaseRecorderSurfaces();

        if (mCameraDevice != null) {
          initCameraPreview();
        }

        if (!stopSucceeded || shouldDiscardFile || videoFile == null || !videoFile.exists() || videoFile.length() <= 0) {
          deleteFileQuietly(videoFile);
          CtyVideoCaptureCordova.CallJSMsg(new JSONArray());
          return;
        }

        try {
          JSONArray mediaFile = CtyVideoCaptureCordova.GetMediaFileInfo(videoFile);
          CtyVideoCaptureCordova.CallJSMsg(mediaFile);
        } catch (JSONException e) {
          Log.e(TAG, "stopRecorder: 组装返回数据失败", e);
          CtyVideoCaptureCordova.CallJSMsg(new JSONArray());
        }
      }
    });

  }

  /**
   * 初始化Camera2的相机管理，CameraManager用于获取摄像头分辨率，摄像头方向，摄像头id与打开摄像头的工作
   */
  private void initCameraManager() {
    mCameraManager = (CameraManager) mActivity.getSystemService(Context.CAMERA_SERVICE);
  }

  /**
   * 选择一颗我们需要使用的摄像头，主要是选择使用前摄还是后摄或者是外接摄像头
   */
  private void selectCamera() {
    if (mCameraManager == null) {
      Log.e(TAG, "selectCamera: CameraManager is null");
      return;
    }

    mCurrentCameraId = null;
    mCameraCharacteristics = null;
    mCurrentPreviewSize = null;
    mCurrentRecorderSize = null;

    try {
      String[] cameraIdList = mCameraManager.getCameraIdList(); // 获取当前设备的全部摄像头id集合
      if (cameraIdList.length == 0) {
        Log.e(TAG, "selectCamera: cameraIdList length is 0");
        return;
      }

      String fallbackCameraId = null;
      CameraCharacteristics fallbackCharacteristics = null;

      for (String cameraId : cameraIdList) { // 遍历所有摄像头
        CameraCharacteristics characteristics = mCameraManager.getCameraCharacteristics(cameraId);// 得到当前id的摄像头描述特征
        Integer facing = characteristics.get(CameraCharacteristics.LENS_FACING); // 获取摄像头的方向特征信息
        if (facing == null || facing != mCameraFacing) {
          continue;
        }

        if (!hasUsableOutput(characteristics, SurfaceTexture.class) || !hasUsableOutput(characteristics, MediaRecorder.class)) {
          Log.w(TAG, "selectCamera: skip cameraId=" + cameraId + " because preview or recorder outputs are unavailable");
          continue;
        }

        if (isLogicalOrPrimaryCamera(cameraId)) {
          mCurrentCameraId = cameraId;
          mCameraCharacteristics = characteristics;
          break;
        }

        if (fallbackCameraId == null) {
          fallbackCameraId = cameraId;
          fallbackCharacteristics = characteristics;
        }
      }

      if (mCurrentCameraId == null && fallbackCameraId != null) {
        mCurrentCameraId = fallbackCameraId;
        mCameraCharacteristics = fallbackCharacteristics;
      }

      if (mCurrentCameraId == null) {
        Log.e(TAG, "selectCamera: no usable camera found for facing=" + mCameraFacing);
        return;
      }

      mCurrentPreviewSize = chooseOutputSize(mCameraCharacteristics, SurfaceTexture.class, displayMetrics.widthPixels, displayMetrics.heightPixels, false);
      mCurrentRecorderSize = chooseOutputSize(mCameraCharacteristics, MediaRecorder.class, displayMetrics.widthPixels, displayMetrics.heightPixels, true);

      if (mCurrentRecorderSize == null) {
        mCurrentRecorderSize = mCurrentPreviewSize;
      }

      Log.i(TAG, "selectCamera: use cameraId=" + mCurrentCameraId
        + ", preview=" + describeSize(mCurrentPreviewSize)
        + ", recorder=" + describeSize(mCurrentRecorderSize));

    } catch (CameraAccessException e) {
      e.printStackTrace();
    }
  }

  /**
   * 切换摄像头
   */
  public void exchangeCamera() {
    if (mChildHandler == null) {
      Log.e(TAG, "exchangeCamera: 相机线程未初始化");
      return;
    }

    mChildHandler.post(new Runnable() {
      @Override
      public void run() {
        if (mCameraDevice == null || mTextureView == null || !mTextureView.isAvailable()) {
          Log.e(TAG, "不能切换摄像头");
          return;
        }

        if (mCameraFacing == CameraCharacteristics.LENS_FACING_FRONT) {
          mCameraFacing = CameraCharacteristics.LENS_FACING_BACK;
        } else {
          mCameraFacing = CameraCharacteristics.LENS_FACING_FRONT;
        }
        mPreviewSize = new Size(PREVIEW_WIDTH, PREVIEW_HEIGHT); // 重置预览大小
        releaseCamera();

        initCameraDeviceStateCallback();
        initCameraManager();
        selectCamera();
        openCamera();
      }
    });
  }

  public void releaseCamera() {
    if (mCameraCaptureSession != null) {
      try {
        mCameraCaptureSession.close();
      } catch (Exception e) {
        Log.w(TAG, "releaseCamera: close session failed", e);
      }
      mCameraCaptureSession = null;
    }

    if (mCameraDevice != null) {
      try {
        mCameraDevice.close();
      } catch (Exception e) {
        Log.w(TAG, "releaseCamera: close device failed", e);
      }
      mCameraDevice = null;
    }

    synchronized (mCameraStateLock) {
      mIsOpeningCamera = false;
    }

    releaseRecorderSurfaces();

    canExchangeCamera = false;
  }

  private void initCameraDeviceStateCallback() {
    mCameraDeviceStateCallback = new CameraDevice.StateCallback() {
      @Override
      // 摄像头被打开
      public void onOpened(@NonNull CameraDevice camera) {
        synchronized (mCameraStateLock) {
          mIsOpeningCamera = false;
          mReconnectAttempts = 0;
        }
        mCameraDevice = camera;
        initCameraPreview();
      }

      @Override
      public void onDisconnected(@NonNull CameraDevice camera) {
        // 摄像头断开
        Log.e(TAG, "摄像头断开");
        synchronized (mCameraStateLock) {
          mIsOpeningCamera = false;
        }
        releaseCamera();
        tryScheduleReconnect();
      }

      @Override
      public void onError(@NonNull CameraDevice camera, int error) {
        // 异常
        String message = "设备异常";
        switch (error) {
          case ERROR_CAMERA_DEVICE:
            message = "Fatal (device)";
            break;
          case ERROR_CAMERA_DISABLED:
            message = "Device policy";
            break;
          case ERROR_CAMERA_IN_USE:
            message = "Camera in use";
            break;
          case ERROR_CAMERA_SERVICE:
            message = "Fatal (service)";
            break;
          case ERROR_MAX_CAMERAS_IN_USE:
            message = "Maximum cameras in use";
            break;
          default:
            break;
        }
        Log.e(TAG, "CameraDevice onError: " + message + " (code=" + error + ")");
        synchronized (mCameraStateLock) {
          mIsOpeningCamera = false;
        }
        releaseCamera();
        tryScheduleReconnect();
        //CtyVideoCapture.CallJS(new CtyVideoCaptureChannelMessage("CameraDeviceState", false, message));
      }
    };
  }

  private void initSessionStateCallback() {
    mSessionStateCallback = new CameraCaptureSession.StateCallback() {
      @Override
      public void onConfigured(@NonNull CameraCaptureSession session) {
        mCameraCaptureSession = session;
        try {
          // 执行重复获取数据请求，等于一直获取数据呈现预览画面，mSessionCaptureCallback会返回此次操作的信息回调
          mCameraCaptureSession.setRepeatingRequest(mRecorderCaptureRequest.build(), mSessionCaptureCallback,
            mChildHandler);

          if (mPendingRecorderStart && mMediaRecorder != null) {
            mMediaRecorder.start();
            mRecorderStarted = true;
            mRecorderStartElapsedMs = SystemClock.elapsedRealtime();
            mPendingRecorderStart = false;
            startDurationTimer();
          }
        } catch (CameraAccessException e) {
          mPendingRecorderStart = false;
          mRecorderStarted = false;
          mRecorderStartElapsedMs = 0L;
          isRecordingVideo = false;
          e.printStackTrace();
        } catch (RuntimeException e) {
          mPendingRecorderStart = false;
          mRecorderStarted = false;
          mRecorderStartElapsedMs = 0L;
          isRecordingVideo = false;
          Log.e(TAG, "录制启动失败", e);
        }
      }

      @Override
      public void onConfigureFailed(@NonNull CameraCaptureSession session) {
        if (mPendingRecorderStart && tryNextRecorderFallbackSize()) {
          Log.w(TAG, "录制会话仍失败，继续降级分辨率重试");
          mUseRecorderOnlySession = false;
          try {
            initMediaRecorder();
          } catch (Exception e) {
            mPendingRecorderStart = false;
            mRecorderStarted = false;
            mRecorderStartElapsedMs = 0L;
            isRecordingVideo = false;
            Log.e(TAG, "录制会话分辨率降级重试失败", e);
          }
          return;
        }

        if (mPendingRecorderStart && !mUseCamcorderProfileMode) {
          Log.w(TAG, "录制会话仍失败，切换 CamcorderProfile 重试");
          mUseRecorderOnlySession = false;
          mUseCamcorderProfileMode = true;
          mCamcorderProfileFallbackIndex = 0;
          try {
            initMediaRecorder();
          } catch (Exception e) {
            mPendingRecorderStart = false;
            mRecorderStarted = false;
            mRecorderStartElapsedMs = 0L;
            isRecordingVideo = false;
            Log.e(TAG, "CamcorderProfile 重试失败", e);
          }
          return;
        }

        if (mPendingRecorderStart && tryNextCamcorderProfileQuality()) {
          Log.w(TAG, "CamcorderProfile 继续降级质量重试");
          mUseRecorderOnlySession = false;
          mUseCamcorderProfileMode = true;
          try {
            initMediaRecorder();
          } catch (Exception e) {
            mPendingRecorderStart = false;
            mRecorderStarted = false;
            mRecorderStartElapsedMs = 0L;
            isRecordingVideo = false;
            Log.e(TAG, "CamcorderProfile 降级质量重试失败", e);
          }
          return;
        }

        mPendingRecorderStart = false;
        mRecorderStarted = false;
        mRecorderStartElapsedMs = 0L;
        isRecordingVideo = false;
        Log.e(TAG, "录制会话配置失败");

      }
    };
  }

  private void closeCaptureSessionSafely() {
    if (mCameraCaptureSession == null) {
      return;
    }
    try {
      mCameraCaptureSession.stopRepeating();
    } catch (Exception e) {
      Log.w(TAG, "closeCaptureSessionSafely: stopRepeating failed", e);
    }
    try {
      mCameraCaptureSession.abortCaptures();
    } catch (Exception e) {
      Log.w(TAG, "closeCaptureSessionSafely: abortCaptures failed", e);
    }
    try {
      mCameraCaptureSession.close();
    } catch (Exception e) {
      Log.w(TAG, "closeCaptureSessionSafely: close failed", e);
    }
    mCameraCaptureSession = null;
  }

  private void startDurationTimer() {
    if (mDuration <= 0) {
      return;
    }
    mCurrentDuration=0;
    timerOnRunning=true;
    TimerTask timerTask= new TimerTask() {
      @Override
      public void run() {
        if(mCurrentDuration<mDuration){
          mCurrentDuration++;
        }else
        {
          cancel();
        }
      }
    };
    mTimer= new Timer("mScheduler");
    mTimer.schedule(timerTask,1000,1000);
  }

  private boolean tryNextRecorderFallbackSize() {
    if (mRecorderFallbackIndex + 1 >= RECORDER_FALLBACK_SIZES.length) {
      return false;
    }
    mRecorderFallbackIndex++;
    return true;
  }

  private boolean tryNextCamcorderProfileQuality() {
    if (mCamcorderProfileFallbackIndex + 1 >= CAMCORDER_PROFILE_QUALITIES.length) {
      return false;
    }
    mCamcorderProfileFallbackIndex++;
    return true;
  }

  private CamcorderProfile resolveCamcorderProfile() {
    if (mCamcorderProfileFallbackIndex < 0 || mCamcorderProfileFallbackIndex >= CAMCORDER_PROFILE_QUALITIES.length) {
      return null;
    }

    int cameraId = parseCameraIdForProfile();
    int quality = CAMCORDER_PROFILE_QUALITIES[mCamcorderProfileFallbackIndex];
    try {
      if (CamcorderProfile.hasProfile(cameraId, quality)) {
        return CamcorderProfile.get(cameraId, quality);
      }
      if (CamcorderProfile.hasProfile(quality)) {
        return CamcorderProfile.get(quality);
      }
    } catch (Exception e) {
      Log.w(TAG, "resolveCamcorderProfile: failed", e);
    }
    return null;
  }

  private int parseCameraIdForProfile() {
    if (mCurrentCameraId != null) {
      try {
        return Integer.parseInt(mCurrentCameraId);
      } catch (NumberFormatException ignored) {
      }
    }
    return mCameraFacing == CameraCharacteristics.LENS_FACING_FRONT ? 1 : 0;
  }

  private void releaseRecorderSurfaces() {
    if (mRecorderPreviewSurface != null) {
      try {
        mRecorderPreviewSurface.release();
      } catch (Exception e) {
        Log.w(TAG, "releaseRecorderSurfaces: preview release failed", e);
      }
      mRecorderPreviewSurface = null;
    }

    if (mRecorderInputSurface != null) {
      try {
        mRecorderInputSurface.release();
      } catch (Exception e) {
        Log.w(TAG, "releaseRecorderSurfaces: recorder release failed", e);
      }
      mRecorderInputSurface = null;
    }
  }

  private void deleteFileQuietly(File file) {
    if (file == null) {
      return;
    }
    try {
      if (file.exists() && !file.delete()) {
        Log.w(TAG, "deleteFileQuietly: delete failed " + file.getAbsolutePath());
      }
    } catch (Exception e) {
      Log.w(TAG, "deleteFileQuietly: exception", e);
    }
  }

  private void initSessionCaptureCallback() {
    mSessionCaptureCallback = new CameraCaptureSession.CaptureCallback() {
      @Override
      public void onCaptureStarted(@NonNull CameraCaptureSession session, @NonNull CaptureRequest request,
                                   long timestamp, long frameNumber) {
        super.onCaptureStarted(session, request, timestamp, frameNumber);
      }

      @Override
      public void onCaptureProgressed(@NonNull CameraCaptureSession session, @NonNull CaptureRequest request,
                                      @NonNull CaptureResult partialResult) {
        super.onCaptureProgressed(session, request, partialResult);
      }

      @Override
      public void onCaptureCompleted(@NonNull CameraCaptureSession session, @NonNull CaptureRequest request,
                                     @NonNull TotalCaptureResult result) {
        super.onCaptureCompleted(session, request, result);
        canExchangeCamera = true;
      }

      @Override
      public void onCaptureFailed(@NonNull CameraCaptureSession session, @NonNull CaptureRequest request,
                                  @NonNull CaptureFailure failure) {
        super.onCaptureFailed(session, request, failure);
      }
    };
  }

  /**
   * 打开摄像头，这里打开摄像头后，我们需要等待mCameraDeviceStateCallback的回调
   */
  @SuppressLint("MissingPermission")
  private void openCamera() {
    if (mCameraManager == null || mCurrentCameraId == null) {
      Log.e(TAG, "openCamera: camera manager or camera id is null");
      return;
    }

    synchronized (mCameraStateLock) {
      if (mIsOpeningCamera) {
        Log.w(TAG, "openCamera: skip duplicate open request");
        return;
      }
      if (mCameraDevice != null) {
        Log.w(TAG, "openCamera: camera already opened");
        return;
      }
      mIsOpeningCamera = true;
    }

    try {
      mCameraManager.openCamera(mCurrentCameraId, mCameraDeviceStateCallback, mChildHandler);
    } catch (CameraAccessException e) {
      synchronized (mCameraStateLock) {
        mIsOpeningCamera = false;
      }
      e.printStackTrace();
      Log.e(TAG,e.getMessage());
      tryScheduleReconnect();
    } catch (SecurityException e) {
      synchronized (mCameraStateLock) {
        mIsOpeningCamera = false;
      }
      Log.e(TAG, "openCamera: permission denied", e);
    }
  }

  private void tryScheduleReconnect() {
    if (mChildHandler == null || mTextureView == null || !mTextureView.isAvailable()) {
      return;
    }
    if (mActivity == null || mActivity.isFinishing()) {
      return;
    }

    synchronized (mCameraStateLock) {
      if (mReconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
        return;
      }
      mReconnectAttempts++;
    }

    Log.w(TAG, "tryScheduleReconnect: attempt=" + mReconnectAttempts);
    mChildHandler.postDelayed(new Runnable() {
      @Override
      public void run() {
        initCameraManager();
        selectCamera();
        openCamera();
      }
    }, 300);
  }

  /**
   * 计算需要的使用的摄像头分辨率
   *
   * @return
   */
  private Size getMatchingSize2() {
    return getPreviewOutputSize();
  }

  private Size getPreviewOutputSize() {
    if (mCurrentPreviewSize != null) {
      return mCurrentPreviewSize;
    }

    mCurrentPreviewSize = chooseOutputSize(mCameraCharacteristics, SurfaceTexture.class, displayMetrics.widthPixels, displayMetrics.heightPixels, false);
    if (mCurrentPreviewSize == null) {
      throw new IllegalStateException("No preview size available for cameraId=" + mCurrentCameraId);
    }
    return mCurrentPreviewSize;
  }

  private Size getRecorderOutputSize() {
    if (mCurrentRecorderSize != null) {
      return mCurrentRecorderSize;
    }

    mCurrentRecorderSize = chooseOutputSize(mCameraCharacteristics, MediaRecorder.class, displayMetrics.widthPixels, displayMetrics.heightPixels, true);
    if (mCurrentRecorderSize == null) {
      mCurrentRecorderSize = getPreviewOutputSize();
    }
    return mCurrentRecorderSize;
  }

  private boolean hasUsableOutput(CameraCharacteristics characteristics, Class<?> outputClass) {
    StreamConfigurationMap streamConfigurationMap = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
    if (streamConfigurationMap == null) {
      return false;
    }

    Size[] sizes = streamConfigurationMap.getOutputSizes(outputClass);
    return sizes != null && sizes.length > 0;
  }

  private boolean isLogicalOrPrimaryCamera(String cameraId) {
    for (int i = 0; i < cameraId.length(); i++) {
      if (!Character.isDigit(cameraId.charAt(i))) {
        return true;
      }
    }

    try {
      return Integer.parseInt(cameraId) < 10;
    } catch (NumberFormatException e) {
      return true;
    }
  }

  private Size chooseOutputSize(CameraCharacteristics characteristics, Class<?> outputClass, int targetWidth, int targetHeight, boolean limitRecorderSize) {
    if (characteristics == null) {
      return null;
    }

    StreamConfigurationMap streamConfigurationMap = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
    if (streamConfigurationMap == null) {
      return null;
    }

    Size[] sizes = streamConfigurationMap.getOutputSizes(outputClass);
    if ((sizes == null || sizes.length == 0) && outputClass != SurfaceTexture.class) {
      sizes = streamConfigurationMap.getOutputSizes(SurfaceTexture.class);
    }
    if ((sizes == null || sizes.length == 0) && outputClass != ImageFormat.class) {
      sizes = streamConfigurationMap.getOutputSizes(ImageFormat.JPEG);
    }
    if (sizes == null || sizes.length == 0) {
      return null;
    }

    int portraitTargetWidth = Math.min(targetWidth, targetHeight);
    int portraitTargetHeight = Math.max(targetWidth, targetHeight);
    float targetRatio = portraitTargetHeight == 0 ? 0f : (float) portraitTargetWidth / (float) portraitTargetHeight;
    long bestScore = Long.MAX_VALUE;
    Size bestSize = null;

    for (Size size : sizes) {
      int sizePortraitWidth = Math.min(size.getWidth(), size.getHeight());
      int sizePortraitHeight = Math.max(size.getWidth(), size.getHeight());

      if (limitRecorderSize && sizePortraitHeight > 1920) {
        continue;
      }

      float ratio = sizePortraitHeight == 0 ? 0f : (float) sizePortraitWidth / (float) sizePortraitHeight;
      long ratioPenalty = (long) (Math.abs(ratio - targetRatio) * 1_000_000);
      long widthPenalty = Math.abs(sizePortraitWidth - portraitTargetWidth) * 1000L;
      long heightPenalty = Math.abs(sizePortraitHeight - portraitTargetHeight);
      long score = ratioPenalty + widthPenalty + heightPenalty;

      if (bestSize == null || score < bestScore) {
        bestSize = size;
        bestScore = score;
      }
    }

    if (bestSize == null && limitRecorderSize) {
      return chooseOutputSize(characteristics, outputClass, targetWidth, targetHeight, false);
    }

    return bestSize;
  }

  private String describeSize(Size size) {
    if (size == null) {
      return "null";
    }
    return size.getWidth() + "x" + size.getHeight();
  }

  public void releaseThread() {
    handlerThread.quitSafely();
  }

}
