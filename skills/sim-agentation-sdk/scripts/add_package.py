#!/usr/bin/env python3
"""Add a remote Swift package product to a target in an .xcodeproj.

Does what Xcode's File > Add Package Dependencies does to project.pbxproj:
a package reference on the project, a product dependency on the target, and
the product in the target's Frameworks phase. The file is edited as text, so
the rest of it stays byte for byte as Xcode wrote it; plutil reads it first
to find the objects, and checks the result.

    add_package.py App.xcodeproj --target App
    add_package.py App.xcodeproj --target App --url URL --from 1.2.0 --product Name

Defaults add SimAgentationPlus. Running it again changes nothing.
"""

import argparse
import json
import os
import re
import secrets
import subprocess
import sys

DEFAULT_URL = "https://github.com/lcandy2/sim-agentation"
DEFAULT_FROM = "0.1.1"
DEFAULT_PRODUCT = "SimAgentationPlus"


def load(pbxproj):
    out = subprocess.run(["plutil", "-convert", "json", "-o", "-", pbxproj], capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"plutil could not read {pbxproj}: {out.stderr.strip()}")
    return json.loads(out.stdout)


def new_id(text, taken):
    while True:
        candidate = secrets.token_hex(12).upper()
        if candidate not in text and candidate not in taken:
            taken.add(candidate)
            return candidate


def block(text, object_id):
    """The span of an object's `{ ... }` body in the file."""
    m = re.search(r"^\t\t" + object_id + r"\b[^\n]*= \{\n", text, re.M)
    if not m:
        sys.exit(f"object {object_id} not found in the file")
    end = text.index("\n\t\t};\n", m.end())
    return m.end(), end


def add_to_list(text, object_id, key, entry):
    """Appends `entry` to the object's `key = ( ... );` list, creating it if needed."""
    start, end = block(text, object_id)
    body = text[start:end]
    m = re.search(r"^(\t+)" + key + r" = \(\n(.*?)^\1\);", body, re.M | re.S)
    if m:
        indent = m.group(1) + "\t"
        insert_at = start + m.start(2) + len(m.group(2))
        return text[:insert_at] + f"{indent}{entry},\n" + text[insert_at:]
    # No list yet: add it in key order, as Xcode sorts an object's keys.
    lines = body.split("\n")
    indent = re.match(r"\t*", lines[0]).group(0) if lines and lines[0] else "\t\t\t"
    keys = [re.match(r"\t*([A-Za-z]+) =", line) for line in lines]
    position = len(lines)
    for i, k in enumerate(keys):
        if k and len(k.group(0)) - len(k.group(1)) - 2 == len(indent) and k.group(1) > key:
            position = i
            break
    new = [f"{indent}{key} = (", f"{indent}\t{entry},", f"{indent});"]
    lines[position:position] = new
    return text[:start] + "\n".join(lines) + text[end:]


