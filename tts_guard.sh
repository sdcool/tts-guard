#!/bin/bash
# tts_guard.sh — AI TTS 配音防慢速守卫 / Slow-speech guard for AI TTS narration
#
# 背景: /opt/hatch/bin/tts 长文本单次合成偶发整段 2~4 倍慢速音频
#       （2026-10-11、10-15、10-17 三次出现，无静音、整段均匀变慢），
#       曾导致坏视频交付给用户后才发现并返工。
# 用法: ./tts_guard.sh <输出mp3路径> <解说文案txt路径> [--voice VOICE] [--speed N]
#       其余 tts speak 参数可追加在最后透传。
# 流程:
#   1) 整段合成一次；
#   2) ffprobe 测时长 D，期望时长 ≈ 总字数 ÷ 4.5（秒）；
#      若 D > 期望 × 1.8 判定异常（或合成失败/时长为0）；
#   3) 异常则按 。！？ 切分短句，逐句单独合成（--speed 100，逐句校验，
#      单句异常重试 1 次仍失败则报错退出），句间插入 0.4 秒静音拼接；
#   4) 输出最终 mp3 并校验总时长合理。
# 环境变量 FORCE_SPLIT=1 可强制走分段路径（用于测试）。
# 环境变量 TTS_PROVIDER: cli（默认，走 TTS_BIN 指向的 CLI）
#                         edge（走 edge-tts，需 pip install edge-tts；
#                               EDGE_VOICE 可指定音色，默认 zh-CN-XiaoxiaoNeural）
# 退出码: 0 成功；非 0 失败并输出原因。

set -u
TTS="${TTS_BIN:-tts}"  # 指向你的 TTS CLI；合成函数 synth() 的参数风格需按你的引擎适配，守卫逻辑与引擎无关
PROVIDER="${TTS_PROVIDER:-cli}"
case "$PROVIDER" in
  cli|edge) ;;
  *) echo "ERR: 未知 TTS_PROVIDER: $PROVIDER（可选 cli / edge）" >&2; exit 2;;
esac
EDGE_TTS="${EDGE_TTS_BIN:-edge-tts}"
OUT="$1"; TXT="$2"; shift 2

VOICE="avocado_v2:MAI_03"   # 与手册步骤2一致：不指定 voice 即默认 MAI_03
SPEED="100"
EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --voice) VOICE="$2"; shift 2;;
    --speed) SPEED="$2"; shift 2;;
    *) EXTRA+=("$1"); shift;;
  esac
done

[ -f "$TXT" ] || { echo "ERR: 文案文件不存在: $TXT" >&2; exit 2; }
command -v ffprobe >/dev/null || { echo "ERR: 缺少 ffprobe" >&2; exit 2; }
if [ "$PROVIDER" = "edge" ]; then
  command -v "$EDGE_TTS" >/dev/null || { echo "ERR: 未找到 edge-tts，请先 pip install edge-tts" >&2; exit 2; }
fi

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT

# 总字数：去掉空白后计数（与手册"总字数÷4.5"口径一致）
chars() { LC_ALL=C.utf8 tr -d '[:space:]' < "$1" | LC_ALL=C.utf8 wc -m | tr -d ' '; }
# 音频时长（秒，失败返回空）
dur() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null | head -1; }

# edge-tts 音色: EDGE_VOICE 优先；其次用 --voice 传入的非默认音色；否则默认晓晓
edge_voice() {
  if [ -n "${EDGE_VOICE:-}" ]; then echo "$EDGE_VOICE";
  elif [ "$VOICE" != "avocado_v2:MAI_03" ]; then echo "$VOICE";
  else echo "zh-CN-XiaoxiaoNeural"; fi
}
# edge-tts 语速: speed 100 → +0%，N → (N-100)%
edge_rate() { awk -v s="$1" 'BEGIN{d=s-100; if (d>=0) printf "+%d%%", d; else printf "%d%%", d}'; }

synth() { # $1=输出, $2=文案文件, $3=speed
  if [ "$PROVIDER" = "edge" ]; then
    "$EDGE_TTS" --file "$2" --voice "$(edge_voice)" --rate="$(edge_rate "$3")" \
      --write-media "$1" >/dev/null 2>"$TMPD/tts.err"
  else
    "$TTS" speak --voice "$VOICE" --language zh --speed "$3" \
      --output "$1" --text-stdin "${EXTRA[@]}" < "$2" >/dev/null 2>"$TMPD/tts.err"
  fi
}

