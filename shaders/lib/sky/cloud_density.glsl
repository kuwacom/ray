/*
 * 体積雲の密度: 低層 (積雲・層積雲・積乱雲・板)・中層・上層の消散係数
 * sky モジュール (cloud_volume.glsl が読む)
 */
#ifndef SKY_CLOUD_DENSITY_GLSL
#define SKY_CLOUD_DENSITY_GLSL

//@include "/lib/sky/cloud_constants.glsl"
//@include "/lib/sky/cloud_weather.glsl"
//@include "/lib/sky/cloud_vanilla.glsl"

// 密度
struct CloudColumn {
    float cover;
    float type;
};

CloudColumn cloudLowColumn(vec4 map) {
    CloudColumn col;
    col.cover = map.r * CLOUD_COVER_RANGE;
    col.type = map.g;
    return col;
}

float cloudStratusWeight(float type) { return 1.0 - smoothstep(0.2, 0.45, type); }
float cloudCumulonimbusWeight(float type) { return smoothstep(0.75, 0.95, type); }
// 嵐の中心ほど 1 (塔の太さ・かなとこ・降水の柱の芯)
float cloudStormCore(float type) { return linearStep(0.75, 1.0, type); }

/*
 * 積雲 1 つの大きさのセルの形 (底 0 から測った高さ hb で)。セル値 v のしきい値 1 - cover より上が雲
 * 立ち上がり幅とドームの幅は被覆に比例させる (小さな雲は被覆が小さく、固定幅だと最後まで薄いまま立ち上がらない)
 */
void cloudCumulusCell(float v, float cover, float topScale, float hb, inout float best, inout float bestX, inout float bestSize) {
    if (cover <= 0.0) return;
    // 被覆がごく小さいと雲はセルの頂点の周りの数テクセル (cloudNoiseTex の 1 テクセル = 既定 84 m) だけになり、双一次補間の面が
    // そのまま見えた (雷雨の全天の被覆で小さなセルが晴れ間の抑制 x 0.2 を受け、近くの雲底に直線の縁の明るい四角い面)。
    // 形は最小の被覆で作り、それより小さい分は濃さで薄める
    float fade = saturate(cover / CLOUD_CELL_MIN_COVER);
    cover = max(cover, CLOUD_CELL_MIN_COVER);
    float threshold = 1.0 - cover;
    // 足跡の外側も負の値のまま返す (外殻のもやの幅を測る)。もやの届かない所はここで打ち切る
    float footprint = min((v - threshold) / (CLOUD_COVER_SOFTNESS * min(cover / 0.35, 1.0)), 1.0);
    if (footprint * 1.25 <= -CLOUD_HAZE_REACH) return;
    // 高さは被覆の飽和した footprint ではなく、セルの値そのものから連続に決める (セルの中心へ向かって盛り上がるドーム。
    // footprint で決めると中が一様な高さになり、頂が平らな箱に見えた)
    float tall = linearStep(threshold, threshold + CLOUD_DOME_WIDTH * min(cover / 0.5, 1.0), v);
    float x = hb / (topScale * (CLOUD_DOME_BASE + (1.0 - CLOUD_DOME_BASE) * pow(tall, CLOUD_DOME_ROUND)));
    // 積雲は被覆から高さの形を引く: 上ほど細るドームに加え、底の近くも少し細らせて縁が巻き上がった底にする
    // (掛け算だと底が雲の一番広い所になり、垂直な壁と平らな張り出しの段が重なった形に見えた)
    // 頂の上も負へ下げ続ける (x を 1 で止めると頂の上一面がもやの縁 0 に張り付く)
    float profile = min(footprint * 1.25 - 1.25 * pow(x, CLOUD_DOME_POW) - CLOUD_BASE_TUCK * (1.0 - smoothstep(0.0, 0.25, x)), 1.0);
    // 負側 (もや) は fade で割らない。被覆が 0 に近い所のもやは、天気図の被覆で連続に消す (cloudLowDensity の hazeReach)
    profile = (profile > 0.0 ? profile * CLOUD_DOME_GAIN : profile) - (CLOUD_DOME_GAIN - 1.0) * CLOUD_DOME_OFFSET;
    if (profile > 0.0) profile = min(profile, 1.0) * fade;
    if (profile > best) {
        best = profile;
        bestX = x;
        bestSize = topScale;
    }
}

#ifdef CLOUD_CB
/*
 * 積乱雲の雲量 (浸食前) と雲の中の高さ。core: 嵐の中心ほど 1, hc: 雲底 0 / 対流圏界面 1
 * 塔: 上ほど少し細る柱。かなとこ: 対流圏界面で上昇が止まり、風下へ伸びる平たい氷の層 (風上の芯を読んで広げる)。
 * オーバーシュート: 最も強い芯の上でかなとこを突き抜けるドーム。乳房雲: かなとこの下面から垂れる袋 (細かいセルの高さ場)
 */
