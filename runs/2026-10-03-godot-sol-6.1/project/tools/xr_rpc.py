"""A local, ephemeral input client for the installed Meta XR Simulator.

The simulator does not enable gRPC reflection. Read its embedded protobuf
descriptors so the client matches the installed version. No simulator preferences,
device profiles, bindings, or input-source settings are written by this client.
Requires grpcio and protobuf (see requirements-xr.txt).
"""
from pathlib import Path
import re
import grpc
from google.protobuf import descriptor_pb2, descriptor_pool, message_factory, json_format
from google.protobuf import empty_pb2, any_pb2, timestamp_pb2, wrappers_pb2, source_context_pb2, type_pb2

DEFAULT_RUNTIME = Path("/Applications/MetaXRSimulator.app/Contents/Resources/MetaXRSimulator/SIMULATOR.so")


def embedded_descriptors(runtime=DEFAULT_RUNTIME):
    blob = Path(runtime).read_bytes()

    def varint(pos):
        value = shift = 0
        while shift < 64:
            byte = blob[pos]
            pos += 1
            value |= (byte & 127) << shift
            if byte < 128:
                return value, pos
            shift += 7
        raise ValueError("Invalid protobuf varint")

    files = {}
    pattern = rb"\x0a[\x01-\x7f]((?:arvr|xplat|schema|proto|google)/[a-zA-Z0-9_/.-]+\.proto)"
    for match in re.finditer(pattern, blob):
        start = pos = match.start()
        try:
            for _ in range(1000):
                tag, pos = varint(pos)
                if tag == 0:
                    break
                wire = tag & 7
                if wire == 2:
                    size, pos = varint(pos)
                    pos += size
                elif wire == 0:
                    _, pos = varint(pos)
                elif wire == 1:
                    pos += 8
                elif wire == 5:
                    pos += 4
                else:
                    break
                if tag >> 3 == 12:
                    break
            raw = blob[start:pos]
            desc = descriptor_pb2.FileDescriptorProto.FromString(raw)
            if desc.name.encode() == match.group(1) and desc.syntax in ("proto3", "proto2"):
                files[desc.name] = raw
        except (ValueError, IndexError, Exception):
            continue
    return files


class SimulatorRPC:
    def __init__(self, port, runtime=DEFAULT_RUNTIME):
        self.pool = descriptor_pool.Default()
        pending = [raw for name, raw in embedded_descriptors(runtime).items() if not name.startswith("google/")]
        while pending:
            deferred = []
            for raw in pending:
                try:
                    self.pool.AddSerializedFile(raw)
                except Exception:
                    deferred.append(raw)
            if len(deferred) == len(pending):
                raise RuntimeError("Simulator protocol dependencies changed; inspect the installed runtime.")
            pending = deferred
        self.channel = grpc.insecure_channel(f"localhost:{port}")

    def call(self, service, method, values=None, timeout=3):
        desc = self.pool.FindServiceByName("openxr_simulator.rpc.proto." + service)
        rpc = desc.methods_by_name[method]
        request = message_factory.GetMessageClass(rpc.input_type)()
        json_format.ParseDict(values or {}, request)
        factory = self.channel.unary_stream if rpc.server_streaming else self.channel.unary_unary
        call = factory(
            f"/{desc.full_name}/{method}",
            request_serializer=lambda value: value.SerializeToString(),
            response_deserializer=message_factory.GetMessageClass(rpc.output_type).FromString,
        )
        result = call(request, timeout=timeout)
        if rpc.server_streaming:
            stream = result
            try:
                result = next(stream)
            finally:
                stream.cancel()
        return json_format.MessageToDict(result, preserving_proto_field_name=True)

    def keys(self, names):
        self.call("Input", "SendKey", {"keys_down": names}, timeout=1)

    def release(self):
        self.keys([])

    def close(self):
        self.channel.close()
