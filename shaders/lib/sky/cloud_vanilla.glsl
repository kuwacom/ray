/*
 * バニラの形の雲の密度・光の見積もり・雲影 (CLOUD_VANILLA_SHAPE, sky モジュール。cloud_march.glsl が読む)
 * バニラの雲と同じ高さ (Iris の cloudHeight)・12 ブロックの格子・模様・流れ (Iris の cloudTime) の、厚み 4 ブロックの平らな体積雲。
 * 模様はバニラの雲のテクスチャ (リソースパックのものに従う) を customTexture で読み、1 画素 = 1 マスとして置く
 * マスの境目は隣のマスと補間して角を丸め、縁を揺らして柔らかく透かす
 * 長さは参照空間の縮尺 VANILLA_CLOUD_KREF (参照 m / ブロック) で測るので、高さテンプレートによらず同じ透け方になる
 */
#ifndef SKY_CLOUD_VANILLA_GLSL
#define SKY_CLOUD_VANILLA_GLSL

//@include "/lib/settings.glsl"
//@include "/lib/common/math.glsl"
//@include "/lib/common/uniforms.glsl"
//@include "/lib/sky/cloud_constants.glsl"
//@include "/lib/sky/clouds.glsl"

#ifdef CLOUD_VANILLA_SHAPE

uniform sampler2D vanillaCloudTex; // バニラの雲のテクスチャ (shaders.properties の customTexture)

const vec2 VANILLA_CLOUD_ORIGIN = vec2(0.0, 3.96); // 格子の座標 = ワールドの xz + これ (x にはさらに cloudTime)
const float VANILLA_CLOUD_ALPHA_CUT = 0.5;         // 雲のあるマスの不透明度のしきい値
const float VANILLA_CLOUD_KREF = 14.0;             // 参照 m / ブロック
const float VANILLA_CLOUD_CORNER = 0.22;           // マスの角の丸み (マスの割合)
const float VANILLA_CLOUD_ROUND = 0.9;             // 上下の縁の丸め (枕のような断面にする)
const float VANILLA_CLOUD_ROUND_POW = 3.0;
const float VANILLA_CLOUD_SOFT = 0.10 * CLOUD_EDGE_SOFTNESS;   // 縁の立ち上がりの幅 (field の単位。約 1 ブロック)
const float VANILLA_CLOUD_EDGE_NOISE = 0.22;       // 縁を揺らす量 (field の単位)
const float VANILLA_CLOUD_NOISE_PERIOD = 18.0;     // ブロック: 縁の揺れの 3D ノイズの周期
const float VANILLA_CLOUD_SIGMA = 0.275 * CLOUD_LOW_DENSITY;   // 1 / 参照 m。既定の濃さで鉛直の光学的深さ約 3.8、横 1 マスで約 11
const float VANILLA_CLOUD_LIGHT_REACH = 24.0;      // ブロック: 光源方向の陰を見る長さ (低い日でも 2 マス先まで)
const int VANILLA_CLOUD_LIGHT_STEPS = 4;
const float VANILLA_CLOUD_MIN_LIGHT_Y = 0.05;      // 光源の高さの下限 (地平線すれすれで陰の長さが発散しない)
const float VANILLA_CLOUD_STEP_LENGTH = 0.8;       // ブロック: 視線の歩幅の目安 (板を短く抜ける視線は歩数を減らす)
const int VANILLA_CLOUD_MIN_STEPS = 6;
const int VANILLA_CLOUD_SHADOW_STEPS = 3;
// 厚み 4 ブロックの薄い板は光が回り込んで白く飛びやすいので、光の各項を絞って上面の白と陰の灰色の差を出す
// (CS_* の光の値はスタイルごとの微調整で、これはどのスタイルでもバニラの形に掛かる)
const float VANILLA_CLOUD_SUN = 0.85;
const float VANILLA_CLOUD_MS_GAIN = 0.6;
const float VANILLA_CLOUD_SILVER = 0.4;
const float VANILLA_CLOUD_POWDER = 0.4;
const float VANILLA_CLOUD_AMBIENT = 1.1;
const float VANILLA_CLOUD_SKY_SATURATION = 0.5; // 空の光の彩度の残し方 (陰が真っ青に沈まないように)

// 雨が降り始めてから雨雲へ移り終わるまでの割合 (0 = 晴天のバニラの形, 1 = 雨雲)
float cloudVanillaRainLook(float rain) { return smoothstep(0.0, CLOUD_HAZE_RAIN.x, rain); }

// 格子の座標 (ブロック) でのカメラの位置。テクスチャの一周で先に畳むので、遠い座標でも精度が落ちない
vec2 vanillaCloudOrigin() {
    vec2 tile = vec2(textureSize(vanillaCloudTex, 0)) * VANILLA_CLOUD_CELL;
    return mod(mod(cameraPosition.xz, tile) + VANILLA_CLOUD_ORIGIN + vec2(cloudTime * CLOUD_SPEED, 0.0), tile);
}

float vanillaCloudCell(ivec2 c) {
    ivec2 size = textureSize(vanillaCloudTex, 0);
    // 負の整数の % は未定義なので、床で畳む
    ivec2 wrapped = c - size * ivec2(floor(vec2(c) / vec2(size)));
    return texelFetch(vanillaCloudTex, wrapped, 0).a >= VANILLA_CLOUD_ALPHA_CUT ? 1.0 : 0.0;
}

