"""Lightweight source invariants; native focus probes are explicit opt-in tests."""
from pathlib import Path
from unittest import mock
import hashlib,json,os,shlex,shutil,subprocess,tempfile,unittest
ROOT=Path(__file__).resolve().parents[2]

class CrispCompatibilityTests(unittest.TestCase):
    def test_mobile_source_matches_original_archive(self):
        root=ROOT/'plugins/crisp_chat'
        expected=json.loads((root/'upstream-mobile-sha256.json').read_text(encoding="utf-8"))
        actual={}
        for folder in ('android','ios'):
            for p in (root/folder).rglob('*'):
                if not p.is_file(): continue
                name=p.relative_to(root).as_posix()
                data=p.read_bytes()
                if name == 'android/build.gradle':
                    patch=b"im.crisp:crisp-sdk:2.0.25"
                    self.assertEqual(data.count(patch),1)
                    # Preserve upstream provenance: only the authorized SDK pin differs.
                    data=data.replace(patch,b"im.crisp:crisp-sdk:2.0.24")
                actual[name]=hashlib.sha256(data).hexdigest()
        self.assertEqual(actual,expected)

    def test_pinned_dependency_and_retired_title_engine(self):
        self.assertIn('desktop_webview_window: 0.4.0',(ROOT/'pubspec.yaml').read_text(encoding="utf-8"))
        self.assertIn('desktop_webview_window: 0.4.0',(ROOT/'plugins/crisp_chat/pubspec.yaml').read_text(encoding="utf-8"))
        self.assertNotIn('runWebViewTitleBarWidget',(ROOT/'lib/main.dart').read_text(encoding="utf-8"))
        self.assertNotIn('$<TARGET_FILE:Webview2>',(ROOT/'windows/CMakeLists.txt').read_text(encoding="utf-8"))

    def test_repository_text_is_explicit_utf8_under_legacy_locale(self):
        original = Path.read_text
        def legacy_read(path, encoding=None, errors=None):
            return original(path, encoding=encoding or 'cp1252', errors=errors)
        # Exercise the same production test entry, not just an encoding literal.
        with mock.patch.object(Path, 'read_text', legacy_read):
            self.test_mobile_source_matches_original_archive()
            self.test_pinned_dependency_and_retired_title_engine()
        # Fixed fixture guarantees a CP1252 failure independently of comments
        # in the production pubspec. Run the actual checker on that fixture.
        with tempfile.TemporaryDirectory(prefix='crisp-encoding-') as temp:
            fixture = Path(temp)
            for name, content in {
                'pubspec.yaml': 'desktop_webview_window: 0.4.0\n# 中文”\n',
                'plugins/crisp_chat/pubspec.yaml': 'desktop_webview_window: 0.4.0\n',
                'lib/main.dart': '// fixture\n',
                'windows/CMakeLists.txt': '# fixture\n',
            }.items():
                path = fixture/name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content, encoding='utf-8')
            with mock.patch.dict(self.test_pinned_dependency_and_retired_title_engine.__globals__, ROOT=fixture):
                with mock.patch.object(Path, 'read_text', legacy_read):
                    self.test_pinned_dependency_and_retired_title_engine()
                # Negative control: reproduce the old default-code-page read.
                with self.assertRaises(UnicodeDecodeError):
                    legacy_read(fixture/'pubspec.yaml')

    @unittest.skipUnless(os.environ.get('XBOARD_NATIVE_FOCUS_TEST') == '1','native focus test requires an explicitly authorized test host')
    def test_real_window_focus_rejects_invalid_and_destroyed_handles(self):
        with tempfile.TemporaryDirectory(prefix='crisp-focus-') as d:
            work=Path(d);src=work/'probe.cpp';exe=work/('probe.exe' if os.name=='nt' else 'probe')
            if os.name=='nt':
                header=ROOT/'plugins/window/windows/xboard_borrowed_focus.h'
                code = r'''#include "HEADER"
#include <cassert>
int main(){
 assert(!XboardFocusBorrowedWindow(0));
 assert(!XboardFocusBorrowedWindow(1));
 assert(!XboardFocusBorrowedWindow(reinterpret_cast<int64_t>(GetDesktopWindow())));
 HWND w=CreateWindowExW(0,L"STATIC",L"Crisp focus test",WS_OVERLAPPEDWINDOW,0,0,80,80,nullptr,nullptr,GetModuleHandleW(nullptr),nullptr);
 assert(w);auto handle=reinterpret_cast<int64_t>(w);
 assert(XboardFocusBorrowedWindow(handle));DestroyWindow(w);
 assert(!XboardFocusBorrowedWindow(handle));return 0;
}'''
                cmd=['cl','/nologo','/EHsc','/std:c++17',str(src),'/Fe:'+str(exe),'user32.lib']
                run=[str(exe)]
            else:
                header=ROOT/'plugins/window/linux/xboard_borrowed_focus.h'
                code=r'''#include "HEADER"
#include <cassert>
int main(int argc,char** argv){
 gtk_init(&argc,&argv);
 assert(!xboard_focus_borrowed_window(0));assert(!xboard_focus_borrowed_window(1));
 auto* w=gtk_window_new(GTK_WINDOW_TOPLEVEL);auto h=reinterpret_cast<int64_t>(w);
 assert(xboard_focus_borrowed_window(h));gtk_widget_destroy(w);
 assert(!xboard_focus_borrowed_window(h));return 0;
}'''
                flags=subprocess.check_output(['pkg-config','--cflags','--libs','gtk+-3.0'],text=True)
                cmd=['c++','-std=c++17',str(src),*shlex.split(flags),'-o',str(exe)]
                run=['xvfb-run','-a',str(exe)]
            src.write_text(code.replace('HEADER',header.as_posix()),encoding='utf-8')
            for command in (cmd,run):
                r=subprocess.run(command,cwd=work,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=60)
                self.assertEqual(r.returncode,0,r.stdout+r.stderr)

if __name__=='__main__':unittest.main(verbosity=2)
