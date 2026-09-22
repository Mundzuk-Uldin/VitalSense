#!/usr/bin/env python3
"""Generate VitalSense.xcodeproj.

A .pbxproj is a graph of objects keyed by 24-hex-digit identifiers, and it is
miserable to maintain by hand. Generating it means the project can be rebuilt
from the sources on disk -- add a .swift file to a target folder, re-run this,
and it is in the build.

    python3 tools/generate_xcodeproj.py
"""

from __future__ import annotations

import hashlib
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT_NAME = "VitalSense"
IOS_TARGET = "VitalSense"
WATCH_TARGET = "VitalSense Watch App"

IOS_DIR = "VitalSense"
WATCH_DIR = "VitalSenseWatch"
SHARED_DIR = "Shared"

IOS_BUNDLE_ID = "com.bayhacks.VitalSense"
WATCH_BUNDLE_ID = f"{IOS_BUNDLE_ID}.watchkitapp"

IOS_DEPLOYMENT = "18.0"
WATCH_DEPLOYMENT = "11.0"


def uid(*parts: str) -> str:
    """Stable identifier, so regenerating does not churn the whole file."""
    return hashlib.sha1("::".join(parts).encode()).hexdigest()[:24].upper()


def swift_files(folder: str) -> list[str]:
    return sorted(p.name for p in (ROOT / folder).glob("*.swift"))


class Project:
    def __init__(self) -> None:
        self.objects: list[str] = []

    def add(self, identifier: str, isa: str, body: str, comment: str = "") -> str:
        label = f" /* {comment} */" if comment else ""
        self.objects.append(f"\t\t{identifier}{label} = {{\n\t\t\tisa = {isa};\n{body}\t\t}};")
        return identifier


def build_settings(pairs: dict[str, str], indent: str = "\t\t\t\t") -> str:
    lines = []
    for key in sorted(pairs):
        value = pairs[key]
        lines.append(f"{indent}{key} = {value};")
    return "\n".join(lines)


