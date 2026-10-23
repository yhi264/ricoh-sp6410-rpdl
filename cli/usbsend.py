#!/usr/bin/env python3
"""usbsend.py — USB プリンタークラスのデバイスに生バイト列を直接書き込む。

CUPS の raw キューが使えない / 動かない場合のフォールバック。
CUPS の usb バックエンドがやっていることを最小限に再現しているだけ。

準備:
    brew install libusb
    python3 -m pip install --user pyusb

使い方:
    python3 usbsend.py --list                    # プリンタークラスのデバイスを列挙
    python3 usbsend.py smoke-test.rpdl           # 最初に見つかった 1 台に送る
    python3 usbsend.py -d 05ca:0000 out.rpdl     # VID:PID 指定

注意:
    - 同じプリンターに対する CUPS のジョブが動いている間は排他で失敗する。
      その場合は該当キューを一時停止（cupsdisable）してから実行。
    - macOS では通常 sudo なしで開けるが、権限エラーが出たら sudo で。
"""

import argparse
import sys
import time

try:
    import usb.core
    import usb.util
except ImportError:
    sys.exit("pyusb がありません: python3 -m pip install --user pyusb")

USB_CLASS_PRINTER = 7
CHUNK = 16 * 1024
TIMEOUT_MS = 30_000


def find_printers():
    """(device, config, interface) のリストを返す。"""
    found = []
    for dev in usb.core.find(find_all=True):
        try:
            for cfg in dev:
                for intf in cfg:
                    if intf.bInterfaceClass == USB_CLASS_PRINTER:
                        found.append((dev, cfg, intf))
        except usb.core.USBError:
            # 開けないデバイス（権限など）は黙って飛ばす
            continue
    return found


def describe(dev):
    def safe(fn):
        try:
            return fn()
        except Exception:
            return "?"

    return "{:04x}:{:04x}  {}  {}".format(
        dev.idVendor,
        dev.idProduct,
        safe(lambda: dev.manufacturer) or "?",
        safe(lambda: dev.product) or "?",
    )


def bulk_out_endpoint(intf):
    return usb.util.find_descriptor(
        intf,
        custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress)
        == usb.util.ENDPOINT_OUT
        and usb.util.endpoint_type(e.bmAttributes) == usb.util.ENDPOINT_TYPE_BULK,
    )


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file", nargs="?", help="送信するファイル（RPDL 等の生データ）")
    ap.add_argument("--list", action="store_true", help="デバイスを列挙して終了")
    ap.add_argument("-d", "--device", help="VID:PID（例 05ca:0000）")
    args = ap.parse_args()

    printers = find_printers()
    if not printers:
        sys.exit("USB プリンタークラスのデバイスが見つかりません。"
                 "ケーブルと電源、USB-C ↔ USB-B の変換を確認してください。")

    if args.list:
        for dev, cfg, intf in printers:
            print(f"{describe(dev)}  (cfg {cfg.bConfigurationValue}, "
                  f"intf {intf.bInterfaceNumber}, alt {intf.bAlternateSetting})")
        return

    if not args.file:
        ap.error("送信するファイルを指定してください（または --list）")

    if args.device:
        vid, pid = (int(x, 16) for x in args.device.split(":"))
        printers = [t for t in printers if t[0].idVendor == vid and t[0].idProduct == pid]
        if not printers:
            sys.exit(f"{args.device} が見つかりません。--list で確認してください。")

    dev, cfg, intf = printers[0]
    print(f"target: {describe(dev)}")

    with open(args.file, "rb") as fh:
        data = fh.read()
    print(f"sending {len(data)} bytes ...")

    try:
        if dev.is_kernel_driver_active(intf.bInterfaceNumber):
            dev.detach_kernel_driver(intf.bInterfaceNumber)
    except (NotImplementedError, usb.core.USBError):
        # macOS では is_kernel_driver_active が未実装のことがある。無視して進む。
        pass

    try:
        dev.set_configuration(cfg.bConfigurationValue)
    except usb.core.USBError:
        # 既に設定済みなら失敗することがある
        pass

    usb.util.claim_interface(dev, intf.bInterfaceNumber)
    try:
        ep = bulk_out_endpoint(intf)
        if ep is None:
            sys.exit("bulk OUT エンドポイントが見つかりません。")

        sent = 0
        t0 = time.time()
        for i in range(0, len(data), CHUNK):
            chunk = data[i:i + CHUNK]
            n = ep.write(chunk, TIMEOUT_MS)
            if n != len(chunk):
                sys.exit(f"書き込みが途中で止まりました: {sent + n}/{len(data)}")
            sent += n
        print(f"done: {sent} bytes in {time.time() - t0:.1f}s")
    finally:
        usb.util.release_interface(dev, intf.bInterfaceNumber)
        usb.util.dispose_resources(dev)


if __name__ == "__main__":
    main()
