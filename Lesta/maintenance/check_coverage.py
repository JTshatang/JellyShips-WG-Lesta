"""Audit stock and optionally upgraded ship hulls in a JellyShips release."""

import argparse
import ast
import base64
from collections import Counter, defaultdict
from contextlib import contextmanager
from functools import cache
from hashlib import sha256
from io import BytesIO
import json
from pathlib import Path, PurePosixPath
import subprocess
import xml.etree.ElementTree as ET
from zipfile import ZipFile
import zlib

from lesta_coverage_sources import NativeAssets, game_params


PROJECT = Path(__file__).resolve().parents[1]
MOD_PREFIX = "PnFMods/JellyShips04Coverage/"
PLAYABLE_GROUPS = {"start", "upgradeable", "special", "specialUnsellable", "ultimate",
                   "superShip", "earlyAccess"}
SHIP_CLASSES = {"Cruiser", "Battleship", "Destroyer", "AirCarrier", "Submarine"}
REASONS = ("旧规则跳过", "原生资源缺失", "原因待定")
UNEQUAL_CONTACTS = "Unequal contact heights;"
MISSING_GEOMETRY = "Indexed model descriptor has no installed root geometry payload"


@contextmanager
def release_files(args):
    if args.package:
        with ZipFile(args.package) as package:
            portal = "莱斯塔-保持Q弹/组件/"
            if portal + "package.json" not in package.namelist():
                portal = "整舰Q弹/组件/"
            release = json.loads(package.read(portal + "package.json"))
            with ZipFile(BytesIO(package.read(portal + "资源包.zip"))) as payload:
                yield args.package.name, release, payload.read("Main.py"), payload, payload.read
        return

    resources = "assets/game-resources.zip"
    if args.ref:
        commit = subprocess.check_output(
            ["git", "rev-parse", "--verify", "--end-of-options", args.ref + "^{commit}"],
            cwd=PROJECT, text=True,
        ).strip()

        def read(path):
            return subprocess.check_output(
                ["git", "show", f"{commit}:./{path}"], cwd=PROJECT,
            )

        if not subprocess.check_output(
            ["git", "ls-tree", "--name-only", commit, "--", resources], cwd=PROJECT,
        ):
            resources = "assets/ships.zip"
        label = commit[:12]
    else:
        def read(path):
            return (PROJECT / path).read_bytes()

        label = "源码目录"

    release = json.loads(read("release.json"))
    with ZipFile(BytesIO(read(resources))) as archive:
        def read_resource(path):
            if "/" not in path and path.endswith(".seq"):
                try:
                    return read("src/mod/" + path)
                except (FileNotFoundError, subprocess.CalledProcessError):
                    pass
            return archive.read(path)

        yield label, release, read("src/mod/Main.py"), archive, read_resource


def registrations(main):
    """Read literal SDK registrations without running the game entry point."""
    names = set()
    for node in ast.walk(ast.parse(main)):
        if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                and node.func.attr == "registerShipMod"):
            if (len(node.args) != 1 or node.keywords or not isinstance(node.args[0], ast.Constant)
                    or not isinstance(node.args[0].value, str)):
                raise ValueError("Unsupported registerShipMod call")
            names.add(node.args[0].value)
    return names


def music_ids(main):
    for node in ast.walk(ast.parse(main)):
        if isinstance(node, ast.Assign) and any(
            isinstance(target, ast.Name) and target.id == "MUSIC_SHIPS" for target in node.targets
        ):
            ids = ast.literal_eval(node.value)
            if (not isinstance(ids, tuple) or any(type(ship_id) is not int for ship_id in ids)
                    or len(set(ids)) != len(ids)):
                raise ValueError("MUSIC_SHIPS must contain unique numeric ship IDs")
            return set(ids)
    raise ValueError("MUSIC_SHIPS is missing from Main.py")


