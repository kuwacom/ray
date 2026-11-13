# alpha・beta 版の間は、Pull Request を受け付けません

# Pull requests are not accepted during the alpha and beta

個人的に必要な機能やルックを調整している間は変更が大きいため、受け付けていません。報告は Issue へお願いします  
I am still changing features and the look for my own needs, so changes are large and I am not accepting pull requests. Please report through issues

## 変更の内容 / Summary

<!-- 何を変えたか なぜ必要か / What changed and why -->

## 見た目 / Visuals

<!-- 見た目が変わる変更は、同じ場所・同じ設定の変更前と変更後のスクリーンショットを貼ってください。変わらない変更は「変化なし」と書いてください -->
<!-- For changes that alter the look, attach before and after screenshots from the same place with the same settings. If nothing changes, write "No change" -->

## 重さ / Performance

<!-- GPU・解像度・品質プリセットと、変更前後のフレーム時間 (または fps) を書いてください。重さに関わらない変更は「影響なし」と書いてください -->
<!-- Give the GPU, resolution, quality preset, and the frame time (or fps) before and after. If performance is unaffected, write "No impact" -->

## 確認 / Checklist

- [ ] `uv run tools/validate_shaders.py` が通る (設定やプロファイルを変えたときは `--full`) / passes (use `--full` when you change settings or profiles)
- [ ] 生成物 (`gen_*.py` の出力) を最新にした / Generated files (output of `gen_*.py`) are up to date
- [ ] 他のシェーダーパックのコードを含んでいない。手法を参考にしたものは `CREDITS.md` に出典を書いた / Contains no code from other shader packs. Techniques I drew on are credited in `CREDITS.md`
- [ ] 投稿内容を `LICENSE` の 4.1 (Contributions) のもとで提供することに同意する / I agree to provide my contribution under section 4.1 (Contributions) of `LICENSE`
