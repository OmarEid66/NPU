#!/usr/bin/env python3
"""
UART-to-APB Master Bridge host utility.

Sends read/write commands over a serial port to the UART-APB debug bridge.
Supports direct 32-bit addresses or slave-number + offset notation.

Usage:
    uart_apb.py write <address> <data>  [options]
    uart_apb.py read  <address>         [options]
    uart_apb.py write --slave N --offset O <data> [options]
    uart_apb.py read  --slave N --offset O        [options]
    uart_apb.py lock                    [options]
    uart_apb.py map                               # print address map

Examples:
    uart_apb.py write 0x2004 0xDEADBEEF           # Slave 1, offset 0x04
    uart_apb.py read  0x2004                       # Slave 1, offset 0x04
    uart_apb.py write --slave 3 --offset 0x100 0xCAFEBABE
    uart_apb.py read  --slave 3 --offset 0x100
    uart_apb.py lock                               # permanently disable bridge
"""

import argparse
import struct
import sys

try:
    import serial
except ImportError:
    serial = None

SYNC       = bytes([0xDE, 0xAD])
CMD_WRITE  = 0xA5
CMD_READ   = 0x5A
STATUS_ACK = 0xAC
STATUS_ERR = 0xEE

NUM_SLAVES = 8
SLOT_SIZE  = 0x2000  # 8 KB per slave

LOCK_ADDR  = 0xFFFFFFF0
LOCK_KEY   = 0xDEAD10CC


def slave_offset_to_addr(slave, offset):
    """Convert (slave, offset) to a 32-bit address."""
    if slave < 0 or slave >= NUM_SLAVES:
        raise ValueError(f"Slave must be 0-{NUM_SLAVES-1}, got {slave}")
    if offset < 0 or offset >= SLOT_SIZE:
        raise ValueError(f"Offset must be 0-0x{SLOT_SIZE-1:X}, got 0x{offset:X}")
    return (slave * SLOT_SIZE) + offset


def addr_to_slave_offset(addr):
    """Convert a 32-bit address to (slave, offset)."""
    if addr < NUM_SLAVES * SLOT_SIZE:
        slave = (addr >> 13) & 0x7
        offset = addr & (SLOT_SIZE - 1)
        return slave, offset
    return None, addr


def open_port(port, baud):
    if serial is None:
        print("Error: pyserial is required. Install with: pip install pyserial")
        sys.exit(1)
    return serial.Serial(port, baud, timeout=2)


def apb_write(ser, addr, data):
    """Send a write command and wait for ACK/NACK."""
    slave, offset = addr_to_slave_offset(addr)
    loc = f"Slave {slave} + 0x{offset:04X}" if slave is not None else f"0x{addr:08X}"

    frame = SYNC + bytes([CMD_WRITE]) + struct.pack(">I", addr) + struct.pack(">I", data)
    ser.write(frame)
    resp = ser.read(1)
    if len(resp) == 0:
        print(f"Error: no response (timeout) — {loc}")
        return False
    status = resp[0]
    if status == STATUS_ACK:
        print(f"Write ACK: [{loc}] = 0x{data:08X}")
        return True
    elif status == STATUS_ERR:
        print(f"Write ERROR at {loc}")
        return False
    else:
        print(f"Unexpected status: 0x{status:02X}")
        return False


def apb_read(ser, addr):
    """Send a read command and return the data word."""
    slave, offset = addr_to_slave_offset(addr)
    loc = f"Slave {slave} + 0x{offset:04X}" if slave is not None else f"0x{addr:08X}"

    frame = SYNC + bytes([CMD_READ]) + struct.pack(">I", addr)
    ser.write(frame)
    resp = ser.read(1)
    if len(resp) == 0:
        print(f"Error: no response (timeout) — {loc}")
        return None
    status = resp[0]
    if status == STATUS_ACK:
        data_bytes = ser.read(4)
        if len(data_bytes) < 4:
            print("Error: incomplete read data")
            return None
        data = struct.unpack(">I", data_bytes)[0]
        print(f"Read ACK: [{loc}] = 0x{data:08X}")
        return data
    elif status == STATUS_ERR:
        print(f"Read ERROR at {loc}")
        return None
    else:
        print(f"Unexpected status: 0x{status:02X}")
        return None


def print_address_map():
    """Print the slave address map."""
    print(f"{'Slave':<8} {'Base':>12} {'End':>12} {'Size':>8}")
    print("-" * 44)
    for i in range(NUM_SLAVES):
        base = i * SLOT_SIZE
        end  = base + SLOT_SIZE - 1
        print(f"  {i:<6} 0x{base:08X}   0x{end:08X}   {SLOT_SIZE} B")
    print(f"\nLock register: 0x{LOCK_ADDR:08X} (write 0x{LOCK_KEY:08X} to lock)")


def parse_int(s):
    """Parse an integer from hex (0x...) or decimal string."""
    return int(s, 0)


def main():
    parser = argparse.ArgumentParser(
        description="UART-to-APB debug bridge host tool",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Address map (8 slaves x 8 KB each):
  Slave 0: 0x00000000 - 0x00001FFF
  Slave 1: 0x00002000 - 0x00003FFF
  ...
  Slave 7: 0x0000E000 - 0x0000FFFF

Use --slave and --offset for convenience, or pass a raw 32-bit address.
        """)

    parser.add_argument("command", choices=["read", "write", "lock", "map"],
                        help="APB transaction type, 'lock' to disable bridge, 'map' to show address map")
    parser.add_argument("address", nargs="?", type=parse_int, default=None,
                        help="32-bit APB address (hex or decimal)")
    parser.add_argument("data", nargs="?", type=parse_int, default=None,
                        help="32-bit write data (hex or decimal, write only)")
    parser.add_argument("--slave", "-s", type=int, default=None,
                        help=f"Slave number (0-{NUM_SLAVES-1})")
    parser.add_argument("--offset", "-o", type=parse_int, default=0,
                        help="Byte offset within slave (default: 0)")
    parser.add_argument("--port", "-p", default="/dev/ttyUSB0",
                        help="Serial port (default: /dev/ttyUSB0)")
    parser.add_argument("--baud", "-b", type=int, default=115200,
                        help="Baud rate (default: 115200)")

    args = parser.parse_args()

    # Handle 'map' — no serial needed
    if args.command == "map":
        print_address_map()
        return

    # Resolve address
    if args.command == "lock":
        addr = LOCK_ADDR
        data = LOCK_KEY
    elif args.slave is not None:
        addr = slave_offset_to_addr(args.slave, args.offset)
        data = args.data
    elif args.address is not None:
        addr = args.address
        data = args.data
    else:
        parser.error("provide an address or --slave/--offset")
        return

    if args.command == "write" and data is None:
        parser.error("write command requires a data argument")

    ser = open_port(args.port, args.baud)
    try:
        if args.command in ("write", "lock"):
            apb_write(ser, addr, data)
        else:
            apb_read(ser, addr)
    finally:
        ser.close()


if __name__ == "__main__":
    main()
