#!/usr/bin/env python3
"""Fail before compilation when brand injection is absent or mixed."""
import json
from pathlib import Path


def identity_fields(identity):
    return {'XB_NATIVE_ID':identity['id'], 'XB_NATIVE_NAME':identity['name'],
            'XB_HELPER_WINDOWS_SERVICE':identity['windowsService'],
            'XB_HELPER_SOCKET':'/run/'+identity['runtimeDirectory']+'/helper.sock',
            'XB_URL_SCHEME':identity['scheme'], 'XB_DEFAULT_MIXED_PORT':str(identity['mixedPort']),
            'XB_WINDOWS_CORE_NAME':identity['name']+'Core',
            'XB_WINDOWS_HELPER_NAME':identity['name']+'HelperService'}


def native_checks(identity, platform):
    return {
      'windows/CMakeLists.txt':[f'set(BINARY_NAME "{identity["name"]}")'],
      'build_config.yaml':[f'core_name: "{identity["name"]+"Core" if platform=="windows" else "FlClashCore"}"',
                          f'helper_name: "{identity["name"]+"HelperService" if platform=="windows" else "FlClashHelperService"}"'],
      'windows/runner/Runner.rc':['VALUE "CompanyName", "com.cloud.app"',f'VALUE "ProductName", "{identity["slug"]}"'],
      'windows/packaging/exe/make_config.yaml':[identity['installerId'],f'executable_name: "{identity["name"]}.exe"'],
      'windows/packaging/exe/inno_setup.iss':[f'#define XbServiceName "{identity["windowsService"]}"'],
      'macos/Runner/Configs/AppInfo.xcconfig':['PRODUCT_BUNDLE_IDENTIFIER = '+identity['id']],
      'macos/Runner/Info.plist':[f"<string>{identity['scheme']}</string>"],
      'linux/packaging/deb/make_config.yaml':[
          f'package_name: "{identity["slug"]}"',
          f'unit=/etc/systemd/system/{identity["linuxService"]}.service',
          f'/usr/share/{identity["slug"]}/FlClashHelperService',
          f'startup_wm_class: "{identity["id"]}"'],
      'linux/packaging/rpm/make_config.yaml':[
          f'unit=/etc/systemd/system/{identity["linuxService"]}.service',
          f'startup_wm_class: "{identity["id"]}"'],
      'linux/packaging/appimage/make_config.yaml':[
          f'startup_wm_class: "{identity["id"]}"'],
      'linux/CMakeLists.txt':[f'set(APPLICATION_ID "{identity["id"]}")'],
      'services/helper/src/service/windows.rs':[f'const SERVICE_NAME: &str = "{identity["windowsService"]}";'],
      'services/helper/src/service/peer.rs':[f'Services\\{identity["windowsService"]}\\Runtime'],
      'services/helper/src/service/linux.rs':[f'const SERVICE_NAME: &str = "{identity["linuxService"]}";',f'"/run/{identity["runtimeDirectory"]}/helper.sock"'],
    }


def verify(root, flavor, platform):
    root=Path(root)
    identity=json.loads((root/'tool/identity/brands.json').read_text(encoding='utf-8'))[flavor]
    defines=json.loads((root/'env.json').read_text(encoding='utf-8'))
    if any(defines.get(k)!=v for k,v in identity_fields(identity).items()):
        raise ValueError('brand_defines_mismatch')
    if platform=='android': return
    for name,needles in native_checks(identity,platform).items():
        source=(root/name).read_text(encoding='utf-8')
        if any(source.count(n)!=1 for n in needles):
            raise ValueError('native_brand_identity_mismatch:'+name)
