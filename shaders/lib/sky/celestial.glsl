/*
 * 天体: 太陽円盤・月 (位相)・星・天の川・大気光・エンドの空 (sky モジュール)
 * すべて解析的に描く (テクスチャ不要)。星と天の川は太陽と一緒に回る天球座標に固定する
 */
#ifndef SKY_CELESTIAL_GLSL
#define SKY_CELESTIAL_GLSL

// 太陽と月の円盤の放射を照度から決める時の周縁減光 (I(mu) = 1 - u (1 - mu)) の係数
const float SUN_LIMB_DARKENING = 0.6;
// 月面の地球照 (新月側がうっすら見える明るさ, 満月の照り返しに対する比)
const float MOON_EARTHSHINE = 0.004;
// 月の円盤の見かけの大きさ (atmosphere.glsl の MOON_ANGULAR_RADIUS に対する倍率)
const float MOON_DISK_SCALE = 2.5;
/*
 * 夜の月の円盤の明るさの倍率 (見た目の調整)。物理的な放射のままだと、夜の露出では円盤が白飛びして強いブルームと光条の
 * 光る玉になり、海もクレーターも見えなかった。昼の月は青空と同じくらいの明るさで淡く見えるのが正しいので 1 にする
 */
const float MOON_NIGHT_BRIGHTNESS = 0.004;

const float STAR_GRID = 110.0;          // 天球を刻む格子の細かさ (セル 1 つに星は最大 1 個)
const float STAR_DENSITY = 0.055;       // 星があるセルの割合
const float STAR_RADIANCE = 0.03;       // 最も明るい星の中心の放射
const float MILKY_WAY_RADIANCE = 4e-4;
const float AIRGLOW_RADIANCE = 6e-5;
const vec3 MILKY_WAY_POLE = vec3(0.3302, 0.5503, 0.7670); // 天球座標での銀河面の法線 (正規化済み)
const vec3 MILKY_WAY_CORE = vec3(0.9184, -0.0, -0.3954);   // 銀河中心の方向 (銀河面上)

const vec3 END_SKY_COLOR = vec3(0.045, 0.030, 0.070);
const vec3 END_NEBULA_COLOR = vec3(0.30, 0.18, 0.55);
const vec3 END_NEBULA_COLOR_COOL = vec3(0.10, 0.20, 0.50); // 星雲の寒色側 (紫一色だと平板なので色相に幅を持たせる)
const float END_ZENITH_DARKEN = 0.3;    // 天頂の暗さ (END_SKY_COLOR に対する倍率)。地平線ほど星雲の光が積もって明るい
const float END_NEBULA_RADIANCE = 0.16; // 星雲の最も明るい所の放射 (END_NEBULA_COLOR に対する倍率)

// 画面 1 ピクセルの見込み角 (rad)。星と円盤の縁のアンチエイリアス幅
float skyPixelAngle() { return 2.0 / (viewHeight * gbufferProjection[1][1]); }

/*
 * 天球の極 (太陽の日周運動の回転軸, player 空間)
 * Iris は太陽を Ry(-90) Rz(sunPathRotation) Rx(角度) で回すので、回転軸は (0, sin a, cos a)
 */
vec3 celestialPole() {
    float a = radians(sunPathRotation);
    return vec3(0.0, sin(a), cos(a));
}

// 視線を天球座標へ (x = 太陽方向, z = 極)。夜空が太陽と一緒に回る
vec3 toCelestial(vec3 dir) {
    vec3 pole = celestialPole();
    vec3 sunDir = getSunDir();
    vec3 e1 = sunDir - pole * dot(sunDir, pole);
    e1 /= max(length(e1), 1e-4);
    vec3 e2 = cross(pole, e1);
    return vec3(dot(dir, e1), dot(dir, e2), dot(dir, pole));
}

float skyFbm3(vec3 p, int octaves) {
    float sum = 0.0, amp = 0.5;
    for (int i = 0; i < octaves; i++) {
        sum += valueNoise3d(p) * amp;
        p = p * 2.03 + 17.1;
        amp *= 0.5;
    }
    return sum;
}

// 夜の度合い (星・天の川・大気光を出す強さ)
float skyNightFactor() { return smoothstep(0.05, -0.12, getSunDir().y); }

/*
 * 太陽円盤。照度 E を円盤の立体角で割った放射に周縁減光を掛ける (円盤の積分 = E)
 * viewT: 視線方向の大気透過率 (地平線の下は 0)
 */
