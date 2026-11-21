"""Read the Lesta 26.11 ship catalog and native visual descriptors."""

from collections import defaultdict
from dataclasses import dataclass
from functools import cache
import base64
import io
import json
import math
from pathlib import Path, PurePosixPath
import pickle
import struct
import xml.etree.ElementTree as ET
from zipfile import ZipFile
import zlib


IDENTITY = tuple(float(row == column) for row in range(4) for column in range(4))


class ParamRecord:
    """Inert stand-in for game classes encoded by GameParams."""

    def __new__(cls, *_args, **_kwargs):
        return super().__new__(cls)


class GameParamsReader(pickle.Unpickler):
    def find_class(self, module, name):
        return ParamRecord


def game_params(data: bytes) -> dict:
    records, _ = GameParamsReader(io.BytesIO(zlib.decompress(data[::-1]))).load()
    if not isinstance(records, dict) or not records:
        raise ValueError("GameParams does not contain a parameter table")
    return records


@dataclass(frozen=True)
class SdkShip:
    models: dict[str, str]
    roots: dict[str, str]
    animations: tuple[str, ...]


def sdk_ships(archive: ZipFile) -> dict[str, SdkShip]:
    ships = {}
    for filename in archive.namelist():
        if not filename.endswith("/content.info") or filename.count("/") != 1:
            continue
        ship = filename.split("/")[0]
        info = ET.fromstring(archive.read(filename))
        if info.tag != "content_info" or ship in ships:
            raise ValueError(f"Unexpected SDK catalog entry: {filename}")
        fields = {node.tag: base64.b64decode(node.text.strip(), validate=True) for node in info}
        if len(fields) != len(info):
            raise ValueError(f"Duplicate SDK catalog entry: {filename}")
        roots = json.loads(zlib.decompress(fields.pop("RootModels.info")))
        animations = tuple(json.loads(zlib.decompress(fields.pop("RootAnims.info"))))
        models = {}
        for data in fields.values():
            exported, native, kind = json.loads(data)
            prefix = f"PnFMods/ModsSDK.zip/{ship}/"
            if not exported.startswith(prefix) or not native.startswith("content/"):
                raise ValueError(f"Unexpected SDK path in {filename}: {exported}, {native}")
            if kind == "ship":
                models[native] = exported.removeprefix(prefix)
        ships[ship] = SdkShip(models, roots, animations)
    if not ships:
        raise ValueError("The SDK archive has no ship catalog")
    return ships


@dataclass(frozen=True)
class NativeModel:
    visual: str
    parent: str | None
    extent: float
    casts_shadow: bool


