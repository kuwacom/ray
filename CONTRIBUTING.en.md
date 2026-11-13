# Pull requests are not accepted during the alpha and beta

**I am still changing features and the look for my own needs, so changes are large and I am not accepting pull requests. Bug reports through issues are welcome**

# Contributing

English | [日本語](CONTRIBUTING.md)

Bug reports are welcome. Pull requests are not accepted until the alpha and beta end

## Reporting bugs

Open an [issue](../../issues/new/choose) with "Bug report". For visual problems, a screenshot, the Ray build you installed (the file name of the nightly zip), and your Minecraft, Iris, and GPU details make it much easier to reproduce

## Pull request criteria

These are the criteria once pull requests are accepted. I consider merging a change when it passes these two checks

- Look: with the default look (Natural) and the "High" quality preset, nothing looks broken. Intended changes are explained with before and after screenshots
- Performance: with default settings, it does not get noticeably heavier. Heavy features should be switchable in settings and limited to the higher presets

In the PR description, include before and after screenshots, and the frame time with the GPU, resolution, and preset. You can match your shots to fixed scenes by following [tools/README.md](tools/README.md#ゲーム内で撮影する) (in Japanese)

Examples of changes that cannot be merged

- Changes that contain code from other shader packs
- Changes whose look or performance cannot be verified
- Changes that rename or renumber settings and break saved settings

## Workflow

- There is a single branch, `main`. Any branch you use for parallel work must be integrable into `main` by fast-forward (rebase)
- Write commit messages briefly with a type and a description, such as `fix: stop the sun contact shadow at the screen edge`. The existing history is in Japanese, and English is fine too
- A `main` push that passes validation is published as the nightly. There is only one nightly, and it is replaced each time

## Checking locally

The Python environment is managed with [uv](https://docs.astral.sh/uv/). See [tools/README.md](tools/README.md) (in Japanese) for setting up glslang

```powershell
uv sync
uv run tools/validate_shaders.py          # default settings, overworld
uv run tools/validate_shaders.py --full   # when you change settings or profiles
```

GitHub Actions runs the same validation. Checking with a real driver (`tools/gl_compile_check.py`) and checking the look need a GPU, so do them locally

The coding rules are in [docs/shader-guidelines.md](docs/shader-guidelines.md) and [docs/architecture.md](docs/architecture.md) (in Japanese). Do not edit generated files (`world*/`, `block.properties`, and so on) by hand. Regenerate them with the scripts in `tools/`

## License

Contributions are treated as part of Ray under section 4.1 (Contributions) of the [LICENSE](LICENSE)