float cloudCumulonimbusShape(float core, vec2 rel, float hc, vec4 cells, float shape, out float x) {
    x = hc;
    float pouch = cells.a;
    // 塔は 1 本の円柱ではなく、積雲のセル (大・中) が束になって盛り上がる。上ほど細り (雄大雲の頭)、かなとこの下で止まる
    // 3D の形状ノイズも足して、高さごとに張り出しの違うこぶの側面にする (2D の足跡だけだと垂直な壁の柱に見えた)
    // 塔の輪郭は 3D ノイズで大きく出し入れし、立ち上がりも狭くする (広い立ち上がりだと中が一様に詰まった、なめらかな灰色の球に見えた)
    float lumpy = core + (cells.r - 0.5) * 0.6 + (cells.b - 0.5) * 0.3 + (shape - 0.5) * 1.1;
    float body = linearStep(0.25 + 0.5 * hc, 0.4 + 0.5 * hc, lumpy) * (1.0 - smoothstep(CLOUD_CB_ANVIL_BASE, CLOUD_CB_ANVIL_TOP, hc));
    float dome = CLOUD_CB_ANVIL_TOP + (1.0 - CLOUD_CB_ANVIL_TOP) * sqrt(linearStep(0.65, 1.0, core));
    float overshoot = linearStep(0.55, 0.8, core) * (1.0 - smoothstep(dome - 0.03, dome, hc));
    float cloudiness = max(body, overshoot);
    float anvilBottom = CLOUD_CB_ANVIL_BASE - CLOUD_CB_MAMMA * sqr(pouch);
    if (hc > anvilBottom - 0.02 && hc < CLOUD_CB_ANVIL_TOP) {
        // 風上の芯を読んで風下へ伸ばす (かなとこは輪ではなく風下に長い)
        // 塔から風下の先まで切れ目なく続くよう、風上の 2 点を読む
        float near = cloudStormCore(cloudMapFetch(rel - CLOUD_HIGH_WIND_DIR * (0.4 * CLOUD_CB_ANVIL_LENGTH)).g);
        float upwind = cloudStormCore(cloudMapFetch(rel - CLOUD_HIGH_WIND_DIR * CLOUD_CB_ANVIL_LENGTH).g);
        float spread = max(max(core, near * 0.95), upwind * 0.8) + (cells.g - 0.5) * 0.2;
        float anvil = linearStep(0.25, 0.55, spread) * linearStep(anvilBottom - 0.02, anvilBottom + 0.02, hc)
                    * (1.0 - linearStep(CLOUD_CB_ANVIL_TOP - 0.03, CLOUD_CB_ANVIL_TOP, hc));
        cloudiness = max(cloudiness, anvil);
    }
    return cloudiness;
}
#endif

// Worley の塊のノイズ n から削る量 (塊の中ほど 0、境目ほど大きい)。body: 浸食前の雲量で見た塊の中らしさ [0,1]
// 鋭くするのは大きな塊の中だけ。薄い小さな雲まで鋭く削ると、こぶが切り離された白い粒の群れ (ポップコーン) になった
float cloudLobeErosion(float n, float body) {
    return mix(1.0 - n, pow(1.0 - n, CLOUD_LOBE_SHARPNESS) * CLOUD_LOBE_SHARP_GAIN, body);
}

#if CLOUDS != 3
/*
 * 2D 押し出しの断面: 平らな芯の高さの区間の外を超楕円の角で丸める (縁の薄い所ほど上下から細って、枕のような断面になる)
 * 区間と指数は、被覆 0.5 で高さの 0.06〜0.92 に雲が残り、被覆 0.1 で 0.16〜0.77 まで細る値
 */
const float CLOUD2D_CORE_LOW = 0.22;
const float CLOUD2D_CORE_HIGH = 0.69;
const float CLOUD2D_ROUND_POW = 1.45; // 2 で円の角、1 で斜めの面取り

float cloud2dShoulder(float h) {
    float s = h < CLOUD2D_CORE_LOW ? (CLOUD2D_CORE_LOW - h) / CLOUD2D_CORE_LOW
                                   : max(h - CLOUD2D_CORE_HIGH, 0.0) / (1.0 - CLOUD2D_CORE_HIGH);
    return 1.0 - pow(1.0 - pow(saturate(s), CLOUD2D_ROUND_POW), 1.0 / CLOUD2D_ROUND_POW);
}
#endif

/*
 * 低層の密度 [0,1] (消散係数 = CLOUD_LOW_SIGMA x 密度)
 * rel: カメラ基準の水平位置 (参照 m), altitude: 参照高度 (m)
 * detail: 縁の浸食の強さ [0,1] (距離の LOD。0 で浸食を省く)
 * cloudHeight: その雲の中の高さ (底 0 / 頂 1)。底を暗く沈める光の計算に使う
 */
