/*
 * カメラの自動露出 (P・A・S) の SS・F 値・ISO の表示 (post モジュール。EXPOSURE_INFO_MODE)
 * 実機のファインダーの点滅 (SS や F 値が限界に着いて露出が合わない) の代わりに、画面の上の中央に小さく出す
 * 左下はチャット・オフハンド、左上と右上は F3 の列、右下は利き手と重なるので、上の中央 (ボスバーの時だけ重なる) に置く
 * 文字は composite25 が 1 回だけ組み立てて FrameData.postParams[CAMERA_INFO_PARAM ..] に置き (文字数は [CAMERA_INFO_PARAM + 1].z)、final は画素ごとに 3x5 の字形を引くだけ
 * 1 文字 6 ビット (下位 5 ビット = 字、CAMERA_INFO_BLINK = 点滅)、float 1 つに 4 文字 (24 ビットまでは float で厳密)
 */
#ifndef POST_CAMERA_INFO_GLSL
#define POST_CAMERA_INFO_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/uniforms.glsl"
//@include "/lib/buffers/frame_data.glsl"
//@include "/lib/post/post_constants.glsl"

const int CAMERA_INFO_PARAM = 9;
const int CAMERA_INFO_CHARS = 24;
const int CAMERA_INFO_CHARS_PER_WORD = 4;
const int CAMERA_INFO_CHAR_BITS = 6;
const int CAMERA_INFO_BLINK = 32;
// 字の番号 (0 = 空き)。数字は 1..10
const int CAMERA_INFO_DIGIT = 1;
const int CAMERA_INFO_SLASH = 11;
const int CAMERA_INFO_DOT = 12;
const int CAMERA_INFO_F = 13;
const int CAMERA_INFO_SECONDS = 14;
const int CAMERA_INFO_I = 15;
const int CAMERA_INFO_S = 16;
const int CAMERA_INFO_O = 17;
const int CAMERA_INFO_SPACE = 18;
// 点滅の速さ (Hz) と、字の大きさを決める画面の高さ (この高さごとに 1 倍ずつ大きくする)
const float CAMERA_INFO_BLINK_HZ = 2.0;
const float CAMERA_INFO_SCALE_HEIGHT = 360.0;
const float CAMERA_INFO_MARGIN_TOP = 4.0;  // 画面の上端からの余白 (字の 1 画素単位)

// 3x5 の字形。上の行から 3 ビットずつ (左が上位。下の行が下位 3 ビットで、gl_FragCoord の y と同じ向きに引ける)
const int CAMERA_INFO_GLYPHS[19] = int[19](
    0,
    31599, 11415, 29671, 29647, 23497, 31183, 31215, 29257, 31727, 31695,  // 0-9
    4772,   // /
    2,      // .
    31140,  // F
    23040,  // "
    29847,  // I
    31183,  // S
    31599,  // O
    0       // 空白
);

bool cameraInfoGlyph(int code, ivec2 cell) {
    if (code <= 0 || code >= 19 || cell.x < 0 || cell.x > 2 || cell.y < 0 || cell.y > 4) return false;
    int bit = cell.y * 3 + (2 - cell.x);
    return ((CAMERA_INFO_GLYPHS[code] >> bit) & 1) != 0;
}

// 1 画素単位の位置 p (左下が原点) にある字の点が立っているか。点滅の字は消える時刻に false
bool cameraInfoDot(ivec2 p, bool blinkOff) {
    if (p.x < 0 || p.y < 0 || p.y > 4) return false;
    int index = p.x / 4;
    if (index >= CAMERA_INFO_CHARS) return false;
    int wordIndex = index / CAMERA_INFO_CHARS_PER_WORD;
    vec4 words = frameData.postParams[CAMERA_INFO_PARAM + wordIndex / 4];
    int word = int(words[wordIndex % 4]);
    int code = (word >> (CAMERA_INFO_CHAR_BITS * (index % CAMERA_INFO_CHARS_PER_WORD))) & 63;
    if (code >= CAMERA_INFO_BLINK) {
        if (blinkOff) return false;
        code -= CAMERA_INFO_BLINK;
    }
    return cameraInfoGlyph(code, ivec2(p.x % 4, p.y));
}

// 表示値 (0..1) に文字を重ねる。白い字に、右下へ 1 単位ずらした黒い影
vec3 applyCameraInfo(vec3 color, vec2 fragCoord) {
    float scale = max(floor(viewHeight / CAMERA_INFO_SCALE_HEIGHT), 1.0);
    float count = frameData.postParams[CAMERA_INFO_PARAM + 1].z;
    if (!(count > 0.0)) return color;
    // 上の中央に寄せる (字 1 つは 3 + 間 1 単位)
    vec2 origin = vec2(floor((viewWidth / scale - (count * 4.0 - 1.0)) * 0.5), floor(viewHeight / scale) - CAMERA_INFO_MARGIN_TOP - 5.0);
    vec2 q = fragCoord / scale - origin;
    // 字の帯の外は読まない
    if (q.x < -1.0 || q.y < -1.0 || q.y > 6.0 || q.x > count * 4.0 + 1.0) return color;
    ivec2 p = ivec2(floor(q));
    bool blinkOff = fract(frameTimeCounter * CAMERA_INFO_BLINK_HZ) >= 0.5;
    if (cameraInfoDot(p, blinkOff)) return vec3(1.0);
    if (cameraInfoDot(p + ivec2(-1, 1), blinkOff)) return color * 0.2;
    return color;
}

#endif
