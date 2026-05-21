#!/usr/bin/env python3
"""
VisionPro 远程日志接收服务器
接收来自 Facial App 的 UDP 日志并打印到终端
支持会话管理：收到 [SESSION_START] 时清屏并存档上一会话
自动检测本机 IP 并写入 RemoteLogger.swift

用法: python3 log_server.py [--port 9527]
"""

import argparse
import os
import re
import socket
import sys
from datetime import datetime


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SWIFT_PATH = os.path.join(SCRIPT_DIR, "Facial", "RemoteLogger.swift")


def clear_screen():
    """跨平台清屏"""
    os.system("cls" if os.name == "nt" else "clear")


def save_session(logs, start_time, end_time, history_dir):
    """将会话日志写入 history_logs/ 文件夹"""
    if not logs:
        return

    os.makedirs(history_dir, exist_ok=True)

    fmt = "%Y%m%d_%H%M%S"
    filename = f"log_{start_time.strftime(fmt)}_to_{end_time.strftime(fmt)}.txt"
    filepath = os.path.join(history_dir, filename)

    with open(filepath, "w", encoding="utf-8") as f:
        f.write(f"VisionPro 远程日志存档\n")
        f.write(f"会话开始: {start_time.strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]}\n")
        f.write(f"会话结束: {end_time.strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]}\n")
        f.write(f"日志条数: {len(logs)}\n")
        f.write(f"{'─' * 60}\n")
        for line in logs:
            f.write(line + "\n")

    print(f"  💾 会话已存档 → {filepath}  ({len(logs)} 条日志)")


def get_local_ip():
    """自动获取本机局域网 IP（UDP connect 法，不依赖网卡名）"""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(0.1)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


def update_swift_ip(new_ip):
    """将 RemoteLogger.swift 中的 IP 替换为检测到的地址"""
    if not os.path.exists(SWIFT_PATH):
        print(f"  ⚠️ 未找到 RemoteLogger.swift ({SWIFT_PATH})，跳过 IP 更新")
        return False

    with open(SWIFT_PATH, "r", encoding="utf-8") as f:
        content = f.read()

    pattern = r'(NWEndpoint\.Host\(")[^"]+("\))'
    replaced = re.sub(pattern, rf'\g<1>{new_ip}\g<2>', content)

    if replaced == content:
        # 可能已经是正确的 IP
        if new_ip in content:
            print(f"  ✅ RemoteLogger.swift 中 IP 已是 {new_ip}，无需更新")
            return True
        print(f"  ⚠️ 未找到 NWEndpoint.Host 模式，IP 更新失败")
        return False

    with open(SWIFT_PATH, "w", encoding="utf-8") as f:
        f.write(replaced)

    print(f"  ✏️  RemoteLogger.swift 已更新 → {new_ip}")
    return True


def main():
    parser = argparse.ArgumentParser(description="VisionPro 远程日志接收服务器")
    parser.add_argument("--port", type=int, default=9527, help="监听端口 (默认 9527)")
    args = parser.parse_args()

    local_ip = get_local_ip()

    # 自动将 IP 写入 Swift 代码
    print(f"📡 检测到本机 IP: {local_ip}")
    update_swift_ip(local_ip)
    print()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", args.port))
    sock.settimeout(None)

    history_dir = "history_logs"
    os.makedirs(history_dir, exist_ok=True)

    # 当前会话状态
    session_logs = []
    session_start = datetime.now()

    print(f"🎧 VisionPro 日志服务器已启动")
    print(f"   监听: UDP {local_ip}:{args.port}")
    print(f"   历史日志目录: {os.path.abspath(history_dir)}/")
    print(f"   等待来自 headset 的日志...")
    print(f"   {'─' * 50}")

    while True:
        try:
            data, addr = sock.recvfrom(65535)
            now = datetime.now()
            timestamp = now.strftime("%H:%M:%S.%f")[:-3]
            message = data.decode("utf-8", errors="replace").strip()

            if not message:
                continue

            # 检查是否是会话开始信号
            if message.strip() == "[SESSION_START]":
                # 存档上一会话
                if session_logs:
                    print()
                    save_session(session_logs, session_start, now, history_dir)
                    print()

                # 清屏，开始新会话
                clear_screen()
                session_logs = []
                session_start = now

                banner_time = now.strftime("%Y-%m-%d %H:%M:%S")
                print(f"🎧 VisionPro 日志服务器 — 新会话 @ {banner_time}")
                print(f"   来源: {addr[0]}:{addr[1]} | 本机: {local_ip}:{args.port}")
                print(f"   历史存档: {os.path.abspath(history_dir)}/")
                print(f"   {'─' * 50}")
                continue

            # 普通日志行
            for line in message.split("\n"):
                line = line.strip()
                if line:
                    formatted = f"[{timestamp}] [{addr[0]}:{addr[1]}] {line}"
                    print(formatted)
                    session_logs.append(formatted)

        except KeyboardInterrupt:
            print(f"\n   {'─' * 50}")
            # 退出前保存当前会话
            save_session(session_logs, session_start, datetime.now(), history_dir)
            print("\n👋 日志服务器已关闭")
            sys.exit(0)
        except Exception as e:
            print(f"[ERROR] {e}", file=sys.stderr)


if __name__ == "__main__":
    main()
