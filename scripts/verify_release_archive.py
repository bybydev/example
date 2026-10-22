#!/usr/bin/env python3
"""Validate the actual unsigned archive before packaging it for mycli."""
import argparse
from pathlib import Path
import plistlib
import subprocess

from release_models import assets, verify, SMALL_ID


def require(condition, message):
    if not condition:
        raise ValueError(message)


def plist(path):
    with path.open('rb') as source:
        return plistlib.load(source)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--platform', required=True, choices=['iOS', 'macOS'])
    parser.add_argument('--configuration', required=True, choices=['Debug', 'Release'])
    parser.add_argument('--ios-models', required=True, choices=['download', 'bundled'])
    parser.add_argument('--settings', required=True, type=Path, help='Effective Xcode build-settings JSON')
    options = parser.parse_args()
    import json
    settings = json.loads(options.settings.read_text())
    target = 'Inkribe' if options.platform == 'iOS' else 'InkribeMac'
    app_settings = [entry['buildSettings'] for entry in settings if entry.get('target') == target]
    require(len(app_settings) == 1, 'App build settings are missing or ambiguous')
    app_settings = app_settings[0]
    require(bool(app_settings.get('DEVELOPMENT_TEAM')), 'Generated project lost DEVELOPMENT_TEAM')
    entitlement_file = Path(app_settings['CODE_SIGN_ENTITLEMENTS'])
    if not entitlement_file.is_absolute():
        entitlement_file = Path(app_settings['SRCROOT']) / entitlement_file
    require(isinstance(plist(entitlement_file), dict), 'Invalid source entitlement plist')
    # Unsigned archives have no final signature entitlement contract. mycli
    # reads these effective project settings and signs/exports on the user's Mac.
    metadata = plist(options.archive / 'Info.plist')
    applications = list((options.archive / 'Products/Applications').glob('*.app'))
    require(len(applications) == 1, 'Expected exactly one archived app')
    app = applications[0]
    ios = options.platform == 'iOS'
    resource_root = app if ios else app / 'Contents/Resources'
    info = plist(app / ('Info.plist' if ios else 'Contents/Info.plist'))
    expected_id = 'com.hoangbkit.inkribe' + ('.ios' if ios else '')
    if options.configuration == 'Debug':
        expected_id += '.debug'
    require(info['CFBundleIdentifier'] == expected_id, 'Wrong archived bundle identifier')
    require(app_settings['PRODUCT_BUNDLE_IDENTIFIER'] == expected_id, 'Wrong effective app identity')
    require(metadata.get('ApplicationProperties', {}).get('CFBundleIdentifier') == expected_id,
            'Archive metadata has the wrong app identity')
    require(info.get('ITSAppUsesNonExemptEncryption') is False, 'Missing non-exempt-encryption declaration')
    require(info.get('CFBundleExecutable'), 'Missing archived executable name')
    executable = app / ('' if ios else 'Contents/MacOS') / info['CFBundleExecutable']
    require(executable.is_file(), 'Missing archived executable')
    architectures = subprocess.check_output(['lipo', '-archs', str(executable)], text=True).split()
    if ios:
        require(info.get('CFBundleSupportedPlatforms') == ['iPhoneOS'], 'Expected an iOS device archive')
        require('arm64' in architectures, 'Missing iOS arm64 slice')
        require(info.get('NSPhotoLibraryAddUsageDescription'), 'Missing Photos add-only usage description')
        flags = app_settings.get('OTHER_SWIFT_FLAGS', '')
        require(('INKRIBE_IOS_BUNDLED_MODELS_ONLY' in flags) == (options.ios_models == 'bundled'),
                'Effective iOS model build policy disagrees with selection')
        model_paths = list(app.rglob('*.bin')) + list(app.rglob('*.gguf')) + list(app.rglob('*.onnx'))
        if options.ios_models == 'bundled':
            small = next(asset for asset in assets() if asset['id'] == SMALL_ID)
            verify(app / 'ggml-small.bin', small)
            require(model_paths == [app / 'ggml-small.bin'], 'Unexpected additional iOS weights')
        else:
            require(not model_paths and not (app / 'Models').exists(), 'Download-enabled iOS contains unwanted weights')
    else:
        require({'arm64', 'x86_64'}.issubset(architectures), 'Missing universal macOS slices')
        for asset in assets():
            verify(resource_root / 'Models' / asset['relativePath'], asset)
        require((resource_root / 'ThirdPartyNotices.txt').is_file(), 'Missing Mac third-party notices')
    # The current repo has no app icon artwork. Do not fabricate it or treat an
    # unsigned development build as App Store metadata validation.
    icon_present = bool(info.get('CFBundleIconFile') or info.get('CFBundleIconName') or info.get('CFBundleIcons'))
    if icon_present:
        require((resource_root / 'Assets.car').is_file() or any(resource_root.glob('*.icns'))
                or any(resource_root.glob('AppIcon*.png')), 'Declared app icon has no compiled output')
    else:
        print('::warning::No app icon is declared in this archive; artwork remains a production release input.')
    print('Validated unsigned ' + options.platform + ' archive: ' + str(options.archive))


if __name__ == '__main__':
    main()