float cloudLowDensityCumulus(CloudContext ctx, CloudColumn col, vec2 rel, float altitude, float detail, bool lightPath, out float cloudHeight) {
    cloudHeight = 0.5;
    float h = (altitude - CLOUD_R_BASE) / CLOUD_R_DEPTH;
    if (h <= 0.0 || altitude >= ctx.lowTop) return 0.0;
    float wCb = 0.0;
#ifdef CLOUD_CB
    wCb = cloudCumulonimbusWeight(col.type);
#endif
    if (h >= 1.0 && wCb <= 0.0) return 0.0;
    vec2 q = rel + ctx.lowOrigin;

#if CLOUDS == 3
    // 3D の座標。上ほど風下へずらす (風のシアで雲頂が傾く)
    vec3 p = vec3(q.x, altitude, q.y) + ctx.evolve;
    p.xz -= CLOUD_WIND_DIR * (h * CLOUD_R_DEPTH * CLOUD_SHEAR);
    vec3 curl = texture(cloudDetailTex, p / CLOUD_CURL_PERIOD).gba * 2.0 - 1.0;
    // 2D の被覆を高さごとに少しずらして読み、セルの縁が垂直な壁にならないようにする (側面がふくらみながら上る)
    vec4 cells = texture(cloudNoiseTex, (q + curl.xz * CLOUD_FOOTPRINT_WARP) / CLOUD_CELL_PERIOD);
    float wStrat = cloudStratusWeight(col.type);

    // 雲底の高さ: 地域ごとの凝結高度の差 (天気図の規模でゆっくり変わる) + 層状の雲の底の波打ち + 雲底の近くだけの乱流
    // 層状の雲の底は乱流で波打ち、下から見ると濃淡のまだらになる
    // 凝結高度の差はセルのなめらかな fbm (雲の背丈のばらつきと同じ) で、隣り合う雲どうしで少しずつ変える (追加のフェッチ無し)
    float lift = cells.g * (CLOUD_BASE_VARIATION / CLOUD_R_DEPTH);
    lift += wStrat * (1.0 - cells.g) * (CLOUD_STRATUS_UNDULATION * (1.0 + 2.0 * ctx.rain) / CLOUD_R_DEPTH);
    float hb = h - lift;
    if (hb <= 0.0) return 0.0;

    // 底は平ら、上は丸く (積雲) / 平たく (層積雲)
    float bottom = linearStep(0.0, CLOUD_BASE_RAMP / CLOUD_R_DEPTH, hb);
    // 底の凹凸 (100-300 m): 水平位置だけの高さ場で雲底を削る (3D のノイズで底の位置を揺らすと、高さごとに底の位置が変わって
    // 雲の中の高さ (底の暗さ) が斑に乱れ、下から見た底に黒い染みが出た)。雲の中の高さ x は凹凸の前の底から測る。
    // 底の近くの、視線方向のサンプル (detail > 0) だけで読む。ちぎれは雲底に集中させた curl の浸食で作る
    float raggedRange = (2.0 * CLOUD_BASE_RAGGED + CLOUD_BASE_RAMP) / CLOUD_R_DEPTH;
    if (detail > 0.0 && hb < raggedRange) {
        float ragged = texture(cloudNoiseTex, q / (CLOUD_CELL_PERIOD / 16.0) + vec2(0.29, 0.61)).g * (2.0 * CLOUD_BASE_RAGGED / CLOUD_R_DEPTH);
        bottom = linearStep(ragged, ragged + CLOUD_BASE_RAMP / CLOUD_R_DEPTH, hb);
    }

    // 断片雲: 濃い雲の周りに散らばる薄い小片 (ちぎれ雲・層積雲の切れ端)。濃い塊だけが並ぶと作り物に見えるので、
    // 天気図の規模 (10 km 前後) の群れの中にだけまばらに置き、群れの中でも 1 km ほどの単位で濃さをばらつかせる。
    // 積雲の形とは別に最後に濃い方を取る (積雲の縁と混ぜて濃さが飛ばないように)
    float fractus = 0.0, fractusHeight = 0.5;
    float rainLook = smoothstep(CLOUD_HAZE_RAIN.x, CLOUD_HAZE_RAIN.y, ctx.rain);
    // 視線方向のサンプル (detail > 0) だけで作る。薄いので光・空の光学的深さと雲影への寄与は省く (断片雲のコストを半分ほどに)
    if (CLOUD_FRACTUS_AMOUNT > 0.0 && detail > 0.0 && h < 1.0 && hb < CLOUD_FRACTUS_TOP) {
        vec4 group = texture(cloudNoiseTex, q / CLOUD_CELL_PERIOD + vec2(0.5, 0.25));
        // 晴れ間の真ん中 (被覆 0) と一面の雲の中には出さない
        float amount = CLOUD_FRACTUS_COVER * (0.75 + 0.25 * CLOUD_FRACTUS_AMOUNT) * linearStep(CLOUD_FRACTUS_GROUP.x, CLOUD_FRACTUS_GROUP.y, group.g)
                     * smoothstep(0.03, 0.2, col.cover) * (1.0 - smoothstep(0.8, 1.15, col.cover));
        if (amount > 0.0) {
            float n = texture(cloudShapeTex, p / CLOUD_FRACTUS_PERIOD * CLOUD_FRACTUS_STRETCH + vec3(0.21, 0.47, 0.83)).r * 0.75 + cells.a * 0.25;
            float frag = linearStep(1.0 - amount, 1.0 - amount + 0.2, n);
            // 小片ほど平たい。上へ細りながら消える
            float fractusX = hb / (CLOUD_FRACTUS_TOP * (0.35 + 0.65 * frag));
            float f = frag * (1.0 - smoothstep(0.3, 1.0, fractusX)) * bottom;
            // 薄い小片は中まで光が通るので、積雲の底のようには沈めない
            fractusHeight = mix(0.5, 1.0, saturate(fractusX));
            if (f > 0.0 && detail > 0.0) {
                // 縁は細かい浸食でほつれさせる (底の巻き上がりと同じ curl の歪み)
                float e = texture(cloudDetailTex, (p + curl * CLOUD_CURL_AMOUNT) / CLOUD_DETAIL_PERIOD).r;
                f -= (1.0 - e) * (0.6 * CLOUD_LOW_EROSION) * min(detail * 2.5, 1.0);
            }
            // 縁の浸食が弱まる 8-13 km で消す (遠くで急に途切れないように。12-18 km まで残すと、ほつれの無い滑らかな小片が
            // 地平線の手前で透視に潰され、夕方の逆光で流し撮りのような筋に見えた)
            fractus = saturate(f * 2.0) * mix(CLOUD_FRACTUS_DENSITY.x, CLOUD_FRACTUS_DENSITY.y, group.a) * saturate(detail * 5.0 - 1.0) * mix(1.0, ctx.densityScale, rainLook)
                    * min(CLOUD_FRACTUS_AMOUNT, 1.0);
        }
    }

    // 雲量は負にもなる (-CLOUD_HAZE_REACH までは外殻のもや)
    float cloudiness = -CLOUD_HAZE_REACH;
    float x = 1.0;
    float turret = -1.0;
    float size = 1.0; // 積雲の大きさ (CLOUD_CU_HEIGHT の大 / 中 / 小)
    if (h < 1.0) {
        // 積雲: 大中小のセル (r / b / a) を同じフェッチから読み、被覆をべき乗則の割合で分ける。
        // 雲頂は対流の強さ (CLOUD_CU_TOP) x セルの中心ほど高いドーム x 隣どうしのばらつき (なめらかな fbm)
        float cumulus = -CLOUD_HAZE_REACH, cumulusX = 1.0, cumulusSize = 1.0;
        if (wStrat < 1.0) {
            // 塔の塊のノイズはここで読み、下の塔の削りでも使う
            turret = texture(cloudShapeTex, p / (CLOUD_SHAPE_PERIOD * CLOUD_TURRET_SCALE) + CLOUD_TURRET_NOISE_OFFSET).g;
            float lumpV = (turret - 0.5) * CLOUD_LUMP_V;
            // 対流の強さの 2 乗で伸ばす: 晴れた日の積雲はふつう背より幅が広い扁平雲・並雲で、雄大雲は対流がかなり強い時だけ
            // (一次だと並の日でも 1.5 km 級の丸い塊が並び、綿玉のように見えた)
            // 2 乗 + 下限 0.22 では並の日の雲が 0.5 km 前後の平たい帯ばかりになり、盛り上がった積雲の立体感が出ない。
            // 下限を上げて一次にする (大きなセルの割合が小さいので綿玉の列にはならない)
            float topBase = mix(CLOUD_CU_TOP.x, CLOUD_CU_TOP.y, ctx.convection) * CS_HEIGHT * (1.0 + CLOUD_CU_TOP_SPREAD * (cells.g - 0.5));
            float topKnee = max(0.2 - abs(topBase - CLOUD_CU_TOP_MAX), 0.0) / 0.2;
            topBase = min(topBase, CLOUD_CU_TOP_MAX) - sqr(topKnee) * 0.05;
            float coverBig = col.cover * CLOUD_CU_SHARE.x;
            // 大きな雲のすぐ外は補償の下降流で晴れるので、中小の雲を減らして間隔を空ける
            float clearing = 1.0 - CLOUD_CU_CLEARING * smoothstep(1.0 - coverBig - CLOUD_CU_CLEARING_WIDTH, 1.0 - coverBig, cells.r);
            cloudCumulusCell(cells.r + lumpV, coverBig, CLOUD_CU_HEIGHT.x, hb / topBase, cumulus, cumulusX, cumulusSize);
            cloudCumulusCell(cells.b + lumpV, col.cover * CLOUD_CU_SHARE.y * clearing, CLOUD_CU_HEIGHT.y, hb / topBase, cumulus, cumulusX, cumulusSize);
            cloudCumulusCell(cells.a + lumpV, col.cover * CLOUD_CU_SHARE.z * clearing, CLOUD_CU_HEIGHT.z, hb / topBase, cumulus, cumulusX, cumulusSize);
        }
        float stratus = 0.0, stratusX = 0.0;
        if (wStrat > 0.0) {
            // 層積雲: 片方向に引き伸ばしたセルとなめらかな fbm を混ぜ、ロール状の塊とその間の隙間を作る
            // ロールも積雲のセルと同じく高さごとに揺らして読む (2D のままだと側面が垂直な壁になり、
            // 雷雨の日に平らな頂と直線の縁の明るい面が見えた)
            float roll = texture(cloudNoiseTex, (q + curl.xz * CLOUD_FOOTPRINT_WARP) / CLOUD_ROLL_PERIOD).r;
            float v = mix(cells.r, roll * 0.7 + cells.g * 0.3, wStrat);
            float footprint = linearStep(1.0 - col.cover, 1.0 - col.cover + CLOUD_COVER_SOFTNESS, v);
            // 頂は縁ほど低い (足跡のまま一定の高さだと、上から見て垂直な壁の箱が並んだ)。小さなセルで頂を波打たせる
            stratusX = hb / (mix(CLOUD_SC_TOP.x, CLOUD_SC_TOP.y, ctx.rain) * (0.35 + 0.65 * footprint) * (0.75 + 0.5 * cells.a));
            stratus = footprint * (1.0 - smoothstep(0.5, 1.0, stratusX));
        }
        // 外殻のもやは積雲だけ (層積雲は足跡の外を -CLOUD_HAZE_REACH 扱いにして、正側だけ積雲と混ぜる)
        float solid = mix(max(cumulus, 0.0), stratus, wStrat);
        cloudiness = solid > 0.0 ? solid : mix(cumulus, -CLOUD_HAZE_REACH, wStrat);
        x = mix(cumulusX, stratusX, wStrat);
        size = mix(cumulusSize, 1.0, wStrat);
    }
#ifdef CLOUD_CB
    float ice = 0.0;
    float stormCore = 0.0;
    vec2 s = vec2(-1.0);
    if (wCb > 0.0) {
        s = texture(cloudShapeTex, p / CLOUD_SHAPE_PERIOD).rg;
        float hc = (altitude - CLOUD_R_BASE - lift * CLOUD_R_DEPTH) / (CLOUD_R_CB_TOP - CLOUD_R_BASE);
        float xCb;
        // 嵐の芯は天気図 (256 m の格子の双一次補間) のなめらかな面なので、そのまま等値面を取ると塔の側面に直線の縁の平らな面が出た。
        // curl で読む位置を揺らして面をうねらせる
        stormCore = cloudStormCore(cloudMapFetch(rel + curl.xz * CLOUD_CB_WARP).g);
        float cb = cloudCumulonimbusShape(stormCore, rel, hc, cells, s.g, xCb) * wCb;
        // 塔の側面の大きなこぶ (0.6-1.5 km)。積雲のこぶ (200-400 m) は 15 km 先では画素以下になり、遠い塔がなめらかな塊に見えた
        float tower = texture(cloudShapeTex, p / (CLOUD_SHAPE_PERIOD * CLOUD_CB_LUMP_SCALE) + vec3(0.61, 0.27, 0.05)).r;
        cb -= (1.0 - tower) * CLOUD_CB_LUMP_EROSION * (1.0 - 0.6 * smoothstep(0.55, 0.8, hc));
        if (cb > max(cloudiness, 0.0)) {
            cloudiness = cb;
            x = xCb;
            size = 1.0;
            // 上部は氷晶化してなめらかな繊維状 (カリフラワーの浸食を弱める)
            ice = smoothstep(0.55, 0.8, hc);
        }
    }
#endif
    cloudHeight = saturate(x);
    // 底より下へはもやを出さない (持ち上げ凝結高度で一斉に雲になる平らな底は保つ)
    cloudiness = cloudiness > 0.0 ? cloudiness * bottom : cloudiness - (1.0 - bottom) * CLOUD_HAZE_REACH;
    float coreBody = smoothstep(CLOUD_CORE_BODY.x, CLOUD_CORE_BODY.y, cloudiness);
    // 外殻のもやの幅 (層積雲・積乱雲は 0 = 輪郭で打ち切る)
    // 被覆 0 の境界 (天気図の双一次補間の直線) でもやが切れないよう、被覆が小さいほど狭める。
    // 雨天・雷雨にはもやを付けない (付けると嵐の穴の縁がもやで埋まり、照らされた縁が鈍る)
    float cumulusShare = (1.0 - wStrat) * (1.0 - wCb) * (1.0 - rainLook);
    float hazeReach = CLOUD_HAZE_REACH * cumulusShare * saturate(col.cover / CLOUD_CELL_MIN_COVER);
    if (cloudiness <= -hazeReach) { cloudHeight = fractusHeight; return fractus; }

#ifdef CLOUD_CB
    if (s.x < 0.0) s = texture(cloudShapeTex, p / CLOUD_SHAPE_PERIOD).rg;
#else
    vec2 s = texture(cloudShapeTex, p / CLOUD_SHAPE_PERIOD).rg;
#endif
    // 積雲は Worley 寄りのもこもこ、層積雲は Perlin 寄りのなめらかな塊
    float shape = mix(s.r, s.g, (1.0 - wStrat) * 0.7);
    // 底の近くは削りを弱めて平らで幅のある底を残し、上ほど削って塔状に盛り上がる塊にする
    // (低周波の 3D ノイズで底まで削ると、底だけ削れて上が残った所が下すぼまりのきのこ・牙の形になった。底の近くはほぼ削らない)
    float baseKeep = mix(mix(CLOUD_BASE_KEEP, 1.0, smoothstep(0.0, CLOUD_BASE_KEEP_REACH, x)), 1.0, wStrat);
    // 小さな雲は形状ノイズ (周期 7 km) の塊より小さいので、同じ量を削ると一様に薄くなり、下から見ても陰の無い白い粒になった。
    // 大きさに比例して削る (小さな雲も芯は光学的に厚く、灰色の底を持つ)
    baseKeep *= mix(0.4, 1.0, saturate((size - CLOUD_CU_HEIGHT.z) / (1.0 - CLOUD_CU_HEIGHT.z)));
    float d = cloudiness - (1.0 - shape) * CLOUD_SHAPE_EROSION * baseKeep;
    if (d <= -hazeReach) { cloudHeight = fractusHeight; return fractus; }
    // 塔: 積雲の上半分を数百 m の丸い塊 (上昇気流の泡) の積み重なりにする。2D の足跡を縦に伸ばした側面は
    // 縦の幕の筋に見えるので、3D の Worley の塊で側面と頂を区切り、こぶごとに陰を作る (平らな底は残す)
    if (turret < 0.0) turret = texture(cloudShapeTex, p / (CLOUD_SHAPE_PERIOD * CLOUD_TURRET_SCALE) + CLOUD_TURRET_NOISE_OFFSET).g;
    d -= cloudLobeErosion(turret, coreBody) * CLOUD_TURRET_EROSION * mix(CLOUD_TURRET_BASE, 1.0, smoothstep(0.0, 0.6, x)) * (1.0 - wStrat) * (1.0 - wCb);
    if (d <= -hazeReach) { cloudHeight = fractusHeight; return fractus; }
    // 中間スケールのこぶ (200-400 m): 大きな塊の表面にカリフラワーの段を付ける。
    // 光のマーチにも効くので、こぶごとに陰ができて立体に見える
    float billow = texture(cloudShapeTex, p / (CLOUD_SHAPE_PERIOD * CLOUD_BILLOW_SCALE) + vec3(0.37, 0.11, 0.73)).g;
    // 雲頂ほど強く削り、上へ盛り上がるこぶの段を際立たせる (底の近くは平らなまま)
    float billowAmount = CLOUD_BILLOW_EROSION * mix(CLOUD_BILLOW_PROFILE.x, CLOUD_BILLOW_PROFILE.y, smoothstep(0.2, 0.9, x));
#ifdef CLOUD_CB
    billowAmount *= 1.0 - 0.7 * ice;
#endif
    // 底の近くもこぶは残す: 下から見上げた雲の輪郭は底の外周そのもので、底で弱めると 2D のセルのなめらかな輪郭が
    // 斜めに引き伸ばされ、刷毛で伸ばしたような帯に見えた
    d -= cloudLobeErosion(billow, coreBody) * billowAmount * (1.0 - smoothstep(0.0, 0.9, d)) * mix(0.8, 1.0, baseKeep) * mix(1.0, 0.5, wStrat);
    if (d <= -hazeReach) { cloudHeight = fractusHeight; return fractus; }
    if (detail > 0.0) {
        // 歪みは雲底に集中させ、底はちぎれて巻き上がり、上面はなめらかなこぶのまま残す
        float curlWeight = mix(1.0, CLOUD_CURL_TOP, smoothstep(0.0, 0.6, x));
        vec3 dp = p + curl * (CLOUD_CURL_AMOUNT * curlWeight);
        // 周期の違う 2 オクターブを重ねて Worley のセルの規則性を崩す。細かいオクターブは近くだけ
        float e = texture(cloudDetailTex, dp / CLOUD_DETAIL_PERIOD).r;
        float fine = saturate(detail * 2.0 - 1.0);
        if (fine > 0.0) e = mix(e, e * 0.7 + texture(cloudDetailTex, dp / (CLOUD_DETAIL_PERIOD / 3.0)).r * 0.3, fine);
        // Worley の谷を削って粒を残す (カリフラワー)。山を削る「ちぎれ」は薄い所に穴の網目 (蜂の巣模様) が透けるので使わず、
        // 底のちぎれは curl の歪みだけで作る
        // 縁 (密度の低い所) だけを削る。中まで削ると斜めの光でセル模様が透けて見える
        float edge = 1.0 - smoothstep(0.0, CLOUD_DETAIL_REACH, d);
        // 雲底の近くは浸食を強めて、歪めた筋のちぎれを際立たせる
        float baseErode = mix(1.3, 1.0, smoothstep(0.0, 0.2, x));
        // 層積雲の細かい浸食は弱める (薄い層に小さな白い粒が散って見えた)
        d -= (1.0 - e) * edge * CLOUD_DETAIL_EROSION * baseErode * mix(0.6, 1.0, smoothstep(0.0, 0.3, x)) * mix(1.0, 0.45, wStrat) * mix(1.6, 1.0, saturate((size - CLOUD_CU_HEIGHT.z) / (1.0 - CLOUD_CU_HEIGHT.z))) * min(detail * 2.0, 1.0);
        if (d <= -hazeReach) { cloudHeight = fractusHeight; return fractus; }
    }
    // 縁の密度勾配: 輪郭の外は外殻のもや (粗い形状ノイズで厚みを変え、外へ CLOUD_HAZE_FALLOFF 乗で消える)、
    // 内は輪郭のもやの濃さから立ち上がり (edgeWidth)、芯へ向かって coreDepth かけて芯の上限まで濃くなる。
    // 浸食で削った所も真空ではなくもやになるので、ほつれた縁が薄く外へ伸びる
    float hazeEdge = CLOUD_HAZE_DENSITY * hazeReach / CLOUD_HAZE_REACH;
    if (d <= 0.0) {
        float reach = hazeReach * (1.0 - CLOUD_HAZE_SWELL * (1.0 - s.r));
        d = hazeEdge * pow(saturate(1.0 + d / max(reach, 1e-3)), CLOUD_HAZE_FALLOFF);
        if (d <= 0.0) { cloudHeight = fractusHeight; return fractus; }
    } else {
        // 芯の上限と濃淡は積雲だけ
        float coreView = mix(CLOUD_CORE_DENSITY_THIN, CLOUD_CORE_DENSITY, coreBody);
        float coreMax = mix(1.0, (lightPath ? CLOUD_CORE_DENSITY_LIGHT : coreView) * (1.0 - CLOUD_CORE_MOTTLE * (1.0 - billow)), cumulusShare);
        float edgeWidth = mix(CLOUD_EDGE_WIDTH, CLOUD_CU_EDGE_WIDTH, cumulusShare);
        float coreDepth = mix(CLOUD_CORE_DEPTH, CLOUD_CU_CORE_DEPTH, cumulusShare);
        float ramp = (1.0 - sqr(1.0 - saturate(d / edgeWidth))) * mix(CLOUD_EDGE_DENSITY, 1.0, saturate(d / coreDepth));
        d = mix(hazeEdge, coreMax, ramp);
    }
    // 積雲の液水量は高さとともに増える
    // 雨雲は一面に覆っても中の水量にむらがあり、下から濃淡のまだらとして見える
    float rainMottle = mix(1.0, 0.45 + 1.1 * cells.g, ctx.rain * wStrat);
    float water = mix(0.6, 1.0, saturate(x * 1.4));
#ifdef CLOUD_CB
    // 積乱雲の塔は液水量が多い。上部の氷晶の層 (かなとこ) は塔の上で厚く、風下の先ほど薄い半透明になる
    // (一様に厚いと、風下の空一面が暗い灰色の天井になった)
    water *= mix(1.0, mix(CLOUD_CB_WATER, 0.08 + 0.7 * stormCore, ice), wCb);
#endif
    // 雨天の濃さの倍率も見た目と同じ範囲で移す (雨上がりの rainWetness が残る間に、層積雲の切れ端まで濃い白い欠片にならないように)
    float density = d * water * rainMottle * mix(1.0, ctx.densityScale, smoothstep(CLOUD_RAIN_DENSITY.x, CLOUD_RAIN_DENSITY.y, ctx.rain));
    // 光源方向は芯の実測の消散係数で陰を見積もっているので (CLOUD_LIGHT_OD_SCALE)、視線の濃さがそれを超えた分だけ濃くする
    density *= mix(lightPath ? max(CS_DENSITY / CLOUD_STYLE_LIGHT_SIGMA_RATIO, 1.0) : CS_DENSITY, 1.0, rainLook);
    if (fractus > density) { cloudHeight = fractusHeight; return fractus; }
    return density;
#else
    // 2D 押し出し: 平面の被覆をそのまま縦に伸ばし、断面を角の丸い箱にする
    vec4 cells = texture(cloudNoiseTex, q / CLOUD_CELL_PERIOD);
    float footprint = linearStep(1.0 - col.cover, 1.0 - col.cover + CLOUD_COVER_SOFTNESS, cells.r);
    cloudHeight = h;
    float d = footprint - cloud2dShoulder(h);
    if (detail > 0.0) d -= (1.0 - texture(cloudNoiseTex, q / (CLOUD_CELL_PERIOD / 12.0)).a) * 0.2 * detail;
    return saturate(d * 2.5) * ctx.densityScale;
#endif
}

