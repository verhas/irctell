# sherpa-onnx

On-device speech synthesis for the natural voices (Kokoro), from
<https://github.com/k2-fsa/sherpa-onnx>, Apache License 2.0.

- `include/c-api.h`: the C API of the release below, unchanged.
- `include/module.modulemap`: makes it a Swift module, `SherpaOnnx`.
- `lib/`: the release's static libraries for macOS (universal), not kept in
  git. `build.sh` downloads them on the first build and checks their SHA-256.

Release: v1.13.8, `sherpa-onnx-v1.13.8-osx-universal2-static-lib.tar.bz2`.

The voice model is not part of the app: Irctell downloads it into
`~/.irctell/voices` when the natural voices are switched on.