/*
 * 密度 [0,1]。q: 格子の座標 (ブロック), y: ワールドの高さ, detail: 縁の揺れの強さ [0,1] (距離の LOD)
 * slabHeight: 板の中の高さ (底 0 / 頂 1)
 */
float vanillaCloudDensity(vec2 q, float y, float detail, out float slabHeight) {
    float hv = (y - vanillaCloudBottom()) / VANILLA_CLOUD_THICKNESS;
    slabHeight = saturate(hv);
    if (hv <= 0.0 || hv >= 1.0) return 0.0;
    vec2 g = q / VANILLA_CLOUD_CELL - 0.5;
    ivec2 i = ivec2(floor(g));
    vec2 f = g - vec2(i);
    vec4 o = vec4(vanillaCloudCell(i), vanillaCloudCell(i + ivec2(1, 0)), vanillaCloudCell(i + ivec2(0, 1)), vanillaCloudCell(i + ivec2(1, 1)));
    if (o.x + o.y + o.z + o.w == 0.0) return 0.0;
    // マスの境目の近くだけで隣のマスへ移す (辺はまっすぐ、角だけ丸い)
    vec2 u = smoothstep(vec2(0.5 - VANILLA_CLOUD_CORNER), vec2(0.5 + VANILLA_CLOUD_CORNER), f);
    float v = mix(mix(o.x, o.y, u.x), mix(o.z, o.w, u.x), u.y);
    float z = abs(2.0 * hv - 1.0);
    float field = v - VANILLA_CLOUD_ROUND * pow(z, VANILLA_CLOUD_ROUND_POW);
    // 縁だけ揺らす (座標に流れが入っているので揺れも雲と一緒に流れる)
    if (detail > 0.0 && abs(field - 0.5) < VANILLA_CLOUD_SOFT + VANILLA_CLOUD_EDGE_NOISE) {
        float n = textureLod(cloudDetailTex, vec3(q.x, y, q.y) / VANILLA_CLOUD_NOISE_PERIOD, 0.0).r;
        // 上下の面は平らなまま残す (揺らすと底がまだらのくぼみになる)
        field += (n - 0.5) * VANILLA_CLOUD_EDGE_NOISE * detail * (1.0 - z * z);
    }
    return smoothstep(0.5 - VANILLA_CLOUD_SOFT, 0.5 + VANILLA_CLOUD_SOFT, field);
}

float vanillaCloudDensity(vec2 q, float y) {
    float slabHeight;
    return vanillaCloudDensity(q, y, 0.0, slabHeight);
}

// 光源方向の光学的深さ: 板の上面まで (最長 VANILLA_CLOUD_LIGHT_REACH ブロック) を等分して積む。\r\n// 歩の位置を揺らすと陰がまだらの粒になるので、決まった位置で読む
float vanillaCloudLightOD(vec2 q, float y, vec3 lightDir) {
    vec3 d = normalize(vec3(lightDir.x, max(lightDir.y, VANILLA_CLOUD_MIN_LIGHT_Y), lightDir.z));
    float top = vanillaCloudBottom() + VANILLA_CLOUD_THICKNESS;
    float reach = min((top - y) / d.y, VANILLA_CLOUD_LIGHT_REACH);
    float ds = reach / float(VANILLA_CLOUD_LIGHT_STEPS);
    float od = 0.0;
    for (int i = 0; i < VANILLA_CLOUD_LIGHT_STEPS; i++) {
        float s = (float(i) + 0.5) * ds;
        od += vanillaCloudDensity(q + d.xz * s, y + d.y * s);
    }
    return od * ds * (VANILLA_CLOUD_KREF * VANILLA_CLOUD_SIGMA);
}

// 真上 (空の光) 方向の光学的深さ: 板の上面までの真ん中の 1 点で代表させる
float vanillaCloudSkyOD(vec2 q, float y) {
    float top = vanillaCloudBottom() + VANILLA_CLOUD_THICKNESS;
    return vanillaCloudDensity(q, 0.5 * (y + top)) * (top - y) * (VANILLA_CLOUD_KREF * VANILLA_CLOUD_SIGMA);
}

/*
 * 雲影マップの点 relWorld (CLOUD_BASE の面の、カメラ基準のワールド xz) から光源方向に板を抜けるまでの透過率
 * weight: 板の濃さの倍率 (雨雲へ移る間は薄める)
 */
float vanillaCloudShadowTransmittance(vec2 relWorld, vec3 lightDir, float weight) {
    float ly = max(lightDir.y, CLOUD_SHADOW_MIN_LIGHT_Y);
    float bottom = vanillaCloudBottom();
    vec2 origin = vanillaCloudOrigin();
    float dh = VANILLA_CLOUD_THICKNESS / float(VANILLA_CLOUD_SHADOW_STEPS);
    float od = 0.0;
    for (int i = 0; i < VANILLA_CLOUD_SHADOW_STEPS; i++) {
        float y = bottom + (float(i) + 0.5) * dh;
        vec2 p = relWorld + lightDir.xz * ((y - CLOUD_BASE) / ly);
        od += vanillaCloudDensity(origin + p, y);
    }
    od *= dh / ly * (VANILLA_CLOUD_KREF * VANILLA_CLOUD_SIGMA) * weight;
    // 多重散乱で厚い雲の下にも光が少し抜ける (低層の雲影と同じ)
    return max(exp(-od), 0.25 * exp(-od * 0.25));
}

#endif

#endif
