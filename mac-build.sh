#!/bin/bash
# Build Code::Blocks 25.03 on macOS and pack a self-contained CodeBlocks.app.
#
# Requires Homebrew wxwidgets@3.2, hunspell and boost headers:
#   brew install wxwidgets@3.2 hunspell boost
#
# Output:
#   mac-install/          configure --prefix (not ~/.local)
#   dist/CodeBlocks.app   drag-and-drop bundle, before signing
#
# Override with PREFIX= and DIST=.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

if [[ -x /opt/homebrew/bin/wx-config-3.2 ]]; then
	BREW="/opt/homebrew"
elif [[ -x /usr/local/bin/wx-config-3.2 ]]; then
	BREW="/usr/local"
else
	echo "wx-config-3.2 not found. Install it with: brew install wxwidgets@3.2" >&2
	exit 1
fi

export PATH="$BREW/bin:$PATH"

if ! pkg-config --exists hunspell; then
	echo "hunspell not found. Install it with: brew install hunspell" >&2
	exit 1
fi

PREFIX="${PREFIX:-$ROOT/mac-install}"
DIST="${DIST:-$ROOT/dist}"
JOBS="$(sysctl -n hw.ncpu)"

echo "Configuring into $PREFIX"
./configure \
	--prefix="$PREFIX" \
	--with-wx-config="$BREW/bin/wx-config-3.2" \
	--with-contrib-plugins=all

echo "Building with $JOBS jobs"
# Nassi-Shneiderman needs Boost headers. configure only detects Boost for wxGTK.
make -j"$JOBS" BOOST_CPPFLAGS="-I$BREW/include"
make install

echo "Packing $DIST/CodeBlocks.app"
rm -rf "$DIST/CodeBlocks.app"
PREFIX="$PREFIX" DEST="$DIST/CodeBlocks.app" BREW="$BREW" python3 - << 'PY'
import os
import shutil
import stat
import subprocess
from pathlib import Path

prefix = Path(os.environ["PREFIX"])
app = Path(os.environ["DEST"])
brew = Path(os.environ["BREW"])
macos = app / "Contents" / "MacOS"
res = app / "Contents" / "Resources"
share = res / "share" / "codeblocks"
plugins = share / "plugins"
macos.mkdir(parents=True)
plugins.mkdir(parents=True)

bundle_src = prefix / "share" / "codeblocks" / "osx_bundle"
if not (bundle_src / "codeblocks.plist").is_file():
    raise SystemExit(f"missing {bundle_src}; make install did not install the macOS bundle files")

shutil.copy(bundle_src / "codeblocks.plist", app / "Contents" / "Info.plist")
for icns in (bundle_src / "icons").glob("*.icns"):
    shutil.copy(icns, res / icns.name)

src_share = prefix / "share" / "codeblocks"
for entry in src_share.iterdir():
    if entry.name == "osx_bundle":
        continue
    dest = share / entry.name
    if entry.is_dir():
        shutil.copytree(entry, dest, symlinks=True)
    else:
        shutil.copy2(entry, dest)

for name in ("codeblocks", "cb_console_runner", "cb_share_config"):
    src = prefix / "bin" / name
    if not src.is_file():
        raise SystemExit(f"missing {src}")
    shutil.copy(src, macos / name)
    os.chmod(macos / name, 0o755)

plugin_dir = prefix / "lib" / "codeblocks" / "plugins"
for plug in plugin_dir.glob("*.dylib"):
    if plug.is_symlink():
        continue
    shutil.copy(plug, plugins / plug.name)
    os.chmod(plugins / plug.name, 0o755)

# dest path -> original file the bytes were copied from
origin_of = {}
real_to_base = {}
queue = []

MH_EXECUTE = 2
MH_DYLIB = 6
MH_BUNDLE = 8


def macho_type(path: Path):
    out = subprocess.check_output(["otool", "-h", str(path)], text=True, errors="replace")
    for line in out.splitlines():
        parts = line.split()
        if parts and parts[0].startswith("0x"):
            return int(parts[4])
    return None


def listed_deps(path: Path):
    out = subprocess.check_output(["otool", "-L", str(path)], text=True, errors="replace")
    deps = []
    for i, line in enumerate(out.splitlines()):
        if i == 0:
            continue
        line = line.strip()
        if not line:
            continue
        if " (compatibility version" in line:
            deps.append(line.split(" (compatibility version", 1)[0])
        else:
            deps.append(line.split()[0])
    return deps


