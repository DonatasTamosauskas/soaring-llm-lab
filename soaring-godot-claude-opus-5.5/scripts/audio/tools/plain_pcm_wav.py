# Rewrites WAVE_FORMAT_EXTENSIBLE 16-bit PCM files (afconvert output) as plain PCM, in place.
import struct, sys
for path in sys.argv[1:]:
    b = open(path, 'rb').read()
    pos = 12; fmt = None; data = None
    while pos + 8 <= len(b):
        cid = b[pos:pos+4]; size = struct.unpack('<I', b[pos+4:pos+8])[0]
        body = b[pos+8:pos+8+size]
        if cid == b'fmt ': fmt = body
        elif cid == b'data': data = body
        pos += 8 + size + (size & 1)
    tag, ch, rate, brate, align, bits = struct.unpack('<HHIIHH', fmt[:16])
    assert bits == 16, path
    out = b'RIFF' + struct.pack('<I', 36 + len(data)) + b'WAVE' + b'fmt ' + struct.pack('<IHHIIHH', 16, 1, ch, rate, rate*ch*2, ch*2, 16) + b'data' + struct.pack('<I', len(data)) + data
    open(path, 'wb').write(out)
