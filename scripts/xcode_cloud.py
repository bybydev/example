#!/usr/bin/env python3
"""Select Xcode Cloud's iOS model resources and verify the archive."""
import argparse
import copy
import json
import re
import shlex
import subprocess
from pathlib import Path

from release_models import REPOSITORY, SMALL_ID, assets, verify
from verify_release_archive import plist, require, verify_ios_models

PROJECT = REPOSITORY / 'Inkribe.xcodeproj/project.pbxproj'
FLAG = 'INKRIBE_IOS_BUNDLED_MODELS_ONLY'
# Stable IDs owned only by this hook; the normal project remains XcodeGen's output.
MODEL_FILE = 'C10D00000000000000000001'
MODEL_BUILD_FILE = 'C10D00000000000000000002'


def read_project():
    data = subprocess.check_output(
        ['plutil', '-convert', 'json', '-o', '-', str(PROJECT)], text=True)
    project = json.loads(data)
    objects = project['objects']
    targets = [value for value in objects.values()
               if value.get('isa') == 'PBXNativeTarget' and value.get('name') == 'Inkribe']
    require(len(targets) == 1, 'Expected one Inkribe iOS target in the committed project')
    target = targets[0]
    configurations = objects[target['buildConfigurationList']]['buildConfigurations']
    require({objects[key]['name'] for key in configurations} == {'Debug', 'Release'},
            'Expected Debug and Release iOS configurations')
    resources = [key for key in target['buildPhases']
                 if objects[key]['isa'] == 'PBXResourcesBuildPhase']
    require(len(resources) == 1, 'Expected one iOS Resources phase')
    return project, configurations, resources[0]


def swift_flags(configuration):
    value = configuration['buildSettings'].get('OTHER_SWIFT_FLAGS', ['$(inherited)'])
    return shlex.split(value) if isinstance(value, str) else list(value)


def serialize(value, indent):
    if isinstance(value, dict):
        rows = ['\t' * (indent + 1) + json.dumps(key) + ' = '
                + serialize(item, indent + 1) + ';\n' for key, item in value.items()]
        return '{\n' + ''.join(rows) + '\t' * indent + '}'
    if isinstance(value, list):
        rows = ['\t' * (indent + 1) + serialize(item, indent + 1) + ',\n' for item in value]
        return '(\n' + ''.join(rows) + '\t' * indent + ')'
    return json.dumps(value)


def replace_object(text, key, value, section):
    # XcodeGen writes object definitions at two tabs, including its one-line refs.
    pattern = (r'(?ms)^\t\t' + re.escape(key) + r'(?: /\*[^\n]*\*/)? = '
               + r'\{(?:[^\n]*\};|.*?^\t\t\};)\n')
    matches = list(re.finditer(pattern, text))
    require(len(matches) <= 1, 'Duplicate project object: ' + key)
    entry = '' if value is None else '\t\t' + key + ' = ' + serialize(value, 2) + ';\n'
    if matches:
        match = matches[0]
        return text[:match.start()] + entry + text[match.end():]
    if value is None:
        return text
    marker = '/* End ' + section + ' section */'
    require(text.count(marker) == 1, 'Missing project section: ' + section)
    return text.replace(marker, entry + marker)