float cloudLowDensity(CloudContext ctx, CloudColumn col, vec2 rel, float altitude, float detail, bool lightPath, out float cloudHeight) {
#ifdef CLOUD_VANILLA_SHAPE
    // 晴天の低層はバニラの形の雲 (cloud_vanilla.glsl) が担う。降り始めのうちに積雲の形 (乱層雲・積乱雲) へ移す
    // (バニラの形の雲と雨雲が重なる間が長いと、バニラの形の明るい筋が雨雲に残る)
    float rainLook = cloudVanillaRainLook(ctx.rain);
    if (rainLook <= 0.0) { cloudHeight = 0.5; return 0.0; }
    return cloudLowDensityCumulus(ctx, col, rel, altitude, detail, lightPath, cloudHeight) * rainLook;
#else
    return cloudLowDensityCumulus(ctx, col, rel, altitude, detail, lightPath, cloudHeight);
#endif
}

// 距離 t (参照 m) の縁の浸食の LOD [0,1]: 0.5-1 で細かいオクターブ、0-0.5 で主オクターブを消していく
float cloudDetailLod(float t) {
    return 0.5 * (1.0 - smoothstep(CLOUD_DETAIL_FADE_FINE.x, CLOUD_DETAIL_FADE_FINE.y, t)) + 0.5 * (1.0 - smoothstep(CLOUD_DETAIL_FADE.x, CLOUD_DETAIL_FADE.y, t));
}