def quote(value: str) -> str:
    """pbxproj only needs quotes around values that are not bare words."""
    if value and all(c.isalnum() or c in "_./$()" for c in value):
        return value
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def generate() -> str:
    p = Project()

    ios_sources = [(IOS_DIR, f) for f in swift_files(IOS_DIR)]
    watch_sources = [(WATCH_DIR, f) for f in swift_files(WATCH_DIR)]
    shared_sources = [(SHARED_DIR, f) for f in swift_files(SHARED_DIR)]

    if not ios_sources or not watch_sources or not shared_sources:
        raise SystemExit("Expected .swift files in all three source folders.")

    # ---- file references -------------------------------------------------
    file_refs: dict[tuple[str, str], str] = {}
    for folder, name in ios_sources + watch_sources + shared_sources:
        ref = uid("ref", folder, name)
        file_refs[(folder, name)] = ref
        p.add(
            ref,
            "PBXFileReference",
            f"\t\t\tlastKnownFileType = sourcecode.swift;\n"
            f"\t\t\tpath = {quote(name)};\n"
            f"\t\t\tsourceTree = \"<group>\";\n",
            name,
        )

    for folder in (IOS_DIR, WATCH_DIR):
        ref = uid("ref", folder, "Info.plist")
        file_refs[(folder, "Info.plist")] = ref
        p.add(
            ref,
            "PBXFileReference",
            "\t\t\tlastKnownFileType = text.plist.xml;\n"
            "\t\t\tpath = Info.plist;\n"
            "\t\t\tsourceTree = \"<group>\";\n",
            "Info.plist",
        )
        asset_ref = uid("ref", folder, "Assets.xcassets")
        file_refs[(folder, "Assets.xcassets")] = asset_ref
        p.add(
            asset_ref,
            "PBXFileReference",
            "\t\t\tlastKnownFileType = folder.assetcatalog;\n"
            "\t\t\tpath = Assets.xcassets;\n"
            "\t\t\tsourceTree = \"<group>\";\n",
            "Assets.xcassets",
        )

    ios_product = uid("product", IOS_TARGET)
    p.add(
        ios_product,
        "PBXFileReference",
        "\t\t\texplicitFileType = wrapper.application;\n"
        "\t\t\tincludeInIndex = 0;\n"
        f"\t\t\tpath = {quote(IOS_TARGET + '.app')};\n"
        "\t\t\tsourceTree = BUILT_PRODUCTS_DIR;\n",
        f"{IOS_TARGET}.app",
    )
    watch_product = uid("product", WATCH_TARGET)
    p.add(
        watch_product,
        "PBXFileReference",
        "\t\t\texplicitFileType = wrapper.application;\n"
        "\t\t\tincludeInIndex = 0;\n"
        f"\t\t\tpath = {quote(WATCH_TARGET + '.app')};\n"
        "\t\t\tsourceTree = BUILT_PRODUCTS_DIR;\n",
        f"{WATCH_TARGET}.app",
    )

    # ---- build files -----------------------------------------------------
    def build_file(target: str, folder: str, name: str) -> str:
        identifier = uid("build", target, folder, name)
        ref = file_refs[(folder, name)]
        p.add(
            identifier,
            "PBXBuildFile",
            f"\t\t\tfileRef = {ref} /* {name} */;\n",
            f"{name} in {target}",
        )
        return identifier

    # Shared files are compiled into BOTH targets. That is the whole point of
    # the folder: one definition of the reading and the API client, two apps.
    ios_compile = [build_file(IOS_TARGET, f, n) for f, n in ios_sources + shared_sources]
    watch_compile = [build_file(WATCH_TARGET, f, n) for f, n in watch_sources + shared_sources]
    ios_resources = [build_file(IOS_TARGET, IOS_DIR, "Assets.xcassets")]
    watch_resources = [build_file(WATCH_TARGET, WATCH_DIR, "Assets.xcassets")]

    embed_watch = uid("embed", WATCH_TARGET)
    p.add(
        embed_watch,
        "PBXBuildFile",
        f"\t\t\tfileRef = {watch_product} /* {WATCH_TARGET}.app */;\n"
        "\t\t\tsettings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); };\n",
        f"{WATCH_TARGET}.app in Embed Watch Content",
    )

    # ---- groups ----------------------------------------------------------
    def group(identifier: str, children: list[str], name: str | None, path: str | None) -> str:
        body = "\t\t\tchildren = (\n"
        for child in children:
            body += f"\t\t\t\t{child},\n"
        body += "\t\t\t);\n"
        if path:
            body += f"\t\t\tpath = {quote(path)};\n"
        elif name:
            body += f"\t\t\tname = {quote(name)};\n"
        body += "\t\t\tsourceTree = \"<group>\";\n"
        return p.add(identifier, "PBXGroup", body, name or path or "")

    shared_group = group(
        uid("group", SHARED_DIR),
        [file_refs[(SHARED_DIR, n)] for _, n in shared_sources],
        None,
        SHARED_DIR,
    )
    ios_group = group(
        uid("group", IOS_DIR),
        [file_refs[(IOS_DIR, n)] for _, n in ios_sources]
        + [file_refs[(IOS_DIR, "Assets.xcassets")], file_refs[(IOS_DIR, "Info.plist")]],
        None,
        IOS_DIR,
    )
    watch_group = group(
        uid("group", WATCH_DIR),
        [file_refs[(WATCH_DIR, n)] for _, n in watch_sources]
        + [file_refs[(WATCH_DIR, "Assets.xcassets")], file_refs[(WATCH_DIR, "Info.plist")]],
        None,
        WATCH_DIR,
    )
    products_group = group(uid("group", "Products"), [ios_product, watch_product], "Products", None)
    root_group = group(
        uid("group", "root"),
        [shared_group, ios_group, watch_group, products_group],
        None,
        None,
    )

    # ---- build phases ----------------------------------------------------
    def phase(identifier: str, isa: str, files: list[str], extra: str = "") -> str:
        body = "\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n"
        for f in files:
            body += f"\t\t\t\t{f},\n"
        body += "\t\t\t);\n" + extra + "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        return p.add(identifier, isa, body, isa)

    ios_sources_phase = phase(uid("phase", IOS_TARGET, "sources"), "PBXSourcesBuildPhase", ios_compile)
    ios_frameworks_phase = phase(uid("phase", IOS_TARGET, "frameworks"), "PBXFrameworksBuildPhase", [])
    ios_resources_phase = phase(uid("phase", IOS_TARGET, "resources"), "PBXResourcesBuildPhase", ios_resources)
    ios_embed_phase = phase(
        uid("phase", IOS_TARGET, "embed"),
        "PBXCopyFilesBuildPhase",
        [embed_watch],
        "\t\t\tdstPath = \"$(CONTENTS_FOLDER_PATH)/Watch\";\n"
        "\t\t\tdstSubfolderSpec = 16;\n"
        "\t\t\tname = \"Embed Watch Content\";\n",
    )
    watch_sources_phase = phase(uid("phase", WATCH_TARGET, "sources"), "PBXSourcesBuildPhase", watch_compile)
    watch_frameworks_phase = phase(uid("phase", WATCH_TARGET, "frameworks"), "PBXFrameworksBuildPhase", [])
    watch_resources_phase = phase(uid("phase", WATCH_TARGET, "resources"), "PBXResourcesBuildPhase", watch_resources)

    # ---- build configurations -------------------------------------------
    shared_project_settings = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
        "CLANG_ANALYZER_NONNULL": "YES",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
        "CLANG_WARN_UNREACHABLE_CODE": "YES",
        "COPY_PHASE_STRIP": "NO",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        # Swift 5 language mode. Swift 6's strict concurrency checking has
        # opinions about HealthKit and WatchConnectivity delegates that would
        # be a project of their own.
        "SWIFT_VERSION": "5.0",
    }
    debug_project = dict(
        shared_project_settings,
        **{
            "DEBUG_INFORMATION_FORMAT": "dwarf",
            "ENABLE_TESTABILITY": "YES",
            "GCC_OPTIMIZATION_LEVEL": "0",
            "GCC_PREPROCESSOR_DEFINITIONS": '("DEBUG=1","$(inherited)")',
            "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
            "ONLY_ACTIVE_ARCH": "YES",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": '"DEBUG $(inherited)"',
            "SWIFT_OPTIMIZATION_LEVEL": "\"-Onone\"",
        },
    )
    release_project = dict(
        shared_project_settings,
        **{
            "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
            "ENABLE_NS_ASSERTIONS": "NO",
            "MTL_ENABLE_DEBUG_INFO": "NO",
            "SWIFT_COMPILATION_MODE": "wholemodule",
        },
    )

    common_target = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "DEVELOPMENT_TEAM": '""',
        "ENABLE_PREVIEWS": "YES",
        "GENERATE_INFOPLIST_FILE": "YES",
        "MARKETING_VERSION": "1.0",
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "SWIFT_EMIT_LOC_STRINGS": "YES",
    }
    ios_target_settings = dict(
        common_target,
        **{
            "INFOPLIST_FILE": f"{IOS_DIR}/Info.plist",
            "IPHONEOS_DEPLOYMENT_TARGET": IOS_DEPLOYMENT,
            "LD_RUNPATH_SEARCH_PATHS": '("$(inherited)","@executable_path/Frameworks")',
            "PRODUCT_BUNDLE_IDENTIFIER": IOS_BUNDLE_ID,
            "SDKROOT": "iphoneos",
            "SUPPORTED_PLATFORMS": '"iphoneos iphonesimulator"',
            "SWIFT_EMIT_LOC_STRINGS": "YES",
            "TARGETED_DEVICE_FAMILY": '"1"',
        },
    )
    watch_target_settings = dict(
        common_target,
        **{
            "INFOPLIST_FILE": f"{WATCH_DIR}/Info.plist",
            "INFOPLIST_KEY_CFBundleDisplayName": "VitalSense",
            "LD_RUNPATH_SEARCH_PATHS": '("$(inherited)","@executable_path/Frameworks")',
            "PRODUCT_BUNDLE_IDENTIFIER": WATCH_BUNDLE_ID,
            "SDKROOT": "watchos",
            "SKIP_INSTALL": "YES",
            "SUPPORTED_PLATFORMS": '"watchos watchsimulator"',
            "TARGETED_DEVICE_FAMILY": '"4"',
            "WATCHOS_DEPLOYMENT_TARGET": WATCH_DEPLOYMENT,
        },
    )

    def config(owner: str, name: str, settings: dict[str, str]) -> str:
        identifier = uid("config", owner, name)
        body = (
            "\t\t\tbuildSettings = {\n"
            + build_settings(settings)
            + f"\n\t\t\t}};\n\t\t\tname = {name};\n"
        )
        return p.add(identifier, "XCBuildConfiguration", body, name)

    def config_list(owner: str, debug: str, release: str) -> str:
        identifier = uid("configlist", owner)
        body = (
            "\t\t\tbuildConfigurations = (\n"
            f"\t\t\t\t{debug} /* Debug */,\n"
            f"\t\t\t\t{release} /* Release */,\n"
            "\t\t\t);\n"
            "\t\t\tdefaultConfigurationIsVisible = 0;\n"
            "\t\t\tdefaultConfigurationName = Release;\n"
        )
        return p.add(identifier, "XCConfigurationList", body, owner)

    project_list = config_list(
        "project",
        config("project", "Debug", debug_project),
        config("project", "Release", release_project),
    )
    ios_list = config_list(
        IOS_TARGET,
        config(IOS_TARGET, "Debug", ios_target_settings),
        config(IOS_TARGET, "Release", ios_target_settings),
    )
    watch_list = config_list(
        WATCH_TARGET,
        config(WATCH_TARGET, "Debug", watch_target_settings),
        config(WATCH_TARGET, "Release", watch_target_settings),
    )

    # ---- targets ---------------------------------------------------------
    watch_target_id = uid("target", WATCH_TARGET)
    p.add(
        watch_target_id,
        "PBXNativeTarget",
        f"\t\t\tbuildConfigurationList = {watch_list};\n"
        "\t\t\tbuildPhases = (\n"
        f"\t\t\t\t{watch_sources_phase},\n"
        f"\t\t\t\t{watch_frameworks_phase},\n"
        f"\t\t\t\t{watch_resources_phase},\n"
        "\t\t\t);\n"
        "\t\t\tbuildRules = (\n\t\t\t);\n"
        "\t\t\tdependencies = (\n\t\t\t);\n"
        f"\t\t\tname = {quote(WATCH_TARGET)};\n"
        f"\t\t\tproductName = {quote(WATCH_TARGET)};\n"
        f"\t\t\tproductReference = {watch_product};\n"
        "\t\t\tproductType = \"com.apple.product-type.application\";\n",
        WATCH_TARGET,
    )

    # The iOS app must not finish linking before the watch app exists to be
    # copied into it.
    dependency_proxy = uid("proxy", WATCH_TARGET)
    project_id = uid("project", PROJECT_NAME)
    p.add(
        dependency_proxy,
        "PBXContainerItemProxy",
        f"\t\t\tcontainerPortal = {project_id};\n"
        "\t\t\tproxyType = 1;\n"
        f"\t\t\tremoteGlobalIDString = {watch_target_id};\n"
        f"\t\t\tremoteInfo = {quote(WATCH_TARGET)};\n",
        "PBXContainerItemProxy",
    )
    dependency = uid("dependency", WATCH_TARGET)
    p.add(
        dependency,
        "PBXTargetDependency",
        f"\t\t\ttarget = {watch_target_id};\n"
        f"\t\t\ttargetProxy = {dependency_proxy};\n",
        "PBXTargetDependency",
    )

    ios_target_id = uid("target", IOS_TARGET)
    p.add(
        ios_target_id,
        "PBXNativeTarget",
        f"\t\t\tbuildConfigurationList = {ios_list};\n"
        "\t\t\tbuildPhases = (\n"
        f"\t\t\t\t{ios_sources_phase},\n"
        f"\t\t\t\t{ios_frameworks_phase},\n"
        f"\t\t\t\t{ios_resources_phase},\n"
        f"\t\t\t\t{ios_embed_phase},\n"
        "\t\t\t);\n"
        "\t\t\tbuildRules = (\n\t\t\t);\n"
        f"\t\t\tdependencies = (\n\t\t\t\t{dependency},\n\t\t\t);\n"
        f"\t\t\tname = {quote(IOS_TARGET)};\n"
        f"\t\t\tproductName = {quote(IOS_TARGET)};\n"
        f"\t\t\tproductReference = {ios_product};\n"
        "\t\t\tproductType = \"com.apple.product-type.application\";\n",
        IOS_TARGET,
    )

    p.add(
        project_id,
        "PBXProject",
        "\t\t\tattributes = {\n"
        "\t\t\t\tBuildIndependentTargetsInParallel = 1;\n"
        "\t\t\t\tLastSwiftUpdateCheck = 2700;\n"
        "\t\t\t\tLastUpgradeCheck = 2700;\n"
        "\t\t\t\tTargetAttributes = {\n"
        f"\t\t\t\t\t{ios_target_id} = {{CreatedOnToolsVersion = 27.0;}};\n"
        f"\t\t\t\t\t{watch_target_id} = {{CreatedOnToolsVersion = 27.0;}};\n"
        "\t\t\t\t};\n"
        "\t\t\t};\n"
        f"\t\t\tbuildConfigurationList = {project_list};\n"
        "\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n"
        "\t\t\tdevelopmentRegion = en;\n"
        "\t\t\thasScannedForEncodings = 0;\n"
        "\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n"
        f"\t\t\tmainGroup = {root_group};\n"
        "\t\t\tminimizedProjectReferenceProxies = 1;\n"
        f"\t\t\tproductRefGroup = {products_group};\n"
        "\t\t\tprojectDirPath = \"\";\n"
        "\t\t\tprojectRoot = \"\";\n"
        "\t\t\ttargets = (\n"
        f"\t\t\t\t{ios_target_id},\n"
        f"\t\t\t\t{watch_target_id},\n"
        "\t\t\t);\n",
        "Project object",
    )

    body = "\n".join(sorted(p.objects))
    return (
        "// !$*UTF8*$!\n"
        "{\n"
        "\tarchiveVersion = 1;\n"
        "\tclasses = {\n\t};\n"
        "\tobjectVersion = 56;\n"
        "\tobjects = {\n"
        f"{body}\n"
        "\t};\n"
        f"\trootObject = {project_id} /* Project object */;\n"
        "}\n"
    )