def configure(ios_models):
    project, configurations, resource_id = read_project()
    objects = project['objects']
    updated = copy.deepcopy(project)
    next_objects = updated['objects']
    small = next(asset for asset in assets() if asset['id'] == SMALL_ID)
    if ios_models == 'bundled':
        verify(REPOSITORY / 'Models' / small['relativePath'], small)
    file_reference = {
        'isa': 'PBXFileReference', 'lastKnownFileType': 'file',
        'path': 'Models/' + small['relativePath'], 'sourceTree': 'SOURCE_ROOT'
    }
    build_reference = {'isa': 'PBXBuildFile', 'fileRef': MODEL_FILE}
    for key, expected in [(MODEL_FILE, file_reference), (MODEL_BUILD_FILE, build_reference)]:
        require(key not in objects or objects[key] == expected, 'Model project object ID collision')
    for key in configurations:
        configuration = next_objects[key]
        flags = swift_flags(configuration)
        retained = []
        index = 0
        while index < len(flags):
            if flags[index:index + 2] == ['-D', FLAG]:
                index += 2
            elif flags[index] == '-D' + FLAG:
                index += 1
            else:
                retained.append(flags[index])
                index += 1
        if ios_models == 'bundled':
            retained += ['-D', FLAG]
        configuration['buildSettings']['OTHER_SWIFT_FLAGS'] = retained

    resource_files = next_objects[resource_id]['files']
    resource_files[:] = [key for key in resource_files if key != MODEL_BUILD_FILE]
    main_group = objects[project['rootObject']]['mainGroup']
    children = next_objects[main_group]['children']
    children[:] = [key for key in children if key != MODEL_FILE]
    if ios_models == 'bundled':
        resource_files.append(MODEL_BUILD_FILE)
        children.append(MODEL_FILE)
        next_objects[MODEL_FILE] = file_reference
        next_objects[MODEL_BUILD_FILE] = build_reference
    else:
        next_objects.pop(MODEL_FILE, None)
        next_objects.pop(MODEL_BUILD_FILE, None)

    text = PROJECT.read_text()
    for key in configurations:
        text = replace_object(text, key, next_objects[key], 'XCBuildConfiguration')
    text = replace_object(text, resource_id, next_objects[resource_id], 'PBXResourcesBuildPhase')
    text = replace_object(text, main_group, next_objects[main_group], 'PBXGroup')
    bundled = ios_models == 'bundled'
    text = replace_object(text, MODEL_FILE, file_reference if bundled else None, 'PBXFileReference')
    text = replace_object(text, MODEL_BUILD_FILE, build_reference if bundled else None, 'PBXBuildFile')
    temporary = PROJECT.with_suffix('.cloud-tmp')
    try:
        temporary.write_text(text)
        parsed = subprocess.check_output(
            ['plutil', '-convert', 'json', '-o', '-', str(temporary)], text=True)
        require(json.loads(parsed) == updated, 'Project model configuration did not round-trip correctly')
        temporary.replace(PROJECT)
    finally:
        temporary.unlink(missing_ok=True)
    print('Prepared Inkribe iOS model policy: ' + ios_models)


def verify_archive(archive, ios_models):
    project, configurations, resource_id = read_project()
    objects = project['objects']
    bundled = ios_models == 'bundled'
    for key in configurations:
        flags = swift_flags(objects[key])
        enabled = FLAG in flags or '-D' + FLAG in flags
        require(enabled == bundled, 'Compiled project model policy disagrees with IOS_MODELS')
    resources = objects[resource_id]['files']
    require((MODEL_BUILD_FILE in resources) == bundled, 'iOS model resource policy disagrees with IOS_MODELS')
    apps = list((archive / 'Products/Applications').glob('*.app'))
    require(len(apps) == 1, 'Expected exactly one archived app')
    app = apps[0]
    info = plist(app / 'Info.plist')
    require(info.get('CFBundleIdentifier') == 'com.hoangbkit.inkribe', 'Unexpected archived app identity')
    metadata = plist(archive / 'Info.plist')
    require(metadata.get('ApplicationProperties', {}).get('CFBundleIdentifier') == 'com.hoangbkit.inkribe',
            'Unexpected archive metadata identity')
    require(info.get('CFBundleSupportedPlatforms') == ['iPhoneOS'], 'Expected an iOS device archive')
    require(info.get('UIDeviceFamily') == [1], 'Expected an iPhone-only archive')
    require(info.get('ITSAppUsesNonExemptEncryption') is False, 'Missing encryption declaration')
    verify_ios_models(app, ios_models)
    print('Verified Inkribe archive with model policy: ' + ios_models)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['configure', 'verify'])
    parser.add_argument('--ios-models', required=True, choices=['download', 'bundled'])
    parser.add_argument('--archive', type=Path)
    options = parser.parse_args()
    if options.action == 'configure':
        configure(options.ios_models)
    else:
        require(options.archive is not None, '--archive is required for archive verification')
        verify_archive(options.archive, options.ios_models)


if __name__ == '__main__':
    main()