vec3 skySunDisk(vec3 dir, vec3 sunDir, vec3 illuminance, vec3 viewT) {
    float angle = length(dir - sunDir); // 小角では弦長 = 角度。acos より精度が高い
    float pixel = skyPixelAngle();
    float coverage = saturate((SUN_ANGULAR_RADIUS - angle) / pixel + 0.5);
    if (coverage <= 0.0) return vec3(0.0);
    float mu = sqrt(max(1.0 - sqr(angle / SUN_ANGULAR_RADIUS), 0.0));
    float limb = (1.0 - SUN_LIMB_DARKENING * (1.0 - mu)) / (1.0 - SUN_LIMB_DARKENING / 3.0);
    return illuminance / (PI * SUN_ANGULAR_RADIUS * SUN_ANGULAR_RADIUS) * limb * viewT * coverage;
}

// 月の位相角 (0 = 満月, PI = 新月)。moonPhase: 0 満月 -> 4 新月 -> 7
float moonPhaseAngle() { return float(moonPhase) * (PI / 4.0); }

/*
 * 月面。Lommel-Seeliger 反射 (月の表土で満月が縁まで平らに明るい) で位相を付け、海とクレーターを描く
 * 見かけの大きさは MOON_DISK_SCALE 倍 (実寸の 0.5 度では画面で数ピクセルの光る点になり模様が見えない)。
 * 照度は変えず放射を面積で割るので、大きくしても月明かりの明るさは同じで、円盤はそのぶん白飛びしにくい
 * illuminanceFull: 満月時の照度 (位相の減光前)
 */
vec3 skyMoonDisk(vec3 dir, vec3 moonDir, vec3 illuminanceFull, vec3 viewT) {
    float radius = MOON_ANGULAR_RADIUS * MOON_DISK_SCALE;
    float angle = length(dir - moonDir);
    float pixel = skyPixelAngle();
    float coverage = saturate((radius - angle) / pixel + 0.5);
    if (coverage <= 0.0) return vec3(0.0);

    vec3 right = normalize(cross(moonDir, celestialPole()));
    vec3 up = cross(right, moonDir);
    vec2 p = vec2(dot(dir, right), dot(dir, up)) / radius;
    float rr = min(dot(p, p), 1.0);
    vec3 n = vec3(p, sqrt(1.0 - rr));

    float alpha = moonPhaseAngle();
    // 満ちる側と欠ける側で照らされる縁が逆になる
    vec3 l = vec3(sin(alpha), 0.0, cos(alpha));
    float mu0 = max(dot(n, l), 0.0);
    float lommel = 2.0 * mu0 / (mu0 + n.z + 1e-3);

    // 月面の模様 (海・クレーター) は廃止し、一様な白い円盤にした。満ち欠けの陰影だけ残す
    vec3 radiance = illuminanceFull / (PI * radius * radius);
    radiance *= mix(MOON_NIGHT_BRIGHTNESS, 1.0, smoothstep(-0.1, 0.1, getSunDir().y));
    return radiance * (lommel + MOON_EARTHSHINE) * viewT * coverage;
}

// 星 1 セル分。明るさはべき乗分布 (暗い星ほど多い)、色は黒体放射、瞬きは地平線ほど強い
vec3 skyStarField(vec3 c, vec3 dir) {
    float band = exp(-sqr(dot(c, MILKY_WAY_POLE)) * 25.0);
    float density = STAR_DENSITY * (1.0 + 1.5 * band);
    vec3 p = c * STAR_GRID;
    ivec3 cell = ivec3(floor(p));
    vec3 h = hash3(uvec3(cell + 32768));
    if (h.x > density) return vec3(0.0);
    float rnd = h.x / density;

    // 星の中心はセルの内側半分に置き、隣のセルで切れないようにする
    vec3 starDir = normalize((vec3(cell) + 0.25 + 0.5 * vec3(h.y, h.z, fract(h.y * 7.31 + h.z * 3.17))) / STAR_GRID);
    float size = max(skyPixelAngle(), 3e-4) * 0.75;
    float profile = exp(-sqr(length(c - starDir) / size));

    float brightness = 0.015 + 0.985 * pow(1.0 - rnd, 7.0);
    float temperature = mix(3200.0, 11000.0, fract(h.y * 13.7 + h.z * 5.1));
    vec3 color = mix(vec3(1.0), blackbody(temperature), 0.6);
    float twinklePhase = fract(h.z * 31.7) * TAU;
    float twinkle = 1.0 + (0.35 + 0.4 * (1.0 - saturate(dir.y * 2.0))) * sin(frameTimeCounter * (6.0 + 5.0 * h.y) + twinklePhase) * (1.0 - brightness * 0.5);
    return color * brightness * twinkle * profile * STAR_RADIANCE;
}

