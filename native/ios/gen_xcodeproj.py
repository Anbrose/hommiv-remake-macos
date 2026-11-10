#!/usr/bin/env python3
"""Write ios/H4Remake.xcodeproj: the iPhone app target over the shared sources.

The app compiles every Sources/h4view/*.swift (the platform code is behind #if os(...)) and
links the package's H4Engine library (the package is native/, referenced locally). Run by
make_ios.sh before each build, so new source files are picked up; the output is not edited by hand.
"""
import hashlib, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCES = os.path.join(HERE, "..", "Sources", "h4view")
PROJ = os.path.join(HERE, "H4Remake.xcodeproj")
BUNDLE_ID = os.environ.get("H4_BUNDLE_ID", "com.anbrose.h4remake")
TEAM = os.environ.get("H4_TEAM_ID", "")

def oid(*parts):
    return hashlib.md5("/".join(parts).encode()).hexdigest()[:24].upper()

swift = sorted(f for f in os.listdir(SOURCES) if f.endswith(".swift"))
P = oid("project"); MAIN = oid("group", "main"); SRC = oid("group", "src"); PRODS = oid("group", "products")
TGT = oid("target"); APP = oid("product", "app"); INFO = oid("file", "Info.plist")
SP = oid("phase", "sources"); FP = oid("phase", "frameworks"); RP = oid("phase", "resources"); SH = oid("phase", "bundledata")
PKG = oid("package"); DEP = oid("dep", "H4Engine"); DEPBF = oid("bf", "H4Engine")
PCL = oid("cl", "project"); TCL = oid("cl", "target")
cfg = {k: (oid("cfg", "project", k), oid("cfg", "target", k)) for k in ("Debug", "Release")}

o = []
w = o.append
w("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 60;\n\tobjects = {\n")
w("\n/* Begin PBXBuildFile section */\n")
for f in swift:
    w(f"\t\t{oid('bf', f)} /* {f} in Sources */ = {{isa = PBXBuildFile; fileRef = {oid('file', f)} /* {f} */; }};\n")
w(f"\t\t{DEPBF} /* H4Engine in Frameworks */ = {{isa = PBXBuildFile; productRef = {DEP} /* H4Engine */; }};\n")
w("/* End PBXBuildFile section */\n\n/* Begin PBXFileReference section */\n")
for f in swift:
    w(f"\t\t{oid('file', f)} /* {f} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = \"{f}\"; path = \"../Sources/h4view/{f}\"; sourceTree = SOURCE_ROOT; }};\n")
