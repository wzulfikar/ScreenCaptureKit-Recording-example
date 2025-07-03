# ScreenCaptureKit-Recording-example

***📚 Make sure to read our article [Recording to a file using ScreenCaptureKit](https://nonstrict.eu/blog/2023/recording-to-disk-with-screencapturekit) before exploring this example project.***

tldr; Use an AVAssetWriter to save CMSampleBuffers in a SCStreamOutput callback.



## Running the example

1. Clone this repo
2. Run `swift run`


## Older macOS

See also: [AVCaptureScreenInput-Recording-example](https://github.com/nonstrict-hq/AVCaptureScreenInput-Recording-example) for use on macOS versions older than 12.3

## Capture microphone

- Works on macOS 15+. Mic audio is added as separate track (system audio = track 1, mic audio = track 2)
- If you use QuickTime to playback the recording that has mic audio, enable "Prefer Passthrough"

## Authors

[Nonstrict B.V.](https://nonstrict.eu), [Mathijs Kadijk](https://github.com/mac-cain13) & [Tom Lokhorst](https://github.com/tomlokhorst), released under [MIT License](LICENSE.md).
