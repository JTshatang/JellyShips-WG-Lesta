"""Build the installable Lesta Mod from this directory and its soundtrack files."""

import argparse
from io import BytesIO
from hashlib import sha256
import json
import os
from pathlib import Path
import re
from shutil import copyfileobj
import subprocess
from tempfile import NamedTemporaryFile, TemporaryDirectory
import wave
from zipfile import ZIP_DEFLATED, ZIP_STORED, ZipFile


ROOT = Path(__file__).resolve().parent
BRAND = "莱斯塔-保持Q弹"
PORTAL = BRAND + "/"
PREVIOUS_PORTAL = "整舰Q弹/"
PAYLOAD = PORTAL + "组件/资源包.zip"
LOOSE_MOD = PORTAL + "模组文件/"
LEGACY_MOD = "res_mods/PnFMods/JellyShips04Coverage/"
LAUNCHER_SCRIPTS = {"Launcher.ps1", "Install.ps1", "Updates.ps1", "UpdateWindow.ps1", "Portable.ps1", "PlayerData.ps1"}


def read_release():
    release = json.loads((ROOT / "release.json").read_text(encoding="utf-8"))
    if (type(release.get("portable_format")) is not int or release["portable_format"] != 1
            or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){4}", release["build"])
            or type(release["revision"]) is not int or not 0 <= release["revision"] <= 2147483647
            or not re.fullmatch(r"(?:[A-Za-z0-9-]+/[A-Za-z0-9_.-]+)?", release["github_repository"])):
        raise ValueError("Invalid build, revision or GitHub repository in release.json")
    series = ".".join(release["build"].split(".")[:2])
    return dict(release, version=f"{series}.{release['revision']}")


def soundtrack(source, track, name, ffmpeg, staging):
    if source.is_file():
        with ZipFile(source) as base:
            member = "music/" + name
            for archive in (PAYLOAD, PREVIOUS_PORTAL + "组件/资源包.zip"):
                if archive in base.namelist():
                    with ZipFile(BytesIO(base.read(archive))) as payload:
                        return payload.read(member)
            for prefix in (LOOSE_MOD, PREVIOUS_PORTAL + "模组文件/", LEGACY_MOD):
                if prefix + member in base.namelist():
                    return base.read(prefix + member)
            raise ValueError(f"Soundtrack missing from player ZIP: {name}")
    wav = source / name
    if wav.is_file():
        return wav.read_bytes()
    original = source / track["source"]
    if not original.exists():
        original = source / (track["title"] + original.suffix)
    if sha256(original.read_bytes()).hexdigest() != track["sha256"]:
        raise ValueError(f"Soundtrack differs from the approved cut: {original.name}")
    with TemporaryDirectory(dir=staging) as folder:
        decoded = Path(folder) / name
        subprocess.run([ffmpeg, "-nostdin", "-loglevel", "error", "-i", str(original),
                        "-map", "0:a:0", "-ar", "48000", "-ac", "2", "-c:a", "pcm_s16le",
                        str(decoded)], check=True)
        return decoded.read_bytes()


def add_music(package, source, ffmpeg, staging):
    tracks = json.loads((ROOT / "src/music/tracks.json").read_text(encoding="utf-8"))
    for track in tracks:
        name = track["id"] + ".wav"
        member = "music/" + name
        data = soundtrack(source, track, name, ffmpeg, staging)
        with wave.open(BytesIO(data)) as wav:
            if (wav.getframerate(), wav.getnchannels(), wav.getsampwidth(), wav.getnframes()) != (
                48000, 2, 2, track["frames"]
            ):
                raise ValueError(f"Soundtrack does not match tracks.json: {name}")
        package.writestr(member, data)


def player_guide():
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    guide, separator, _ = readme.partition("\n## 二次开发\n")
    if not separator:
        raise ValueError("README.md is missing the developer section after the player guide")
    guide = re.sub(r"^#{1,3} ", "", guide, flags=re.MULTILINE)
    guide = re.sub(r"\[([^\]\n]+)\]\((https://[^)\n]+)\)", r"\1（\2）", guide)
    return guide.replace("**", "").replace("`", "").strip() + "\n"


