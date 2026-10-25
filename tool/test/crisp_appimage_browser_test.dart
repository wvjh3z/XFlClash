// Pure Dart regression of the production selector and actual child environment.
import 'dart:convert';
import 'dart:io';
// The cold preflight uses the packaging tool graph, not a Flutter app graph.
// ignore: avoid_relative_lib_imports
import '../../lib/xboard/services/crisp_appimage_browser.dart';

void check(bool condition, String label) {
  if (!condition) throw StateError(label);
  stdout.writeln('PASS: $label');
}

Future<void> main() async {
  if (!Platform.isLinux) {
    stdout.writeln('SKIP: Linux process test');
    return;
  }
  final base = await Directory.systemTemp.createTemp("crisp-browser-中文-'空格 ");
  final aliases = await Directory.systemTemp.createTemp('crisp-link-');
  try {
    final root = Directory('${base.path}/image')..createSync();
    final host = Directory('${base.path}/host')..createSync();
    final hostLib = Directory('${host.path}/lib')..createSync();
    final output = '${base.path}/captured.json';
    final browser = File('${base.path}/host-browser');
    browser.writeAsStringSync('''#!/usr/bin/python3
import os,sys,json
with open(os.environ['CAPTURE'], 'w') as f:
 json.dump({'env':dict(os.environ),'args':sys.argv[1:],'cwd':os.getcwd()},f)
''');
    await Process.run('chmod', ['+x', browser.path]);
    for (final name in ['omofly', 'daishu']) {
      final exe = File('${root.path}/$name')..writeAsStringSync('fixture');
      final env = <String, String>{
        'HOME': host.path,
        'PATH': '${root.path}/bin:/usr/bin:/bin',
        'CAPTURE': output,
        'APPDIR': root.path,
        'APPIMAGE': '${base.path}/$name.AppImage',
        'XBOARD_APPIMAGE_ROOT': root.path,
        'XBOARD_APPIMAGE_EXECUTABLE': exe.path,
        'XBOARD_APPIMAGE_ENV_SAVED': '1',
        'XBOARD_APPIMAGE_ORIGINAL_CWD': host.path,
        'XBOARD_APPIMAGE_ORIGINAL_LD_SET': 'x',
        'XBOARD_APPIMAGE_ORIGINAL_LD': 'lib',
        'LD_LIBRARY_PATH': 'usr/lib',
        'GIO_MODULE_DIR': '${root.path}/modules',
        'DISPLAY': ':71',
        'WAYLAND_DISPLAY': 'wayland-test',
        'DBUS_SESSION_BUS_ADDRESS': 'fixture-bus',
        'LANG': 'C.UTF-8',
      };
      check(
        crispAppImageRoot(environment: env, executable: exe.path) == root.path,
        '$name belongs to marked image',
      );
      check(
        crispAppImageRoot(environment: env, executable: '/usr/bin/other') ==
            null,
        '$name inherited markers rejected',
      );
      final alias = Link('${base.path}/alias-$name')..createSync(exe.path);
      check(
        crispAppImageRoot(environment: env, executable: alias.path) ==
            root.path,
        '$name symlink identity canonicalized',
      );
      final uri = Uri.https('go.crisp.chat', '/chat/embed/', {
        'website_id': '$name-test',
      });
      final ok = await openCrispAppImageBrowser(
        uri,
        environment: env,
        executable: exe.path,
        currentDirectory: root.path,
        commands: [
          [browser.path],
        ],
      );
      check(ok, '$name real browser child succeeds');
      final data = jsonDecode(File(output).readAsStringSync()) as Map;
      final child = data['env'] as Map;
      check(
        child['LD_LIBRARY_PATH'] == hostLib.path,
        '$name restores relative host library path',
      );
      check(
        !child.containsKey('APPDIR') &&
            !child.containsKey('APPIMAGE') &&
            !child.containsKey('GIO_MODULE_DIR') &&
            !child.keys.any(
              (k) => (k as String).startsWith('XBOARD_APPIMAGE_'),
            ),
        '$name child contains no image markers',
      );
      check(
        child['PATH'] == '/usr/bin:/bin' &&
            child['DISPLAY'] == ':71' &&
            child['DBUS_SESSION_BUS_ADDRESS'] == 'fixture-bus',
        '$name desktop session preserved',
      );
      check(
        data['cwd'] == host.path &&
            (data['args'] as List).single == uri.toString(),
        '$name URL passed literally outside image',
      );
      check(
        env['LD_LIBRARY_PATH'] == 'usr/lib' && env['APPDIR'] == root.path,
        '$name parent environment unchanged',
      );
      final old = await Process.run(
        browser.path,
        [uri.toString()],
        environment: env,
        includeParentEnvironment: false,
        workingDirectory: root.path,
      );
      check(old.exitCode == 0, '$name legacy launch control executes');
      final oldEnvironment =
          (jsonDecode(File(output).readAsStringSync()) as Map)['env'] as Map;
      check(
        oldEnvironment['APPDIR'] == root.path &&
            oldEnvironment['LD_LIBRARY_PATH'] == 'usr/lib',
        '$name legacy launch leaks image environment',
      );

      final insideLaunch = {
        ...env,
        'XBOARD_APPIMAGE_ORIGINAL_CWD': root.path,
        'XBOARD_APPIMAGE_ORIGINAL_LD': hostLib.path,
      };
      check(
        crispBrowserEnvironment(
              insideLaunch,
              appRoot: root.path,
              currentDirectory: root.path,
            )['LD_LIBRARY_PATH'] ==
            hostLib.path,
        '$name launch from inside image still restores host library path',
      );
      final hostPreload = {
        ...env,
        'LD_AUDIT': 'libhost.so:${root.path}/image.so:/opt/host.so',
      };
      check(
        crispBrowserEnvironment(
              hostPreload,
              appRoot: root.path,
              currentDirectory: root.path,
            )['LD_AUDIT'] ==
            'libhost.so:/opt/host.so',
        '$name host preload soname preserved while image path removed',
      );
      // These values are inspected, never loaded into the test process.
      for (final key in ['LD_LIBRARY_PATH', 'LD_PRELOAD', 'LD_AUDIT']) {
        for (final token in [
          r'$ORIGIN',
          r'${ORIGIN}',
          r'$LIB',
          r'${LIB}',
          r'$PLATFORM',
          r'${PLATFORM}',
        ]) {
          final value = '$token/../lib';
          final input = <String, String>{key: value};
          final clean = crispBrowserEnvironment(
            input,
            appRoot: '/tmp/image',
            currentDirectory: '/home/test',
          );
          check(clean[key] == value, '$name $key preserves $token literally');
          check(
            clean[key] != '/home/test/lib',
            '$name $key rejects old token normalization',
          );
          check(
            !crispBrowserEnvironment(
              {key: '/tmp/image/$token/lib'},
              appRoot: '/tmp/image',
              currentDirectory: '/home/test',
            ).containsKey(key),
            '$name $key removes owned literal prefix before $token',
          );
        }
        final boundary = crispBrowserEnvironment(
          {
            key:
                '/tmp/image/bad.so:/tmp/image-other/keep.so:/opt/archive/tmp/image/keep.so',
          },
          appRoot: '/tmp/image',
          currentDirectory: '/home/test',
        );
        check(
          boundary[key] ==
              '/tmp/image-other/keep.so:/opt/archive/tmp/image/keep.so',
          '$name $key keeps sibling and middle substring, removes owned entry',
        );
        final linked = Link('${aliases.path}/owned-$name-$key')
          ..createSync(root.path);
        check(
          !crispBrowserEnvironment(
            {key: '${linked.path}/'},
            appRoot: root.path,
            currentDirectory: host.path,
          ).containsKey(key),
          '$name $key removes canonical symlink to image',
        );
      }
      check(
        crispBrowserEnvironment(
              {'LD_AUDIT': '/opt/host one.so:/opt/host two.so'},
              appRoot: root.path,
              currentDirectory: host.path,
            )['LD_AUDIT'] ==
            '/opt/host one.so:/opt/host two.so',
        '$name audit preserves spaces within entries and colon separator',
      );
      check(
        crispBrowserEnvironment(
              {
                'LD_PRELOAD':
                    '/tmp/image/bad.so /opt/a.so:/opt/b.so libhost.so',
              },
              appRoot: '/tmp/image',
              currentDirectory: host.path,
            )['LD_PRELOAD'] ==
            '/opt/a.so:/opt/b.so:libhost.so',
        '$name preload accepts both separators and retains soname',
      );
      check(
        crispBrowserEnvironment(
              {'LD_LIBRARY_PATH': r'$ORIGIN/../lib;/tmp/image/lib:/opt/host'},
              appRoot: '/tmp/image',
              currentDirectory: host.path,
            )['LD_LIBRARY_PATH'] ==
            r'$ORIGIN/../lib:/opt/host',
        '$name library path accepts semicolon and removes owned path',
      );
      check(
        crispBrowserEnvironment(
              {...env, 'XBOARD_APPIMAGE_ORIGINAL_LD': r'$ORIGIN/../lib'},
              appRoot: root.path,
              currentDirectory: root.path,
            )['LD_LIBRARY_PATH'] ==
            r'$ORIGIN/../lib',
        '$name snapshot preserves loader token',
      );

      final noOriginal = {...env, 'XBOARD_APPIMAGE_ORIGINAL_LD_SET': ''};
      check(
        !crispBrowserEnvironment(
          noOriginal,
          appRoot: root.path,
          currentDirectory: root.path,
        ).containsKey('LD_LIBRARY_PATH'),
        '$name originally unset stays unset',
      );
      final legacy = {...env}
        ..removeWhere((key, _) => key.startsWith('XBOARD_APPIMAGE_'));
      check(
        !crispBrowserEnvironment(
          legacy,
          appRoot: root.path,
          currentDirectory: root.path,
        ).containsKey('LD_LIBRARY_PATH'),
        '$name legacy relative image path removed',
      );
      check(
        !await openCrispAppImageBrowser(
          uri,
          environment: env,
          executable: exe.path,
          commands: [
            ['${base.path}/missing'],
          ],
        ),
        '$name missing opener fails',
      );
      check(
        !await openCrispAppImageBrowser(
          uri,
          environment: env,
          executable: exe.path,
          commands: [
            ['/bin/sh', '-c', 'exit 3', 'fixture'],
          ],
        ),
        '$name failed child propagates',
      );
      check(
        await openCrispAppImageBrowser(
          uri,
          environment: env,
          executable: exe.path,
          commands: [
            [
              '/usr/bin/python3',
              '-c',
              'import sys;sys.stdout.write("x"*131072);sys.stderr.write("y"*131072)',
            ],
          ],
        ),
        '$name child output is drained',
      );
      final denied = File('${base.path}/not-executable-$name')
        ..writeAsStringSync('fixture');
      check(
        !await openCrispAppImageBrowser(
          uri,
          environment: env,
          executable: exe.path,
          commands: [
            [denied.path],
          ],
        ),
        '$name non-executable opener fails',
      );
      final contaminated = {
        ...env,
        'LD_AUDIT': '${root.path}/bad.so',
        'PATH': '${root.path}/bin:/usr/bin',
        'GSETTINGS_SCHEMA_DIR': '${root.path}/schemas',
      };
      final filtered = crispBrowserEnvironment(
        contaminated,
        appRoot: root.path,
        currentDirectory: root.path,
      );
      check(
        !filtered.containsKey('LD_AUDIT') &&
            !filtered.containsKey('GSETTINGS_SCHEMA_DIR') &&
            filtered['PATH'] == '/usr/bin',
        '$name image preload and resource paths removed',
      );

      for (final key in [
        'GIO_MODULE_DIR',
        'GSETTINGS_SCHEMA_DIR',
        'GDK_PIXBUF_MODULE_FILE',
        'GTK_IM_MODULE_FILE',
        'GTK_EXE_PREFIX',
        'GTK_DATA_PREFIX',
      ]) {
        Map<String, String> cleanResource(
          String value, {
          bool snapshot = true,
        }) {
          final input = {...env, key: value};
          if (!snapshot) {
            input.removeWhere((k, _) => k.startsWith('XBOARD_APPIMAGE_'));
          }
          return crispBrowserEnvironment(
            input,
            appRoot: root.path,
            currentDirectory: root.path,
          );
        }

        check(
          cleanResource('resources')[key] == '${host.path}/resources',
          '$name $key resolves original relative path',
        );
        check(
          cleanResource(hostLib.path)[key] == hostLib.path,
          '$name $key retains absolute host path',
        );
        check(
          !cleanResource('../image/resources').containsKey(key),
          '$name $key removes original relative image path',
        );
        check(
          !cleanResource('resources', snapshot: false).containsKey(key),
          '$name $key legacy resolves current image path',
        );
        check(
          !cleanResource(root.path).containsKey(key),
          '$name $key rejects image root',
        );
      }
      final insideHome = Link('${base.path}/inside-home-$name')
        ..createSync(root.path);
      final outsideHome = Link('${base.path}/outside-home-$name')
        ..createSync(host.path);
      final danglingHome = Link('${base.path}/dangling-home-$name')
        ..createSync('${base.path}/missing');
      final fileHome = File('${base.path}/file-home-$name')
        ..writeAsStringSync('not directory');
      for (final item in <String?, String>{
        host.path: host.path,
        outsideHome.path: host.path,
        root.path: '/',
        insideHome.path: '/',
        danglingHome.path: '/',
        '${base.path}/missing': '/',
        fileHome.path: '/',
        'relative-home': '/',
        null: '/',
      }.entries) {
        final input = {...env};
        if (item.key == null) {
          input.remove('HOME');
        } else {
          input['HOME'] = item.key!;
        }
        check(
          await openCrispAppImageBrowser(
            uri,
            environment: input,
            executable: exe.path,
            currentDirectory: root.path,
            commands: [
              [browser.path],
            ],
          ),
          '$name HOME case starts child: ${item.key}',
        );
        final captured = jsonDecode(File(output).readAsStringSync()) as Map;
        check(
          captured['cwd'] == item.value,
          '$name HOME physical cwd: ${item.key}',
        );
        check(
          (captured['env'] as Map)['HOME'] == item.key,
          '$name HOME preference remains unchanged',
        );
      }

      // Deterministic timeout: the child waits for a release file, not a short sleep.
      final release = File('${base.path}/release-$name');
      final done = File('${base.path}/done-$name');
      final waiting = File('${base.path}/waiting');
      waiting.writeAsStringSync(
        '#!/usr/bin/python3\nimport os,time\nwhile not os.path.exists(os.environ["RELEASE"]): time.sleep(.02)\nopen(os.environ["DONE"],"w").close()\n',
      );
      await Process.run('chmod', ['+x', waiting.path]);
      try {
        check(
          !await openCrispAppImageBrowser(
            uri,
            environment: {...env, 'RELEASE': release.path, 'DONE': done.path},
            executable: exe.path,
            commands: [
              [waiting.path],
            ],
            timeout: Duration.zero,
          ),
          '$name blocked opener has bounded wait',
        );
      } finally {
        release.writeAsStringSync('release');
      }
      final wait = Stopwatch()..start();
      while (!done.existsSync() && wait.elapsed < const Duration(seconds: 10)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      check(done.existsSync(), '$name timed-out child released and completed');
    }
  } finally {
    await aliases.delete(recursive: true);
    await base.delete(recursive: true);
  }
}
