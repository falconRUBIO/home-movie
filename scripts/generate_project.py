#!/usr/bin/env python3
"""Generate a dependency-free, deterministic Xcode project and shared test scheme."""
import hashlib
import json
import os
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
bundle_id = os.environ.get('BUNDLE_ID', 'com.falconcraft.homemovie')
build_number = os.environ.get('BUILD_NUMBER', '1')
if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', bundle_id):
    raise SystemExit('BUNDLE_ID must be a valid reverse-domain identifier')
if not build_number.isdecimal() or int(build_number) < 1:
    raise SystemExit('BUILD_NUMBER must be a positive integer')
objects = {}
def ident(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def add(object_key, isa, **values):
    key = ident(object_key); objects[key] = {'isa': isa, **values}; return key

def config(name, values): return add(name, 'XCBuildConfiguration', buildSettings=values, name=name.split(':')[-1])
def configlist(name, debug, release):
    return add(name, 'XCConfigurationList', buildConfigurations=[debug, release], defaultConfigurationIsVisible=0, defaultConfigurationName='Release')
app_sources = sorted((root / 'HomeMovie').rglob('*.swift'))
tests = sorted((root / 'HomeMovieTests').glob('*.swift'))
app_files = []; test_files = []; app_build = []; test_build = []
for paths, refs, builds in [(app_sources, app_files, app_build), (tests, test_files, test_build)]:
    for path in paths:
        relative = path.relative_to(root).as_posix()
        ref = add(relative, 'PBXFileReference', lastKnownFileType='sourcecode.swift', path=relative, sourceTree='<group>')
        refs.append(ref); builds.append(add(relative + ':build', 'PBXBuildFile', fileRef=ref))
resources = []
for path, filetype in [('HomeMovie/PrivacyInfo.xcprivacy', 'text.xml'), ('HomeMovie/Assets.xcassets', 'folder.assetcatalog'), ('HomeMovie/Resources/AppleLogToRec709.lut', 'file')]:
    ref = add(path, 'PBXFileReference', lastKnownFileType=filetype, path=path, sourceTree='<group>')
    app_files.append(ref); resources.append(add(path + ':build', 'PBXBuildFile', fileRef=ref))
app = add('app-product', 'PBXFileReference', explicitFileType='wrapper.application', path='HomeMovie.app', sourceTree='BUILT_PRODUCTS_DIR')
test_product = add('test-product', 'PBXFileReference', explicitFileType='wrapper.cfbundle', path='HomeMovieTests.xctest', sourceTree='BUILT_PRODUCTS_DIR')
products = add('products', 'PBXGroup', children=[app, test_product], name='Products', sourceTree='<group>')
app_group = add('app-files', 'PBXGroup', children=app_files, name='HomeMovie', sourceTree='<group>')
test_group = add('test-files', 'PBXGroup', children=test_files, name='Tests', sourceTree='<group>')
main_group = add('root-group', 'PBXGroup', children=[app_group, test_group, products], sourceTree='<group>')
phases = {}
for prefix, source_builds, res in [('app', app_build, resources), ('test', test_build, [])]:
    phases[prefix] = [add(prefix + ':sources', 'PBXSourcesBuildPhase', buildActionMask=2147483647, files=source_builds, runOnlyForDeploymentPostprocessing=0),
        add(prefix + ':frameworks', 'PBXFrameworksBuildPhase', buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0),
        add(prefix + ':resources', 'PBXResourcesBuildPhase', buildActionMask=2147483647, files=res, runOnlyForDeploymentPostprocessing=0)]
project_id = ident('project'); app_id = ident('app-target')
shared = dict(IPHONEOS_DEPLOYMENT_TARGET='18.0', SDKROOT='iphoneos', SWIFT_VERSION='5.0', CLANG_ENABLE_MODULES='YES', CODE_SIGN_STYLE='Automatic', TARGETED_DEVICE_FAMILY='1', SUPPORTED_PLATFORMS='iphoneos iphonesimulator', SWIFT_STRICT_CONCURRENCY='targeted')
project_debug = config('project:Debug', dict(shared, DEBUG_INFORMATION_FORMAT='dwarf', SWIFT_OPTIMIZATION_LEVEL='-Onone', ENABLE_TESTABILITY='YES', SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG', ONLY_ACTIVE_ARCH='YES'))
project_release = config('project:Release', dict(shared, DEBUG_INFORMATION_FORMAT='dwarf-with-dsym', SWIFT_OPTIMIZATION_LEVEL='-O', SWIFT_COMPILATION_MODE='wholemodule'))
app_settings = dict(PRODUCT_BUNDLE_IDENTIFIER=bundle_id, PRODUCT_NAME='$(TARGET_NAME)', INFOPLIST_FILE='HomeMovie/Info.plist', GENERATE_INFOPLIST_FILE='NO', MARKETING_VERSION='0.2.0', CURRENT_PROJECT_VERSION=build_number, ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon', LD_RUNPATH_SEARCH_PATHS='$(inherited) @executable_path/Frameworks', SUPPORTS_MACCATALYST='NO')
app_configs = configlist('app-configs', config('app:Debug', app_settings), config('app:Release', app_settings))
add('app-target', 'PBXNativeTarget', buildConfigurationList=app_configs, buildPhases=phases['app'], buildRules=[], dependencies=[], name='HomeMovie', productName='HomeMovie', productReference=app, productType='com.apple.product-type.application')
proxy = add('test-proxy', 'PBXContainerItemProxy', containerPortal=project_id, proxyType=1, remoteGlobalIDString=app_id, remoteInfo='HomeMovie')
dep = add('test-dependency', 'PBXTargetDependency', target=app_id, targetProxy=proxy)
test_settings = dict(PRODUCT_BUNDLE_IDENTIFIER=bundle_id + '.Tests', PRODUCT_NAME='$(TARGET_NAME)', GENERATE_INFOPLIST_FILE='YES', TEST_HOST='$(BUILT_PRODUCTS_DIR)/HomeMovie.app/HomeMovie', BUNDLE_LOADER='$(TEST_HOST)', LD_RUNPATH_SEARCH_PATHS='$(inherited) @executable_path/Frameworks @loader_path/Frameworks')
test_configs = configlist('test-configs', config('test:Debug', test_settings), config('test:Release', test_settings))
test_id = add('test-target', 'PBXNativeTarget', buildConfigurationList=test_configs, buildPhases=phases['test'], buildRules=[], dependencies=[dep], name='HomeMovieTests', productName='HomeMovieTests', productReference=test_product, productType='com.apple.product-type.bundle.unit-test')
add('project', 'PBXProject', attributes={'LastUpgradeCheck': '2600', 'TargetAttributes': {app_id: {'CreatedOnToolsVersion': '26.0'}, test_id: {'CreatedOnToolsVersion': '26.0', 'TestTargetID': app_id}}}, buildConfigurationList=configlist('project-configs', project_debug, project_release), compatibilityVersion='Xcode 14.0', developmentRegion='en', hasScannedForEncodings=0, knownRegions=['en', 'Base'], mainGroup=main_group, productRefGroup=products, projectDirPath='', projectRoot='', targets=[app_id, test_id])
def fmt(value, depth=0):
    if isinstance(value, dict):
        return '{\n' + ''.join('  ' * (depth+1) + json.dumps(str(k)) + ' = ' + fmt(v, depth+1) + ';\n' for k,v in value.items()) + '  ' * depth + '}'
    if isinstance(value, list): return '(' + ', '.join(fmt(v, depth) for v in value) + (',' if value else '') + ')'
    if isinstance(value, int): return str(value)
    return json.dumps(value)
project = root / 'HomeMovie.xcodeproj'; project.mkdir(exist_ok=True)
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n' + fmt(dict(archiveVersion=1, classes={}, objectVersion=56, objects=objects, rootObject=project_id)) + '\n')
ref = lambda id_, name: f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{id_}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:HomeMovie.xcodeproj"/>'
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref(app_id,'HomeMovie.app')}</BuildActionEntry><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{ref(test_id,'HomeMovieTests.xctest')}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref(test_id,'HomeMovieTests.xctest')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref(app_id,'HomeMovie.app')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref(app_id,'HomeMovie.app')}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
scheme_dir = project / 'xcshareddata/xcschemes'; scheme_dir.mkdir(parents=True, exist_ok=True)
(scheme_dir / 'HomeMovie.xcscheme').write_text(scheme)
print(f'Generated project: {len(app_sources)} source files, {len(tests)} test files')
