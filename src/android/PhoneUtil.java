package com.cty.CtyVideoCapture;

import android.content.res.Resources;

public class PhoneUtil {
  public static int dp2px(int dpVal) {
    return Math.round(dpVal * Resources.getSystem().getDisplayMetrics().density);
  }
}