abnormal() { # $1=音频文件, $2=字数 → 回显 0 正常 / 1 异常
  local d c exp
  d="$(dur "$1")"; c="$2"
  [ -z "$d" ] && { echo 1; return; }
  exp="$(awk -v c="$c" 'BEGIN{printf "%.2f", c/4.5}')"
  awk -v d="$d" -v e="$exp" 'BEGIN{exit !(d > e*1.8 || d <= 0.1)}' && echo 1 || echo 0
}

C="$(chars "$TXT")"
[ "$C" -lt 5 ] && { echo "ERR: 文案过短($C 字)，请检查: $TXT" >&2; exit 2; }

echo "[tts_guard] 共 ${C} 字，期望时长约 $(awk -v c="$C" 'BEGIN{printf "%.1f", c/4.5}')s"

# --- 1) 整段合成 ---
if [ "${FORCE_SPLIT:-0}" != "1" ]; then
  synth "$TMPD/whole.mp3" "$TXT" "$SPEED"
  if [ "$(abnormal "$TMPD/whole.mp3" "$C")" = "0" ]; then
    cp "$TMPD/whole.mp3" "$OUT"
    echo "[tts_guard] 整段合成通过校验: $OUT ($(dur "$OUT")s)"
    exit 0
  fi
  echo "[tts_guard] 整段合成语速异常($(dur "$TMPD/whole.mp3")s)，转分段合成…" >&2
else
  echo "[tts_guard] FORCE_SPLIT=1，强制走分段路径（测试）" >&2
fi

# --- 2) 按 。！？ 切分 ---
python3 - "$TXT" "$TMPD" <<'EOF'
import re, sys
txt = open(sys.argv[1], encoding='utf-8').read().strip()
tmpd = sys.argv[2]
parts = [p for p in re.split(r'(?<=[。！？])', txt) if p.strip()]
# 过短碎片并入下一句，避免单字合成不稳定
merged, buf = [], ''
for idx, p in enumerate(parts):
    buf += p
    if len(buf.strip()) >= 4 or idx == len(parts) - 1:
        merged.append(buf); buf = ''
if buf: merged.append(buf)
for i, p in enumerate(merged):
    open(f"{tmpd}/s{i:02d}.txt", 'w', encoding='utf-8').write(p)
print(len(merged))
EOF
N="$(ls "$TMPD"/s*.txt | wc -l)"
echo "[tts_guard] 切分为 ${N} 句"

# --- 3) 逐句合成 + 校验 ---
i=0
for sf in "$TMPD"/s*.txt; do
  sc="$(chars "$sf")"
  ok=0
  for attempt in 1 2; do
    synth "$TMPD/s$(printf '%02d' $i).mp3" "$sf" 100
    if [ "$(abnormal "$TMPD/s$(printf '%02d' $i).mp3" "$sc")" = "0" ]; then ok=1; break; fi
    echo "[tts_guard] 第 $((i+1)) 句第 ${attempt} 次合成异常，重试…" >&2
  done
  [ "$ok" = "1" ] || { echo "ERR: 第 $((i+1)) 句两次合成均异常，需人工处理: $(cat "$sf")" >&2; exit 3; }
  i=$((i+1))
done

# --- 4) 0.4s 静音拼接 ---
SR="$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 "$TMPD/s00.mp3")"
CH="$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$TMPD/s00.mp3")"
CL="stereo"; [ "$CH" = "1" ] && CL="mono"
ffmpeg -y -v error -f lavfi -i "anullsrc=r=${SR}:cl=${CL}" -t 0.4 "$TMPD/sil.mp3"

LIST="$TMPD/list.txt"; : > "$LIST"
for f in "$TMPD"/s??.mp3; do
  echo "file '$f'" >> "$LIST"
  echo "file '$TMPD/sil.mp3'" >> "$LIST"
done
# 去掉末尾多余的一段静音；重编码拼接（避免 mp3 流拷贝 dts 错乱导致接缝杂音）
sed -i '$ d' "$LIST"
ffmpeg -y -v error -f concat -safe 0 -i "$LIST" -c:a libmp3lame -b:a 128k "$OUT"

# --- 5) 终检 ---
FD="$(dur "$OUT")"
SUMS="$(for f in "$TMPD"/s??.mp3; do dur "$f"; done | awk '{s+=$1}END{print s}')"
EXP="$(awk -v s="$SUMS" -v n="$N" 'BEGIN{printf "%.2f", s + 0.4*(n-1)}')"
ok="$(awk -v d="$FD" -v e="$EXP" 'BEGIN{print (d > e*0.8 && d < e*1.25) ? 1 : 0}')"
[ "$ok" = "1" ] || { echo "ERR: 拼接后时长异常(${FD}s vs 期望 ${EXP}s)，需人工检查" >&2; exit 4; }
echo "[tts_guard] 分段合成完成: $OUT (${FD}s，${N} 句 + 句间 0.4s 静音)"
