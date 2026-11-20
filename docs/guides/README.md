# 使い方ガイド

> [!NOTE]
> Ray はアルファ版で、設定の項目と既定値は予告なく変わります  
> ここの値が設定画面と違うときは、設定画面と [../settings.md](../settings.md) のほうが新しい値です

## 始め方

1. Iris のシェーダーパックの一覧で Ray を選びます  
   最初の読み込みは長くかかります ([troubleshooting.md](troubleshooting.md) の「読み込みが遅い」)
2. 設定画面のいちばん上で品質プロファイルを選びます  
   既定は「高」で、フレームが足りなければ「高 (軽量)」「高 (最軽量)」「中」へ下げます ([profiles.md](profiles.md))
3. 同じ画面の「ルック」で光と色の作り方を選びます  
   プロファイルを変えてもルックはそのままです
4. 気になる所を下の表から探して調整します

ON/OFF や方式の選択を先に決めて、強さや明るさの値はあとで詰めると、読み込みの待ちが短く済みます  
値を変えるだけの設定は、読み込み直しが速く終わります (理由は [troubleshooting.md](troubleshooting.md))

## 画面とページ

| 設定画面 | ページ |
|---|---|
| トップ (プロファイル、ルック、LUT、LUT の強さ) | [profiles.md](profiles.md) |
| ブロックライト | [block-light.md](block-light.md) |
| 影と GI | [shadows-gi.md](shadows-gi.md) |
| マテリアル | [materials.md](materials.md) |
| 水と反射 | [water-reflections.md](water-reflections.md) |
| 空、雲、フォグとボリューメトリック | [sky-clouds-fog.md](sky-clouds-fog.md) |
| カメラ (露出、ボケ、シャッター、測光) | [camera.md](camera.md) |
| カメラ > レンズ | [lens.md](lens.md) |
| カメラ > アナログ | [analog.md](analog.md) |
| ポストプロセス (トーンマップ、色、効果、アンチエイリアス) | [post-processing.md](post-processing.md) |
| デバッグ | [troubleshooting.md](troubleshooting.md) の「デバッグ表示」 |

重くて困ったときは [performance.md](performance.md)、縞やノイズ、暗さなど見え方がおかしいときは [troubleshooting.md](troubleshooting.md) へ

## やりたいことから

| やりたいこと | 見る所 |
|---|---|
| まずきれいな絵で見たい | プロファイル「高」のまま、ルックを順に試す ([profiles.md](profiles.md)) |
| 普段のプレイ用に軽くしたい | [performance.md](performance.md) |
| たいまつの影をきれいにしたい | [block-light.md](block-light.md) の「光源シャドウ」 |
| カメラのように F 値・SS・ISO で撮りたい | [camera.md](camera.md) |
| オールドレンズや魚眼の写りにしたい | [lens.md](lens.md) |
| 2000 年代のビデオカメラの画にしたい | [analog.md](analog.md) |
| 色をレタッチしたい | [post-processing.md](post-processing.md) の「カラーグレーディング」 |
| 雲の形や天気の雰囲気を変えたい | [sky-clouds-fog.md](sky-clouds-fog.md) |

## 知っておくと迷わないこと

- 設定にマウスを乗せると説明文が出ます
- 名前に `_C_` が入る設定 (例: `LENS_C_GHOSTS`) は、親のプリセットが「カスタム」のときだけ効きます  
  プリセットを選んでいる間は動かしても何も変わりません
- すべての設定の既定値と候補は [../settings.md](../settings.md)、手法と出典は [../architecture.md](../architecture.md) にあります