def hull_upgrades(ship):
    upgrades = getattr(ship, "ShipUpgradeInfo", {})
    upgrades = upgrades if isinstance(upgrades, dict) else vars(upgrades)
    return {name: upgrade for name, upgrade in upgrades.items()
            if getattr(upgrade, "ucType", None) == "_Hull"}


def stock_components(ship):
    return sorted({component for upgrade in hull_upgrades(ship).values()
                   if upgrade.prev == "" for component in upgrade.components.get("hull", [])})


def playable(ship):
    return ship.group in PLAYABLE_GROUPS and ship.typeinfo.species in SHIP_CLASSES


def upgraded_hulls(params):
    roots = defaultdict(lambda: defaultdict(set))
    for ship in params.values():
        if getattr(ship.typeinfo, "type", None) != "Ship" or not playable(ship):
            continue
        upgrades = hull_upgrades(ship)
        successors = defaultdict(list)
        for name, upgrade in upgrades.items():
            successors[upgrade.prev].append(name)

        reached = set(successors[""])
        pending = list(reached)
        while pending:
            predecessor = pending.pop()
            for name in successors[predecessor]:
                reached.add(name)
                pending.append(name)
                components = upgrades[name].components.get("hull") or ["（升级组件不明）"]
                for component in components:
                    root = getattr(getattr(ship, component, None), "model", None)
                    roots[ship.id][root].add((name, predecessor, component))
        if reached != upgrades.keys():
            raise ValueError(f"Unreachable hull upgrades for {ship.name}: {sorted(upgrades.keys() - reached)}")
    return roots


def catalog(params):
    names = defaultdict(set)
    stock = defaultdict(lambda: defaultdict(set))
    display_names = {}
    excluded = Counter()
    for name, ship in params.items():
        if getattr(ship.typeinfo, "type", None) != "Ship":
            continue
        for alias in {name, ship.name}:
            names[alias.removeprefix("P")].add(ship.id)
        if not playable(ship):
            excluded[ship.group] += 1
            continue
        display_names.setdefault(ship.id, ship.name)
        components = stock_components(ship)
        for component in components or ["（基础组件不明）"]:
            root = getattr(getattr(ship, component, None), "model", None)
            stock[ship.id][root].add(component)
    if not stock:
        raise ValueError("GameParams contains no ships in the supported playable groups")
    return names, stock, display_names, excluded


def mapping(data):
    info = ET.fromstring(data)
    if info.tag != "content_info" or not info.text:
        raise ValueError("Expected a compile.info model mapping")
    models = json.loads(zlib.decompress(base64.b64decode(info.text.strip(), validate=True)))
    if not isinstance(models, dict) or not all(isinstance(path, str) for path in models.values()):
        raise ValueError("Expected a native-to-Mod path mapping")
    return models


def mod_path(path):
    if (path.startswith(MOD_PREFIX) and ".." not in PurePosixPath(path).parts
            and "\\" not in path):
        return path.removeprefix(MOD_PREFIX)
    raise ValueError(f"路径不在当前 Mod 目录 {path}")


def archive_checks(archive, read):
    members = archive.namelist()
    counts = Counter(members)
    if duplicates := [name for name, count in counts.items() if count > 1]:
        raise ValueError(f"Duplicate ZIP member: {duplicates[0]}")
    tables = {}
    for name in members:
        if name.count("/") == 1 and name.endswith("/compile.info"):
            owner = name.split("/")[0]
            try:
                tables[owner] = mapping(read(name)), None
            except (ValueError, ET.ParseError, zlib.error) as error:
                tables[owner] = {}, str(error)

    @cache
    def xml(path):
        try:
            return ET.fromstring(read(path))
        except KeyError:
            raise KeyError(path) from None

    return tables, xml


def root_animation(owner, root):
    stem = PurePosixPath(root).stem
    return f"{owner}/animations/{stem}/{stem}.ssm"