float cloudLowDensity(CloudContext ctx, CloudColumn col, vec2 rel, float altitude, bool detail, bool lightPath) {
    float cloudHeight;
    return cloudLowDensity(ctx, col, rel, altitude, detail ? 1.0 : 0.0, lightPath, cloudHeight);
}

/*
 * 中層 (高積雲 / 高層雲) の密度 [0,1]。cover: 天気図の中層の被覆
 * 被覆が小さい時は小さな塊が群れる高積雲、広く覆う時は一様な高層雲
 * grainHeight: 粒 (または層) の中の高さ (底 0 / 頂 1)。粒の下側を沈めて陰影を付ける
 */
float cloudMidDensity(CloudContext ctx, float cover, vec2 rel, float altitude, bool detail, out float grainHeight) {
    grainHeight = 0.5;
    float h = (altitude - CLOUD_R_MID_BASE) / CLOUD_R_MID_DEPTH;
    if (h <= 0.0 || h >= 1.0) return 0.0;
    vec2 q = rel + ctx.midOrigin;
    // 雨の前後に増える中層は一様な高層雲として広げる (雨上がりの rainWetness が残る間に高積雲の粒のまま増やすと、
    // 低層の雲の周りに縁のくっきりした白い欠片が散らばって見えた)
    float stratus = max(smoothstep(0.6, 1.0, cover), linearStep(CLOUD_MID_RAIN_VEIL.x, CLOUD_MID_RAIN_VEIL.y, ctx.rainLight));
    vec4 n = texture(cloudNoiseTex, q / CLOUD_MID_PERIOD);
    float patches = linearStep(1.0 - cover, 1.0 - cover + CLOUD_MID_PATCH_SOFTNESS, n.g);
    // 高積雲: 細かいセルの一つ一つを、中心ほど背の高い小さなドームにする (うろこ状の小塊。壁のような縁を作らない)
    // 被覆が増えるほど粒どうしをつなげて、でこぼこした一枚の層にする (粒の隙間が穴の模様として透けないように)
    // 粒は風と直交する向きに伸ばして列 (さざ波) に並べ、なめらかな fbm を混ぜて Worley のセルの角張った輪郭を丸める
    // (セルのままだと角張った小片が散らばる点描に見えた)。倍率 0.5 は CLOUD_MID_TILE の畳みで継ぎ目が出ない値
    float cell = texture(cloudNoiseTex, q / CLOUD_MID_PERIOD * vec2(1.0, 0.5)).a;
    float grain = smoothstep(mix(0.25, -0.3, stratus), mix(0.85, 0.5, stratus), cell * 0.75 + n.g * 0.25) * patches;
    float x = (h - CLOUD_AC_BASE) / (0.6 * grain + 1e-3);
    float altocumulus = grain * linearStep(CLOUD_AC_BASE, CLOUD_AC_BASE + 0.05, h) * saturate(1.0 - x * x);
    // 高層雲の底と頂は位置ごとに上下させる (平らな面のままだと、浸食の穴の縁で直線の縁の平らな面が見えた)
    float hs = h + (n.r - 0.5) * 0.3;
    float altostratus = linearStep(0.3, 0.8, cover * (0.75 + 0.5 * n.g)) * linearStep(0.15, 0.35, hs) * (1.0 - linearStep(0.6, 0.85, hs + (cell - 0.5) * 0.2));
    float cloudiness = mix(altocumulus, altostratus, stratus);
    if (cloudiness <= 0.0) return 0.0;
    grainHeight = mix(saturate(x), h, stratus);

    vec3 p = vec3(q.x, altitude, q.y) + ctx.evolve * 0.5;
    float d = cloudiness - (1.0 - texture(cloudShapeTex, p / CLOUD_MID_SHAPE_PERIOD).g) * mix(CLOUD_MID_ERODE.x, 0.3, stratus) * CLOUD_MID_EROSION;
    if (d <= 0.0) return 0.0;
    if (detail) {
        float edge = 1.0 - smoothstep(0.0, CLOUD_DETAIL_REACH, d);
        d -= (1.0 - texture(cloudDetailTex, p / CLOUD_MID_DETAIL_PERIOD).r) * edge * (CLOUD_MID_ERODE.y * CLOUD_MID_EROSION);
        if (d <= 0.0) return 0.0;
    }
    // 低層 (縁で急に立ち上げる 3 乗) より柔らかく立ち上げる。遠い薄い小塊は輪郭がぼやけて見える
    d = smoothstep(0.0, CLOUD_MID_EDGE_WIDTH, d);
    // 小さな粒・群れの縁の粒ほど水量が少なく透ける (一様に濃いと、輪郭のはっきりした白い小片が貼り付いたように見えた)
    float thin = mix(CLOUD_MID_GRAIN_THIN, 1.0, smoothstep(0.1, 0.8, grain));
    // 雨天の濃さの倍率は高層雲と本降りの時だけ。雨上がりの rainWetness が残る間 (雨天度 0.1-0.4) に被覆が増えた高積雲の粒まで
    // 濃くすると、低層の雲の周りに縁のくっきりした白い欠片が散らばった
    float rainScale = mix(1.0, ctx.densityScale, max(stratus, smoothstep(CLOUD_HAZE_RAIN.x, CLOUD_HAZE_RAIN.y, ctx.rain)));
    return d * mix(thin, 0.45, stratus) * rainScale;
}

