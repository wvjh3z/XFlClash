"""Lightweight source invariants; native focus probes are explicit opt-in tests."""
from pathlib import Path
import hashlib,json,os,shlex,shutil,subprocess,tempfile,unittest
ROOT=Path(__file__).resolve().parents[2]

class CrispCompatibilityTests(unittest.TestCase):
    def test_mobile_source_matches_original_archive(self):
        root=ROOT/'plugins/crisp_chat'
        expected=json.loads((root/'upstream-mobile-sha256.json').read_text())
        actual={str(p.relative_to(root)).replace('\\','/'):hashlib.sha256(p.read_bytes()).hexdigest()
                for folder in ('android','ios') for p in (root/folder).rglob('*') if p.is_file()}
        self.assertEqual(actual,expected)

    def test_pinned_dependency_and_retired_title_engine(self):
        self.assertIn('desktop_webview_window: 0.4.0',(ROOT/'pubspec.yaml').read_text())
        self.assertIn('desktop_webview_window: 0.4.0',(ROOT/'plugins/crisp_chat/pubspec.yaml').read_text())
        self.assertNotIn('runWebViewTitleBarWidget',(ROOT/'lib/main.dart').read_text())
        self.assertNotIn('$<TARGET_FILE:Webview2>',(ROOT/'windows/CMakeLists.txt').read_text())

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
