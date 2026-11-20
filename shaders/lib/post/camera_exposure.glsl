/*
 * 露出がカメラの時の SS と ISO (post モジュール)
 * M は設定の値 (uniform)。P・A・S は composite25 が自動で決めて FrameData に置いた値で、前のフレームのものになる
 * (シャッターの状態・ぶれ・アナログは composite25 より前に走る)。setup の 0 の間は設定の値で始める
 */
#ifndef POST_CAMERA_EXPOSURE_GLSL
#define POST_CAMERA_EXPOSURE_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/uniforms.glsl"
//@include "/lib/buffers/frame_data.glsl"
//@include "/lib/post/post_constants.glsl"

// シャッター速度 (秒)
float cameraShutterSpeed() {
#ifdef EXPOSURE_CAMERA_AE
    float t = frameData.postParams[CAMERA_AE_PARAM].x;
    return t > 0.0 ? t : optShutterSpeed;
#else
    return optShutterSpeed;
#endif
}

// ISO 感度
float cameraIso() {
#ifdef EXPOSURE_CAMERA_AE
    float iso = frameData.postParams[CAMERA_AE_PARAM].z;
    return iso > 0.0 ? iso : optExposureIso;
#else
    return optExposureIso;
#endif
}

#endif
