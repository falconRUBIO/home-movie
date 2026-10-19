import copy
import importlib.util
import json
import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location('release_check', Path(__file__).with_name('release_check.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

class ReleaseChecks(unittest.TestCase):
    def test_unverified_release_is_blocked(self):
        config = json.loads((release.ROOT / 'release-readiness.json').read_text())
        self.assertTrue(release.store_blockers(config, '1234'))

    def test_complete_evidence_must_match_exact_build(self):
        config = {'privacy_policy_url': 'https://falconcraft.test/privacy', 'support_url': 'https://falconcraft.test/support',
                  'app_review_notes': 'Camera test instructions', 'original_lut_redistribution_confirmed': True,
                  'privacy_labels_reviewed': True, 'export_compliance_reviewed': True, 'store_screenshots_reviewed': True,
                  'device_tests': [{'role': role, 'model': 'Test device', 'os_version': 'Test OS', 'build_number': '1234',
                                    'evidence': 'Recorded test run', 'status': 'passed',
                                    'scenarios': {key: True for key in release.REQUIRED_SCENARIOS}} for role in ('primary', 'oldest_supported')]}
        self.assertEqual(release.store_blockers(config, '1234'), [])
        self.assertTrue(release.store_blockers(config, '1235'))
        missing = copy.deepcopy(config); missing['device_tests'][0]['scenarios']['recovery'] = False
        self.assertTrue(release.store_blockers(missing, '1234'))

    def test_archive_rejects_missing_effects_and_embedded_keys(self):
        with tempfile.TemporaryDirectory() as temp:
            ipa = Path(temp) / 'fixture.ipa'
            info = {'CFBundleIdentifier': 'com.falconcraft.homemovie', 'CFBundleVersion': '1234',
                    'CFBundleShortVersionString': '1.0', 'NSCameraUsageDescription': 'Record',
                    'NSMicrophoneUsageDescription': 'Audio', 'NSPhotoLibraryAddUsageDescription': 'Save'}
            prefix = 'Payload/HomeMovie.app/'
            with zipfile.ZipFile(ipa, 'w') as archive:
                archive.writestr(prefix + 'Info.plist', plistlib.dumps(info))
                archive.writestr(prefix + 'PrivacyInfo.xcprivacy', plistlib.dumps({'NSPrivacyTracking': False}))
                for resource in ('Cinema.json', 'AppleLogToRec709.lut'):
                    archive.writestr(prefix + resource, b'fixture')
            with self.assertRaisesRegex(ValueError, 'FilmEffects.metallib'):
                release.inspect_ipa(ipa)
            with zipfile.ZipFile(ipa, 'a') as archive:
                archive.writestr(prefix + 'FilmEffects.metallib', b'fixture')
            self.assertEqual(release.inspect_ipa(ipa)['CFBundleVersion'], '1234')
            with zipfile.ZipFile(ipa, 'a') as archive:
                archive.writestr(prefix + 'private.p8', b'not an actual key')
            with self.assertRaisesRegex(ValueError, 'Signing key'):
                release.inspect_ipa(ipa)
