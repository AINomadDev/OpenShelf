# OpenShelf streaming verification

Measured on this Mac using a generated 30-second 1280x720 ProRes MOV (42,894,399 bytes), FFmpeg, and isolated fresh rclone caches. These are single-run measurements, not service guarantees.

| Provider | First-frame decode | Seek to 20 s | Repeated seek | Downloaded bytes | Allocated cache bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| google | 2.22 s | 1.976 s | 0.049 s | 1,564,672 | 1,568,768 |
| icloud | 7.672 s | 3.577 s | 1.471 s | 1,564,672 | 1,576,960 |

Both decoded frames matched their locally decoded reference hashes. Both trials downloaded approximately 3.65% of the source, and both normally unmounted. Samples remain in `OpenShelf streaming check 4d3ad92b` in each cloud. Existing user files were not used.

The updated installed app uses a 5 GiB cache target per provider, 10 GiB minimum free-space target, 10-second cache checks, a visible free-space reading and low-space warning, and a new-mount block when free space is below the reserve or cannot be measured. Core tests cover low/unknown capacity and the exact reserve boundary. These are eviction targets, not a hard quota: active files, unuploaded changes, and other applications can still fill disk.

DaVinci Resolve is not installed and was not tested. Multi-gigabyte sources, timeline editing, exports, codec variations, long playback, network interruptions, and sustained cache pressure were not benchmarked. Full playback or analysis may eventually read the entire source. The test demonstrates partial reads and seeking for this sample, not universal editor compatibility.
