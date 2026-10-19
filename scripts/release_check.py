#!/usr/bin/env python3
"""Release preflight. --app-store deliberately fails until human evidence is recorded."""
import argparse
import json
import plistlib
import sys
import zipfile
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
REQUIRED_SCENARIOS = ('long_recording', 'repeated_flips', 'pip_orientations', 'log_effects_export',
                      'interruptions', 'low_storage', 'recovery', 'upgrade', 'backup_restore', 'accessibility')

def store_blockers(config, build=None):
    blockers = []
    for key in ('privacy_policy_url', 'support_url'):
        parsed = urlparse(config.get(key) or '')
        if parsed.scheme != 'https' or not parsed.hostname or parsed.hostname in ('example.com', 'localhost'):
            blockers.append(key + ' requires the actual public HTTPS URL')
    for key in ('original_lut_redistribution_confirmed', 'privacy_labels_reviewed',
                'export_compliance_reviewed', 'store_screenshots_reviewed'):
        if config.get(key) is not True:
            blockers.append(key + ' is not confirmed')
    if not str(config.get('app_review_notes') or '').strip():
        blockers.append('app_review_notes are missing')
    devices = config.get('device_tests', [])
    roles = {device.get('role') for device in devices if device.get('status') == 'passed'}
    if not {'primary', 'oldest_supported'} <= roles:
        blockers.append('primary and oldest-supported physical device tests must pass')
    for device in devices:
        if device.get('status') != 'passed' or not all(device.get(key) for key in ('model', 'os_version', 'build_number', 'evidence')):
            blockers.append('device evidence is incomplete for ' + str(device.get('role')))
        if not all(device.get('scenarios', {}).get(key) is True for key in REQUIRED_SCENARIOS):
            blockers.append('required physical scenarios are incomplete for ' + str(device.get('role')))
        if build is not None and str(device.get('build_number')) != str(build):
            blockers.append('physical evidence does not match archive build for ' + str(device.get('role')))
    return blockers

def inspect_ipa(path):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        infos = [name for name in names if name.startswith('Payload/') and name.count('/') == 2 and name.endswith('.app/Info.plist')]
        if len(infos) != 1:
            raise ValueError('Expected one app in Payload')
        info = plistlib.loads(archive.read(infos[0]))
        prefix = infos[0].removesuffix('Info.plist')
        if info.get('CFBundleIdentifier') != 'com.falconcraft.homemovie':
            raise ValueError('Unexpected bundle identifier')
        if not str(info.get('CFBundleVersion', '')).isdigit() or not info.get('CFBundleShortVersionString'):
            raise ValueError('Missing release version/build')
        if not all(info.get(key) for key in ('NSCameraUsageDescription', 'NSMicrophoneUsageDescription', 'NSPhotoLibraryAddUsageDescription')):
            raise ValueError('Missing permission purpose strings')
        if 'NSPhotoLibraryUsageDescription' in info:
            raise ValueError('Unexpected Photos read permission')
        for resource in ('PrivacyInfo.xcprivacy', 'Cinema.json', 'AppleLogToRec709.lut', 'FilmEffects.metallib'):
            if prefix + resource not in names:
                raise ValueError('Missing bundled resource: ' + resource)
        if any(prefix + resource in names for resource in ('CinemaTwo.json', 'CinemaThree.json')):
            raise ValueError('Retired LUTs are still bundled')
        privacy = plistlib.loads(archive.read(prefix + 'PrivacyInfo.xcprivacy'))
        if privacy.get('NSPrivacyTracking') is not False:
            raise ValueError('Unexpected privacy tracking declaration')
        if any(name.endswith(('.p8', '.p12', '.pem')) for name in names):
            raise ValueError('Signing key material must not be included')
        return info

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--ipa', type=Path)
    parser.add_argument('--app-store', action='store_true')
    parser.add_argument('--readiness', type=Path, default=ROOT / 'release-readiness.json')
    args = parser.parse_args()
    try:
        info = inspect_ipa(args.ipa) if args.ipa else None
        config = json.loads(args.readiness.read_text())
        if args.app_store:
            blockers = store_blockers(config, info.get('CFBundleVersion') if info else None)
            if not args.ipa:
                blockers.append('provide the exact tested signed IPA with --ipa')
            if blockers:
                print(json.dumps({'status': 'BLOCKED', 'blockers': blockers}, indent=2))
                return 1
        print(json.dumps({'status': 'PASS', 'archive_checked': info is not None,
                          'app_store_evidence_checked': args.app_store,
                          'not_verified': ['physical camera behavior', 'Apple processing or approval', 'URL reachability', 'codesigning validity']}, indent=2))
        return 0
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        print(json.dumps({'status': 'FAIL', 'reason': str(error)}))
        return 1

if __name__ == '__main__':
    sys.exit(main())
