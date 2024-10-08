# cython: language_level=3, profile=True

"""
Flitter DMX control
"""

import asyncio
import enum
import struct

import cython
from libc.math cimport round
from loguru import logger

from .. import name_patch
from ..clock import system_clock
from .. cimport model
from ..plugins import get_plugin
from ..streams import SerialStream, SerialException


logger = name_patch(logger, __name__)


class DMXDriver:
    async def update(self, model.Node node, data):
        raise NotImplementedError()

    def close(self):
        raise NotImplementedError()


class EntecDMXDriver(DMXDriver):
    VENDOR_ID = 0x0403
    PRODUCT_ID = 0x6001
    DEFAULT_BAUD_RATE = 57600
    PACKET_START = 0x7e
    PACKET_END = 0xe7

    class Label(enum.IntEnum):
        GetParameters = 3
        SetParameters = 4
        ReceivedDMXPacket = 5
        SendDMXPacket = 6

    class Parameters:
        @classmethod
        def from_payload(cls, payload):
            firmware_version, break_time, mark_after_break_time, refresh_rate = struct.unpack_from('<HBBB', payload)
            user_data = payload[6:]
            return cls(firmware_version, break_time, mark_after_break_time, refresh_rate, user_data)

        def __init__(self, firmware_version=None, break_time=9, mark_after_break_time=1, refresh_rate=40, user_data=b''):
            self.firmware_version = firmware_version
            self.break_time = break_time
            self.mark_after_break_time = mark_after_break_time
            self.refresh_rate = refresh_rate
            self.user_data = user_data

        def __bytes__(self):
            return struct.pack('<HBBB', len(self.user_data), self.break_time, self.mark_after_break_time, self.refresh_rate)

    def __init__(self, timeout=2.5):
        self._timeout = timeout
        self._stream = None
        self._failed = False
        self.parameters = None

    async def update(self, model.Node node, data):
        baudrate = node.get('baudrate', 1, int, self.DEFAULT_BAUD_RATE)
        device = node.get('device', 1, str)
        if self._stream is not None:
            if device is not None and device != self._stream.device:
                self._stream.close()
                self._stream = None
            elif baudrate != self._stream.baudrate:
                self._stream.baudrate = baudrate
        if self._stream is None:
            try:
                if device is not None:
                    self._stream = SerialStream(device, baudrate=baudrate)
                else:
                    self._stream = SerialStream.stream_matching(vid=self.VENDOR_ID, pid=self.PRODUCT_ID, baudrate=baudrate)
                await self.send_packet(self.Label.GetParameters, struct.pack('<H', 508))
                label, payload = await self.recv_packet()
                if label != self.Label.GetParameters:
                    raise ConnectionError("Label mismatch on initial parameters request")
                self.parameters = self.Parameters.from_payload(payload)
                logger.success("Connected to Entec DMX interface on {}", self._stream.device)
                logger.debug("Firmware version {}, refresh rate {}", self.parameters.firmware_version, self.parameters.refresh_rate)
                self._failed = False
            except (ConnectionError, SerialException):
                if not self._failed:
                    logger.warning("Unable to connect to DMX interface")
                    self._failed = True
        if self._stream is not None:
            try:
                await self.send_packet(self.Label.SendDMXPacket, data, pad=25)
            except SerialException:
                logger.error("Error writing to DMX interface")
                self.close()
                self._failed = True

    async def send_packet(self, label, payload, pad=None):
        length = len(payload) if pad is None else max(len(payload), pad)
        data = bytearray(length + 5)
        data[:4] = struct.pack('<BBH', self.PACKET_START, label, length)
        data[4:4+len(payload)] = payload
        data[-1] = self.PACKET_END
        self._stream.write(data)

    async def _readexactly(self, nbytes, until_time):
        return await asyncio.wait_for(self._stream.readexactly(nbytes), max(0, until_time - system_clock()))

    async def recv_packet(self):
        fail_time = system_clock() + self._timeout
        data = bytearray()
        junk = 0
        while True:
            data += await self._readexactly(4 - len(data), fail_time)
            index = data.find(self.PACKET_START)
            if index == 0:
                break
            if index == -1:
                index = len(data)
            junk += index
            del data[:index]
        if junk:
            logger.warning("Discarded {} leading bytes of junk in stream", junk)
        _, label, payload_length = struct.unpack('<BBH', data)
        payload = await self._readexactly(payload_length, fail_time)
        assert (await self._readexactly(1, fail_time)) == bytes([self.PACKET_END])
        return label, payload

    def close(self):
        if self._stream is not None:
            self._stream.close()
            self._stream = None