def check_animation(machine, xml, check_references):
    try:
        nodes = xml(machine).findall("node")
        root_loop = False
        for node in nodes:
            if node.findtext("type") != "sequence":
                continue
            loop = node.findtext("isLoop") == "true" and node.findtext("loop") == "-1"
            if not loop and not check_references:
                continue
            sequence = xml(mod_path(node.findtext("resource", "")))
            for obj in sequence.findall("sequenceObject"):
                reference = obj.findtext("resource", "").strip()
                if check_references and reference:
                    xml(mod_path(reference))
                if (obj.findtext("name") == "Root" and obj.findtext("type") == "model"
                        and any(track.findtext("name") == "scale" and track.findall("frame")
                                for track in obj.findall("track")) and loop):
                    if not check_references:
                        return None
                    root_loop = True
        return None if root_loop else f"无 Root 循环缩放 {machine}"
    except KeyError as error:
        return f"缺动画文件 {error.args[0]}"
    except (ValueError, ET.ParseError) as error:
        return f"无效动画 {machine}（{error}）"


def check_binding(owner, root, paths, tables, xml, native, check_references=False):
    models, error = tables.get(owner, (None, None))
    if error:
        return [f"{owner}/compile.info 无效（{error}）"]
    if models is None:
        return [f"缺 {owner}/compile.info、基础模型映射及根动画"]

    gaps = []
    missing = sorted(paths - models.keys())
    if root in missing:
        gaps.append("缺船体根映射")
        missing.remove(root)
    if missing:
        detail = (f"全部 {len(missing)} 个" if len(missing) == len(paths - {root})
                  else ", ".join(PurePosixPath(path).name for path in missing))
        gaps.append("缺舰段映射 " + detail)
    for path in sorted(paths & models.keys()):
        target = models[path]
        try:
            model = xml(mod_path(target))
            visual = model.findtext("nodefullVisual", "").strip()
            if visual.startswith(MOD_PREFIX):
                xml(mod_path(visual + ".visual"))
            elif visual + ".visual" not in native.ids:
                gaps.append(f"模型 visual 引用缺失 {target} → {visual or '（空）'}")
            if check_references and (parent := model.findtext("parent", "").strip()):
                if parent.startswith(MOD_PREFIX):
                    xml(mod_path(parent + ".model"))
                elif parent + ".model" not in native.ids:
                    gaps.append(f"模型 parent 引用缺失 {target} → {parent}")
        except KeyError as error:
            gaps.append(f"缺映射目标 {error.args[0]}")
        except (ValueError, ET.ParseError) as error:
            gaps.append(f"无效模型 {target}（{error}）")

    if animation_gap := check_animation(root_animation(owner, root), xml, check_references):
        gaps.append(animation_gap)
    return gaps


def classify(entry, root, native):
    diagnostic = entry.get("diagnostic", "")
    if root and (root not in native.ids or
                 diagnostic == MISSING_GEOMETRY):
        return REASONS[1], diagnostic or "客户端索引无基础船体"
    if diagnostic.startswith(UNEQUAL_CONTACTS):
        return REASONS[0], ""
    return REASONS[2], diagnostic


