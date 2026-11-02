#!/bin/sh
#=============================================================================
# tamper_demo.sh —— 篡改拒绝演示：翻密文一位 -> 拒绝启动 -> 自动恢复
#
# 实测结论（2026-10-27，板卡 192.168.1.200）：
#   · P1-a 之前：仅靠 canary，单点翻位多数检不出（PROBE_X 是 2^(k%64) 指数序列，
#     Y 被大 k 列主导，小 k 列改动低于 fp32 ulp）；块级破坏才触发拒绝。
#   · P1-a 之后：镜像摘要（W.enc|b|cfg 字节级）先于 probe 校验，任意一位改动都拒绝启动。
#   本脚本验证的是 P1-a 的效果。
#
# 用法（板卡上）： sh tamper_demo.sh
#=============================================================================
set -u

W=/opt/fara/models/board_W_transformer_h_0_mlp_c_fc.enc
BAK=/dev/shm/W.enc.good
IDX=1811162                    # 幅值最大的权重（|w|=4.5877, m=2358 k=218）
BOFF=$((IDX * 4 + 3))          # fp32 字节 3 = 符号+指数高位；bit0 即整个 word 的 bit24
                               # 与 BFA 翻的 bit24~26 同一量级
                               # 注意：翻"小权重"或尾数 LSB 会被 fp32 累加吞掉，canary 抓不到

restore() {
  echo "[demo] 恢复密文"
  sudo systemctl stop fara-weights.service
  sudo cp -f "$BAK" "$W"
  sync
  sudo systemctl start fara-weights.service
  sleep 8
  echo "[demo] 恢复后: active=$(systemctl is-active fara-weights.service)"
  ss -ltn 2>/dev/null | grep ':9000' || echo "[demo] 恢复后仍无监听（异常）"
}
trap restore EXIT INT TERM

echo "[demo] 备份密文 -> $BAK"
sudo cp -f "$W" "$BAK" || { echo "备份失败"; exit 2; }

echo "[demo] 停止服务"
sudo systemctl stop fara-weights.service
sleep 2

echo "[demo] 翻转 word[$IDX] 的指数位（byte $BOFF, bit0 = word bit24）"
sudo python3 -c "
p='$W'
f=open(p,'r+b')
f.seek($BOFF); b=f.read(1)
f.seek($BOFF); f.write(bytes([b[0]^1]))
f.close()
print('  %d -> %d' % (b[0], b[0]^1))
" || { echo "翻转失败"; exit 2; }

echo "[demo] 启动服务（预期拒绝）"
sudo systemctl start fara-weights.service
sleep 10

echo "[demo] --- 篡改后 ---"
echo "[demo] active=$(systemctl is-active fara-weights.service)"
if ss -ltn 2>/dev/null | grep -q ':9000'; then
  echo "[demo] FAIL: 9000 仍在监听（篡改未被拦截）"
else
  echo "[demo] PASS: 9000 无监听（拒绝启动）"
fi
sudo journalctl -u fara-weights.service --since '2 min ago' --no-pager \
  | grep -E 'CANARY|REFUSED|resident as ciphertext|canary hash' | tail -6