def add_section_entry(text, isa, entry):
    """Puts an object in its `/* Begin isa section */`, creating the section in order."""
    begin, end_marker = f"/* Begin {isa} section */\n", f"/* End {isa} section */\n"
    if begin in text:
        at = text.index(end_marker)
        return text[:at] + entry + text[at:]
    section = f"\n{begin}{entry}{end_marker}"
    # Sections are sorted by isa; find the first that sorts after this one.
    for m in re.finditer(r"^/\* Begin (\w+) section \*/\n", text, re.M):
        if m.group(1) > isa:
            at = m.start()
            return text[:at] + section.lstrip("\n") + "\n" + text[at:]
    at = text.index("\t};\n\trootObject")
    return text[:at] + section + text[at:]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("project", help="path to the .xcodeproj")
    parser.add_argument("--target", required=True, help="the target that links the product (usually the app)")
    parser.add_argument("--url", default=DEFAULT_URL)
    parser.add_argument("--from", dest="minimum", default=DEFAULT_FROM, help="minimum version, up to the next major")
    parser.add_argument("--product", default=DEFAULT_PRODUCT)
    args = parser.parse_args()

    pbxproj = os.path.join(args.project, "project.pbxproj")
    if not os.path.isfile(pbxproj):
        sys.exit(f"no project.pbxproj in {args.project}")
    data = load(pbxproj)
    objects = data["objects"]
    root_id = data["rootObject"]
    root = objects[root_id]

    targets = {objects[t]["name"]: t for t in root.get("targets", [])}
    if args.target not in targets:
        sys.exit(f"no target {args.target!r}; the project has: {', '.join(sorted(targets))}")
    target_id = targets[args.target]
    target = objects[target_id]

    package_name = args.url.rstrip("/").split("/")[-1].removesuffix(".git")
    url = args.url.rstrip("/")

    # Already there? Reuse the package reference; add only what's missing.
    package_id = next((i for i, o in objects.items() if o.get("isa") == "XCRemoteSwiftPackageReference"
                       and o.get("repositoryURL", "").rstrip("/").removesuffix(".git") == url.removesuffix(".git")), None)
    for dep in target.get("packageProductDependencies", []):
        if objects[dep].get("productName") == args.product:
            print(f"{args.target} already links {args.product}; nothing to do.")
            return

    with open(pbxproj, encoding="utf-8") as f:
        text = f.read()
    taken = set()
    ref_comment = f'XCRemoteSwiftPackageReference "{package_name}"'

    if package_id is None:
        package_id = new_id(text, taken)
        text = add_section_entry(text, "XCRemoteSwiftPackageReference",
            f"\t\t{package_id} /* {ref_comment} */ = {{\n"
            f"\t\t\tisa = XCRemoteSwiftPackageReference;\n"
            f"\t\t\trepositoryURL = \"{url}\";\n"
            f"\t\t\trequirement = {{\n"
            f"\t\t\t\tkind = upToNextMajorVersion;\n"
            f"\t\t\t\tminimumVersion = {args.minimum};\n"
            f"\t\t\t}};\n"
            f"\t\t}};\n")
        text = add_to_list(text, root_id, "packageReferences", f"{package_id} /* {ref_comment} */")

    product_id = new_id(text, taken)
    text = add_section_entry(text, "XCSwiftPackageProductDependency",
        f"\t\t{product_id} /* {args.product} */ = {{\n"
        f"\t\t\tisa = XCSwiftPackageProductDependency;\n"
        f"\t\t\tpackage = {package_id} /* {ref_comment} */;\n"
        f"\t\t\tproductName = {args.product};\n"
        f"\t\t}};\n")
    text = add_to_list(text, target_id, "packageProductDependencies", f"{product_id} /* {args.product} */")

    # Link it: the product in the target's Frameworks phase.
    phases = [p for p in target.get("buildPhases", []) if objects[p].get("isa") == "PBXFrameworksBuildPhase"]
    build_file_id = new_id(text, taken)
    text = add_section_entry(text, "PBXBuildFile",
        f"\t\t{build_file_id} /* {args.product} in Frameworks */ = "
        f"{{isa = PBXBuildFile; productRef = {product_id} /* {args.product} */; }};\n")
    if phases:
        phase_id = phases[0]
    else:
        phase_id = new_id(text, taken)
        text = add_section_entry(text, "PBXFrameworksBuildPhase",
            f"\t\t{phase_id} /* Frameworks */ = {{\n"
            f"\t\t\tisa = PBXFrameworksBuildPhase;\n"
            f"\t\t\tbuildActionMask = 2147483647;\n"
            f"\t\t\tfiles = (\n"
            f"\t\t\t);\n"
            f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
            f"\t\t}};\n")
        text = add_to_list(text, target_id, "buildPhases", f"{phase_id} /* Frameworks */")
    text = add_to_list(text, phase_id, "files", f"{build_file_id} /* {args.product} in Frameworks */")

    with open(pbxproj + ".new", "w", encoding="utf-8") as f:
        f.write(text)
    lint = subprocess.run(["plutil", "-lint", pbxproj + ".new"], capture_output=True, text=True)
    if lint.returncode != 0:
        os.replace(pbxproj + ".new", pbxproj + ".rejected")
        sys.exit(f"the edited file doesn't parse; left it at project.pbxproj.rejected: {lint.stdout.strip()}")
    os.replace(pbxproj + ".new", pbxproj)
    print(f"Added {args.product} ({url}, from {args.minimum}) to {args.target}.")
    print("Next: xcodebuild -resolvePackageDependencies, then build.")


if __name__ == "__main__":
    main()