def inspect(params, native, history, main, archive, read, include_upgrades=False):
    names, stock, display_names, excluded = catalog(params)
    upgrades = upgraded_hulls(params) if include_upgrades else {}
    tables, xml = archive_checks(archive, read)
    registered = registrations(main)
    by_id = defaultdict(set)
    for owner in registered | tables.keys():
        ids = names[owner]
        if len(ids) == 1:
            by_id[next(iter(ids))].add(owner)

    bound_owners = defaultdict(set)
    music_expected = {}
    for owner in sorted(registered & tables.keys()):
        models, _ = tables[owner]
        for path in models:
            bound_owners[path].add(owner)
        if models and len(names[owner]) == 1:
            music_expected.setdefault(next(iter(names[owner])), owner)

    root_ships = defaultdict(set)
    for ship_id, roots in stock.items():
        for root in roots:
            if root:
                root_ships[root].add(ship_id)

    audit_rows = defaultdict(dict)
    for ship in history["ships"].values():
        audit_rows[ship["id"]].update(ship["variants"])

    rows = []
    upgrade_rows = []
    for ship_id, name in sorted(display_names.items(), key=lambda item: item[1]):
        owners = by_id[ship_id]
        active = owners & registered
        stock_roots = stock[ship_id]
        upgrade_roots = upgrades.get(ship_id, {})
        for root in sorted(stock_roots.keys() | upgrade_roots.keys(), key=lambda path: path or ""):
            problems = [] if active else ["缺舰船注册"]
            if root:
                paths = set(native.assembly(root)) | {root}
                candidates = active or owners or {name.removeprefix("P")}
                other = bound_owners[root] - owners
            else:
                other = set()
            entry = audit_rows[ship_id].get(root, {})
            reason, diagnostic = classify(entry, root, native)
            for is_upgrade, components in ((False, stock_roots.get(root)), (True, upgrade_roots.get(root))):
                if components is None:
                    continue
                row_problems = problems.copy()
                owner = None
                if root:
                    results = {
                        candidate: check_binding(candidate, root, paths, tables, xml, native, is_upgrade)
                        for candidate in sorted(candidates)
                    }
                    owner = min(results, key=lambda candidate: len(results[candidate]))
                    row_problems += results[owner]
                    if reason == REASONS[1] and root not in native.ids:
                        row_problems.append("客户端索引无升级船体" if is_upgrade else "客户端索引无基础船体")
                else:
                    row_problems.append("升级组件无法解析到模型路径" if is_upgrade else "基础组件无法解析到模型路径")
                row = {
                    "name": name, "id": ship_id, "root": root, "components": sorted(components),
                    "problems": row_problems, "reason": reason, "diagnostic": diagnostic,
                    "shared": len(root_ships[root]) > 1, "other": sorted(other),
                }
                if is_upgrade:
                    row["owner"] = owner
                    row["stock_roots"] = stock_roots
                    if owner and not row_problems:
                        row["binding"] = tables[owner][0][root]
                        row["animation"] = root_animation(owner, root)
                        row["sequences"] = [
                            node.findtext("resource") for node in xml(row["animation"]).findall("node")
                            if node.findtext("type") == "sequence"
                        ]
                    upgrade_rows.append(row)
                else:
                    rows.append(row)
    unknown = sorted(name for name in registered if len(names[name]) != 1)
    return rows, excluded, len(registered), unknown, upgrade_rows, music_expected


def report(label, release, rows, excluded, registrations_count, unknown, focus):
    failures = [row for row in rows if row["problems"]]
    counts = Counter(row["reason"] for row in failures)
    ship_ids = {row["id"] for row in rows}
    failed_ids = {row["id"] for row in failures}
    lines = [
        f"# 基础船体覆盖检查 · {release['build']} r{release['revision']}",
        "",
        f"检查目标：`{label}`。",
        "",
        f"覆盖 {len(ship_ids) - len(failed_ids)}/{len(ship_ids)} 艘常规舰船，"
        f"{len(rows) - len(failures)}/{len(rows)} 个舰船 ID／基础船体组合。"
        f"入口包含 {registrations_count} 个注册名。"
        f"有 {sum(row['shared'] for row in rows)} 个组合的船体被其他常规舰船共用。",
        "",
        "缺口按组合计：" + "，".join(f"{reason} {counts[reason]}" for reason in REASONS) + "。",
        "",
        "范围为常规组舰船的初始船体升级组件。活动／测试／保留舰、改模涂装、"
        "后续升级船体及运行时装配另行验证。完整映射仅代表静态覆盖。",
        "",
        "范围外参数记录数：" + "，".join(f"{group} {count}" for group, count in sorted(excluded.items())) + "。",
    ]
    if unknown:
        lines += ["", "未唯一对应舰船 ID 的注册名：" + "，".join(unknown) + "。"]

    selected = [row for row in rows if row["id"] in focus]
    for title, group in [(reason, [row for row in failures if row["reason"] == reason])
                         for reason in REASONS] + [("指定舰船", selected)]:
        if not group:
            continue
        lines += ["", f"## {title}", ""]
        if title == REASONS[0]:
            lines += ["与北安普敦同一条旧规则，舰艏与舰艉的尾流挂点高度不同。", ""]
        lines += ["| 舰船参数 | 数值 ID | 基础船体 | 检查结果 |",
                  "| --- | ---: | --- | --- |"]
        for row in group:
            result = list(row["problems"]) or ["已注册，模型和根动画齐全"]
            if row["problems"] and row["diagnostic"]:
                result.append(row["diagnostic"])
            if row["problems"] and row["other"]:
                result.append("同路径见其他舰船注册 " + ", ".join(row["other"]))
            root = row["root"] or "（路径待定）"
            lines.append(f"| {row['name']} | {row['id']} | `{root}` ({', '.join(row['components'])}) | "
                         + "；".join(result).replace("|", r"\|") + " |")
    if missing := focus - ship_ids:
        raise ValueError(f"Ship IDs outside the audited catalog: {sorted(missing)}")
    return "\n".join(lines) + "\n"


