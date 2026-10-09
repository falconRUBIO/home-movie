#!/usr/bin/env python3
"""Portable checks. Does not compile Swift or validate AVFoundation on a device."""
import json
import plistlib
import re
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(__file__).resolve().parents[1]
checks=[]
def check(condition, label):
    if not condition: raise AssertionError(label)
    checks.append(label)

info=plistlib.loads((root/'HomeMovie/Info.plist').read_bytes())
check(all(info.get(key) for key in ['NSCameraUsageDescription','NSMicrophoneUsageDescription','NSPhotoLibraryAddUsageDescription']), 'Permission purpose strings present')
check('NSPhotoLibraryUsageDescription' not in info, 'No broad Photos read permission requested')
check(len(info['UISupportedInterfaceOrientations'])==3, 'Portrait and both landscape orientations configured')
privacy=plistlib.loads((root/'HomeMovie/PrivacyInfo.xcprivacy').read_bytes())
check(privacy['NSPrivacyTracking'] is False and not privacy['NSPrivacyCollectedDataTypes'], 'Privacy manifest declares no tracking or collected data')
check(len(privacy['NSPrivacyAccessedAPITypes'])==3, 'Required-reason categories included')
project=(root/'HomeMovie.xcodeproj/project.pbxproj').read_text()
check('"IPHONEOS_DEPLOYMENT_TARGET" = "18.0"' in project, 'iOS 18 deployment target')
paths=re.findall(r'"path" = "([^"\n]+)"',project)
check(all((root/path).exists() for path in paths if not path.endswith(('.app','.xctest'))), 'Every referenced source/resource exists')
refs=re.findall(r'"fileRef" = "([A-F0-9]{24})"',project)
check(all(('"'+ref+'" = {') in project for ref in refs), 'Build file references resolve')
scheme=ET.parse(root/'HomeMovie.xcodeproj/xcshareddata/xcschemes/HomeMovie.xcscheme').getroot()
check(len(scheme.findall('./TestAction/Testables/TestableReference'))==1, 'Shared scheme includes unit test target')
asset=root/'HomeMovie/Assets.xcassets/AppIcon.appiconset'
icon=json.loads((asset/'Contents.json').read_text())
check(all((asset/image['filename']).exists() for image in icon['images']), 'App icon asset references resolve')
swift=list(root.rglob('*.swift'))
try:
    import tree_sitter_swift
    from tree_sitter import Language,Parser
    parser=Parser(Language(tree_sitter_swift.language()))
    for path in swift:
        tree=parser.parse(path.read_bytes())
        check(not tree.root_node.has_error, 'Swift grammar: '+str(path.relative_to(root)))
except ImportError:
    print('SKIP Swift grammar parser: install tree-sitter and tree-sitter-swift for this optional check.')
print(json.dumps({'status':'PASS','checks':checks,'swift_files':len(swift),'not_performed':['Xcode compilation','XCTest execution','real device tests']},indent=2))
