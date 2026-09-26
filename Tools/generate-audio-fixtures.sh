#!/usr/bin/env bash
# generate-audio-fixtures.sh —— 生成 M2-T1 音频元数据测试素材（Tests/Fixtures/Audio/）。
#
# 素材策略：不许引用本机音乐库（版权与可复现性），全部由系统提示音
# /System/Library/Sounds/Tink.aiff（0.564s，Apple 随系统提供）转码而来，
# 生成后提交入库（体积均为几 KB～几十 KB）。
#
# 工具分工：
#   - afconvert（macOS 自带，无外部依赖）：生成无标签的 wav/m4a/caf/aiff。
#     它不能写标签，所以「带标签」的样本必须走别的工具。
#   - ffmpeg（可选）：写 title/artist/album 标签并内嵌封面，覆盖
#     mp3/flac/m4a/ogg/wav 五格式。本机已装（/opt/homebrew/bin/ffmpeg），
#     故 mp3/flac/ogg 也能生成真实样本——这是对规划中「afconvert 不支持
#     mp3/flac」这一限制的改善，非依赖：无 ffmpeg 时脚本降级为只产
#     afconvert 能做的 wav/m4a/caf/aiff，并打印缺失清单。
#
# 用法：Tools/generate-audio-fixtures.sh [输出目录]
#       默认输出到 Tests/Fixtures/Audio/。

set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="${1:-$root_dir/Tests/Fixtures/Audio}"
source_aiff="/System/Library/Sounds/Tink.aiff"

if [[ ! -f "$source_aiff" ]]; then
  echo "找不到源音频 $source_aiff（macOS 系统提示音）" >&2
  exit 1
fi

mkdir -p "$out_dir"

# 统一的标签值。测试断言直接引用这三个常量（见 AudioMetadataReaderTests）。
fixture_title="Fixture Title"
fixture_artist="Fixture Artist"
fixture_album="Fixture Album"

# 生成一张 64x64 的纯色 PNG 作内嵌封面（174 字节，无第三方素材）。
cover_png="$(mktemp -t nerplayer-cover).png"
has_ffmpeg=0
if command -v ffmpeg >/dev/null 2>&1; then
  has_ffmpeg=1
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i color=c=blue:s=64x64 -frames:v 1 "$cover_png"
fi

echo "输出目录：$out_dir"

# ---------- 无标签样本（afconvert，保证无外部依赖也能复现） ----------
# 0.564s 单声道 WAV：用于「读不到标签时用文件名兜底 + duration/fileSize 兜底」用例。
afconvert -f WAVE -d LEI16@22050 -c 1 "$source_aiff" "$out_dir/untagged.wav"
echo "  ✓ untagged.wav"

# 文件名兜底用例：无标签，文件名形如 "Artist - Title"。
# 断言 reader 去扩展名后按 " - " 拆出 artist=Fallback Artist / title=Fallback Title。
afconvert -f WAVE -d LEI16@22050 -c 1 "$source_aiff" "$out_dir/Fallback Artist - Fallback Title.wav"
echo "  ✓ Fallback Artist - Fallback Title.wav"

if [[ "$has_ffmpeg" -eq 0 ]]; then
  echo "未检测到 ffmpeg：只生成了 afconvert 可产出的样本。" >&2
  echo "缺失（需 ffmpeg 才能写标签）：tagged.mp3 / tagged.flac / tagged.m4a / tagged.ogg / tagged.wav" >&2
  exit 0
fi

# ---------- 带标签 + 内嵌封面的五格式样本（ffmpeg） ----------
# -map 0 -map 1：把封面作为视频流/附加图片写进容器（mp3 ID3 APIC、flac PICTURE、
# m4a covr、ogg METADATA_BLOCK_PICTURE 均支持）。
tag_args=(-metadata "title=$fixture_title" -metadata "artist=$fixture_artist" -metadata "album=$fixture_album")

ffmpeg -hide_banner -loglevel error -y -i "$source_aiff" -i "$cover_png" \
  -map 0:a -map 1:v -c:a libmp3lame -c:v png -id3v2_version 3 \
  "${tag_args[@]}" -metadata:s:v title="Album cover" -metadata:s:v comment="Cover (front)" \
  "$out_dir/tagged.mp3"
echo "  ✓ tagged.mp3"

ffmpeg -hide_banner -loglevel error -y -i "$source_aiff" -i "$cover_png" \
  -map 0:a -map 1:v -c:a flac -c:v png -disposition:v attached_pic \
  "${tag_args[@]}" "$out_dir/tagged.flac"
echo "  ✓ tagged.flac"

ffmpeg -hide_banner -loglevel error -y -i "$source_aiff" -i "$cover_png" \
  -map 0:a -map 1:v -c:a aac -c:v png -disposition:v attached_pic \
  "${tag_args[@]}" "$out_dir/tagged.m4a"
echo "  ✓ tagged.m4a"

# Ogg 容器不接受 PNG 视频流（本机 ffmpeg 报 "Unsupported codec id in stream 1"），
# 且 Vorbis 封面要走 METADATA_BLOCK_PICTURE（base64 注释）而非附加流。
# 本任务只需 title/artist/album/duration，故 ogg 样本只写标签、不嵌封面。
ffmpeg -hide_banner -loglevel error -y -i "$source_aiff" \
  -c:a vorbis -strict -2 "${tag_args[@]}" "$out_dir/tagged.ogg"
echo "  ✓ tagged.ogg（无封面）"

# WAV：ffmpeg 写 RIFF INFO 块（INAM/IART/IPRD）；TagLib 的 RIFF::WAV 能读。
# 指定 22050 单声道与 untagged.wav 同规格，把素材压到 ~29KB（未压缩 PCM，
# 采样率/声道数直接决定体积）。
ffmpeg -hide_banner -loglevel error -y -i "$source_aiff" \
  -c:a pcm_s16le -ar 22050 -ac 1 -map_metadata 0 "${tag_args[@]}" "$out_dir/tagged.wav"
echo "  ✓ tagged.wav"

ls -la "$out_dir"