def rpaths(path: Path):
    out = subprocess.check_output(["otool", "-l", str(path)], text=True, errors="replace")
    found = []
    lines = out.splitlines()
    for i, line in enumerate(lines):
        if line.strip() != "cmd LC_RPATH":
            continue
        for nxt in lines[i + 1:i + 4]:
            nxt = nxt.strip()
            if nxt.startswith("path "):
                found.append(nxt.split(" ", 1)[1].rsplit(" (", 1)[0])
    return found


def expand_rpath_token(token: str, origin: Path) -> str:
    return (
        token.replace("@loader_path", str(origin.parent))
        .replace("@executable_path", str(origin.parent))
    )


def resolve_dep(dep: str, origin: Path):
    if dep.startswith("@rpath/"):
        name = dep[len("@rpath/"):]
        for raw in rpaths(origin):
            candidate = Path(expand_rpath_token(raw, origin)) / name
            if candidate.exists():
                return str(candidate)
        for base in (brew / "lib", Path("/usr/local/lib")):
            candidate = base / name
            if candidate.exists():
                return str(candidate)
        return None
    if dep.startswith("@loader_path/"):
        candidate = origin.parent / dep[len("@loader_path/"):]
        return str(candidate) if candidate.exists() else None
    if dep.startswith("/"):
        return dep if os.path.exists(dep) else None
    return None


def is_system(path: str) -> bool:
    return path.startswith("/usr/lib/") or path.startswith("/System/")


def ensure_copied(source: str) -> str:
    real = os.path.realpath(source)
    if real in real_to_base:
        return real_to_base[real]
    base = os.path.basename(source)
    dest = macos / base
    n = 0
    while dest.exists() and os.path.realpath(dest) != real:
        n += 1
        stem = Path(base).stem
        suffix = Path(base).suffix
        base = f"{stem}-{n}{suffix}"
        dest = macos / base
    if not dest.exists():
        shutil.copy(real, dest)
        os.chmod(dest, 0o755)
        subprocess.run(["codesign", "--remove-signature", str(dest)], check=False, capture_output=True)
        subprocess.check_call(["install_name_tool", "-id", f"@executable_path/{base}", str(dest)])
        origin_of[dest] = Path(real)
        queue.append(dest)
    real_to_base[real] = base
    return base


def rewrite(path: Path, origin: Path):
    subprocess.run(["codesign", "--remove-signature", str(path)], check=False, capture_output=True)
    os.chmod(path, os.stat(path).st_mode | stat.S_IWUSR)
    deps = listed_deps(path)
    kind = macho_type(path)
    start = 1 if kind in (MH_DYLIB, MH_BUNDLE) else 0
    under_plugins = False
    try:
        path.relative_to(plugins)
        under_plugins = True
    except ValueError:
        under_plugins = False
    if kind in (MH_DYLIB, MH_BUNDLE) and under_plugins:
        subprocess.check_call(["install_name_tool", "-id", f"@loader_path/{path.name}", str(path)])
    for dep in deps[start:]:
        if dep.startswith("@executable_path/") or dep.startswith("@loader_path/"):
            continue
        if dep.startswith("/") and is_system(dep):
            continue
        source = resolve_dep(dep, origin)
        if source is None:
            if dep.startswith("/") or dep.startswith("@"):
                print(f"warning: unresolved {dep} from {path.name}")
            continue
        if is_system(os.path.realpath(source)):
            continue
        base = ensure_copied(source)
        subprocess.check_call(
            ["install_name_tool", "-change", dep, f"@executable_path/{base}", str(path)]
        )


roots = [macos / name for name in ("codeblocks", "cb_console_runner", "cb_share_config")]
roots += list(plugins.glob("*.dylib"))
for path in roots:
    rewrite(path, path)

while queue:
    path = queue.pop(0)
    rewrite(path, origin_of.get(path, path))

bad = []
for folder in (macos, plugins):
    for path in folder.iterdir():
        if not path.is_file():
            continue
        try:
            deps = listed_deps(path)
            kind = macho_type(path)
        except subprocess.CalledProcessError:
            continue
        start = 1 if kind in (MH_DYLIB, MH_BUNDLE) else 0
        for dep in deps[start:]:
            if dep.startswith("/opt/") or dep.startswith("/Users/") or dep.startswith("/usr/local/") or dep.startswith("@rpath/"):
                bad.append(f"{path.relative_to(app)}: {dep}")

print(f"libraries in MacOS: {len(list(macos.glob('*.dylib')))}")
print(f"plugins: {len(list(plugins.glob('*.dylib')))}")
if bad:
    print("unbundled dependencies:")
    print("\n".join(bad))
    raise SystemExit(1)
PY

echo "Built $DIST/CodeBlocks.app"
echo "Sign and publish it with ./mac-release.sh"