def build_payload(audio, ffmpeg, staging, destination):
    with ZipFile(destination, "w", ZIP_DEFLATED) as package:
        package.writestr("使用说明.txt", player_guide())
        for group in ("mod", "editor", "music"):
            for path in sorted((ROOT / "src" / group).iterdir()):
                if not path.is_file() or path.suffix not in {
                    ".py", ".cmd", ".ps1", ".cs", ".seq", ".svg", ".txt", ".json"
                }:
                    continue
                dest = "music/tracks.json" if path.name == "tracks.json" else path.name
                package.write(path, dest)
        for name in ("game-resources.zip", "libraries.zip"):
            with ZipFile(ROOT / "assets" / name) as resources:
                for entry in resources.infolist():
                    with resources.open(entry) as src, package.open(entry.filename, "w") as dst:
                        copyfileobj(src, dst)
        add_music(package, audio, ffmpeg, staging)
    with ZipFile(destination) as payload:
        names = payload.namelist()
        if len(names) != len(set(names)) or payload.testzip():
            raise ValueError("Duplicate or damaged runtime files")


def build(audio, output, ffmpeg):
    release = read_release()
    hashes = {}
    launcher_scripts = sorted((ROOT / "src/launcher").glob("*.ps1"))
    if not LAUNCHER_SCRIPTS.issubset(script.name for script in launcher_scripts):
        raise ValueError("Launcher scripts do not match the player updater's component list")
    output.parent.mkdir(parents=True, exist_ok=True)
    with NamedTemporaryFile(dir=output.parent, suffix=".tmp", delete=False) as pending:
        temp = Path(pending.name)
    try:
        with ZipFile(temp, "w", ZIP_DEFLATED) as package:
            compiler = Path(os.environ["WINDIR"]) / "Microsoft.NET/Framework/v4.0.30319/csc.exe"
            with TemporaryDirectory(dir=output.parent) as folder:
                exe = Path(folder) / (BRAND + ".exe")
                subprocess.run([str(compiler), "/nologo", "/target:winexe", "/platform:anycpu",
                                "/codepage:65001", "/reference:System.Windows.Forms.dll",
                                f"/out:{exe}", str(ROOT / "src/launcher/Launcher.cs")], check=True)
                package.write(exe, PORTAL + exe.name)
                payload = Path(folder) / "资源包.zip"
                build_payload(audio, ffmpeg, output.parent, payload)
                package.write(payload, PAYLOAD, compress_type=ZIP_STORED)
                for artifact in (exe, payload):
                    digest = sha256()
                    with artifact.open("rb") as source:
                        for block in iter(lambda: source.read(1024 * 1024), b""):
                            digest.update(block)
                    hashes[artifact.name] = digest.hexdigest()
            for script in launcher_scripts:
                launcher = script.read_text(encoding="utf-8-sig").encode("utf-8-sig")
                hashes[script.name] = sha256(launcher).hexdigest()
                package.writestr(PORTAL + "组件/" + script.name, launcher)
            package.write(ROOT / "安装说明.txt", "安装说明.txt")
            release["launcher_hashes"] = hashes
            package.writestr(PORTAL + "组件/package.json", json.dumps(release))
        with ZipFile(temp) as package:
            names = package.namelist()
            if len(names) != len(set(names)) or package.testzip():
                raise ValueError("Duplicate or damaged installation files")
        temp.replace(output)
    finally:
        temp.unlink(missing_ok=True)


if __name__ == "__main__":
    release = read_release()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--audio", type=Path, default=ROOT / "audio",
                        help="Directory of soundtrack masters or WAVs, or an existing full player ZIP")
    parser.add_argument("--ffmpeg", default="ffmpeg", help="Decoder for FLAC or MP3 masters")
    parser.add_argument("--output", type=Path,
                        default=ROOT / "dist" / f"{release['version']}.zip")
    args = parser.parse_args()
    if not args.audio.exists():
        parser.error("Supply --audio with the full player ZIP or the directory containing the two WAVs")
    if args.audio.resolve() == args.output.resolve():
        parser.error("Choose a separate output file")
    build(args.audio, args.output, args.ffmpeg)
    print(args.output.resolve())