class NativeAssets:
    """Read the indexed model and split visual skeleton records for this layout."""

    def __init__(self, data: bytes):
        self.data = data
        if self.read("2I", 0) != (0x42574442, 0x01010000):
            raise ValueError("Unsupported assets.bin header")
        count, _, entries = self.read("IIq", 80)
        names = {}
        for i in range(count):
            offset = 80 + entries + i * 32
            identifier, parent, size, _, relative = self.read("QQIIq", offset)
            start = offset + 16 + relative
            names[identifier] = (parent, data[start:start + size].rstrip(b"\0").decode())
        if len(names) != count:
            raise ValueError("Duplicate resource ID in assets.bin")

        visiting = set()

        @cache
        def full_path(identifier: int) -> str:
            if identifier in visiting:
                raise ValueError("Cyclic resource path in assets.bin")
            parent, name = names[identifier]
            visiting.add(identifier)
            path = f"{full_path(parent)}/{name}" if parent in names else name
            visiting.remove(identifier)
            return path

        self.paths = {identifier: full_path(identifier) for identifier in names}
        self.ids = {path: identifier for identifier, path in self.paths.items()}

        count, _, keys, values = self.read("IIqq", 56)
        self.refs = {}
        for i in range(count):
            identifier, occupied = self.read("QQ", 56 + keys + i * 16)
            if identifier or occupied:
                self.refs[identifier], = self.read("I", 56 + values + i * 4)

        count, _, entries = self.read("IIq", 96)
        self.blobs = []
        for i in range(count):
            offset = 16 + entries + i * 24
            _, _, size, _, relative = self.read("IIIIq", offset)
            self.blobs.append((offset + relative, size))
        start, size = self.blobs[3]
        records, = self.read("Q", start)
        if 16 + records * 32 != size:
            raise ValueError("Unsupported native model record layout")
        self.models_by_directory = defaultdict(list)
        for path in self.ids:
            if "/ship/" in path and path.startswith("content/") and path.endswith(".model"):
                self.models_by_directory[path.rpartition("/")[0]].append(path)
        self.names = self.read_strings()

    def read(self, fmt: str, offset: int) -> tuple:
        return struct.unpack_from("<" + fmt, self.data, offset)

    def read_strings(self) -> dict[int, str]:
        count, _, keys, values, _, _, strings = self.read("IIqqIIq", 16)
        result = {}
        for i in range(count):
            identifier, occupied = self.read("II", 16 + keys + i * 8)
            if identifier or occupied:
                relative, = self.read("I", 16 + values + i * 4)
                start = 16 + strings + relative
                result[identifier] = self.data[start:self.data.index(b"\0", start)].decode()
        return result

    def record(self, path: str, blob: int, width: int) -> int:
        ref = self.refs.get(self.ids.get(path, -1), -1)
        if ref & 255 != blob * 4:
            raise ValueError(f"Missing resource or unsupported reference: {path}")
        start, size = self.blobs[blob]
        offset = 16 + (ref >> 8) * width
        if offset + width > size:
            raise ValueError(f"Out-of-range native record: {path}")
        return start + offset

    def model_record(self, path: str) -> tuple:
        offset = self.record(path, 3, 32)
        return self.read("QQffII", offset)

    def model(self, path: str) -> NativeModel:
        parent, visual, extent, alternate_extent, flags, reserved = self.model_record(path)
        if (extent != alternate_extent or not math.isfinite(extent)
                or flags not in {8, 9, 10, 11} or reserved):
            raise ValueError(f"Unsupported model flags or LOD extent: {path}")
        if (visual not in self.paths or not self.paths[visual].endswith(".visual")
                or (parent and (parent not in self.paths or not self.paths[parent].endswith(".model")))):
            raise ValueError(f"Unresolved model reference: {path}")
        return NativeModel(self.paths[visual], self.paths[parent] if parent else None, extent, bool(flags & 1))

    def skeleton(self, visual: str) -> dict[str, tuple[str | None, tuple[float, ...]]]:
        offset = self.record("@" + visual, 1, 64)
        count, _, _, _, names, matrices, _, _, parents = self.read("II7q", offset)
        identifiers = self.read(f"{count}I", offset + names)
        hierarchy = self.read(f"{count}H", offset + parents)
        result = {}
        for i, (identifier, parent) in enumerate(zip(identifiers, hierarchy)):
            name = self.names[identifier]
            matrix = self.read("16f", offset + matrices + i * 64)
            value = (self.names[identifiers[parent]] if parent < count else None, matrix)
            if not all(math.isfinite(x) for x in matrix):
                raise ValueError(f"Non-finite transform in {visual}: {name}")
            if name in result and result[name] != value:
                if name in {"Scene Root", "export", "Bow_ports", "Stern_ports", "HP_FX_WakeTrace",
                            "HP_FX_WakeTraceBack"}:
                    raise ValueError(f"Ambiguous transform in {visual}: {name}")
            result[name] = value
        return result

    def assembly(self, root: str) -> list[str]:
        folder, _, filename = root.rpartition("/")
        stem = PurePosixPath(filename).stem
        return sorted(path for path in self.models_by_directory[folder]
                      if path == root or PurePosixPath(path).stem.startswith(stem + "_"))

    def lod_chain(self, path: str) -> list[str]:
        chain = []
        while path:
            if path in chain:
                raise ValueError(f"Cyclic native LOD chain: {path}")
            chain.append(path)
            # A native parent keeps its own flags and extents when loaded directly.
            parent, visual, *_ = self.model_record(path)
            if not self.paths.get(visual, "").endswith(".visual"):
                raise ValueError(f"Unresolved visual reference in LOD chain: {path}")
            path = self.paths[parent] if parent else ""
        return chain
