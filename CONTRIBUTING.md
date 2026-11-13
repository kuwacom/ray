# alpha・beta 版の間は、Pull Request を受け付けません

**個人的に必要な機能やルックを調整している間は変更が大きいため、受け付けていません。Issue での報告は歓迎します**

# Contributing

[English](CONTRIBUTING.en.md) | 日本語

バグ報告を歓迎します。Pull Request は、alpha・beta 版が終わるまで受け付けていません

## バグを報告する

[Issue](../../issues/new/choose) の「不具合の報告」から投稿してください。見た目の問題は、スクリーンショットと、入れている Ray のビルド (nightly の zip のファイル名)、Minecraft / Iris / GPU の情報があると再現しやすくなります

## Pull Request の受け入れ基準

受け付けを始めたあとの基準です。次の 2 点を見て、問題がなければ取り込みを検討します

- 見た目: 既定のルック (ナチュラル) と品質プリセットの「高」で、見た目が崩れない。意図した変化は、変更前後のスクリーンショットで説明されている
- 重さ: 既定の設定で、目に見えて重くならない。重い機能は設定で切れるようにして、上位のプリセットに限る

PR の説明には、変更前後のスクリーンショットと、GPU・解像度・プリセットつきのフレーム時間を書いてください。定点撮影は [tools/README.md](tools/README.md#ゲーム内で撮影する) の手順で揃えられます

取り込めない変更の例です

- 他のシェーダーパックのコードをそのまんま含むコピー品
- 見た目や重さの確認ができないもの
- 設定の名前や番号を変えて、保存済みの設定を壊すもの

## 開発の流れ

- ブランチは `main` の 1 本です。並行して作業するときのブランチも、`main` に fast-forward で取り込める形 (rebase) にしてください
- コミットメッセージは `fix: 太陽の接触影を画面の縁で打ち切る` のように、種類と内容を簡潔に書きます
- push した `main` は検証を通ると nightly として公開されます。nightly は 1 つだけで、そのつど置き換わります

## 手元での検証

Python の環境は [uv](https://docs.astral.sh/uv/) で管理しています。glslang の用意は [tools/README.md](tools/README.md) を見てください

```powershell
uv sync
uv run tools/validate_shaders.py          # 既定値・オーバーワールド
uv run tools/validate_shaders.py --full   # 設定やプロファイルを変えたとき
```

GitHub Actions も同じ検証を回します。実機のドライバでの確認 (`tools/gl_compile_check.py`) と見た目の確認は GPU が要るので、手元で行ってください

シェーダーの書き方の決まりは [docs/shader-guidelines.md](docs/shader-guidelines.md) と [docs/architecture.md](docs/architecture.md) にあります。生成物 (`world*/`、`block.properties` など) は手で編集せず、`tools/` のスクリプトで作り直してください

## ライセンス

投稿された内容は [LICENSE](LICENSE) の 4.1 (Contributions) のもとで Ray の一部として扱われます