def music_report(main, expected, focus):
    actual = music_ids(main)
    missing = expected.keys() - actual
    extra = actual - expected.keys()
    lines = [
        "", "## 战斗音乐覆盖", "",
        f"音乐名单覆盖 {len(expected) - len(missing)}/{len(expected)} 个已注册且有模型映射的舰船 ID。"
        f"漏列 {len(missing)} 个，无对应视觉绑定 {len(extra)} 个。", "",
    ]
    selected = missing | extra | focus
    if selected:
        lines += ["| 舰船注册名 | 数值 ID | 视觉绑定 | 战斗音乐名单 |",
                  "| --- | ---: | --- | --- |"]
        for ship_id in sorted(selected):
            owner = expected.get(ship_id, "—")
            visual = "有" if ship_id in expected else "无"
            music = "有" if ship_id in actual else "无"
            lines.append(f"| {owner} | {ship_id} | {visual} | {music} |")
    return "\n".join(lines) + "\n"


def upgrade_report(rows, stock, focus):
    def shares_stock(row):
        return row["root"] is not None and row["root"] in row["stock_roots"]

    def upgrade_links(row):
        return "；".join(f"`{predecessor} → {name}`（`{component}`）"
                        for name, predecessor, component in row["components"])

    stock_failed = {row["id"] for row in stock if row["problems"]}
    shared = [row for row in rows if shares_stock(row)]
    different = [row for row in rows if not shares_stock(row)]
    failures = [row for row in rows if row["problems"]]
    different_failures = [row for row in different if row["problems"]]
    new_only = sum(row["id"] not in stock_failed for row in different_failures)
    lines = [
        "",
        "## 升级船体覆盖",
        "",
        f"从初始船体升级沿 `ShipUpgradeInfo` 的 `_Hull` / `prev` 追到 "
        f"{len({(row['id'], name) for row in rows for name, _, _ in row['components']})} 个后续升级，"
        f"涉及 {len({row['id'] for row in rows})} 艘舰。按舰船 ID 和模型根合并后，"
        f"{len(rows) - len(failures)}/{len(rows)} 个升级装配静态覆盖完整。",
        "",
        f"- 复用本舰基础根 {len(shared)} 个，发现缺项 {len(failures) - len(different_failures)} 个。",
        f"- 使用不同根 {len(different)} 个，发现缺项 {len(different_failures)} 个。"
        f"其中 {new_only} 个发生在基础船体覆盖完整的舰船上。",
    ]
    if failures:
        lines += ["", "### 缺项与处理方向", "",
                  "| 舰船（ID） | 升级关系／组件 | 游戏引用的模型根 | 缺失环节 | 处理方向 |",
                  "| --- | --- | --- | --- | --- |"]
        for row in failures:
            if shares_stock(row):
                action = "同根复用，随基础绑定一并排查"
            elif row["reason"] == REASONS[0]:
                action = "核对原生根、舰段和 LOD 后可尝试沿用 42 的绑定方式"
            elif row["reason"] == REASONS[1] or not row["root"]:
                action = "先核对客户端的模型引用与原生资源"
            else:
                action = "单独核对装配并补绑定"
            result = "；".join(row["problems"] + ([row["diagnostic"]] if row["diagnostic"] else []))
            root = row["root"] or "（路径待定）"
            lines.append(f"| {row['name']}（{row['id']}） | {upgrade_links(row)} | `{root}` | "
                         + result.replace("|", r"\|") + f" | {action} |")

    for row in rows:
        if row["id"] not in focus or row["problems"]:
            continue
        stock_paths = "，".join(f"`{root}`" for root in sorted(root for root in row["stock_roots"] if root))
        sequences = "，".join(f"`{path}`" for path in row["sequences"])
        lines += ["", f"### {row['name']}（{row['id']}）", "",
                  f"- 基础船体引用 {stock_paths or '（路径待定）'}。",
                  f"- 升级关系 {upgrade_links(row)} 指向 `{row['root']}`。",
                  f"- `{row['owner']}` 已注册，模型根映射到 `{row['binding']}`。",
                  f"- 根动画 `{row['animation']}` 引用 {sequences}，包含 Root 循环缩放。"
                  "检查涉及的模型、visual 和 parent 引用均可解析。"]

    for title, group in (("复用基础模型根", shared), ("使用其他模型根", different)):
        lines += ["", f"### {title}", ""]
        if not group:
            lines.append("本构建未发现此类升级。")
            continue
        lines += ["| 舰船（ID） | 升级关系／组件 | 模型根 | 状态 |",
                  "| --- | --- | --- | --- |"]
        for row in group:
            state = "有缺项" if row["problems"] else "已覆盖"
            root = row["root"] or "（路径待定）"
            lines.append(f"| {row['name']}（{row['id']}） | {upgrade_links(row)} | `{root}` | {state} |")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group()
    target.add_argument("--package", type=Path, help="Complete player ZIP")
    target.add_argument("--ref", help="Git revision containing the project sources (default: working files)")
    parser.add_argument("--gameparams", type=Path, required=True)
    parser.add_argument("--assets", type=Path, required=True, help="Native assets.bin")
    parser.add_argument("--audit", type=Path, required=True, help="Same-build coverage.json from the fleet audit")
    parser.add_argument("--upgrades", action="store_true", help="Also follow the equippable hull upgrade chains")
    parser.add_argument("--ship-id", type=int, action="append", default=[], help="Also report this ID when covered")
    parser.add_argument("--output", type=Path, help="Write UTF-8 Markdown to this path instead of stdout")
    args = parser.parse_args()

    with release_files(args) as (label, release, entry, archive, read):
        history = json.loads(args.audit.read_text(encoding="utf-8-sig"))
        if history["client_build"] != release["build"]:
            parser.error("The audit and target release have different client builds")
        params, assets = args.gameparams.read_bytes(), args.assets.read_bytes()
        for name, data in (("gameparams", params), ("assets", assets)):
            if sha256(data).hexdigest() != history["inputs_sha256"][name]:
                parser.error(f"{name} does not match the source fingerprint in the audit")
        rows, excluded, count, unknown, upgraded, music_expected = inspect(
            game_params(params), NativeAssets(assets), history, entry, archive, read, args.upgrades,
        )
        focus = set(args.ship_id)
        markdown = report(label, release, rows, excluded, count, unknown, focus)
        markdown += music_report(entry, music_expected, focus)
        if args.upgrades:
            markdown += upgrade_report(upgraded, rows, focus)
    if args.output:
        args.output.write_text(markdown, encoding="utf-8")
    else:
        print(markdown, end="")


if __name__ == "__main__":
    main()