float cloudMidDensity(CloudContext ctx, float cover, vec2 rel, float altitude, bool detail) {
    float grainHeight;
    return cloudMidDensity(ctx, cover, rel, altitude, detail, grainHeight);
}

// 中層が空に占める割合 (粒を均した粗い被覆)。下の層に落とす影に使う
float cloudMidCoverage(CloudContext ctx, float cover, vec2 rel) {
    float g = texture(cloudNoiseTex, (rel + ctx.midOrigin) / CLOUD_MID_PERIOD).g;
    float stratus = max(smoothstep(0.6, 1.0, cover), linearStep(CLOUD_MID_RAIN_VEIL.x, CLOUD_MID_RAIN_VEIL.y, ctx.rainLight));
    float patches = linearStep(1.0 - cover, 1.0 - cover + CLOUD_MID_PATCH_SOFTNESS, g);
    float altostratus = linearStep(0.3, 0.8, cover * (0.75 + 0.5 * g));
    // 高積雲の粒は群れの中の半分ほど、高層雲は薄いので雲 1 つ分より光を通す
    return mix(patches * 0.5, altostratus * 0.7, stratus);
}

/*
 * 上層 (薄い体積) の消散係数 (1/m)。cover: 天気図の上層の被覆, dist: 距離 (繊維の LOD)
 * veil: 消散のうち巻層雲の割合 (ハロ用)
 * 巻雲は房 (層の上の方の発生源) から氷晶が落ちて筋になる。筋は下ほど風下に取り残されて傾き、
 * 斜めに層を抜ける視線がその傾いた筋を積むので、平面の筋ノイズを貼ったような刷毛目にならない
 */