def scheme(name: str, target_id: str, blueprint: str) -> str:
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2700" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target_id}"
               BuildableName = "{blueprint}.app"
               BlueprintName = "{blueprint}"
               ReferencedContainer = "container:{PROJECT_NAME}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}"
            BuildableName = "{blueprint}.app"
            BlueprintName = "{blueprint}"
            ReferencedContainer = "container:{PROJECT_NAME}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}"
            BuildableName = "{blueprint}.app"
            BlueprintName = "{blueprint}"
            ReferencedContainer = "container:{PROJECT_NAME}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""


def write_asset_catalogs() -> None:
    """Minimal catalogs so the asset compiler has an AppIcon and an
    AccentColor to find rather than warning about their absence."""
    for folder, platform in ((IOS_DIR, "ios"), (WATCH_DIR, "watchos")):
        catalog = ROOT / folder / "Assets.xcassets"
        (catalog / "AppIcon.appiconset").mkdir(parents=True, exist_ok=True)
        (catalog / "AccentColor.colorset").mkdir(parents=True, exist_ok=True)

        (catalog / "Contents.json").write_text(
            '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n'
        )
        icon_platform = "watchos" if platform == "watchos" else "ios"
        (catalog / "AppIcon.appiconset" / "Contents.json").write_text(
            '{\n  "images" : [\n    {\n'
            f'      "idiom" : "universal",\n      "platform" : "{icon_platform}",\n'
            '      "size" : "1024x1024"\n    }\n  ],\n'
            '  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n'
        )
        # A teal accent: distinct from every one of the four reserved risk
        # colours, so a button chrome can never be mistaken for a verdict.
        (catalog / "AccentColor.colorset" / "Contents.json").write_text(
            '{\n  "colors" : [\n    {\n      "color" : {\n'
            '        "color-space" : "srgb",\n        "components" : {\n'
            '          "alpha" : "1.000",\n          "blue" : "0.612",\n'
            '          "green" : "0.541",\n          "red" : "0.114"\n'
            '        }\n      },\n      "idiom" : "universal"\n    }\n  ],\n'
            '  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n'
        )


