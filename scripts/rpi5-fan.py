#!/usr/bin/env python3
# Fan control for Raspberry Pi 5 + Talos (no pwm-rp1 driver).
# https://github.com/siderolabs/sbc-raspberrypi/issues/90

import mmap
import os
import struct
import sys

RESOURCE1 = os.environ.get(
    "RP1_RESOURCE1", "/host-sys/bus/pci/devices/0002:01:00.0/resource1"
)
THERMAL = os.environ.get("THERMAL_ZONE", "/host-sys/class/thermal/thermal_zone0/temp")


def read_temp_c() -> float:
    with open(THERMAL) as f:
        return int(f.read().strip()) / 1000


def speed_from_temp_c(temp_c: float) -> int:
    """Rough match to Pi 5 DT cooling trips (tepid/warm/hot/vhot)."""
    if temp_c < 50:
        return 0
    if temp_c < 60:
        return 30
    if temp_c < 67.5:
        return 55
    if temp_c < 75:
        return 80
    return 100


def get_fan_percent() -> int | None:
    """Read current PWM duty from RP1 (only works on the Pi with RESOURCE1)."""
    try:
        fd = os.open(RESOURCE1, os.O_RDWR | os.O_SYNC)
    except OSError:
        return None
    mm = mmap.mmap(fd, 4 * 1024 * 1024, mmap.MAP_SHARED, mmap.PROT_READ)
    CH = 3
    PWM1 = 0x9C000
    DUTY_REG = PWM1 + 0x020 + CH * 16
    RANGE_REG = PWM1 + 0x018 + CH * 16
    duty = struct.unpack_from("<I", mm, DUTY_REG)[0]
    range_ticks = struct.unpack_from("<I", mm, RANGE_REG)[0]
    mm.close()
    os.close(fd)
    if range_ticks == 0:
        return None
    return max(0, min(100, duty * 100 // range_ticks))


def print_status(temp_mc: int | None = None) -> None:
    if temp_mc is not None:
        temp_c = temp_mc / 1000
    else:
        temp_c = read_temp_c()
    target = speed_from_temp_c(temp_c)
    actual = get_fan_percent()
    print(f"Temperature: {temp_c:.1f}°C")
    print(f"Fan speed (auto target): {target}%")
    if actual is not None:
        print(f"Fan speed (hardware):    {actual}%")


def set_fan(speed: int) -> None:
    speed = max(0, min(100, speed))
    fd = os.open(RESOURCE1, os.O_RDWR | os.O_SYNC)
    mm = mmap.mmap(fd, 4 * 1024 * 1024, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)

    def read32(offset):
        return struct.unpack_from("<I", mm, offset)[0]

    def write32(offset, val):
        struct.pack_into("<I", mm, offset, val)

    CLK_PWM1_CTRL = 0x18084
    CLK_PWM1_DIV_INT = 0x18088
    CLK_PWM1_DIV_FRAC = 0x1808C
    CLK_PWM1_SEL = 0x18090
    CLK_CTRL_ENABLE = 1 << 11
    AUXSRC_XOSC = 2

    clk_ctrl = read32(CLK_PWM1_CTRL)
    write32(CLK_PWM1_CTRL, clk_ctrl & ~CLK_CTRL_ENABLE)
    write32(CLK_PWM1_DIV_INT, 1)
    write32(CLK_PWM1_DIV_FRAC, 0)
    clk_ctrl = read32(CLK_PWM1_CTRL)
    clk_ctrl &= ~0x3E1
    clk_ctrl |= (AUXSRC_XOSC << 5) | 1 | CLK_CTRL_ENABLE
    write32(CLK_PWM1_CTRL, clk_ctrl)
    write32(CLK_PWM1_SEL, 1 << 1)

    GPIO45_CTRL = 0xD0000 + 0x8000 + 11 * 8 + 4
    ctrl = read32(GPIO45_CTRL)
    if (ctrl & 0x1F) != 0:
        write32(GPIO45_CTRL, (ctrl & ~0x1F))

    PWM1 = 0x9C000
    CH = 3
    GLOB_CTRL = PWM1
    CHAN_CTRL = PWM1 + 0x014 + CH * 16
    RANGE_REG = PWM1 + 0x018 + CH * 16
    DUTY_REG = PWM1 + 0x020 + CH * 16
    RANGE_TICKS = 41566 // 20
    DUTY_TICKS = RANGE_TICKS * speed // 100

    write32(CHAN_CTRL, 0x109)
    write32(DUTY_REG, DUTY_TICKS)
    write32(RANGE_REG, RANGE_TICKS)
    glob = read32(GLOB_CTRL)
    glob |= 1 << CH
    write32(GLOB_CTRL, glob)
    glob = read32(GLOB_CTRL)
    glob |= 1 << 31
    write32(GLOB_CTRL, glob)

    mm.close()
    os.close(fd)


def main() -> None:
    if len(sys.argv) >= 2 and sys.argv[1] == "status":
        temp_mc = int(sys.argv[2]) if len(sys.argv) > 2 else None
        print_status(temp_mc)
        return

    if len(sys.argv) < 2 or sys.argv[1] in ("auto", "thermal"):
        temp_c = read_temp_c()
        speed = speed_from_temp_c(temp_c)
        mode = "auto"
    else:
        speed = int(sys.argv[1])
        temp_c = read_temp_c()
        mode = "manual"

    set_fan(speed)
    print(f"Fan: {speed}% ({mode}, temp={temp_c:.1f}C)")


if __name__ == "__main__":
    main()