float cloudHighExtinction(CloudContext ctx, float cover, vec2 rel, float altitude, float dist, bool detail, out float veil) {
    veil = 0.0;
    float h = (altitude - CLOUD_R_HIGH_BASE) / CLOUD_R_HIGH_DEPTH;
    if (h <= 0.0 || h >= 1.0) return 0.0;
    vec2 q = rel + ctx.highOrigin;
    // 低い所ほど風下の房から落ちてきた氷晶を読む = 筋が房から風上側へ傾いて垂れる
    q += CLOUD_HIGH_WIND_DIR * ((1.0 - h) * CLOUD_CIRRUS_FALL_SHEAR);
    vec4 broad = texture(cloudNoiseTex, q / CLOUD_HIGH_PATCH_PERIOD);
    // 巻雲は空一面ではなく群れで現れる
    float patches = linearStep(0.45, 0.85, broad.g + 0.35 * (cover - 0.5));
    // 風向き (2, 1) に回した座標 (x 風下, y 横)。東西のままだと朝夕に筋が太陽へ放射状に集まって光線のように見える。
    // 整数の回転行列なので、原点を CLOUD_HIGH_TILE で畳んでも繰り返しの継ぎ目が出ない
    vec2 wq = vec2(CLOUD_HIGH_WIND_ROT.x * q.x + CLOUD_HIGH_WIND_ROT.y * q.y, CLOUD_HIGH_WIND_ROT.x * q.y - CLOUD_HIGH_WIND_ROT.y * q.x);
    float cirrus = 0.0;
    if (patches > 0.0) {
        // 房: 3D Perlin-Worley を風下に伸ばして読む。高さでも形が変わるので、層を抜ける視線ごとに違う断面が積まれる
        vec3 pc = vec3(wq.x / CLOUD_CIRRUS_ALONG, altitude / CLOUD_CIRRUS_VERTICAL, wq.y / CLOUD_CIRRUS_ACROSS);
        vec2 s = texture(cloudShapeTex, pc).rg;
        float threshold = 1.0 - 0.6 * cover;
        float tuft = s.r * 0.75 + broad.g * 0.25;
        float body = smoothstep(threshold, threshold + 0.22, tuft) * patches;
        // 鉛直の分布: 房 (上) が濃く、落下筋 (下) は薄れながら垂れる
        cirrus = body * smoothstep(0.0, 0.45, h) * (1.0 - smoothstep(0.85, 1.0, h)) * mix(0.4, 1.0, smoothstep(0.35, 0.85, h));
        if (detail && cirrus > 0.0 && dist < CLOUD_CIRRUS_FIBER_DIST) {
            // 繊維: 細かい Worley を風下に伸ばし、房の形状ノイズで曲げて密度に掛ける (輪郭は房の柔らかいまま、中に糸の濃淡)
            vec3 warp = vec3(s.g - 0.5, 0.0, s.r - 0.5) * 2.0;
            vec3 pf = vec3(wq.x / CLOUD_CIRRUS_FIBER_ALONG, altitude / CLOUD_CIRRUS_FIBER_VERTICAL, wq.y / CLOUD_CIRRUS_FIBER_ACROSS) + warp * CLOUD_CIRRUS_FIBER_CURL;
            float fiber = texture(cloudDetailTex, pf).r;
            // 遠くは繊維が画素より細かくちらつくので均す
            fiber = mix(fiber, 0.6, smoothstep(CLOUD_CIRRUS_FIBER_FADE_NEAR, CLOUD_CIRRUS_FIBER_DIST, dist));
            cirrus *= mix(CLOUD_CIRRUS_FIBER_MIN, 1.0, fiber);
            // 房の縁は繊維の谷から先に消える (ほつれた縁)
            cirrus = max(cirrus - (1.0 - fiber) * 0.25 * (1.0 - cirrus), 0.0);
        }
    }
    // 巻積雲: 層の上の方に細かい粒が所々に群れる。粒で穴を開けず、まだらな薄い膜にする (粒だけだと点描の網に見える)
    // 粒は風と直交する向きに少し並べる (さざ波状)。遠くは粒が画素より細かくちらつくので早めに均す
    float ccPatch = linearStep(0.9 - 0.1 * cover, 1.05 - 0.1 * cover, broad.r + 0.1 * (broad.g - 0.5));
    float cirrocumulus = 0.0;
    if (ccPatch > 0.0) {
        float grain = texture(cloudNoiseTex, q / CLOUD_CC_PERIOD * vec2(1.0, 2.0)).a;
        float grainFade = smoothstep(CLOUD_CC_GRAIN_FADE_NEAR, CLOUD_CC_GRAIN_FADE_FAR, dist);
        cirrocumulus = mix(mix(0.3, 1.0, smoothstep(0.15, 0.85, grain)), 0.6, grainFade) * sqr(ccPatch) * smoothstep(0.65, 0.8, h) * (1.0 - smoothstep(0.92, 1.0, h));
    }
    // 巻層雲: 広く覆う時の一様なベール
    float cs = linearStep(0.7, 1.2, cover) * (0.6 + 0.4 * broad.g) * smoothstep(0.1, 0.3, h) * (1.0 - smoothstep(0.75, 0.95, h));
    float extinction = cirrus * CLOUD_CIRRUS_SIGMA + cirrocumulus * CLOUD_CC_SIGMA + cs * CLOUD_CS_SIGMA;
    veil = extinction > 0.0 ? cs * CLOUD_CS_SIGMA / extinction : 0.0;
    return extinction;
}

#endif
