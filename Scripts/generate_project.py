#!/usr/bin/env python3
"""Deterministic Xcode project generation, no XcodeGen or external dependencies."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
objects = {}


def oid(label):
    return hashlib.sha1(label.encode()).hexdigest()[:24].upper()


def add(label, isa, **values):
    identifier = oid(label)
    objects[identifier] = {"isa": isa, **values}
    return identifier


def file(path, kind, name=None):
    return add("file:" + path, "PBXFileReference", lastKnownFileType=kind,
               path=path, sourceTree="SOURCE_ROOT", **({"name": name} if name else {}))


def build(ref, target):
    return add("build:" + target + ref, "PBXBuildFile", fileRef=ref)


def configurations(label, settings):
    refs = []
    for mode in ["Debug", "Release"]:
        values = dict(settings)
        values.update({"SWIFT_OPTIMIZATION_LEVEL": "-Onone" if mode == "Debug" else "-O",
                       "DEBUG_INFORMATION_FORMAT": "dwarf" if mode == "Debug" else "dwarf-with-dsym"})
        if mode == "Debug":
            values.update({"ENABLE_TESTABILITY": "YES", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG", "ONLY_ACTIVE_ARCH": "YES"})
        refs.append(add(label + mode, "XCBuildConfiguration", name=mode, buildSettings=values))
    return add(label + "configs", "XCConfigurationList", buildConfigurations=refs,
               defaultConfigurationIsVisible=0, defaultConfigurationName="Release")


app_sources = [file(str(p.relative_to(ROOT)), "sourcecode.swift") for p in sorted((ROOT / "PDFEditor").rglob("*.swift"))]
test_sources = [file(str(p.relative_to(ROOT)), "sourcecode.swift") for p in sorted((ROOT / "Tests/PDFEditorAppTests").glob("*.swift"))]
localizations = [file("PDFEditor/Resources/" + locale + ".lproj/Localizable.strings", "text.plist.strings", locale) for locale in ["en", "ru"]]
strings = add("localized-strings", "PBXVariantGroup", name="Localizable.strings", children=localizations, sourceTree="<group>")
info_locales = [file("PDFEditor/Resources/" + locale + ".lproj/InfoPlist.strings", "text.plist.strings", locale) for locale in ["en", "ru"]]
info_strings = add("localized-info", "PBXVariantGroup", name="InfoPlist.strings", children=info_locales, sourceTree="<group>")
info = file("Configuration/Info.plist", "text.plist.xml")
privacy = file("PDFEditor/Resources/PrivacyInfo.xcprivacy", "text.plist.xml")
assets = file("PDFEditor/Resources/Assets.xcassets", "folder.assetcatalog")
app_product = add("app-product", "PBXFileReference", explicitFileType="wrapper.application", path="PDFEditor.app", sourceTree="BUILT_PRODUCTS_DIR")
test_product = add("test-product", "PBXFileReference", explicitFileType="wrapper.cfbundle", path="PDFEditorTests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
groups = [add("app-group", "PBXGroup", name="Application", children=app_sources, sourceTree="<group>"),
          add("resources-group", "PBXGroup", name="Resources", children=[strings, info_strings, assets, privacy, info], sourceTree="<group>"),
          add("tests-group", "PBXGroup", name="Tests", children=test_sources, sourceTree="<group>"),
          add("products-group", "PBXGroup", name="Products", children=[app_product, test_product], sourceTree="<group>")]
root_group = add("root-group", "PBXGroup", children=groups, sourceTree="<group>")
package_ref = add("core-package", "XCLocalSwiftPackageReference", relativePath=".")
app_core = add("app-core-product", "XCSwiftPackageProductDependency", package=package_ref, productName="PDFEditorCore")
test_core = add("test-core-product", "XCSwiftPackageProductDependency", package=package_ref, productName="PDFEditorCore")
app_core_build = add("app-core-build", "PBXBuildFile", productRef=app_core)
test_core_build = add("test-core-build", "PBXBuildFile", productRef=test_core)


def phase(label, kind, refs):
    return add(label, kind, buildActionMask=2147483647, files=refs, runOnlyForDeploymentPostprocessing=0)


common = {"IPHONEOS_DEPLOYMENT_TARGET": "17.0", "SDKROOT": "iphoneos", "SWIFT_VERSION": "5.0",
          "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES", "SWIFT_STRICT_CONCURRENCY": "minimal"}
app_settings = {"PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": "com.sultonovmuzafar.pdfeditor",
                "INFOPLIST_FILE": "Configuration/Info.plist", "CODE_SIGN_STYLE": "Automatic",
                "TARGETED_DEVICE_FAMILY": "1,2", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
                "SWIFT_EMIT_LOC_STRINGS": "YES", "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks", "SUPPORTS_MACCATALYST": "NO"}
app_target = add("app-target", "PBXNativeTarget", name="PDFEditor", productName="PDFEditor", productReference=app_product,
                 productType="com.apple.product-type.application", buildConfigurationList=configurations("app", app_settings),
                 buildPhases=[phase("app-sources", "PBXSourcesBuildPhase", [build(ref, "app") for ref in app_sources]),
                              phase("app-frameworks", "PBXFrameworksBuildPhase", [app_core_build]),
                              phase("app-resources", "PBXResourcesBuildPhase", [build(ref, "app") for ref in [strings, info_strings, assets, privacy]])],
                 buildRules=[], dependencies=[], packageProductDependencies=[app_core])
proxy = add("app-proxy", "PBXContainerItemProxy", containerPortal=oid("project"), proxyType=1, remoteGlobalIDString=app_target, remoteInfo="PDFEditor")
dependency = add("test-dependency", "PBXTargetDependency", target=app_target, targetProxy=proxy)
test_settings = {"PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": "com.sultonovmuzafar.pdfeditor.tests",
                 "GENERATE_INFOPLIST_FILE": "YES", "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/PDFEditor.app/PDFEditor",
                 "BUNDLE_LOADER": "$(TEST_HOST)", "CODE_SIGN_STYLE": "Automatic", "TARGETED_DEVICE_FAMILY": "1,2",
                 "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @loader_path/Frameworks"}
test_target = add("test-target", "PBXNativeTarget", name="PDFEditorTests", productName="PDFEditorTests", productReference=test_product,
                  productType="com.apple.product-type.bundle.unit-test", buildConfigurationList=configurations("tests", test_settings),
                  buildPhases=[phase("test-sources", "PBXSourcesBuildPhase", [build(ref, "test") for ref in test_sources]),
                               phase("test-frameworks", "PBXFrameworksBuildPhase", [test_core_build])],
                  buildRules=[], dependencies=[dependency], packageProductDependencies=[test_core])
project = add("project", "PBXProject", attributes={"LastUpgradeCheck": "1600", "TargetAttributes": {test_target: {"TestTargetID": app_target}}},
              buildConfigurationList=configurations("project", common), compatibilityVersion="Xcode 14.0", developmentRegion="en",
              hasScannedForEncodings=0, knownRegions=["en", "ru", "Base"], mainGroup=root_group, productRefGroup=groups[-1],
              projectDirPath="", projectRoot="", targets=[app_target, test_target], packageReferences=[package_ref])


def encode(value, level=0):
    tab = "\t" * level
    if isinstance(value, dict):
        return "{\n" + "".join("\t" * (level + 1) + json.dumps(k) + " = " + encode(v, level + 1) + ";\n" for k, v in value.items()) + tab + "}"
    if isinstance(value, list):
        return "(\n" + "".join("\t" * (level + 1) + encode(v, level + 1) + ",\n" for v in value) + tab + ")"
    return json.dumps(value, ensure_ascii=False)


directory = ROOT / "PDFEditor.xcodeproj"
directory.mkdir(exist_ok=True)
(directory / "project.pbxproj").write_text("// !$*UTF8*$!\n" + encode({"archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": objects, "rootObject": project}) + "\n")
schemes = directory / "xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
(schemes / "PDFEditor.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
      <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="PDFEditor.app" BlueprintName="PDFEditor" ReferencedContainer="container:PDFEditor.xcodeproj"/>
    </BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
    <Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_target}" BuildableName="PDFEditorTests.xctest" BlueprintName="PDFEditorTests" ReferencedContainer="container:PDFEditor.xcodeproj"/></TestableReference></Testables>
  </TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugServiceExtension="internal" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="PDFEditor.app" BlueprintName="PDFEditor" ReferencedContainer="container:PDFEditor.xcodeproj"/></BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugServiceExtension="internal"/>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(f"Generated PDFEditor.xcodeproj: {len(app_sources)} app sources, {len(test_sources)} test sources")