@cython.boundscheck(False)
@cython.wraparound(False)
cdef frame_and_escape(unsigned char[:] data):
    cdef int n=0, i, j
    cdef unsigned char b
    for i in range(len(data)):
        b = data[i]
        if b == 0x7d or b == 0x7e:
            n += 2
        else:
            n += 1
    cdef unsigned char[:] frame = bytearray(n + 2)
    frame[0] = 0x7e
    j = 1
    for i in range(len(data)):
        b = data[i]
        if b == 0x7d or b == 0x7e:
            frame[j] = 0x7d
            frame[j+1] = b ^ 0x20
            j += 2
        else:
            frame[j] = b
            j += 1
    frame[j] = 0x7e
    return frame


class OutputArtsDMXDriver(DMXDriver):
    VENDOR_ID = 0x03eb
    PRODUCT_ID = 0x2044
    DEFAULT_BAUD_RATE = 115200

    def __init__(self):
        self._stream = None
        self._failed = False

    async def update(self, model.Node node, data):
        baudrate = node.get('baudrate', 1, int, self.DEFAULT_BAUD_RATE)
        device = node.get('device', 1, str)
        if self._stream is not None:
            if device is not None and device != self._stream.device:
                self._stream.close()
                self._stream = None
            elif baudrate != self._stream.baudrate:
                self._stream.baudrate = baudrate
        if self._stream is None:
            try:
                if device is not None:
                    self._stream = SerialStream(device, baudrate=baudrate)
                else:
                    self._stream = SerialStream.stream_matching(vid=self.VENDOR_ID, pid=self.PRODUCT_ID, baudrate=baudrate)
                self._failed = False
                logger.success("Connected to OutputArts DMX interface on {}", self._stream.device)
            except SerialException:
                if not self._failed:
                    logger.warning("Unable to connect to DMX interface")
                    self._failed = True
        if self._stream is not None:
            try:
                frame = frame_and_escape(data)
                self._stream.write(bytes(frame))
                await self._stream.drain()
            except SerialException:
                logger.error("Error writing to DMX interface")
                self.close()
                self._failed = True

    def close(self):
        if self._stream is not None:
            self._stream.close()
            self._stream = None


cdef class DMX:
    cdef object driver

    def __init__(self, **kwargs):
        self.driver = None

    async def purge(self):
        pass

    async def destroy(self):
        if self.driver is not None:
            self.driver.close()
            self.driver = None

    async def update(self, engine, model.Node node, **kwargs):
        driver = node.get('driver', 1, str, '').lower()
        cls = get_plugin('flitter.render.dmx', driver)
        if cls is not None:
            if not isinstance(self.driver, cls):
                if self.driver is not None:
                    self.driver.close()
                self.driver = cls()
            channel_data = bytearray(513)
            end = self.collect_channels(node, channel_data)
            await self.driver.update(node, channel_data[:end])
        elif self.driver is not None:
            self.driver.close()
            self.driver = None

    cpdef int collect_channels(self, model.Node node, unsigned char[:] channel_data):
        cdef model.Node child
        cdef double channel
        cdef list channels
        cdef int start, end, i, n=1
        for child in node.children:
            if child.kind is 'fixture':
                address = child.get('address', 1, int)
                channels = child.get('channels', 0, float)
                if address is not None and channels is not None:
                    start = int(address)
                    end = start + len(channels)
                    if start >=1 and end <= len(channel_data):
                        for i, channel in zip(range(start, end), channels):
                            channel_data[i] = min(max(0, <int>(round(channel*255))), 255)
                        if end > n:
                            n = end
        return n