w(f"\t\t{INFO} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};\n")
w(f"\t\t{APP} /* H4Remake.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = H4Remake.app; sourceTree = BUILT_PRODUCTS_DIR; }};\n")
w("/* End PBXFileReference section */\n\n/* Begin PBXFrameworksBuildPhase section */\n")
w(f"\t\t{FP} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t\t{DEPBF} /* H4Engine in Frameworks */,\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
w("/* End PBXFrameworksBuildPhase section */\n\n/* Begin PBXGroup section */\n")
w(f"\t\t{MAIN} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{INFO} /* Info.plist */,\n\t\t\t\t{SRC} /* h4view */,\n\t\t\t\t{PRODS} /* Products */,\n\t\t\t);\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
w(f"\t\t{SRC} /* h4view */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n")
for f in swift:
    w(f"\t\t\t\t{oid('file', f)} /* {f} */,\n")
w(f"\t\t\t);\n\t\t\tname = h4view;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
w(f"\t\t{PRODS} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{APP} /* H4Remake.app */,\n\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
w("/* End PBXGroup section */\n\n/* Begin PBXNativeTarget section */\n")
w(f"""\t\t{TGT} /* H4Remake */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {TCL};
\t\t\tbuildPhases = (
\t\t\t\t{SP} /* Sources */,
\t\t\t\t{FP} /* Frameworks */,
\t\t\t\t{RP} /* Resources */,
\t\t\t\t{SH} /* Bundle game data */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = H4Remake;
\t\t\tpackageProductDependencies = (
\t\t\t\t{DEP} /* H4Engine */,
\t\t\t);
\t\t\tproductName = H4Remake;
\t\t\tproductReference = {APP} /* H4Remake.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
\t\t{P} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 1500;
\t\t\t\tLastUpgradeCheck = 1500;
\t\t\t}};
\t\t\tbuildConfigurationList = {PCL};
\t\t\tcompatibilityVersion = "Xcode 14.0";
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {MAIN};
\t\t\tpackageReferences = (
\t\t\t\t{PKG} /* XCLocalSwiftPackageReference ".." */,
\t\t\t);
\t\t\tproductRefGroup = {PRODS} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{TGT} /* H4Remake */,
\t\t\t);
\t\t}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
\t\t{RP} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXShellScriptBuildPhase section */
\t\t{SH} /* Bundle game data */ = {{
\t\t\tisa = PBXShellScriptBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\tname = "Bundle game data";
\t\t\talwaysOutOfDate = 1;
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t\tshellPath = /bin/sh;
\t\t\tshellScript = "if [ \\"$H4_BUNDLE_DATA\\" = 1 ]; then d=\\"$TARGET_BUILD_DIR/$WRAPPER_NAME/GameData\\"; mkdir -p \\"$d\\"; rsync -a --delete \\"$H4DATA/\\" \\"$d/Data/\\"; [ -d \\"$H4MAPS\\" ] && rsync -a --delete \\"$H4MAPS/\\" \\"$d/maps/\\" || true; else rm -rf \\"$TARGET_BUILD_DIR/$WRAPPER_NAME/GameData\\"; fi\\n";
\t\t}};
/* End PBXShellScriptBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
\t\t{SP} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
""")
for f in swift:
    w(f"\t\t\t\t{oid('bf', f)} /* {f} in Sources */,\n")
w("\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n/* End PBXSourcesBuildPhase section */\n\n/* Begin XCBuildConfiguration section */\n")

def settings(d):
    return "".join(f"\t\t\t\t{k} = {v};\n" for k, v in d.items())
for name, (pc, tc) in cfg.items():
    proj = {
        "ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_ENABLE_MODULES": "YES", "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "SDKROOT": "iphoneos", "SWIFT_VERSION": "5.0",
        "ONLY_ACTIVE_ARCH": "YES" if name == "Debug" else "NO",
        "SWIFT_OPTIMIZATION_LEVEL": "\"-Onone\"" if name == "Debug" else "\"-O\"",
        "SWIFT_COMPILATION_MODE": "singlefile" if name == "Debug" else "wholemodule",
        "DEBUG_INFORMATION_FORMAT": "dwarf" if name == "Debug" else "\"dwarf-with-dsym\"",
        "ENABLE_TESTABILITY": "YES" if name == "Debug" else "NO",
        "VALIDATE_PRODUCT": "NO" if name == "Debug" else "YES",
    }
    if name == "Debug":
        proj["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
    tgt = {
        "CODE_SIGN_STYLE": "Automatic", "ENABLE_USER_SCRIPT_SANDBOXING": "NO", "DEVELOPMENT_TEAM": f"\"{TEAM}\"",
        "CURRENT_PROJECT_VERSION": "1", "MARKETING_VERSION": "0.1",
        "GENERATE_INFOPLIST_FILE": "NO", "INFOPLIST_FILE": "Info.plist",
        "LD_RUNPATH_SEARCH_PATHS": "\"$(inherited) @executable_path/Frameworks\"",
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID, "PRODUCT_NAME": "H4Remake",
        "SUPPORTED_PLATFORMS": "\"iphoneos iphonesimulator\"", "SUPPORTS_MACCATALYST": "NO",
        "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO", "TARGETED_DEVICE_FAMILY": "1",
        "SWIFT_EMIT_LOC_STRINGS": "NO",
    }
    w(f"\t\t{pc} /* {name} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{settings(proj)}\t\t\t}};\n\t\t\tname = {name};\n\t\t}};\n")
    w(f"\t\t{tc} /* {name} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{settings(tgt)}\t\t\t}};\n\t\t\tname = {name};\n\t\t}};\n")
w("/* End XCBuildConfiguration section */\n\n/* Begin XCConfigurationList section */\n")
for lst, idx in ((PCL, 0), (TCL, 1)):
    w(f"\t\t{lst} = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{cfg['Debug'][idx]} /* Debug */,\n\t\t\t\t{cfg['Release'][idx]} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n")
w("/* End XCConfigurationList section */\n\n")
w(f"/* Begin XCLocalSwiftPackageReference section */\n\t\t{PKG} /* XCLocalSwiftPackageReference \"..\" */ = {{\n\t\t\tisa = XCLocalSwiftPackageReference;\n\t\t\trelativePath = ..;\n\t\t}};\n/* End XCLocalSwiftPackageReference section */\n\n")
w(f"/* Begin XCSwiftPackageProductDependency section */\n\t\t{DEP} /* H4Engine */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tproductName = H4Engine;\n\t\t}};\n/* End XCSwiftPackageProductDependency section */\n")
w(f"\t}};\n\trootObject = {P} /* Project object */;\n}}\n")

os.makedirs(os.path.join(PROJ, "xcshareddata", "xcschemes"), exist_ok=True)
open(os.path.join(PROJ, "project.pbxproj"), "w").write("".join(o))
ref = f"""<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{TGT}" BuildableName = "H4Remake.app" BlueprintName = "H4Remake" ReferencedContainer = "container:H4Remake.xcodeproj"></BuildableReference>"""
open(os.path.join(PROJ, "xcshareddata", "xcschemes", "H4Remake.xcscheme"), "w").write(f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1500" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "NO" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            {ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <LaunchAction buildConfiguration = "Release" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "NO">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {ref}
      </BuildableProductRunnable>
   </LaunchAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
""")
print(f"wrote {PROJ} ({len(swift)} sources)")