def main() -> None:
    write_asset_catalogs()

    xcodeproj = ROOT / f"{PROJECT_NAME}.xcodeproj"
    if xcodeproj.exists():
        shutil.rmtree(xcodeproj)
    xcodeproj.mkdir(parents=True)
    (xcodeproj / "project.pbxproj").write_text(generate())

    schemes = xcodeproj / "xcshareddata" / "xcschemes"
    schemes.mkdir(parents=True)
    (schemes / f"{IOS_TARGET}.xcscheme").write_text(
        scheme(IOS_TARGET, uid("target", IOS_TARGET), IOS_TARGET)
    )
    (schemes / f"{WATCH_TARGET}.xcscheme").write_text(
        scheme(WATCH_TARGET, uid("target", WATCH_TARGET), WATCH_TARGET)
    )

    workspace = xcodeproj / "project.xcworkspace"
    workspace.mkdir()
    (workspace / "contents.xcworkspacedata").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<Workspace version = "1.0">\n'
        '   <FileRef location = "self:">\n'
        "   </FileRef>\n"
        "</Workspace>\n"
    )

    print(f"Wrote {xcodeproj}")
    print(f"  {IOS_TARGET}: {len(swift_files(IOS_DIR))} + {len(swift_files(SHARED_DIR))} shared files")
    print(f"  {WATCH_TARGET}: {len(swift_files(WATCH_DIR))} + {len(swift_files(SHARED_DIR))} shared files")


if __name__ == "__main__":
    main()