vec3 skyMilkyWay(vec3 c) {
    float latitude = dot(c, MILKY_WAY_POLE);
    float band = exp(-latitude * latitude / 0.03);
    if (band < 0.01) return vec3(0.0);
    float core = exp((dot(c, MILKY_WAY_CORE) - 1.0) * 2.5);
    float cloud = skyFbm3(c * 6.0, 4);
    // 中心線に沿った暗黒帯 (星間塵)
    float dust = smoothstep(0.42, 0.68, skyFbm3(c * 13.0 + 5.0, 3)) * exp(-latitude * latitude / 0.004);
    vec3 color = mix(vec3(0.72, 0.80, 1.0), vec3(1.0, 0.86, 0.66), core);
    return color * band * (0.25 + cloud) * (1.0 + 2.5 * core) * (1.0 - 0.8 * dust) * MILKY_WAY_RADIANCE;
}

// 大気光 (上空の酸素の化学発光)。地平線から少し上の緑の帯で、夜空が真っ黒にならない下地を作る
vec3 skyAirglow(vec3 dir) {
    float elevation = max(dir.y, 0.0);
    float glow = exp(-abs(elevation - 0.1) * 12.0) + 0.15;
    return vec3(0.40, 1.0, 0.55) * glow * AIRGLOW_RADIANCE;
}

// 夜空 (星 + 天の川 + 大気光)。viewT で地平線の減光
vec3 skyNightSky(vec3 dir, vec3 viewT) {
    float night = skyNightFactor();
    if (night <= 0.0) return vec3(0.0);
    vec3 c = toCelestial(dir);
    vec3 result = vec3(0.0);
#ifdef STARS
    result += skyStarField(c, dir) + skyMilkyWay(c);
#endif
    result += skyAirglow(dir);
    return result * viewT * night * (1.0 - 0.9 * rainStrength);
}

/*
 * エンドの空: 暗い紫の地に、渦を巻く星雲と星
 * 星はワールド軸に固定 (エンドに日周運動はない)
 * 一様な地に薄い斑を足すだけだと、露出が上がって全体が平板なラベンダー色になる。
 * 天頂を暗く、星雲を歪めた fbm の筋と暗黒帯で強弱を付け、色相も紫から青へ振る
 */
vec3 renderEndSky(vec3 dir) {
    float horizon = exp(-abs(dir.y) * 3.0);
    vec3 base = END_SKY_COLOR * mix(END_ZENITH_DARKEN, 1.0, horizon);
    vec3 p = dir * 2.2 + vec3(0.0, frameTimeCounter * 0.004, 0.0);
    // 渦: 低周波の fbm で座標を歪めてから読み、引き伸ばされた筋にする
    vec3 warp = vec3(skyFbm3(p + 3.1, 3), skyFbm3(p + 7.7, 3), skyFbm3(p + 1.3, 3)) - 0.5;
    vec3 q = p * 1.6 + warp * 2.5;
    float n = skyFbm3(q, 5);
    float cloud = smoothstep(0.38, 0.78, n);
    // 筋の稜線 (明るいフィラメント) と、星雲の中を横切る暗黒帯
    float filament = pow(1.0 - abs(2.0 * skyFbm3(q * 2.3 + 5.0, 4) - 1.0), 6.0);
    float dust = smoothstep(0.48, 0.7, skyFbm3(q * 3.1 + 9.0, 3));
    vec3 color = mix(END_NEBULA_COLOR, END_NEBULA_COLOR_COOL, smoothstep(0.35, 0.65, skyFbm3(p * 0.7 + 11.0, 2)));
    float nebula = (cloud * 0.55 + filament * cloud * 0.8 + filament * 0.12) * (1.0 - 0.75 * dust);
    vec3 result = base + color * nebula * END_NEBULA_RADIANCE * mix(0.6, 1.0, horizon);
#ifdef STARS
    // 星雲の暗黒帯は星も隠す
    result += skyStarField(dir, dir) * (1.0 - 0.6 * dust * cloud);
#endif
    return result;
}

#endif
